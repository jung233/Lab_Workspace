"""Method-oriented JSON-RPC entry point for bundled CPython hosts.

The bridge accepts only JSON data for allowlisted calculations and explicitly
reviewed ROI samples. It has no file, shell, network, import-name, or source-code
execution method. Hosts must extract ROI samples from an immutable original
Asset snapshot before calling this module.
"""

from __future__ import annotations

import json
import sys
from typing import Any

from lab_workspace_calculation import (
    PRIMITIVES,
    CalculationError,
    OriginalRoiPixelSamples,
    Roi,
    RoiApproval,
    execute_approved_pack,
    quantify_original_roi_samples,
)


RPC_VERSION = "2.0"
MAX_REQUEST_BYTES = 32 * 1024 * 1024
MAX_ROI_PIXELS = 1_000_000
_LOGS: dict[str, list[str]] = {}


class MobileRpcError(ValueError):
    """A malformed JSON-RPC request or unsupported method."""


def _reject_float(value: str) -> Any:
    raise MobileRpcError("Decimal numeric JSON values are unsupported; use exact decimal strings")


def _error_code(message: str) -> str:
    prefix = message.split(":", 1)[0]
    if prefix.startswith(("CALC_", "IMAGE_")) and prefix.replace("_", "").isalnum():
        return prefix
    if "primitive" in message.lower() or "unsupported" in message.lower():
        return "CALC_PRIMITIVE_MISSING"
    return "CALC_EXECUTION_FAILED"


def _probe(runtime_target: str) -> dict[str, Any]:
    operations = sorted(PRIMITIVES)
    return {
        "executor_id": "trusted-python-mobile-v2",
        "available": True,
        "bundled_executor": True,
        "runtime": "trusted-python-mobile-v2",
        "python_runtime": sys.version.split()[0],
        "python_version": sys.version.split()[0],
        "platform": runtime_target,
        "supported_operations": operations,
        "operations": operations,
        "operation_build_versions": {
            operation: PRIMITIVES[operation].build_id for operation in sorted(PRIMITIVES)
        },
        "arbitrary_python_execution": False,
        "network_access": False,
        "filesystem_access": False,
        "supports_cancellation": False,
    }


def _execute(params: dict[str, Any], runtime_target: str) -> dict[str, Any]:
    job = params.get("job")
    if not isinstance(job, dict) or set(job) != {
        "job_id", "calculation_id", "trace_id", "pack", "inputs", "source_assets", "context"
    }:
        raise MobileRpcError("execute requires the typed CalculationJob contract")
    job_id = job["job_id"]
    calculation_id = job["calculation_id"]
    trace_id = job["trace_id"]
    if not all(isinstance(value, str) and value for value in (job_id, calculation_id, trace_id)):
        raise MobileRpcError("execute requires job, calculation, and trace identifiers")

    pack_envelope = job["pack"]
    if not isinstance(pack_envelope, dict) or set(pack_envelope) != {"document", "approval", "sha256"}:
        raise MobileRpcError("execute requires a frozen approved Pack envelope")
    document = pack_envelope["document"]
    approval = pack_envelope["approval"]
    pack_hash = pack_envelope["sha256"]
    inputs = job["inputs"]
    source_assets = job["source_assets"]
    context = job["context"]
    if not isinstance(document, dict) or not isinstance(approval, dict) or not isinstance(pack_hash, str):
        raise MobileRpcError("Pack envelope has invalid types")
    if set(approval) != {"approval_ref", "kind"}:
        raise MobileRpcError("Pack approval must contain only its reference and kind")
    if not isinstance(context, dict) or set(context) - {
        "run_id", "sample_id", "step_id", "parent_calculation_id", "ai_provenance"
    }:
        raise MobileRpcError("Calculation context contains unsupported fields")

    try:
        trace = execute_approved_pack(
            document,
            inputs,
            expected_pack_sha256=pack_hash,
            approval=approval,
            source_assets=source_assets,
            context=context,
            calculation_id=calculation_id,
            trace_id=trace_id,
            executor_id="trusted-python-mobile-v2",
            runtime_target=runtime_target,
        )
    except CalculationError as exc:
        return {
            "status": "failed",
            "calculation_id": calculation_id,
            "error_code": _error_code(str(exc)),
        }
    _LOGS[job_id] = [
        f"step {step['seq']}/{len(trace['steps'])}: {step['op']}"
        for step in trace["steps"]
    ]
    return {
        "status": "completed",
        "calculation_id": calculation_id,
        "outputs": trace["outputs"],
        "trace": trace,
    }


