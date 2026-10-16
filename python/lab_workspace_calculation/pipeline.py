"""Strict declarative Calculation Pack validation and execution."""

from __future__ import annotations

import platform
import re
import sys
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from decimal import Decimal
from typing import Any, Callable

from .canonical import (
    CalculationError,
    calculation_pack_content_sha256,
    canonical_json,
    json_value,
)
from .decimal_support import (
    DECIMAL_PRECISION,
    ROUNDING_POLICY,
    calculation_decimal_text,
    subtract_calculation_decimals,
)
from .primitives import PRIMITIVES, PrimitiveResult, Quantity
from .units import conversion_factor, parse_unit
from .primitive_code_manifest import PYTHON_PACK_PRIMITIVE_CODE_SHA256
from .runtime_source_manifest import runtime_source_metadata


_PACK_ID = re.compile(r"^[a-z0-9][a-z0-9._-]*$")
_VERSION = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?$")
_REF = re.compile(r"^\$(inputs|steps)(?:\.[A-Za-z_][A-Za-z0-9_-]*)+$")
_SHA256 = re.compile(r"^[0-9a-f]{64}$")
_MAX_PIPELINE_STEPS = 512
_MAX_INPUT_BYTES = 32 * 1024 * 1024
_MAX_PACK_BYTES = 2 * 1024 * 1024


@dataclass(frozen=True)
class PackValidationReport:
    valid: bool
    errors: tuple[str, ...]
    warnings: tuple[str, ...]
    unsupported_operations: tuple[str, ...]
    requires_user_input: tuple[str, ...]
    content_sha256: str | None

    def to_json(self) -> dict[str, Any]:
        return {
            "valid": self.valid,
            "errors": list(self.errors),
            "warnings": list(self.warnings),
            "unsupported_operations": list(self.unsupported_operations),
            "requires_user_input": list(self.requires_user_input),
            "content_sha256": self.content_sha256,
        }


@dataclass(frozen=True)
class GoldenTestReport:
    passed: bool
    cases: tuple[dict[str, Any], ...]
    errors: tuple[str, ...]
    pack_sha256: str

    def to_json(self) -> dict[str, Any]:
        return {
            "passed": self.passed,
            "cases": list(self.cases),
            "errors": list(self.errors),
            "pack_sha256": self.pack_sha256,
        }


@dataclass
class ExecutionControl:
    cancelled: Callable[[], bool] = lambda: False
    log: Callable[[str], None] = lambda _line: None


_OUTPUT_KEYS: dict[str, frozenset[str]] = {
    "csv.parse_table@1": frozenset({"rows"}),
    "table.select@1": frozenset({"rows"}),
    "table.group_by@1": frozenset({"groups"}),
    "math.unit_convert@1": frozenset({"value"}),
    "stats.mean@1": frozenset({"value"}),
    "stats.sd@1": frozenset({"value"}),
    "stats.linear_regression@1": frozenset({"slope", "intercept", "r_squared", "min_x", "max_x"}),
    "bca.blank_adjust@1": frozenset({"standards"}),
    "math.linear_inverse@1": frozenset({"value"}),
    "math.subtract@1": frozenset({"value"}),
    "math.multiply@1": frozenset({"value"}),
    "math.divide@1": frozenset({"value"}),
    "data.qc_range@1": frozenset({"in_range"}),
    "data.qc_limits@1": frozenset({"in_range"}),
    "data.export_table@1": frozenset({"json"}),
    "wb.normalize_ratio@1": frozenset({"value", "ratio", "relative_ratio"}),
}


def _is_json_scalar(value: Any) -> bool:
    if value is None or isinstance(value, (str, bool, int)):
        return True
    return False


def _input_names(pack: dict[str, Any]) -> set[str]:
    return {item["key"] for item in pack.get("inputs", []) if isinstance(item, dict) and isinstance(item.get("key"), str)}


