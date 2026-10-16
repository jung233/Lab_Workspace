#!/usr/bin/env python3
"""Regenerate the independent image ROI CalculationTrace v2 schema.

Run only when changing the image trace contract. This is separate from
build_schemas.py so rebuilding the shared contracts cannot overwrite its
image-specific raw-pixel, approval, and primitive-provenance requirements.
"""
from __future__ import annotations

import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1] / "contracts"
SHA = {"type": "string", "pattern": "^[a-f0-9]{64}$"}
NONEMPTY = {"type": "string", "minLength": 1}
NULLABLE_STRING = {"type": ["string", "null"]}


def obj(properties: dict, required: list[str]) -> dict:
    return {
        "type": "object",
        "additionalProperties": False,
        "properties": properties,
        "required": required,
    }


roi = obj(
    {
        "x": {"type": "integer", "minimum": 0},
        "y": {"type": "integer", "minimum": 0},
        "width": {"type": "integer", "minimum": 1},
        "height": {"type": "integer", "minimum": 1},
    },
    ["x", "y", "width", "height"],
)
result = obj(
    {
        "key": NONEMPTY,
        "value": NONEMPTY,
        "unit": NULLABLE_STRING,
        "source_ref": NONEMPTY,
    },
    ["key", "value", "unit", "source_ref"],
)
source_asset = obj(
    {"asset_id": NONEMPTY, "sha256": SHA, "validation_level": {"enum": ["verified"]}},
    ["asset_id", "sha256", "validation_level"],
)
engine = obj(
    {
        "executor_id": {"const": "trusted-original-pixel-arithmetic"},
        "python_version": NONEMPTY,
        "primitive_versions": {"type": "object", "additionalProperties": NONEMPTY},
        "primitive_code_sha256": {"type": "object", "additionalProperties": SHA},
        "platform": NONEMPTY,
    },
    ["executor_id", "python_version", "primitive_versions", "primitive_code_sha256", "platform"],
)
trace_input = obj(
    {
        "key": NONEMPTY,
        "value": NONEMPTY,
        "unit": NULLABLE_STRING,
        "source_ref": NULLABLE_STRING,
    },
    ["key", "value", "unit", "source_ref"],
)
step_result = obj(
    {
        "key": NONEMPTY,
        "value": {"type": ["string", "number", "integer"]},
        "unit": NULLABLE_STRING,
        "source_ref": NONEMPTY,
    },
    ["key", "value", "unit", "source_ref"],
)
step = obj(
    {
        "seq": {"type": "integer", "minimum": 1, "maximum": 2},
        "op": {"enum": ["image.compute_roi_pixels@1", "image.background_correct@1"]},
        "expression": NONEMPTY,
        "substitution": NONEMPTY,
        "inputs": {"type": "object"},
        "intermediates": {"type": "object"},
        "result": {"$ref": "#/$defs/result"},
        "results": {"type": "array", "minItems": 1, "maxItems": 1, "items": {"$ref": "#/$defs/result"}},
        "warnings": {"type": "array", "items": {"type": "string"}},
    },
    ["seq", "op", "expression", "substitution", "inputs", "intermediates", "result", "results", "warnings"],
)
quantification = obj(
    {
        "source_asset_kind": {"const": "raw"},
        "source_immutable": {"const": True},
        "generated_pixels_used": {"const": False},
        "source_sha256": SHA,
        "channel_index": {"type": "integer", "minimum": 0},
        "channel_name": NONEMPTY,
        "image_width": {"type": "integer", "minimum": 1},
        "image_height": {"type": "integer", "minimum": 1},
        "bit_depth": {"enum": [8, 16]},
        "page_index": {"type": "integer", "minimum": 0},
        "page_count": {"type": "integer", "minimum": 1},
        "signal_roi": {"$ref": "#/$defs/roi"},
        "background_roi": {"anyOf": [{"$ref": "#/$defs/roi"}, {"type": "null"}]},
        "background_method": {"enum": ["none", "mean_subtract"]},
        "approval_ref": NONEMPTY,
        "approved_at_utc": {"type": "string", "format": "date-time"},
        "reviewer": NONEMPTY,
    },
    [
        "source_asset_kind", "source_immutable", "generated_pixels_used", "source_sha256",
        "channel_index", "channel_name", "image_width", "image_height", "bit_depth",
        "page_index", "page_count", "signal_roi", "background_roi", "background_method",
        "approval_ref", "approved_at_utc", "reviewer",
    ],
)
ai_provenance_item = obj(
    {
        "source": {"enum": ["report_extraction", "model_suggestion", "tool_result"]},
        "tool_call_id": NULLABLE_STRING,
        "model_id": NULLABLE_STRING,
        "values": {"type": "object"},
        "confidence": NULLABLE_STRING,
        "user_confirmed": {"type": "boolean"},
        "confirmation_ref": NULLABLE_STRING,
        "confirmed_at_utc": NULLABLE_STRING,
    },
    ["source", "user_confirmed"],
)
execution_context = obj(
    {"run_id": NULLABLE_STRING, "sample_id": NULLABLE_STRING, "step_id": NULLABLE_STRING},
    [],
)

