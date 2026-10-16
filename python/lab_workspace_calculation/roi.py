"""Deterministic arithmetic over explicitly approved ROIs on original pixels.

This module does not decode images, find bands, segment cells, or propose ROIs.
The caller must obtain the pixel plane from an immutable original Asset through
the app-owned AssetGateway and supply the exact human-reviewed ROI approval.
"""

from __future__ import annotations

import re
import hashlib
import platform
import sys
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from decimal import Decimal
from typing import Any, Sequence

from .canonical import CalculationError, canonical_json, json_value
from .decimal_support import (
    DECIMAL_PRECISION,
    ROUNDING_POLICY,
    calculation_decimal_text,
    divide_calculation_decimals,
    multiply_calculation_decimals,
    subtract_calculation_decimals,
)
from .primitive_code_manifest import IMAGE_ROI_PRIMITIVE_CODE_SHA256
from .runtime_source_manifest import runtime_source_metadata
from .units import parse_unit

_SHA256 = re.compile(r"^[0-9a-f]{64}$")


@dataclass(frozen=True)
class Roi:
    x: int
    y: int
    width: int
    height: int

    @classmethod
    def from_json(cls, value: Any) -> "Roi":
        if not isinstance(value, dict) or set(value) != {"x", "y", "width", "height"}:
            raise CalculationError("ROI must contain integer x, y, width, and height")
        if any(isinstance(value[key], bool) or not isinstance(value[key], int) for key in value):
            raise CalculationError("ROI geometry values must be integers")
        roi = cls(value["x"], value["y"], value["width"], value["height"])
        if roi.x < 0 or roi.y < 0 or roi.width <= 0 or roi.height <= 0:
            raise CalculationError("ROI must have a non-negative origin and positive dimensions")
        return roi

    def to_json(self) -> dict[str, int]:
        return {"x": self.x, "y": self.y, "width": self.width, "height": self.height}

    @property
    def pixel_count(self) -> int:
        return self.width * self.height

    def validate_bounds(self, width: int, height: int) -> None:
        if self.x + self.width > width or self.y + self.height > height:
            raise CalculationError("IMAGE_ROI_OUT_OF_BOUNDS")


@dataclass(frozen=True)
class OriginalPixelPlane:
    """A single channel copied from the AssetGateway's immutable source view."""

    asset_id: str
    sha256: str
    asset_kind: str
    immutable_original: bool
    generated_pixels: bool
    validation_level: str
    width: int
    height: int
    bit_depth: int
    channel_index: int
    channel_name: str
    pixels: Sequence[int]

    def validate(self) -> None:
        if not isinstance(self.asset_id, str) or not self.asset_id or not isinstance(self.sha256, str) or not _SHA256.fullmatch(self.sha256):
            raise CalculationError("ROI source requires Asset ID and original SHA-256")
        if (
            self.asset_kind != "raw"
            or self.immutable_original is not True
            or self.generated_pixels is not False
        ):
            raise CalculationError("IMAGE_ORIGINAL_REQUIRED: quantification requires immutable raw Asset pixels")
        if not isinstance(self.validation_level, str) or self.validation_level not in {"verified", "quick_checked"}:
            raise CalculationError("IMAGE_SOURCE_INTEGRITY_REQUIRED")
        if self.validation_level == "quick_checked":
            # A metadata check is not a cryptographic assertion. The retained
            # import SHA still anchors lineage, while UI can show this warning.
            pass
        if (
            isinstance(self.width, bool)
            or not isinstance(self.width, int)
            or isinstance(self.height, bool)
            or not isinstance(self.height, int)
            or self.width <= 0
            or self.height <= 0
            or self.width * self.height > 20_000_000
        ):
            raise CalculationError("Image dimensions are invalid or exceed the bounded pixel arithmetic limit")
        if isinstance(self.bit_depth, bool) or not isinstance(self.bit_depth, int) or self.bit_depth < 1 or self.bit_depth > 32:
            raise CalculationError("Pixel bit depth must be between 1 and 32")
        if isinstance(self.channel_index, bool) or not isinstance(self.channel_index, int) or self.channel_index < 0 or not isinstance(self.channel_name, str) or not self.channel_name.strip():
            raise CalculationError("Pixel channel selection is invalid")
        if not isinstance(self.pixels, tuple):
            raise CalculationError("Pixel values must be an immutable tuple from the original Asset snapshot")
        if len(self.pixels) != self.width * self.height:
            raise CalculationError("Pixel plane length does not match the original image dimensions")
        maximum = (1 << self.bit_depth) - 1
        for value in self.pixels:
            if isinstance(value, bool) or not isinstance(value, int) or value < 0 or value > maximum:
                raise CalculationError("Pixel values must be integers within the declared bit depth")

    def values_in(self, roi: Roi) -> list[int]:
        roi.validate_bounds(self.width, self.height)
        values: list[int] = []
        for y in range(roi.y, roi.y + roi.height):
            start = y * self.width + roi.x
            values.extend(self.pixels[start : start + roi.width])
        return values