def _ref_parts(value: Any) -> list[str] | None:
    if not isinstance(value, str) or not value.startswith("$"):
        return None
    if not _REF.fullmatch(value):
        raise CalculationError(f"Invalid pipeline reference: {value}")
    return value[1:].split(".")


def validate_pack(
    pack: Any,
    *,
    allow_draft: bool = True,
    trusted_builtin: bool = False,
) -> PackValidationReport:
    """Validate the Calculation Pack v2 contract and execution graph.

    This validator deliberately understands only the fields used by the v2
    calculation contract and rejects unknown keys so a draft cannot smuggle
    executable behavior through extension fields.
    """
    errors: list[str] = []
    unsupported: list[str] = []
    requires_user_input: list[str] = []
    warnings: list[str] = []
    if not isinstance(pack, dict):
        return PackValidationReport(False, ("Pack must be a JSON object",), (), (), (), None)
    allowed_top = {
        "schema_version", "pack_id", "version", "kind", "status", "title", "inputs",
        "pipeline", "outputs", "quality_gates", "tests", "review",
    }
    extra = set(pack) - allowed_top
    if extra:
        errors.append(f"Unknown top-level fields: {', '.join(sorted(map(str, extra)))}")
    required_top = allowed_top
    missing = required_top - pack.keys()
    if missing:
        errors.append(f"Missing fields: {', '.join(sorted(missing))}")
    if pack.get("schema_version") != "2.0":
        errors.append("Unsupported Calculation Pack schema_version")
    if pack.get("kind") != "calculation":
        errors.append("kind must be calculation")
    if not isinstance(pack.get("pack_id"), str) or not _PACK_ID.fullmatch(pack.get("pack_id", "")):
        errors.append("pack_id is invalid")
    if not isinstance(pack.get("version"), str) or not _VERSION.fullmatch(pack.get("version", "")):
        errors.append("version must be a semantic version")
    if not isinstance(pack.get("title"), str) or not pack.get("title", "").strip():
        errors.append("title must be a non-empty string")
    status = pack.get("status")
    if status not in {"draft", "approved", "disabled"}:
        errors.append("status must be draft, approved, or disabled")
    review_block = pack.get("review")
    if not allow_draft:
        review_is_valid = isinstance(review_block, dict)
        if (
            status != "approved"
            or not review_is_valid
            or (not trusted_builtin and review_block.get("approved_by_user") is not True)
        ):
            errors.append("CALC_PACK_NOT_APPROVED: live calculations require an approved pack")

    inputs = pack.get("inputs")
    if not isinstance(inputs, list):
        errors.append("inputs must be an array")
        inputs = []
    seen_inputs: set[str] = set()
    input_allowed = {"key", "kind", "unit", "required"}
    valid_kinds = {"decimal", "integer", "text", "table", "asset_ref", "sample_ref", "boolean"}
    for index, definition in enumerate(inputs):
        path = f"inputs[{index}]"
        if not isinstance(definition, dict):
            errors.append(f"{path} must be an object")
            continue
        if set(definition) - input_allowed:
            errors.append(f"{path} contains unknown fields")
        key = definition.get("key")
        kind = definition.get("kind")
        if not isinstance(key, str) or not key:
            errors.append(f"{path}.key must be non-empty")
        elif key in seen_inputs:
            errors.append(f"Duplicate input key: {key}")
        else:
            seen_inputs.add(key)
        if kind not in valid_kinds:
            errors.append(f"{path}.kind is unsupported")
        if not isinstance(definition.get("required"), bool):
            errors.append(f"{path}.required must be boolean")
        if "unit" in definition and definition["unit"] is not None:
            if not isinstance(definition["unit"], str):
                errors.append(f"{path}.unit must be string or null")
            else:
                try:
                    parse_unit(definition["unit"])
                except CalculationError as exc:
                    errors.append(f"{path}: {exc}")

    pipeline = pack.get("pipeline")
    if not isinstance(pipeline, list) or not pipeline:
        errors.append("pipeline must be a non-empty array")
        pipeline = []
    if len(pipeline) > _MAX_PIPELINE_STEPS:
        errors.append(f"pipeline cannot exceed {_MAX_PIPELINE_STEPS} steps")
    step_ids: set[str] = set()
    prior_outputs: dict[str, frozenset[str]] = {}
    pipeline_allowed = {"step_id", "op", "inputs", "params"}
    for index, step in enumerate(pipeline):
        path = f"pipeline[{index}]"
        if not isinstance(step, dict):
            errors.append(f"{path} must be an object")
            continue
        if set(step) - pipeline_allowed:
            errors.append(f"{path} contains unknown fields")
        step_id, operation = step.get("step_id"), step.get("op")
        if not isinstance(step_id, str) or not step_id:
            errors.append(f"{path}.step_id must be non-empty")
            continue
        if step_id in step_ids:
            errors.append(f"Duplicate step_id: {step_id}")
            continue
        if not isinstance(operation, str) or operation not in PRIMITIVES:
            message = str(operation)
            unsupported.append(message)
            errors.append(f"CALC_PRIMITIVE_MISSING: {message}")
            step_ids.add(step_id)
            prior_outputs[step_id] = frozenset()
            continue
        step_ids.add(step_id)
        primitive = PRIMITIVES[operation]
        step_inputs, params = step.get("inputs"), step.get("params")
        if not isinstance(step_inputs, dict):
            errors.append(f"{path}.inputs must be an object")
            step_inputs = {}
        if not isinstance(params, dict):
            errors.append(f"{path}.params must be an object")
            params = {}
        # Validate references before operation input names; forward references
        # cannot be repaired by execution order and must remain explicit errors.
        for input_name, reference in step_inputs.items():
            if not isinstance(input_name, str):
                errors.append(f"{path}.inputs keys must be strings")
                continue
            try:
                parts = _ref_parts(reference)
            except CalculationError as exc:
                errors.append(f"{path}: {exc}")
                continue
            if parts is None:
                if not _is_json_scalar(reference):
                    errors.append(f"{path}.inputs.{input_name} must be a scalar or a safe reference")
                continue
            if parts[0] == "inputs":
                if parts[1] not in seen_inputs:
                    errors.append(f"{path} references undeclared input {parts[1]!r}")
            else:
                source_step = parts[1]
                if source_step not in prior_outputs:
                    errors.append(f"Forward or missing step reference: {reference}")
                elif len(parts) < 3 or parts[2] not in prior_outputs[source_step]:
                    errors.append(f"Reference has no declared output: {reference}")
        try:
            missing_inputs = primitive.required_inputs - step_inputs.keys()
            extra_inputs = step_inputs.keys() - primitive.required_inputs - primitive.optional_inputs
            extra_params = params.keys() - primitive.allowed_params
            if missing_inputs:
                errors.append(f"{path} missing primitive inputs: {', '.join(sorted(missing_inputs))}")
            if extra_inputs:
                errors.append(f"{path} has unsupported primitive inputs: {', '.join(sorted(extra_inputs))}")
            if extra_params:
                errors.append(f"{path} has unsupported params: {', '.join(sorted(extra_params))}")
            if operation == "math.unit_convert@1":
                source = params.get("from")
                target = params.get("to")
                if not isinstance(source, str) or not isinstance(target, str):
                    raise CalculationError("unit_convert requires string 'from' and 'to' units")
                expected = conversion_factor(source, target)
                if Decimal(str(params.get("factor", "NaN"))) != expected:
                    errors.append(f"{path}: unit conversion factor does not match registered units")
            if operation == "csv.parse_table@1" and "column_map" in params and not isinstance(params["column_map"], dict):
                errors.append(f"{path}: column_map must be an object")
        except (CalculationError, ArithmeticError, ValueError) as exc:
            errors.append(f"{path}: {exc}")
        prior_outputs[step_id] = _OUTPUT_KEYS[operation]

    outputs = pack.get("outputs")
    if not isinstance(outputs, list) or not outputs:
        errors.append("outputs must be a non-empty array")
        outputs = []
    output_keys: set[str] = set()
    for index, output in enumerate(outputs):
        path = f"outputs[{index}]"
        if not isinstance(output, dict) or set(output) != {"key", "from_ref", "unit"}:
            errors.append(f"{path} must contain only key, from_ref, and unit")
            continue
        key, from_ref, unit = output.get("key"), output.get("from_ref"), output.get("unit")
        if not isinstance(key, str) or not key or key in output_keys:
            errors.append(f"{path}.key must be a unique non-empty string")
        else:
            output_keys.add(key)
        try:
            parts = _ref_parts(from_ref)
            if parts is None or parts[0] != "steps" or len(parts) < 3:
                errors.append(f"{path}.from_ref must reference a step output")
            elif parts[1] not in prior_outputs or parts[2] not in prior_outputs[parts[1]]:
                errors.append(f"{path}.from_ref references an unknown output")
        except CalculationError as exc:
            errors.append(f"{path}: {exc}")
        if unit is not None:
            if not isinstance(unit, str):
                errors.append(f"{path}.unit must be string or null")
            else:
                try:
                    parse_unit(unit)
                except CalculationError as exc:
                    errors.append(f"{path}: {exc}")

    quality_gates = pack.get("quality_gates")
    if not isinstance(quality_gates, list):
        errors.append("quality_gates must be an array")
        quality_gates = []
    gate_ids: set[str] = set()
    for index, gate in enumerate(quality_gates):
        path = f"quality_gates[{index}]"
        if not isinstance(gate, dict) or set(gate) != {"id", "expression_ref", "severity", "message"}:
            errors.append(f"{path} has invalid fields")
            continue
        if not isinstance(gate.get("id"), str) or not gate.get("id") or gate["id"] in gate_ids:
            errors.append(f"{path}.id must be unique and non-empty")
        gate_ids.add(gate.get("id", ""))
        if gate.get("severity") not in {"warn", "block"} or not isinstance(gate.get("message"), str):
            errors.append(f"{path} has invalid severity or message")
        try:
            parts = _ref_parts(gate.get("expression_ref"))
            if parts is None or parts[0] != "steps" or len(parts) < 3:
                errors.append(f"{path}.expression_ref must reference a step output")
            elif parts[1] not in prior_outputs or parts[2] not in prior_outputs[parts[1]]:
                errors.append(f"{path}.expression_ref references an unknown output")
        except CalculationError as exc:
            errors.append(f"{path}: {exc}")

    fixtures = pack.get("tests")
    if not isinstance(fixtures, list) or not fixtures:
        errors.append("tests must contain at least one golden fixture")
        fixtures = []
    for index, fixture in enumerate(fixtures):
        if not isinstance(fixture, dict) or not {"name", "inputs", "expected"}.issubset(fixture):
            errors.append(f"tests[{index}] requires name, inputs, and expected")
        elif not isinstance(fixture.get("name"), str) or not isinstance(fixture.get("inputs"), dict) or not isinstance(fixture.get("expected"), dict):
            errors.append(f"tests[{index}] has invalid types")
    review = pack.get("review")
    if not isinstance(review, dict) or set(review) != {"approved_by_user", "warnings"}:
        errors.append("review must contain approved_by_user and warnings only")
    elif not isinstance(review.get("approved_by_user"), bool) or not isinstance(review.get("warnings"), list) or any(not isinstance(item, str) for item in review["warnings"]):
        errors.append("review fields have invalid types")

    try:
        encoded_pack = canonical_json(pack).encode("utf-8")
        if len(encoded_pack) > _MAX_PACK_BYTES:
            errors.append(f"Calculation Pack document exceeds the {_MAX_PACK_BYTES}-byte content limit")
            content_hash = None
        else:
            content_hash = calculation_pack_content_sha256(pack)
    except CalculationError as exc:
        errors.append(str(exc))
        content_hash = None
    warnings.extend(requires_user_input)
    return PackValidationReport(
        valid=not errors,
        errors=tuple(errors),
        warnings=tuple(warnings),
        unsupported_operations=tuple(dict.fromkeys(unsupported)),
        requires_user_input=tuple(requires_user_input),
        content_sha256=content_hash,
    )


