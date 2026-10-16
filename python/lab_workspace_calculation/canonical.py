"""Canonical JSON and strict value helpers used for immutable pack hashes."""

from __future__ import annotations

import hashlib
import json
from decimal import Decimal
from typing import Any

from .decimal_support import calculation_decimal_text


class CalculationError(ValueError):
    """An input, contract, or supported scientific operation was invalid."""


def json_value(value: Any) -> Any:
    """Return a JSON-safe tree; floats and non-finite values are rejected.

    Decimal values are serialized as decimal strings so hashes and traces do
    not depend on binary floating-point formatting.
    """
    if isinstance(value, Decimal):
        if not value.is_finite():
            raise CalculationError("Non-finite decimal values are not allowed")
        return calculation_decimal_text(value)
    # ``Quantity`` is deliberately kept out of the canonical module to avoid a
    # dependency cycle, but has a stable public ``value``/``unit.symbol`` pair.
    unit = getattr(value, "unit", None)
    quantity_value = getattr(value, "value", None)
    if unit is not None and hasattr(unit, "symbol") and isinstance(quantity_value, Decimal):
        return {"value": json_value(quantity_value), "unit": unit.symbol}
    if value is None or isinstance(value, (str, bool, int)):
        return value
    if isinstance(value, float):
        raise CalculationError("Binary floating-point values are not accepted")
    if isinstance(value, list):
        return [json_value(item) for item in value]
    if isinstance(value, tuple):
        return [json_value(item) for item in value]
    if isinstance(value, dict):
        if any(not isinstance(key, str) for key in value):
            raise CalculationError("JSON object keys must be strings")
        return {key: json_value(item) for key, item in value.items()}
    raise CalculationError(f"Unsupported JSON value type: {type(value).__name__}")


def canonical_json(value: Any) -> str:
    return json.dumps(
        json_value(value),
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
        allow_nan=False,
    )


def sha256_json(value: Any) -> str:
    return hashlib.sha256(canonical_json(value).encode("utf-8")).hexdigest()


def calculation_pack_content_sha256(pack: Any) -> str:
    """Hash executable Pack content independently of review-state metadata."""
    normalized = json_value(pack)
    if not isinstance(normalized, dict):
        raise CalculationError("Calculation Pack must be a JSON object")
    normalized["status"] = "draft"
    review = normalized.get("review")
    if isinstance(review, dict):
        review["approved_by_user"] = False
    return sha256_json(normalized)