@dataclass(frozen=True)
class RoiApproval:
    approval_ref: str
    approved: bool
    source_asset_id: str
    source_sha256: str
    signal_roi: Roi
    background_roi: Roi | None
    channel_index: int
    channel_name: str
    approved_at_utc: str
    reviewer: str = "local_user"

    def validate(self) -> None:
        if self.approved is not True or not isinstance(self.approval_ref, str) or not self.approval_ref:
            raise CalculationError("IMAGE_ROI_REVIEW_REQUIRED")
        if not isinstance(self.source_asset_id, str) or not self.source_asset_id:
            raise CalculationError("ROI approval must bind an Asset ID")
        if not isinstance(self.source_sha256, str) or not _SHA256.fullmatch(self.source_sha256):
            raise CalculationError("ROI approval must bind an original SHA-256")
        if not isinstance(self.reviewer, str) or not self.reviewer.strip():
            raise CalculationError("ROI approval reviewer is required")
        if isinstance(self.channel_index, bool) or not isinstance(self.channel_index, int) or self.channel_index < 0:
            raise CalculationError("ROI approval channel index is invalid")
        if not isinstance(self.channel_name, str) or not self.channel_name.strip():
            raise CalculationError("ROI approval channel name is required")
        if not isinstance(self.approved_at_utc, str) or not self.approved_at_utc:
            raise CalculationError("ROI approval time must be an ISO-8601 timestamp")
        try:
            approved_at = datetime.fromisoformat(self.approved_at_utc.replace("Z", "+00:00"))
        except ValueError as exc:
            raise CalculationError("ROI approval time must be an ISO-8601 timestamp") from exc
        if approved_at.tzinfo is None or approved_at.utcoffset() is None or approved_at.utcoffset().total_seconds() != 0:
            raise CalculationError("ROI approval time must be expressed in UTC")