def _resolve_reference(reference: Any, context: dict[str, Any]) -> Any:
    parts = _ref_parts(reference)
    if parts is None:
        return reference
    value: Any = context
    for part in parts:
        if not isinstance(value, dict) or part not in value:
            raise CalculationError(f"Missing or forward pipeline reference: {reference}")
        value = value[part]
    return value


def _input_snapshot(pack: dict[str, Any], values: Any) -> dict[str, Any]:
    if not isinstance(values, dict):
        raise CalculationError("Input snapshot must be an object")
    encoded = canonical_json(values).encode("utf-8")
    if len(encoded) > _MAX_INPUT_BYTES:
        raise CalculationError("Input snapshot exceeds 32 MiB")
    definitions = {item["key"]: item for item in pack["inputs"]}
    unknown = set(values) - definitions.keys()
    if unknown:
        raise CalculationError(f"Undeclared input keys: {', '.join(sorted(unknown))}")
    output: dict[str, Any] = {}
    for key, definition in definitions.items():
        if key not in values:
            if definition["required"]:
                raise CalculationError(f"Missing required input: {key}")
            continue
        value = values[key]
        kind = definition["kind"]
        if kind in {"decimal", "integer"}:
            if kind == "integer" and (isinstance(value, bool) or not isinstance(value, int)):
                raise CalculationError(f"Input {key!r} must be an integer")
            if kind == "decimal" and isinstance(value, (list, dict, bool, float)):
                raise CalculationError(f"Input {key!r} must be a decimal string or integer")
            output[key] = Quantity.of(value, definition.get("unit"))
        elif kind == "table":
            if not isinstance(value, list) or any(not isinstance(row, dict) for row in value):
                raise CalculationError(f"Input {key!r} must be an array of table rows")
            output[key] = value
        elif kind == "boolean":
            if not isinstance(value, bool):
                raise CalculationError(f"Input {key!r} must be boolean")
            output[key] = value
        elif kind in {"text", "asset_ref", "sample_ref"}:
            if not isinstance(value, str) or not value:
                raise CalculationError(f"Input {key!r} must be a non-empty string")
            output[key] = value
        else:
            raise CalculationError(f"Unsupported input kind: {kind}")
    return output


