"""Isolated JSON-RPC worker for the official OpenAI Python SDK.

This module performs no work on import. Requests contain an ephemeral API key
and are never logged or persisted. The app owns consent, tool policy, and audit
decisions; this worker only makes the explicitly requested SDK call.
"""
from __future__ import annotations

import json
import sys
from typing import Any, Callable

_MAX_REQUEST_BYTES = 12 * 1024 * 1024
_SYNTHETIC_PNG = (
    "data:image/png;base64,"
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/"
    "lfoAAAAASUVORK5CYII="
)


def _sanitize_error(error: BaseException) -> dict[str, Any]:
    status = getattr(error, "status_code", None)
    if not isinstance(status, int):
        return {"ok": False, "code": "AI_SDK_REQUEST_FAILED", "status_code": None}
    if status == 401:
        code = "AI_AUTH_FAILED"
    elif status == 403:
        code = "AI_ACCESS_DENIED"
    elif status in (400, 404, 405, 422):
        code = "AI_CAPABILITY_OR_REQUEST_UNSUPPORTED"
    elif status == 429:
        code = "AI_RATE_LIMITED"
    else:
        code = "AI_PROVIDER_HTTP_ERROR"
    return {"ok": False, "code": code, "status_code": status}


def _jsonable(response: Any) -> dict[str, Any]:
    dump = getattr(response, "model_dump", None)
    if not callable(dump):
        raise TypeError("SDK response does not expose model_dump")
    value = dump(mode="json")
    if not isinstance(value, dict):
        raise TypeError("SDK response is not an object")
    # Round-trip through JSON to ensure no SDK objects escape the bridge.
    return json.loads(json.dumps(value, ensure_ascii=False, allow_nan=False))


def _client(api_key: str, base_url: str | None, timeout: int, sdk_factory: Callable[..., Any] | None):
    if sdk_factory is None:
        from openai import OpenAI

        sdk_factory = OpenAI
    options: dict[str, Any] = {"api_key": api_key, "timeout": timeout, "max_retries": 0}
    if base_url:
        options["base_url"] = base_url
    return sdk_factory(**options)


def execute_request(
    request: dict[str, Any], *, sdk_factory: Callable[..., Any] | None = None
) -> dict[str, Any]:
    """Execute one SDK request and return a safe, JSON-only result envelope."""
    mode = request.get("api_mode")
    api_key = request.get("api_key")
    body = request.get("body")
    timeout = request.get("timeout_seconds", 60)
    base_url = request.get("base_url")
    if mode not in ("responses", "chat_completions"):
        return {"ok": False, "code": "AI_API_MODE_INVALID"}
    if not isinstance(api_key, str) or not api_key or not isinstance(body, dict):
        return {"ok": False, "code": "AI_REQUEST_INVALID"}
    if not isinstance(timeout, int) or timeout < 1 or timeout > 300:
        return {"ok": False, "code": "AI_TIMEOUT_INVALID"}
    if base_url is not None and not isinstance(base_url, str):
        return {"ok": False, "code": "AI_BASE_URL_INVALID"}
    if base_url:
        from urllib.parse import urlsplit

        parsed = urlsplit(base_url)
        local = parsed.hostname in ("localhost", "127.0.0.1", "::1")
        if parsed.scheme != "https" and not (local and parsed.scheme == "http"):
            return {"ok": False, "code": "AI_HTTPS_REQUIRED"}
        if parsed.username or parsed.password:
            return {"ok": False, "code": "AI_BASE_URL_INVALID"}
    try:
        if len(json.dumps(body, ensure_ascii=False).encode("utf-8")) > _MAX_REQUEST_BYTES:
            return {"ok": False, "code": "AI_REQUEST_TOO_LARGE"}
        client = _client(api_key, base_url, timeout, sdk_factory)
        if mode == "responses":
            response = client.responses.create(**body)
        else:
            response = client.chat.completions.create(**body)
        return {"ok": True, "body": _jsonable(response)}
    except BaseException as error:  # redact SDK/provider messages; they can contain request data.
        return _sanitize_error(error)