@dataclass(frozen=True)
class OriginalRoiPixelSamples:
    """Read-only integer samples extracted from explicitly approved ROIs.

    The host must bind these samples to an immutable AssetGateway snapshot
    before calling this arithmetic boundary; no image path or decoder is used.
    """

    asset_id: str
    sha256: str
    asset_kind: str
    immutable_original: bool
    generated_pixels: bool
    validation_level: str
    width: int
    height: int
    bit_depth: int
    channel_index: int
    channel_name: str
    signal_roi: Roi
    background_roi: Roi | None
    signal_pixels: tuple[int, ...]
    background_pixels: tuple[int, ...] = ()

    def validate(self) -> None:
        if not isinstance(self.asset_id, str) or not self.asset_id or not isinstance(self.sha256, str) or not _SHA256.fullmatch(self.sha256):
            raise CalculationError("ROI source requires Asset ID and original SHA-256")
        if (
            self.asset_kind != "raw"
            or self.immutable_original is not True
            or self.generated_pixels is not False
        ):
            raise CalculationError("IMAGE_ORIGINAL_REQUIRED: quantification requires immutable raw Asset pixels")
        if not isinstance(self.validation_level, str) or self.validation_level not in {"verified", "quick_checked"}:
            raise CalculationError("IMAGE_SOURCE_INTEGRITY_REQUIRED")
        if (
            isinstance(self.width, bool)
            or not isinstance(self.width, int)
            or isinstance(self.height, bool)
            or not isinstance(self.height, int)
            or self.width <= 0
            or self.height <= 0
            or self.width * self.height > 20_000_000
        ):
            raise CalculationError("Image dimensions are invalid or exceed the bounded pixel arithmetic limit")
        if isinstance(self.bit_depth, bool) or not isinstance(self.bit_depth, int) or self.bit_depth < 1 or self.bit_depth > 32:
            raise CalculationError("Pixel bit depth must be between 1 and 32")
        if isinstance(self.channel_index, bool) or not isinstance(self.channel_index, int) or self.channel_index < 0 or not isinstance(self.channel_name, str) or not self.channel_name.strip():
            raise CalculationError("Pixel channel selection is invalid")
        self.signal_roi.validate_bounds(self.width, self.height)
        if self.background_roi is not None:
            self.background_roi.validate_bounds(self.width, self.height)
            if _overlaps(self.signal_roi, self.background_roi):
                raise CalculationError("IMAGE_ROI_OVERLAP: signal and background ROIs must not overlap")
        if not isinstance(self.signal_pixels, tuple) or not isinstance(self.background_pixels, tuple):
            raise CalculationError("Selected ROI pixel values must be immutable tuples")
        if len(self.signal_pixels) + len(self.background_pixels) > 1_000_000:
            raise CalculationError("Selected ROI pixels exceed the one-million-pixel arithmetic limit")
        if len(self.signal_pixels) != self.signal_roi.pixel_count:
            raise CalculationError("Signal pixel count does not match the approved ROI")
        expected_background = self.background_roi.pixel_count if self.background_roi is not None else 0
        if len(self.background_pixels) != expected_background:
            raise CalculationError("Background pixel count does not match the approved ROI")
        maximum = (1 << self.bit_depth) - 1
        for value in self.signal_pixels + self.background_pixels:
            if isinstance(value, bool) or not isinstance(value, int) or value < 0 or value > maximum:
                raise CalculationError("Pixel values must be integers within the declared bit depth")


def _sum_roi(plane: OriginalPixelPlane, roi: Roi) -> tuple[int, Decimal, list[int]]:
    values = plane.values_in(roi)
    total = sum(values)
    return total, divide_calculation_decimals(Decimal(total), Decimal(roi.pixel_count)), values


def _overlaps(left: Roi, right: Roi) -> bool:
    return (
        left.x < right.x + right.width
        and right.x < left.x + left.width
        and left.y < right.y + right.height
        and right.y < left.y + left.height
    )