def _trace_value(value: Any) -> str | int | bool | None:
    if isinstance(value, Quantity):
        return calculation_decimal_text(value.value)
    if isinstance(value, Decimal):
        return calculation_decimal_text(value)
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (str, int)) or value is None:
        return value
    return canonical_json(value)


def _trace_input(value: Any) -> Any:
    if isinstance(value, Quantity):
        return calculation_decimal_text(value.value)
    if isinstance(value, (dict, list)):
        return canonical_json(value)
    if isinstance(value, bool):
        return "true" if value else "false"
    return _trace_value(value)


def _check_source_assets(assets: Any) -> list[dict[str, Any]]:
    if not isinstance(assets, list):
        raise CalculationError("source_assets must be an array")
    result = []
    seen: set[str] = set()
    for item in assets:
        if not isinstance(item, dict) or not isinstance(item.get("asset_id"), str) or not _SHA256.fullmatch(str(item.get("sha256", ""))):
            raise CalculationError("Each source asset requires asset_id and lowercase SHA-256")
        asset_id = item["asset_id"]
        if asset_id in seen:
            raise CalculationError(f"Duplicate source Asset ID: {asset_id}")
        seen.add(asset_id)
        validation_level = item.get("validation_level", "unknown")
        if validation_level not in {"verified", "quick_checked", "unknown"}:
            raise CalculationError(f"Unsupported source asset validation level: {validation_level}")
        result.append({
            "asset_id": asset_id,
            "sha256": item["sha256"],
            "validation_level": validation_level,
        })
    return result


