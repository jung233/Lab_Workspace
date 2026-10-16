#!/usr/bin/env python3
"""JSON-RPC stdio adapter for approved declarative Calculation Packs.

Only the operations in ``lab_workspace_calculation.primitives`` are executable.
The process accepts JSON values and immutable Asset identifiers/hashes; it does
not accept paths, shell commands, module names, or user Python source.
"""

from __future__ import annotations

import json
import sys
import threading
from collections import deque
from concurrent.futures import Future, ThreadPoolExecutor
from pathlib import Path
from typing import Any

PYTHON_ROOT = Path(__file__).resolve().parents[1]
if str(PYTHON_ROOT) not in sys.path:
    sys.path.insert(0, str(PYTHON_ROOT))

from lab_workspace_calculation import PRIMITIVES, CalculationError, execute_approved_pack
from lab_workspace_calculation.pipeline import ExecutionControl
from lab_workspace_calculation.roi import (
    OriginalRoiPixelSamples,
    Roi,
    RoiApproval,
    quantify_original_roi_samples,
)


RPC_VERSION = "2.0"
MAX_LINE_BYTES = 32 * 1024 * 1024
MAX_LOG_LINES = 500
WORKERS = ThreadPoolExecutor(max_workers=2, thread_name_prefix="lab-calc")
OUTPUT_LOCK = threading.Lock()
JOBS_LOCK = threading.Lock()
JOB_CANCEL: dict[str, threading.Event] = {}
JOB_LOGS: dict[str, deque[str]] = {}


class RpcProtocolError(ValueError):
    pass


def _reject_float(value: str) -> Any:
    raise RpcProtocolError(f"JSON decimal number {value!r} is unsafe; send decimal strings")


def _write_response(response: dict[str, Any]) -> None:
    line = json.dumps(response, ensure_ascii=False, separators=(",", ":"), allow_nan=False)
    with OUTPUT_LOCK:
        sys.stdout.write(line + "\n")
        sys.stdout.flush()


def _error(request_id: Any, code: int, message: str) -> dict[str, Any]:
    return {"jsonrpc": RPC_VERSION, "id": request_id, "error": {"code": code, "message": message}}


def _method_probe() -> dict[str, Any]:
    return {
        "runtime": "trusted-python-stdlib-v2",
        "python_version": sys.version.split()[0],
        "platform": sys.platform,
        "operations": sorted(PRIMITIVES),
        "operation_build_versions": {key: PRIMITIVES[key].build_id for key in sorted(PRIMITIVES)},
        "arbitrary_python_execution": False,
        "network_access": False,
        "filesystem_access": False,
    }


def _run_job(job: dict[str, Any], cancel_event: threading.Event) -> dict[str, Any]:
    job_id = job.get("job_id")
    if not isinstance(job_id, str) or not job_id:
        raise CalculationError("CALC_JOB_ID_REQUIRED")
    pack_envelope = job.get("pack")
    if not isinstance(pack_envelope, dict):
        raise CalculationError("CALC_PACK_REQUIRED")
    document = pack_envelope.get("document")
    approval = pack_envelope.get("approval")
    pack_hash = pack_envelope.get("sha256")
    if not isinstance(document, dict) or not isinstance(approval, dict) or not isinstance(pack_hash, str):
        raise CalculationError("CALC_APPROVED_PACK_ENVELOPE_INVALID")
    inputs = job.get("inputs")
    assets = job.get("source_assets", [])
    context = job.get("context", {})
    if not isinstance(context, dict):
        raise CalculationError("CALC_CONTEXT_INVALID")
    with JOBS_LOCK:
        logs = JOB_LOGS.setdefault(job_id, deque(maxlen=MAX_LOG_LINES))

    trace = execute_approved_pack(
        document,
        inputs,
        expected_pack_sha256=pack_hash,
        approval=approval,
        source_assets=assets,
        context=context,
        calculation_id=job.get("calculation_id"),
        trace_id=job.get("trace_id"),
        executor_id="trusted-python-stdlib-v2",
        runtime_target="windows" if sys.platform in {"win32", "cygwin"} else sys.platform,
        control=ExecutionControl(cancelled=cancel_event.is_set, log=logs.append),
    )
    return {
        "status": "completed",
        "calculation_id": trace["calculation_id"],
        "outputs": trace["outputs"],
        "trace": trace,
    }