def quantify_original_roi(
    plane: OriginalPixelPlane,
    approval: RoiApproval,
    *,
    background_method: str,
    run_id: str | None = None,
    sample_id: str | None = None,
    step_id: str | None = None,
    calculation_id: str | None = None,
    trace_id: str | None = None,
    ai_provenance: list[dict[str, Any]] | None = None,
    runtime_target: str | None = None,
) -> dict[str, Any]:
    """Compute integrated density from one reviewed signal ROI.

    Supported methods are explicitly limited to `none` and area-adjusted mean
    background subtraction. The latter computes ``sum(signal) -
    mean(background) * signal_pixel_count``. It does not clamp negative values.
    """
    plane.validate()
    samples = OriginalRoiPixelSamples(
        asset_id=plane.asset_id,
        sha256=plane.sha256,
        asset_kind=plane.asset_kind,
        immutable_original=plane.immutable_original,
        generated_pixels=plane.generated_pixels,
        validation_level=plane.validation_level,
        width=plane.width,
        height=plane.height,
        bit_depth=plane.bit_depth,
        channel_index=plane.channel_index,
        channel_name=plane.channel_name,
        signal_roi=approval.signal_roi,
        background_roi=approval.background_roi,
        signal_pixels=tuple(plane.values_in(approval.signal_roi)),
        background_pixels=(
            tuple(plane.values_in(approval.background_roi))
            if approval.background_roi is not None
            else ()
        ),
    )
    return quantify_original_roi_samples(
        samples,
        approval,
        background_method=background_method,
        run_id=run_id,
        sample_id=sample_id,
        step_id=step_id,
        calculation_id=calculation_id,
        trace_id=trace_id,
        ai_provenance=ai_provenance,
        runtime_target=runtime_target,
    )