def _execute_pipeline(
    pack: dict[str, Any],
    inputs: dict[str, Any],
    *,
    raw_input_snapshot: dict[str, Any] | None = None,
    calculation_id: str,
    trace_id: str,
    source_assets: list[dict[str, Any]],
    context_metadata: dict[str, Any],
    pack_sha256: str,
    approval: dict[str, Any],
    executor_id: str,
    execution_environment: dict[str, Any] | None = None,
    control: ExecutionControl | None = None,
) -> dict[str, Any]:
    control = control or ExecutionControl()
    context: dict[str, Any] = {"inputs": inputs, "steps": {}}
    step_traces: list[dict[str, Any]] = []
    used_ops: set[str] = set()
    warnings: list[str] = []
    for sequence, step in enumerate(pack["pipeline"], start=1):
        if control.cancelled():
            raise CalculationError("CALC_CANCELLED: calculation was cancelled")
        operation_id = step["op"]
        primitive = PRIMITIVES.get(operation_id)
        if primitive is None:
            raise CalculationError(f"CALC_PRIMITIVE_MISSING: {operation_id}")
        used_ops.add(operation_id)
        resolved = {key: _resolve_reference(value, context) for key, value in step["inputs"].items()}
        outcome: PrimitiveResult = primitive.invoke(resolved, step["params"])
        context["steps"][step["step_id"]] = outcome.values
        record = {
            "seq": sequence,
            "op": operation_id,
            "expression": outcome.expression,
            "substitution": outcome.substitution,
            "inputs": json_value(outcome.inputs),
            "intermediates": json_value(outcome.intermediates),
            "result": {
                "key": step["step_id"],
                "value": _trace_value(outcome.trace_value),
                "unit": outcome.trace_unit,
                "source_ref": None,
            },
            "warnings": list(outcome.warnings),
            "results": [
                {
                    "key": output_key,
                    "value": _trace_value(output_value),
                    "unit": output_value.unit.symbol if isinstance(output_value, Quantity) else None,
                    "source_ref": f"$steps.{step['step_id']}.{output_key}",
                }
                for output_key, output_value in sorted(outcome.values.items())
            ],
        }
        step_traces.append(record)
        warnings.extend(outcome.warnings)
        control.log(f"step {sequence}/{len(pack['pipeline'])}: {operation_id}")

    output_rows = []
    output_context: dict[str, Any] = {}
    for definition in pack["outputs"]:
        value = _resolve_reference(definition["from_ref"], context)
        requested_unit = definition.get("unit")
        if isinstance(value, Quantity) and requested_unit is not None:
            value = value.to_unit(requested_unit)
        output_context[definition["key"]] = value
        output_rows.append({
            "key": definition["key"],
            "value": _trace_value(value),
            "unit": value.unit.symbol if isinstance(value, Quantity) else requested_unit,
            "source_ref": definition["from_ref"],
        })

    for gate in pack["quality_gates"]:
        condition = _resolve_reference(gate["expression_ref"], context)
        if isinstance(condition, Quantity):
            condition = condition.value != 0
        if not condition:
            message = gate["message"]
            if gate["severity"] == "block":
                raise CalculationError(f"CALC_QUALITY_GATE_BLOCKED: {message}")
            warnings.append(message)

    input_units: dict[str, str | None] = {}
    for key, value in inputs.items():
        if isinstance(value, Quantity):
            unit = value.unit.symbol
        else:
            unit = None
        input_units[key] = unit
    input_records = []
    raw_input_snapshot = raw_input_snapshot or {}
    for key, value in inputs.items():
        source_ref = value if isinstance(value, str) and value in {item["asset_id"] for item in source_assets} else None
        raw_value = raw_input_snapshot.get(key)
        traced_input = (
            raw_value
            if isinstance(value, Quantity) and isinstance(raw_value, str)
            else _trace_input(value)
        )
        input_records.append({
            "key": key,
            "value": traced_input,
            "unit": input_units.get(key),
            "source_ref": source_ref,
        })
    primitive_versions = {operation: "1" for operation in sorted(used_ops)}
    primitive_build_versions = {
        operation: PRIMITIVES[operation].build_id for operation in sorted(used_ops)
    }
    primitive_code_sha256 = {
        operation: PYTHON_PACK_PRIMITIVE_CODE_SHA256
        for operation in sorted(used_ops)
    }
    return {
        "schema_version": "2.0",
        "trace_id": trace_id,
        "calculation_id": calculation_id,
        "pack_ref": f"{pack['pack_id']}@{pack['version']}",
        "engine": {
            "executor_id": executor_id,
            "python_version": sys.version.split()[0],
            "primitive_versions": primitive_versions,
            "primitive_code_sha256": primitive_code_sha256,
            "platform": platform.system(),
        },
        "inputs": input_records,
        "steps": step_traces,
        "outputs": output_rows,
        "source_assets": source_assets,
        "warnings": list(dict.fromkeys(warnings)),
        "user_confirmed": False,
        "created_at_utc": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "pack_sha256": pack_sha256,
        "primitive_build_versions": primitive_build_versions,
        "execution_context": {
            "run_id": context_metadata.get("run_id"),
            "sample_id": context_metadata.get("sample_id"),
            "step_id": context_metadata.get("step_id"),
        },
        "approval": {
            "reference": approval["approval_ref"],
            "kind": approval["kind"],
        },
        "ai_provenance": context_metadata.get("ai_provenance", []),
        "recalculation_parent_id": context_metadata.get("parent_calculation_id"),
        "precision": {
            "decimal_precision": DECIMAL_PRECISION,
            "rounding": ROUNDING_POLICY,
            "float_inputs_allowed": False,
        },
        "execution_environment": execution_environment or {
            "runtime": f"CPython {sys.version.split()[0]}",
            "platform": platform.system(),
            "dependencies": {"calculation_primitives": "lab-core-primitives-2.1"},
        },
    }