def _quantify_roi(params: dict[str, Any], runtime_target: str) -> dict[str, Any]:
    source = params.get("source")
    approval_json = params.get("approval")
    if not isinstance(source, dict) or not isinstance(approval_json, dict):
        raise MobileRpcError("quantifyRoi requires source and approval objects")
    if set(source) != {
        "asset_id", "sha256", "asset_kind", "immutable_original", "generated_pixels",
        "validation_level", "width", "height", "bit_depth", "channel_index", "channel_name",
        "signal_roi", "background_roi",
    }:
        raise MobileRpcError("quantifyRoi source does not match the typed original-Asset contract")
    if set(approval_json) != {
        "approval_ref", "approved", "source_asset_id", "source_sha256", "signal_roi",
        "background_roi", "channel_index", "channel_name", "approved_at_utc", "reviewer",
    }:
        raise MobileRpcError("quantifyRoi approval does not match the typed review contract")

    signal_pixels = params.get("signal_pixels")
    background_pixels = params.get("background_pixels", [])
    if not isinstance(signal_pixels, list) or not isinstance(background_pixels, list):
        raise MobileRpcError("quantifyRoi pixel values must be integer arrays")
    if len(signal_pixels) + len(background_pixels) > MAX_ROI_PIXELS:
        raise MobileRpcError("quantifyRoi selected pixels exceed the one-million-pixel limit")
    if any(isinstance(value, bool) or not isinstance(value, int)
           for value in signal_pixels + background_pixels):
        raise MobileRpcError("quantifyRoi pixel values must be integers")

    signal_roi = Roi.from_json(source["signal_roi"])
    background_roi = None if source["background_roi"] is None else Roi.from_json(source["background_roi"])
    approval_signal = Roi.from_json(approval_json["signal_roi"])
    approval_background = (
        None if approval_json["background_roi"] is None else Roi.from_json(approval_json["background_roi"])
    )
    if approval_signal != signal_roi or approval_background != background_roi:
        raise MobileRpcError("quantifyRoi geometry must exactly match the reviewed approval")

    samples = OriginalRoiPixelSamples(
        asset_id=source["asset_id"],
        sha256=source["sha256"],
        asset_kind=source["asset_kind"],
        immutable_original=source["immutable_original"],
        generated_pixels=source["generated_pixels"],
        validation_level=source["validation_level"],
        width=source["width"],
        height=source["height"],
        bit_depth=source["bit_depth"],
        channel_index=source["channel_index"],
        channel_name=source["channel_name"],
        signal_roi=signal_roi,
        background_roi=background_roi,
        signal_pixels=tuple(signal_pixels),
        background_pixels=tuple(background_pixels),
    )
    approval = RoiApproval(
        approval_ref=approval_json["approval_ref"],
        approved=approval_json["approved"],
        source_asset_id=approval_json["source_asset_id"],
        source_sha256=approval_json["source_sha256"],
        signal_roi=approval_signal,
        background_roi=approval_background,
        channel_index=approval_json["channel_index"],
        channel_name=approval_json["channel_name"],
        approved_at_utc=approval_json["approved_at_utc"],
        reviewer=approval_json["reviewer"],
    )
    context = params.get("context", {})
    if not isinstance(context, dict) or set(context) - {"run_id", "sample_id", "step_id", "ai_provenance"}:
        raise MobileRpcError("quantifyRoi context contains unsupported fields")
    calculation_id = params.get("calculation_id")
    job_id = params.get("job_id")
    trace_id = params.get("trace_id")
    if not isinstance(calculation_id, str) or not calculation_id or not isinstance(job_id, str) or not job_id:
        raise MobileRpcError("quantifyRoi requires calculation_id and job_id")
    if trace_id is not None and (not isinstance(trace_id, str) or not trace_id):
        raise MobileRpcError("quantifyRoi trace_id must be a non-empty string")
    try:
        trace = quantify_original_roi_samples(
            samples,
            approval,
            background_method=params.get("background_method"),
            run_id=context.get("run_id"),
            sample_id=context.get("sample_id"),
            step_id=context.get("step_id"),
            calculation_id=calculation_id,
            trace_id=trace_id,
            ai_provenance=context.get("ai_provenance"),
            runtime_target=runtime_target,
        )
    except CalculationError as exc:
        return {
            "status": "failed",
            "calculation_id": calculation_id,
            "error_code": _error_code(str(exc)),
        }
    _LOGS[job_id] = [step["op"] for step in trace["steps"]]
    return {
        "status": "completed",
        "calculation_id": calculation_id,
        "outputs": trace["outputs"],
        "trace": trace,
    }