schema = {
    "$schema": "https://json-schema.org/draft/2020-12/schema",
    "$id": "https://labworkspace.local/contracts/image-calculation-trace-v2.schema.json",
    "title": "Lab Workspace image CalculationTrace v2",
    **obj(
        {
            "schema_version": {"const": "2.0"},
            "content_sha256": SHA,
            "trace_id": NONEMPTY,
            "calculation_id": NONEMPTY,
            "pack_ref": {"const": "lab-workspace.image-roi@1.0.0"},
            "engine": {"$ref": "#/$defs/engine"},
            "inputs": {"type": "array", "minItems": 4, "items": {"$ref": "#/$defs/input"}},
            "steps": {"type": "array", "minItems": 1, "maxItems": 2, "items": {"$ref": "#/$defs/step"}},
            "outputs": {"type": "array", "minItems": 1, "maxItems": 1, "items": {"$ref": "#/$defs/result"}},
            "user_confirmed": {"type": "boolean"},
            "source_assets": {"type": "array", "minItems": 1, "maxItems": 1, "items": {"$ref": "#/$defs/source_asset"}},
            "warnings": {"type": "array", "items": {"type": "string"}},
            "errors": {"type": "array", "items": {"type": "string"}},
            "created_at_utc": {"type": "string", "format": "date-time"},
            "primitive_build_versions": {"type": "object", "additionalProperties": NONEMPTY},
            "execution_context": {"$ref": "#/$defs/execution_context"},
            "ai_provenance": {"type": "array", "items": {"$ref": "#/$defs/ai_provenance_item"}},
            "recalculation_parent_id": NULLABLE_STRING,
            "approval": {"$ref": "#/$defs/approval"},
            "precision": {"$ref": "#/$defs/precision"},
            "execution_environment": {"$ref": "#/$defs/execution_environment"},
            "quantification_context": {"$ref": "#/$defs/quantification_context"},
        },
        [
            "schema_version", "content_sha256", "trace_id", "calculation_id", "pack_ref", "engine",
            "inputs", "steps", "outputs", "source_assets", "warnings", "errors", "user_confirmed",
            "created_at_utc", "primitive_build_versions", "execution_context", "ai_provenance",
            "recalculation_parent_id", "approval", "precision", "execution_environment", "quantification_context",
        ],
    ),
    "$defs": {
        "roi": roi,
        "result": result,
        "source_asset": source_asset,
        "engine": engine,
        "input": trace_input,
        "step": step,
        "approval": obj({"reference": NONEMPTY, "kind": {"const": "user_approval"}}, ["reference", "kind"]),
        "precision": obj(
            {"decimal_precision": {"type": "integer", "minimum": 1}, "rounding": NONEMPTY, "float_inputs_allowed": {"const": False}},
            ["decimal_precision", "rounding", "float_inputs_allowed"],
        ),
        "execution_environment": obj(
            {"runtime": NONEMPTY, "platform": NONEMPTY, "dependencies": {"type": "object", "additionalProperties": NONEMPTY}},
            ["runtime", "platform", "dependencies"],
        ),
        "execution_context": execution_context,
        "ai_provenance_item": ai_provenance_item,
        "quantification_context": quantification,
    },
}

(ROOT / "image-calculation-trace-v2.schema.json").write_text(
    json.dumps(schema, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
)