def execute_approved_pack(
    pack: Any,
    input_values: Any,
    *,
    expected_pack_sha256: str,
    approval: Any,
    source_assets: Any = (),
    context: Any = None,
    calculation_id: str | None = None,
    trace_id: str | None = None,
    executor_id: str = "trusted-python-stdlib",
    runtime_target: str | None = None,
    execution_environment: dict[str, Any] | None = None,
    control: ExecutionControl | None = None,
) -> dict[str, Any]:
    """Execute a frozen approved JSON Pack; arbitrary code is never accepted."""
    if not isinstance(approval, dict) or not isinstance(approval.get("approval_ref"), str) or not approval["approval_ref"]:
        raise CalculationError("CALC_PACK_APPROVAL_REQUIRED: approval reference is missing")
    if approval.get("kind") not in {"user_approval", "trusted_builtin"}:
        raise CalculationError("CALC_PACK_APPROVAL_REQUIRED: unsupported approval kind")
    report = validate_pack(
        pack,
        allow_draft=False,
        trusted_builtin=approval.get("kind") == "trusted_builtin",
    )
    if not report.valid:
        raise CalculationError("Pack validation failed: " + "; ".join(report.errors))
    if not _SHA256.fullmatch(expected_pack_sha256):
        raise CalculationError("expected_pack_sha256 must be lowercase SHA-256")
    actual_hash = calculation_pack_content_sha256(pack)
    if actual_hash != expected_pack_sha256:
        raise CalculationError("CALC_PACK_HASH_MISMATCH: frozen pack contents changed")
    normalized_inputs = _input_snapshot(pack, input_values)
    checked_assets = _check_source_assets(source_assets)
    metadata = dict(context or {})
    target = runtime_target or sys.platform
    if target in {"win32", "cygwin"}:
        target = "windows"
    elif target == "darwin":
        target = "macos"
    runtime_environment = {
        "runtime": f"CPython {sys.version.split()[0]}",
        "platform": platform.system(),
        "dependencies": {
            "calculation_primitives": "lab-core-primitives-2.1",
            **runtime_source_metadata(executor_id, target),
        },
    }
    if execution_environment is not None:
        runtime_environment = {
            **runtime_environment,
            **execution_environment,
            "dependencies": {
                **runtime_environment["dependencies"],
                **execution_environment.get("dependencies", {}),
            },
        }
    calc_id = calculation_id or str(uuid.uuid4())
    trace = _execute_pipeline(
        pack,
        normalized_inputs,
        raw_input_snapshot=input_values,
        calculation_id=calc_id,
        trace_id=trace_id or str(uuid.uuid4()),
        source_assets=checked_assets,
        context_metadata=metadata,
        pack_sha256=actual_hash,
        approval=approval,
        executor_id=executor_id,
        execution_environment=runtime_environment,
        control=control,
    )
    canonical_json(trace)  # Reject non-serializable or non-finite trace values.
    return trace