def _quantify_roi(params: dict[str, Any]) -> dict[str, Any]:
    """Accept only selected integer pixels for a user-approved original ROI."""
    source = params.get("source")
    approval_json = params.get("approval")
    if not isinstance(source, dict) or not isinstance(approval_json, dict):
        raise RpcProtocolError("quantifyRoi requires source and approval objects")
    allowed_source = {
        "asset_id", "sha256", "asset_kind", "immutable_original", "generated_pixels",
        "validation_level", "width", "height", "bit_depth", "channel_index", "channel_name",
        "signal_roi", "background_roi",
    }
    if set(source) != allowed_source:
        raise RpcProtocolError("quantifyRoi source fields do not match the typed contract")
    allowed_approval = {
        "approval_ref", "approved", "source_asset_id", "source_sha256", "signal_roi",
        "background_roi", "channel_index", "channel_name", "approved_at_utc", "reviewer",
    }
    if set(approval_json) != allowed_approval:
        raise RpcProtocolError("quantifyRoi approval fields do not match the typed contract")
    signal_pixels = params.get("signal_pixels")
    background_pixels = params.get("background_pixels", [])
    if not isinstance(signal_pixels, list) or not isinstance(background_pixels, list):
        raise RpcProtocolError("quantifyRoi pixels must be integer arrays")
    if len(signal_pixels) + len(background_pixels) > 1_000_000:
        raise RpcProtocolError("quantifyRoi selected pixels exceed the one-million-pixel RPC limit")
    if any(isinstance(value, bool) or not isinstance(value, int) for value in signal_pixels + background_pixels):
        raise RpcProtocolError("quantifyRoi pixels must be integers")
    signal_roi = Roi.from_json(source.get("signal_roi"))
    background_raw = source.get("background_roi")
    background_roi = None if background_raw is None else Roi.from_json(background_raw)
    approval_signal = Roi.from_json(approval_json.get("signal_roi"))
    approval_background_raw = approval_json.get("background_roi")
    approval_background = None if approval_background_raw is None else Roi.from_json(approval_background_raw)
    if approval_signal != signal_roi or approval_background != background_roi:
        raise RpcProtocolError("quantifyRoi geometry must exactly match the reviewed approval")

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
        raise RpcProtocolError("quantifyRoi context contains unsupported fields")
    calculation_id = params.get("calculation_id")
    job_id = params.get("job_id")
    if not isinstance(calculation_id, str) or not calculation_id or not isinstance(job_id, str) or not job_id:
        raise RpcProtocolError("quantifyRoi requires calculation_id and job_id")
    try:
        trace = quantify_original_roi_samples(
            samples,
            approval,
            background_method=params.get("background_method"),
            run_id=context.get("run_id"),
            sample_id=context.get("sample_id"),
            step_id=context.get("step_id"),
            calculation_id=calculation_id,
            trace_id=params.get("trace_id"),
            ai_provenance=context.get("ai_provenance"),
            runtime_target="windows" if sys.platform in {"win32", "cygwin"} else sys.platform,
        )
    except CalculationError as exc:
        message = str(exc)
        return {
            "status": "failed",
            "calculation_id": calculation_id,
            "error_code": _error_code(message),
        }
    return {
        "status": "completed",
        "calculation_id": calculation_id,
        "outputs": trace["outputs"],
        "trace": trace,
    }


def _complete(request_id: Any, job_id: str, future: Future[dict[str, Any]], cancel_event: threading.Event) -> None:
    try:
        result = future.result()
        _write_response({"jsonrpc": RPC_VERSION, "id": request_id, "result": result})
    except Exception as exc:
        message = str(exc)
        status = "cancelled" if cancel_event.is_set() or "CALC_CANCELLED" in message else "failed"
        _write_response({
            "jsonrpc": RPC_VERSION,
            "id": request_id,
            "result": {"status": status, "calculation_id": None, "error_code": _error_code(message), "message": message},
        })
    finally:
        with JOBS_LOCK:
            JOB_CANCEL.pop(job_id, None)