def quantify_original_roi_samples(
    samples: OriginalRoiPixelSamples,
    approval: RoiApproval,
    *,
    background_method: str,
    run_id: str | None = None,
    sample_id: str | None = None,
    step_id: str | None = None,
    calculation_id: str | None = None,
    trace_id: str | None = None,
    ai_provenance: list[dict[str, Any]] | None = None,
    runtime_target: str | None = None,
) -> dict[str, Any]:
    """Run deterministic ROI arithmetic on selected original-source pixels."""
    samples.validate()
    approval.validate()
    if approval.source_asset_id != samples.asset_id or approval.source_sha256 != samples.sha256:
        raise CalculationError("IMAGE_ROI_APPROVAL_SOURCE_MISMATCH")
    if approval.channel_index != samples.channel_index or approval.channel_name != samples.channel_name:
        raise CalculationError("IMAGE_ROI_APPROVAL_CHANNEL_MISMATCH")
    if approval.signal_roi != samples.signal_roi or approval.background_roi != samples.background_roi:
        raise CalculationError("IMAGE_ROI_APPROVAL_GEOMETRY_MISMATCH")
    if not isinstance(background_method, str) or background_method not in {"none", "mean_subtract"}:
        raise CalculationError("Unsupported ROI background method")
    if background_method == "mean_subtract" and samples.background_roi is None:
        raise CalculationError("IMAGE_ROI_REVIEW_REQUIRED: mean subtraction needs an approved background ROI")
    _validate_ai_provenance(ai_provenance)

    signal_sum = sum(samples.signal_pixels)
    signal_mean = divide_calculation_decimals(
        Decimal(signal_sum), Decimal(len(samples.signal_pixels))
    )
    signal_hash = hashlib.sha256(canonical_json(list(samples.signal_pixels)).encode("utf-8")).hexdigest()
    background_sum: int | None = None
    background_mean: Decimal | None = None
    background_hash: str | None = None
    integrated = Decimal(signal_sum)
    steps = [{
        "seq": 1,
        "op": "image.compute_roi_pixels@1",
        "expression": "signal_sum = sum(original_pixel_values inside the approved signal ROI)",
        "substitution": f"sum({len(samples.signal_pixels)} pixels; values_sha256={signal_hash}) = {signal_sum}",
        "inputs": {
            "asset_id": samples.asset_id,
            "source_sha256": samples.sha256,
            "signal_roi": samples.signal_roi.to_json(),
            "channel_index": samples.channel_index,
            "channel_name": samples.channel_name,
            "pixel_count": samples.signal_roi.pixel_count,
            "bit_depth": samples.bit_depth,
            "pixel_values_sha256": signal_hash,
        },
        "intermediates": {"signal_sum": signal_sum, "signal_mean": signal_mean},
        "result": {"key": "signal_integrated_density", "value": str(signal_sum), "unit": "intensity*pixel^2", "source_ref": samples.asset_id},
        "warnings": [],
        "results": [{"key": "signal_integrated_density", "value": str(signal_sum), "unit": "intensity*pixel^2", "source_ref": samples.asset_id}],
    }]
    if background_method == "mean_subtract":
        background_sum = sum(samples.background_pixels)
        background_mean = divide_calculation_decimals(
            Decimal(background_sum), Decimal(len(samples.background_pixels))
        )
        background_hash = hashlib.sha256(canonical_json(list(samples.background_pixels)).encode("utf-8")).hexdigest()
        background_total = multiply_calculation_decimals(
            background_mean, Decimal(samples.signal_roi.pixel_count)
        )
        integrated = subtract_calculation_decimals(Decimal(signal_sum), background_total)
        steps.append({
            "seq": 2,
            "op": "image.background_correct@1",
            "expression": "corrected_integrated_density = signal_sum - mean(background_pixels) * signal_pixel_count",
            "substitution": (
                f"{signal_sum} - ({background_sum}/{len(samples.background_pixels)})*"
                f"{samples.signal_roi.pixel_count} = {calculation_decimal_text(integrated)}"
            ),
            "inputs": {
                "signal_sum": signal_sum,
                "signal_pixel_count": samples.signal_roi.pixel_count,
                "background_roi": samples.background_roi.to_json(),
                "background_pixel_count": len(samples.background_pixels),
                "background_pixel_values_sha256": background_hash,
            },
            "intermediates": {
                "background_sum": background_sum,
                "background_mean": background_mean,
                "background_total": background_total,
                "signal_pixel_count": samples.signal_roi.pixel_count,
                "background_corrected_integrated_density": integrated,
            },
            "result": {"key": "background_corrected_integrated_density", "value": calculation_decimal_text(integrated), "unit": "intensity*pixel^2", "source_ref": samples.asset_id},
            "warnings": [],
            "results": [{"key": "background_corrected_integrated_density", "value": calculation_decimal_text(integrated), "unit": "intensity*pixel^2", "source_ref": samples.asset_id}],
        })

    warnings: list[str] = []
    maximum = (1 << samples.bit_depth) - 1
    if maximum in samples.signal_pixels or maximum in samples.background_pixels:
        warnings.append("ROI contains values at the declared maximum; saturation is possible")
    if samples.validation_level == "quick_checked":
        warnings.append("Source access used metadata quick check; it is not a full SHA-256 verification")
    if background_method == "none":
        warnings.append("No background subtraction was applied; use the experiment SOP to choose a method")
    warnings.append("ROI intensity has no acquisition calibration; compare only under compatible imaging conditions")

    calc_id = calculation_id or str(uuid.uuid4())
    resolved_trace_id = trace_id or str(uuid.uuid4())
    now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
    resolved_runtime_target = runtime_target or sys.platform
    runtime_executor_id = (
        "trusted-python-mobile-v2"
        if resolved_runtime_target in {"android", "ios"}
        else "trusted-python-stdlib-v2"
    )
    output_source_ref = (
        "$steps.2.background_corrected_integrated_density"
        if background_method == "mean_subtract"
        else "$steps.1.signal_integrated_density"
    )
    trace = {
        "schema_version": "2.0",
        "trace_id": resolved_trace_id,
        "calculation_id": calc_id,
        "pack_ref": "lab-workspace.image-roi@1.0.0",
        "engine": {
            "executor_id": "trusted-original-pixel-arithmetic",
            "python_version": sys.version.split()[0],
            "primitive_versions": {
                "image.compute_roi_pixels@1": "1",
                **({"image.background_correct@1": "1"} if background_method == "mean_subtract" else {}),
            },
            "primitive_code_sha256": {
                "image.compute_roi_pixels@1": IMAGE_ROI_PRIMITIVE_CODE_SHA256,
                **(
                    {"image.background_correct@1": IMAGE_ROI_PRIMITIVE_CODE_SHA256}
                    if background_method == "mean_subtract"
                    else {}
                ),
            },
            "platform": platform.system(),
        },
        "inputs": [
            {"key": "source_asset_id", "value": samples.asset_id, "unit": None, "source_ref": samples.asset_id},
            {"key": "source_sha256", "value": samples.sha256, "unit": None, "source_ref": samples.asset_id},
            {"key": "signal_roi", "value": canonical_json(approval.signal_roi.to_json()), "unit": None, "source_ref": approval.approval_ref},
            {"key": "channel", "value": samples.channel_name, "unit": None, "source_ref": approval.approval_ref},
        ],
        "steps": steps,
        "outputs": [{"key": "integrated_density", "value": calculation_decimal_text(integrated), "unit": "intensity*pixel^2", "source_ref": output_source_ref}],
        "source_assets": [{"asset_id": samples.asset_id, "sha256": samples.sha256, "validation_level": samples.validation_level}],
        "warnings": warnings,
        "user_confirmed": False,
        "created_at_utc": now,
        "primitive_build_versions": {
            "image.compute_roi_pixels@1": "lab-core-primitives-2.1",
            **({"image.background_correct@1": "lab-core-primitives-2.1"} if background_method == "mean_subtract" else {}),
        },
        "execution_context": {"run_id": run_id, "sample_id": sample_id, "step_id": step_id},
        "approval": {"reference": approval.approval_ref, "kind": "user_approval"},
        "ai_provenance": ai_provenance or [],
        "recalculation_parent_id": None,
        "precision": {
            "decimal_precision": DECIMAL_PRECISION,
            "rounding": f"{ROUNDING_POLICY}; integer pixel sums are exact",
            "float_inputs_allowed": False,
        },
        "execution_environment": {
            "runtime": "original-pixel arithmetic",
            "platform": platform.system(),
            "dependencies": {
                "calculation_primitives": "lab-core-primitives-2.1",
                **runtime_source_metadata(runtime_executor_id, resolved_runtime_target),
            },
        },
        "quantification_context": {
            "source_asset_kind": samples.asset_kind,
            "source_immutable": samples.immutable_original,
            "generated_pixels_used": False,
            "channel_index": samples.channel_index,
            "channel_name": samples.channel_name,
            "image_width": samples.width,
            "image_height": samples.height,
            "bit_depth": samples.bit_depth,
            "signal_roi": samples.signal_roi.to_json(),
            "background_roi": samples.background_roi.to_json() if samples.background_roi is not None else None,
            "background_method": background_method,
            "approval_ref": approval.approval_ref,
            "approved_at_utc": approval.approved_at_utc,
            "reviewer": approval.reviewer,
        },
    }
    return json_value(trace)


def _validate_ai_provenance(value: Any) -> None:
    if value is None:
        return
    if not isinstance(value, list):
        raise CalculationError("AI provenance must be a list of typed objects")
    allowed = {
        "source", "tool_call_id", "model_id", "values", "confidence",
        "user_confirmed", "confirmation_ref", "confirmed_at_utc",
    }
    for index, item in enumerate(value):
        if not isinstance(item, dict) or set(item) - allowed:
            raise CalculationError(f"AI provenance entry {index} has unsupported fields")
        if item.get("source") not in {"report_extraction", "model_suggestion", "tool_result"}:
            raise CalculationError(f"AI provenance entry {index} has an invalid source")
        if not isinstance(item.get("user_confirmed"), bool):
            raise CalculationError(f"AI provenance entry {index} requires a confirmation state")
        for key in ("tool_call_id", "model_id", "confidence", "confirmation_ref", "confirmed_at_utc"):
            if key in item and item[key] is not None and not isinstance(item[key], str):
                raise CalculationError(f"AI provenance entry {index} field {key} must be a string or null")
        if "values" in item and not isinstance(item["values"], dict):
            raise CalculationError(f"AI provenance entry {index} values must be an object")
        json_value(item)