def _dispatch(request: Any, runtime_target: str) -> dict[str, Any]:
    if not isinstance(request, dict) or request.get("jsonrpc") != RPC_VERSION:
        raise MobileRpcError("Request must be a JSON-RPC 2.0 object")
    method = request.get("method")
    params = request.get("params", {})
    if not isinstance(method, str) or not isinstance(params, dict):
        raise MobileRpcError("method and params have invalid types")
    if method == "probe":
        return _probe(runtime_target)
    if method == "execute":
        return _execute(params, runtime_target)
    if method == "quantifyRoi":
        return _quantify_roi(params, runtime_target)
    if method == "requestCancel":
        job_id = params.get("job_id")
        if not isinstance(job_id, str) or not job_id:
            raise MobileRpcError("requestCancel requires a job_id")
        return {"job_id": job_id, "accepted": False}
    if method == "getLogs":
        job_id = params.get("job_id")
        if not isinstance(job_id, str) or not job_id:
            raise MobileRpcError("getLogs requires a job_id")
        return {"job_id": job_id, "lines": list(_LOGS.get(job_id, []))}
    raise MobileRpcError("Unsupported mobile calculation method")


def handle_json(request_json: str, runtime_target: str | None = None) -> str:
    """Handle one bounded JSON-RPC request and return one JSON-RPC response."""
    if not isinstance(request_json, str) or len(request_json.encode("utf-8")) > MAX_REQUEST_BYTES:
        return json.dumps({
            "jsonrpc": RPC_VERSION,
            "id": None,
            "error": {"code": -32600, "message": "Request exceeds the typed JSON-RPC limit"},
        }, separators=(",", ":"))
    request: Any = None
    try:
        target = runtime_target or sys.platform
        if target not in {"android", "ios"}:
            raise MobileRpcError("Bundled mobile runtime target must be android or ios")
        request = json.loads(request_json, parse_float=_reject_float, parse_constant=_reject_float)
        request_id = request.get("id") if isinstance(request, dict) else None
        result = _dispatch(request, target)
        response = {"jsonrpc": RPC_VERSION, "id": request_id, "result": result}
    except (json.JSONDecodeError, MobileRpcError) as exc:
        request_id = request.get("id") if isinstance(request, dict) else None
        response = {
            "jsonrpc": RPC_VERSION,
            "id": request_id,
            "error": {"code": -32602, "message": str(exc)},
        }
    except CalculationError as exc:
        request_id = request.get("id") if isinstance(request, dict) else None
        response = {
            "jsonrpc": RPC_VERSION,
            "id": request_id,
            "result": {
                "status": "failed",
                "calculation_id": None,
                "error_code": _error_code(str(exc)),
            },
        }
    except Exception:
        request_id = request.get("id") if isinstance(request, dict) else None
        response = {
            "jsonrpc": RPC_VERSION,
            "id": request_id,
            "error": {"code": -32603, "message": "Trusted calculation runtime failed"},
        }
    return json.dumps(response, ensure_ascii=False, separators=(",", ":"), allow_nan=False)