def _error_code(message: str) -> str:
    prefix = message.split(":", 1)[0]
    if prefix.startswith(("CALC_", "IMAGE_")) and prefix.replace("_", "").isalnum():
        return prefix
    if "unsupported" in message.lower() or "primitive" in message.lower():
        return "CALC_PRIMITIVE_MISSING"
    return "CALC_EXECUTION_FAILED"


def _dispatch(request: Any) -> None:
    if not isinstance(request, dict) or request.get("jsonrpc") != RPC_VERSION:
        raise RpcProtocolError("Request must be a JSON-RPC 2.0 object")
    request_id = request.get("id")
    method = request.get("method")
    params = request.get("params", {})
    if not isinstance(method, str) or not isinstance(params, dict):
        raise RpcProtocolError("method must be a string and params must be an object")
    if method == "probe":
        _write_response({"jsonrpc": RPC_VERSION, "id": request_id, "result": _method_probe()})
        return
    if method == "quantifyRoi":
        _write_response({"jsonrpc": RPC_VERSION, "id": request_id, "result": _quantify_roi(params)})
        return
    if method == "execute":
        job = params.get("job")
        if not isinstance(job, dict):
            raise RpcProtocolError("execute.params.job must be an object")
        job_id = job.get("job_id")
        if not isinstance(job_id, str) or not job_id:
            raise RpcProtocolError("execute job_id must be a non-empty string")
        with JOBS_LOCK:
            if job_id in JOB_CANCEL:
                raise RpcProtocolError("A job with this job_id is already active")
            cancel_event = threading.Event()
            JOB_CANCEL[job_id] = cancel_event
            JOB_LOGS[job_id] = deque(maxlen=MAX_LOG_LINES)
        future = WORKERS.submit(_run_job, job, cancel_event)
        future.add_done_callback(lambda done: _complete(request_id, job_id, done, cancel_event))
        return
    if method == "requestCancel":
        job_id = params.get("job_id")
        if not isinstance(job_id, str) or not job_id:
            raise RpcProtocolError("requestCancel requires job_id")
        with JOBS_LOCK:
            cancel_event = JOB_CANCEL.get(job_id)
            if cancel_event is not None:
                cancel_event.set()
        _write_response({"jsonrpc": RPC_VERSION, "id": request_id, "result": {"job_id": job_id, "accepted": cancel_event is not None}})
        return
    if method == "getLogs":
        job_id = params.get("job_id")
        if not isinstance(job_id, str) or not job_id:
            raise RpcProtocolError("getLogs requires job_id")
        with JOBS_LOCK:
            logs = list(JOB_LOGS.get(job_id, ()))
        _write_response({"jsonrpc": RPC_VERSION, "id": request_id, "result": {"job_id": job_id, "lines": logs}})
        return
    raise RpcProtocolError(f"Unsupported method: {method}")


def serve(stdin: Any = sys.stdin) -> None:
    for line in stdin:
        request: Any = None
        if len(line.encode("utf-8")) > MAX_LINE_BYTES:
            _write_response(_error(None, -32700, "Request exceeds the 32 MiB limit"))
            continue
        try:
            request = json.loads(line, parse_float=_reject_float, parse_constant=_reject_float)
            _dispatch(request)
        except json.JSONDecodeError as exc:
            _write_response(_error(None, -32700, f"Parse error at byte {exc.pos}"))
        except RpcProtocolError as exc:
            request_id = request.get("id") if isinstance(request, dict) else None
            _write_response(_error(request_id, -32600, str(exc)))
        except Exception as exc:
            request_id = request.get("id") if isinstance(request, dict) else None
            _write_response(_error(request_id, -32603, str(exc)))
    WORKERS.shutdown(wait=True, cancel_futures=False)


if __name__ == "__main__":
    serve()