def run_golden_tests(pack: Any) -> GoldenTestReport:
    """Run a pack's declared synthetic fixtures when an explicit caller asks.

    This function is provided to Pack validation services. It is never invoked
    by importing the runtime, and callers must not treat a passing fixture as
    wet-lab or assay validation.
    """
    validation = validate_pack(pack, allow_draft=True)
    if not validation.valid:
        return GoldenTestReport(False, (), validation.errors, validation.content_sha256 or "")
    cases: list[dict[str, Any]] = []
    errors: list[str] = []
    for fixture in pack["tests"]:
        try:
            values = _input_snapshot(pack, fixture["inputs"])
            trace = _execute_pipeline(
                pack,
                values,
                raw_input_snapshot=fixture["inputs"],
                calculation_id="golden-test",
                trace_id="golden-test-trace",
                source_assets=[],
                context_metadata={},
                pack_sha256=validation.content_sha256 or "",
                approval={"approval_ref": "validation-only", "kind": "user_approval"},
                executor_id="golden-test-validation",
                execution_environment={
                    "runtime": "pack-golden-validation",
                    "platform": "host",
                    "dependencies": {"calculation_primitives": "lab-core-primitives-2.1"},
                },
            )
            actual = {item["key"]: item["value"] for item in trace["outputs"]}
            expected = fixture["expected"]
            tolerance = fixture.get("tolerance", {})
            passed_fields: dict[str, bool] = {}
            for key, expected_value in expected.items():
                if key not in actual:
                    passed_fields[key] = False
                    continue
                tol = Decimal(str(tolerance.get(key, "0")))
                try:
                    difference = subtract_calculation_decimals(
                        Decimal(str(actual[key])), Decimal(str(expected_value))
                    )
                    passed_fields[key] = abs(difference) <= tol
                except Exception:
                    passed_fields[key] = actual[key] == expected_value
            passed = all(passed_fields.values())
            if not passed:
                errors.append(f"Golden fixture {fixture['name']!r} did not match expected outputs")
            cases.append({"name": fixture["name"], "passed": passed, "actual": actual, "expected": expected, "fields": passed_fields})
        except Exception as exc:  # Fixture failures are returned as report data.
            errors.append(f"Golden fixture {fixture.get('name', '<unnamed>')!r}: {exc}")
            cases.append({"name": fixture.get("name"), "passed": False, "error": str(exc)})
    return GoldenTestReport(not errors and all(item["passed"] for item in cases), tuple(cases), tuple(errors), validation.content_sha256 or "")