def _probe_call(client: Any, mode: str, model: str, *, image: bool = False, tools: bool = False, json_schema: bool = False) -> bool | None:
    try:
        if mode == "responses":
            arguments: dict[str, Any] = {
                "model": model,
                "input": "Reply with the single word OK.",
                "max_output_tokens": 8,
                "store": False,
            }
            if tools:
                arguments["input"] = "Call the synthetic probe function."
                arguments["tools"] = [{
                    "type": "function", "name": "probe_echo", "description": "Synthetic capability probe",
                    "parameters": {"type": "object", "properties": {"ok": {"type": "boolean"}}, "required": ["ok"], "additionalProperties": False},
                    "strict": True,
                }]
            if json_schema:
                arguments["text"] = {"format": {"type": "json_schema", "name": "probe", "schema": {"type": "object", "properties": {"ok": {"type": "boolean"}}, "required": ["ok"], "additionalProperties": False}, "strict": True}}
            if image:
                arguments["input"] = [{"role": "user", "content": [
                    {"type": "input_text", "text": "Describe this synthetic one-pixel image in one word."},
                    {"type": "input_image", "image_url": _SYNTHETIC_PNG},
                ]}]
            client.responses.create(**arguments)
        else:
            message: dict[str, Any] = {"role": "user", "content": "Reply with the single word OK."}
            arguments = {"model": model, "messages": [message], "max_tokens": 8}
            if tools:
                message["content"] = "Call the synthetic probe function."
                arguments["tools"] = [{"type": "function", "function": {
                    "name": "probe_echo", "description": "Synthetic capability probe",
                    "parameters": {"type": "object", "properties": {"ok": {"type": "boolean"}}, "required": ["ok"], "additionalProperties": False},
                }}]
            if json_schema:
                arguments["response_format"] = {"type": "json_schema", "json_schema": {
                    "name": "probe", "strict": True,
                    "schema": {"type": "object", "properties": {"ok": {"type": "boolean"}}, "required": ["ok"], "additionalProperties": False},
                }}
            if image:
                message["content"] = [
                    {"type": "text", "text": "Describe this synthetic one-pixel image in one word."},
                    {"type": "image_url", "image_url": {"url": _SYNTHETIC_PNG}},
                ]
            client.chat.completions.create(**arguments)
        return True
    except BaseException as error:
        status = getattr(error, "status_code", None)
        return False if status in (400, 404, 405, 415, 422) else None


def probe_capabilities(
    request: dict[str, Any], *, sdk_factory: Callable[..., Any] | None = None
) -> dict[str, Any]:
    """Probe APIs with small synthetic prompts and a synthetic 1x1 PNG only.

    Probes may incur provider charges. Image editing is left unknown because a
    real edit request may create billable output and cannot be inferred from a
    text/vision probe.
    """
    api_key = request.get("api_key")
    model = request.get("model_id")
    base_url = request.get("base_url")
    timeout = request.get("timeout_seconds", 60)
    if not isinstance(api_key, str) or not api_key or not isinstance(model, str) or not model:
        return {"ok": False, "code": "AI_PROBE_REQUEST_INVALID"}
    if not isinstance(timeout, int) or timeout < 1 or timeout > 300:
        return {"ok": False, "code": "AI_TIMEOUT_INVALID"}
    if base_url is not None and not isinstance(base_url, str):
        return {"ok": False, "code": "AI_BASE_URL_INVALID"}
    if base_url:
        from urllib.parse import urlsplit

        parsed = urlsplit(base_url)
        local = parsed.hostname in ("localhost", "127.0.0.1", "::1")
        if parsed.scheme != "https" and not (local and parsed.scheme == "http"):
            return {"ok": False, "code": "AI_HTTPS_REQUIRED"}
        if parsed.username or parsed.password:
            return {"ok": False, "code": "AI_BASE_URL_INVALID"}
    try:
        client = _client(api_key, base_url, timeout, sdk_factory)
        responses = _probe_call(client, "responses", model)
        chat = _probe_call(client, "chat_completions", model)
        mode = request.get("api_mode")
        selected = "responses" if mode == "responses" else "chat_completions"
        tools = _probe_call(client, selected, model, tools=True) if (responses if selected == "responses" else chat) else None
        schema = _probe_call(client, selected, model, json_schema=True) if (responses if selected == "responses" else chat) else None
        vision = _probe_call(client, selected, model, image=True) if (responses if selected == "responses" else chat) else None
        return {"ok": True, "capabilities": {
            "responses": _state(responses),
            "chat_completions": _state(chat),
            "function_tools": _state(tools),
            "json_schema": _state(schema),
            "vision": _state(vision),
            "image_edit": "unknown",
            "streaming": "unknown",
        }}
    except BaseException as error:
        return _sanitize_error(error)


def _state(value: bool | None) -> str:
    return "supported" if value is True else "unsupported" if value is False else "unknown"


def handle_rpc(method: str, params: dict[str, Any]) -> dict[str, Any]:
    if method == "ai.self_test":
        try:
            import openai

            version = getattr(openai, "__version__", "unknown")
            return {"ok": True, "sdk": "openai", "version": str(version)}
        except BaseException:
            return {"ok": False, "code": "AI_OPENAI_SDK_UNAVAILABLE"}
    if method == "ai.request":
        return execute_request(params)
    if method == "ai.probe":
        return probe_capabilities(params)
    return {"ok": False, "code": "AI_RPC_METHOD_UNSUPPORTED"}


def serve(stdin: Any = sys.stdin, stdout: Any = sys.stdout) -> None:
    """Serve JSON-RPC lines. Never print diagnostics to stdout."""
    for line in stdin:
        try:
            if len(line.encode("utf-8")) > _MAX_REQUEST_BYTES:
                raise ValueError("request too large")
            request = json.loads(line)
            request_id = request.get("id")
            params = request.get("params")
            if not isinstance(params, dict):
                result = {"ok": False, "code": "AI_RPC_PARAMS_INVALID"}
            else:
                result = handle_rpc(str(request.get("method", "")), params)
            response = {"jsonrpc": "2.0", "id": request_id, "result": result}
        except BaseException:
            response = {"jsonrpc": "2.0", "id": None, "result": {"ok": False, "code": "AI_RPC_REQUEST_INVALID"}}
        stdout.write(json.dumps(response, ensure_ascii=False, allow_nan=False) + "\n")
        stdout.flush()


if __name__ == "__main__":
    serve()
