"""Versioned, built-in primitive allowlist.

Primitive bodies are application-owned functions. Calculation Pack documents
can select an operation and provide values, but cannot register or import code.
"""

from __future__ import annotations

import csv
import io
from dataclasses import dataclass
from decimal import Decimal
from typing import Any, Callable

from .canonical import CalculationError, canonical_json
from .decimal_support import (
    add_calculation_decimals,
    calculation_decimal_context,
    calculation_decimal_text,
    divide_calculation_decimals,
    multiply_calculation_decimals,
    square_root_calculation_decimal,
    subtract_calculation_decimals,
)
from .units import Unit, conversion_factor, divide_units, parse_unit


MAX_ROWS = 100_000
MAX_CSV_BYTES = 8 * 1024 * 1024


@dataclass(frozen=True)
class Quantity:
    value: Decimal
    unit: Unit

    @classmethod
    def of(cls, value: Any, unit: str | Unit | None = None) -> "Quantity":
        return cls(as_decimal(value), parse_unit(unit) if isinstance(unit, (str, type(None))) else unit)

    def to_unit(self, target: str) -> "Quantity":
        factor = conversion_factor(self.unit.symbol, target)
        return Quantity(multiply_calculation_decimals(self.value, factor), parse_unit(target))


def as_decimal(value: Any) -> Decimal:
    if isinstance(value, Quantity):
        return value.value
    if isinstance(value, bool) or isinstance(value, float):
        raise CalculationError("Decimal inputs must be strings or integers, not binary floats")
    if isinstance(value, (str, int, Decimal)):
        try:
            number = Decimal(str(value))
        except Exception as exc:
            raise CalculationError(f"Invalid decimal value: {value!r}") from exc
        if not number.is_finite():
            raise CalculationError("Decimal inputs must be finite")
        return number
    raise CalculationError(f"Expected a decimal string or integer, got {type(value).__name__}")


def _quantity(value: Any, expected_unit: str | None = None) -> Quantity:
    if isinstance(value, Quantity):
        if expected_unit is not None:
            return value.to_unit(expected_unit)
        return value
    return Quantity.of(value, expected_unit)


def _sum_decimals(values: Any) -> Decimal:
    total = Decimal(0)
    for value in values:
        total = add_calculation_decimals(total, value)
    return total


def _scalar(value: Any) -> Any:
    if isinstance(value, Quantity):
        return calculation_decimal_text(value.value)
    if isinstance(value, Decimal):
        return calculation_decimal_text(value)
    if isinstance(value, (str, bool, int)) or value is None:
        return value
    return value


def _trace(
    expression: str,
    substitution: str,
    inputs: dict[str, Any],
    intermediates: dict[str, Any],
    value: Any,
    unit: str | None,
    warnings: list[str] | None = None,
) -> "PrimitiveResult":
    return PrimitiveResult(
        values={},
        expression=expression,
        substitution=substitution,
        inputs=inputs,
        intermediates=intermediates,
        trace_value=_scalar(value),
        trace_unit=unit,
        warnings=tuple(warnings or ()),
    )


@dataclass(frozen=True)
class PrimitiveResult:
    values: dict[str, Any]
    expression: str
    substitution: str
    inputs: dict[str, Any]
    intermediates: dict[str, Any]
    trace_value: Any
    trace_unit: str | None
    warnings: tuple[str, ...] = ()


PrimitiveFunction = Callable[[dict[str, Any], dict[str, Any]], PrimitiveResult]


@dataclass(frozen=True)
class PrimitiveDefinition:
    primitive_id: str
    required_inputs: frozenset[str]
    optional_inputs: frozenset[str]
    allowed_params: frozenset[str]
    description: str
    apply: PrimitiveFunction
    build_id: str = "lab-core-primitives-2.1"

    def invoke(self, inputs: dict[str, Any], params: dict[str, Any]) -> PrimitiveResult:
        missing = self.required_inputs - inputs.keys()
        unknown = inputs.keys() - self.required_inputs - self.optional_inputs
        unknown_params = params.keys() - self.allowed_params
        if missing:
            raise CalculationError(
                f"{self.primitive_id} missing inputs: {', '.join(sorted(missing))}"
            )
        if unknown:
            raise CalculationError(
                f"{self.primitive_id} has unknown inputs: {', '.join(sorted(unknown))}"
            )
        if unknown_params:
            raise CalculationError(
                f"{self.primitive_id} has unknown params: {', '.join(sorted(unknown_params))}"
            )
        with calculation_decimal_context():
            return self.apply(inputs, params)


def _require_rows(value: Any) -> list[dict[str, Any]]:
    if not isinstance(value, list) or len(value) > MAX_ROWS:
        raise CalculationError("Expected a bounded table of rows")
    if any(not isinstance(row, dict) for row in value):
        raise CalculationError("Table rows must be objects")
    return value


def _parse_csv(inputs: dict[str, Any], params: dict[str, Any]) -> PrimitiveResult:
    content = inputs["text"]
    if not isinstance(content, str) or len(content.encode("utf-8")) > MAX_CSV_BYTES:
        raise CalculationError("CSV text must be UTF-8 text no larger than 8 MiB")
    delimiter = params.get("delimiter", ",")
    if not isinstance(delimiter, str) or len(delimiter) != 1 or delimiter in "\r\n\"":
        raise CalculationError("CSV delimiter must be one safe character")
    has_header = params.get("has_header", True)
    if not isinstance(has_header, bool):
        raise CalculationError("has_header must be boolean")
    reader = csv.reader(io.StringIO(content, newline=""), delimiter=delimiter, strict=True)
    raw_rows = list(reader)
    if len(raw_rows) > MAX_ROWS + 1:
        raise CalculationError("CSV exceeds the maximum row count")
    if not raw_rows:
        raise CalculationError("CSV contains no rows")
    if has_header:
        headers = raw_rows.pop(0)
        if not headers or len(set(headers)) != len(headers) or any(not h.strip() for h in headers):
            raise CalculationError("CSV header names must be present and unique")
    else:
        width = len(raw_rows[0])
        headers = [f"column_{index + 1}" for index in range(width)]
    if not headers or any(len(row) != len(headers) for row in raw_rows):
        raise CalculationError("CSV rows must have the same number of columns as the header")
    column_map = params.get("column_map", {})
    if not isinstance(column_map, dict) or any(
        not isinstance(source, str) or not isinstance(target, str) or not target
        for source, target in column_map.items()
    ):
        raise CalculationError("column_map must map source column names to non-empty names")
    unknown = set(column_map) - set(headers)
    if unknown:
        raise CalculationError(f"CSV column_map references missing columns: {sorted(unknown)}")
    mapped_headers = [column_map.get(header, header) for header in headers]
    if len(set(mapped_headers)) != len(mapped_headers):
        raise CalculationError("CSV column_map produces duplicate output keys")
    rows = [dict(zip(mapped_headers, row)) for row in raw_rows]
    return PrimitiveResult(
        values={"rows": rows},
        expression="CSV text parsed into rows using the declared delimiter and column map",
        substitution=f"rows={len(rows)}; columns={len(mapped_headers)}; delimiter={delimiter!r}",
        inputs={"text_bytes": len(content.encode("utf-8"))},
        intermediates={"columns": mapped_headers, "row_count": len(rows)},
        trace_value=str(len(rows)),
        trace_unit=None,
    )


def _table_select(inputs: dict[str, Any], params: dict[str, Any]) -> PrimitiveResult:
    rows = _require_rows(inputs["rows"])
    equals = params.get("equals", {})
    if not isinstance(equals, dict):
        raise CalculationError("table.select filters must be an object of exact matches")
    for key in equals:
        if not isinstance(key, str) or not key:
            raise CalculationError("Filter column names must be non-empty strings")
        if any(key not in row for row in rows):
            raise CalculationError(f"Filter column {key!r} is missing from a row")
    selected = [row for row in rows if all(row[key] == expected for key, expected in equals.items())]
    return PrimitiveResult(
        values={"rows": selected},
        expression="rows retained where each declared column equals its configured value",
        substitution=f"{len(selected)} of {len(rows)} rows match {canonical_json(equals)}",
        inputs={"row_count": len(rows), "equals": equals},
        intermediates={"selected_row_count": len(selected)},
        trace_value=str(len(selected)),
        trace_unit=None,
    )


def _table_group_by(inputs: dict[str, Any], params: dict[str, Any]) -> PrimitiveResult:
    rows = _require_rows(inputs["rows"])
    keys = params.get("keys")
    if not isinstance(keys, list) or not keys or any(not isinstance(key, str) or not key for key in keys):
        raise CalculationError("table.group_by keys must be a non-empty string list")
    groups: dict[str, dict[str, Any]] = {}
    for row in rows:
        if any(key not in row for key in keys):
            raise CalculationError("A group key is missing from a row")
        key_values = {key: row[key] for key in keys}
        token = canonical_json(key_values)
        groups.setdefault(token, {"key": key_values, "rows": []})["rows"].append(row)
    output = list(groups.values())
    return PrimitiveResult(
        values={"groups": output},
        expression="rows grouped by the declared key columns",
        substitution=f"{len(rows)} rows -> {len(output)} groups by {', '.join(keys)}",
        inputs={"row_count": len(rows), "keys": keys},
        intermediates={"group_sizes": [len(group["rows"]) for group in output]},
        trace_value=str(len(output)),
        trace_unit=None,
    )


def _unit_convert(inputs: dict[str, Any], params: dict[str, Any]) -> PrimitiveResult:
    source, target = params["from"], params["to"]
    expected_factor = conversion_factor(source, target)
    factor = as_decimal(params["factor"])
    if factor != expected_factor:
        raise CalculationError("AI-supplied factor conflicts with validated unit registry")
    quantity = _quantity(inputs["value"], source)
    result = Quantity(
        multiply_calculation_decimals(quantity.value, factor), parse_unit(target)
    )
    return PrimitiveResult(
        values={"value": result},
        expression="value * registered_unit_conversion_factor",
        substitution=(
            f"{calculation_decimal_text(quantity.value)} {source} * "
            f"{calculation_decimal_text(factor)} = "
            f"{calculation_decimal_text(result.value)} {target}"
        ),
        inputs={"value": quantity, "from": source, "to": target, "factor": factor},
        intermediates={"source_scale": quantity.unit.scale, "target_scale": result.unit.scale},
        trace_value=calculation_decimal_text(result.value),
        trace_unit=target,
    )


def _mean(inputs: dict[str, Any], params: dict[str, Any]) -> PrimitiveResult:
    values = inputs["values"]
    if not isinstance(values, list) or not values:
        raise CalculationError("stats.mean requires a non-empty list")
    expected_unit = params.get("unit")
    quantities = [_quantity(value, expected_unit) for value in values]
    if any(not quantities[0].unit.compatible_with(item.unit) for item in quantities[1:]):
        raise CalculationError("CALC_UNIT_INCOMPATIBLE: mean inputs have different units")
    converted = [item.to_unit(quantities[0].unit.symbol).value for item in quantities]
    total = _sum_decimals(converted)
    average = divide_calculation_decimals(total, Decimal(len(converted)))
    result = Quantity(average, quantities[0].unit)
    return PrimitiveResult(
        values={"value": result},
        expression="mean = sum(values) / n",
        substitution=(
            f"{calculation_decimal_text(total)} / {len(converted)} = "
            f"{calculation_decimal_text(average)}"
        ),
        inputs={"values": quantities},
        intermediates={"n": len(converted), "sum": total},
        trace_value=calculation_decimal_text(result.value),
        trace_unit=result.unit.symbol,
    )


def _sd(inputs: dict[str, Any], params: dict[str, Any]) -> PrimitiveResult:
    values = inputs["values"]
    if not isinstance(values, list) or len(values) < 2:
        raise CalculationError("stats.sd requires at least two observations")
    expected_unit = params.get("unit")
    quantities = [_quantity(value, expected_unit) for value in values]
    if any(not quantities[0].unit.compatible_with(item.unit) for item in quantities[1:]):
        raise CalculationError("CALC_UNIT_INCOMPATIBLE: SD inputs have different units")
    converted = [item.to_unit(quantities[0].unit.symbol).value for item in quantities]
    average = divide_calculation_decimals(
        _sum_decimals(converted), Decimal(len(converted))
    )
    deviations = [
        subtract_calculation_decimals(value, average) for value in converted
    ]
    squared = [multiply_calculation_decimals(value, value) for value in deviations]
    squared_total = _sum_decimals(squared)
    variance = divide_calculation_decimals(
        squared_total, Decimal(len(converted) - 1)
    )
    deviation = square_root_calculation_decimal(variance)
    result = Quantity(deviation, quantities[0].unit)
    record = _trace(
        "sample_sd = sqrt(sum((x - mean)^2) / (n - 1))",
        f"sqrt({calculation_decimal_text(squared_total)} / ({len(converted)} - 1)) = "
        f"{calculation_decimal_text(deviation)}",
        {"values": quantities},
        {
            "n": len(converted),
            "mean": average,
            "deviations": deviations,
            "squared_deviations": squared,
            "sum_squared_deviations": squared_total,
            "sample_variance": variance,
        },
        result,
        result.unit.symbol,
    )
    return PrimitiveResult({"value": result}, record.expression, record.substitution, record.inputs,
                           record.intermediates, record.trace_value, record.trace_unit, record.warnings)


def _linear_regression(inputs: dict[str, Any], params: dict[str, Any]) -> PrimitiveResult:
    rows = _require_rows(inputs.get("standards", inputs.get("points")))
    if len(rows) < 2:
        raise CalculationError("stats.linear_regression requires at least two rows")
    x_key = params.get("x_key", "concentration")
    y_key = params.get("y_key", "absorbance")
    if any(x_key not in row or y_key not in row for row in rows):
        raise CalculationError("Regression rows must contain the configured x and y columns")
    x_unit, y_unit = parse_unit(params.get("x_unit")), parse_unit(params.get("y_unit"))
    xs = [as_decimal(row[x_key]) for row in rows]
    ys = [as_decimal(row[y_key]) for row in rows]
    if len(set(xs)) < 2:
        raise CalculationError("Linear regression requires at least two distinct x values")
    n = Decimal(len(xs))
    xbar = divide_calculation_decimals(_sum_decimals(xs), n)
    ybar = divide_calculation_decimals(_sum_decimals(ys), n)
    centered_x = [subtract_calculation_decimals(x, xbar) for x in xs]
    centered_y = [subtract_calculation_decimals(y, ybar) for y in ys]
    sxx = _sum_decimals(
        multiply_calculation_decimals(value, value) for value in centered_x
    )
    sxy = _sum_decimals(
        multiply_calculation_decimals(left, right)
        for left, right in zip(centered_x, centered_y)
    )
    if sxx == 0:
        raise CalculationError("Linear regression has zero Sxx")
    slope = divide_calculation_decimals(sxy, sxx)
    intercept = subtract_calculation_decimals(
        ybar, multiply_calculation_decimals(slope, xbar)
    )
    residuals = [
        subtract_calculation_decimals(
            y,
            add_calculation_decimals(
                multiply_calculation_decimals(slope, x), intercept
            ),
        )
        for x, y in zip(xs, ys)
    ]
    rss = _sum_decimals(
        multiply_calculation_decimals(item, item) for item in residuals
    )
    sst = _sum_decimals(
        multiply_calculation_decimals(value, value) for value in centered_y
    )
    r_squared = (
        subtract_calculation_decimals(
            Decimal(1), divide_calculation_decimals(rss, sst)
        )
        if sst != 0
        else Decimal(1)
        if rss == 0
        else Decimal(0)
    )
    slope_dimensions: dict[str, int] = {}
    for key, exponent in y_unit.dimensions + tuple((key, -exponent) for key, exponent in x_unit.dimensions):
        slope_dimensions[key] = slope_dimensions.get(key, 0) + exponent
    reduced_dimensions = tuple(
        sorted((key, exponent) for key, exponent in slope_dimensions.items() if exponent)
    )
    slope_scale = divide_calculation_decimals(y_unit.scale, x_unit.scale)
    slope_unit = f"{y_unit.symbol}/({x_unit.symbol})" if x_unit.symbol != "1" else y_unit.symbol
    slope_quantity = Quantity(slope, Unit(slope_unit, reduced_dimensions, slope_scale))
    intercept_quantity = Quantity(intercept, y_unit)
    outputs = {
        "slope": slope_quantity,
        "intercept": intercept_quantity,
        "r_squared": Quantity(r_squared, parse_unit("1")),
        "min_x": Quantity(min(xs), x_unit),
        "max_x": Quantity(max(xs), x_unit),
    }
    intermediate = {
        "n": len(xs), "xbar": xbar, "ybar": ybar, "sxx": sxx, "sxy": sxy,
        "centered_x": centered_x, "centered_y": centered_y,
        "rss": rss, "sst": sst, "r_squared": r_squared,
        "intercept": intercept, "residuals": residuals,
    }
    return PrimitiveResult(
        values=outputs,
        expression="slope=Sxy/Sxx; intercept=ybar-slope*xbar; R2=1-RSS/SST",
        substitution=(
            f"slope={calculation_decimal_text(sxy)}/{calculation_decimal_text(sxx)}; "
            f"intercept={calculation_decimal_text(ybar)}-"
            f"{calculation_decimal_text(slope)}*{calculation_decimal_text(xbar)}"
        ),
        inputs={"standards": rows, "x_key": x_key, "y_key": y_key},
        intermediates=intermediate,
        trace_value=calculation_decimal_text(slope),
        trace_unit=slope_unit,
    )


def _blank_adjust(inputs: dict[str, Any], params: dict[str, Any]) -> PrimitiveResult:
    standards = _require_rows(inputs["standards"])
    blank = _quantity(inputs["blank"], params.get("absorbance_unit", "AU"))
    concentration_key = params.get("concentration_key", "concentration")
    absorbance_key = params.get("absorbance_key", "absorbance")
    concentration_unit = params.get("concentration_unit")
    absorbance_unit = params.get("absorbance_unit", "AU")
    adjusted: list[dict[str, str]] = []
    for row in standards:
        if concentration_key not in row or absorbance_key not in row:
            raise CalculationError("BCA standards require concentration and absorbance values")
        corrected = subtract_calculation_decimals(
            as_decimal(row[absorbance_key]), blank.value
        )
        raw_concentration = row[concentration_key]
        adjusted.append({
            "concentration": (
                raw_concentration
                if isinstance(raw_concentration, str)
                else calculation_decimal_text(as_decimal(raw_concentration))
            ),
            "absorbance": calculation_decimal_text(corrected),
        })
    return PrimitiveResult(
        values={"standards": adjusted},
        expression="y_i_corrected = y_i - blank",
        substitution=(
            f"each of {len(standards)} standard absorbances minus "
            f"{calculation_decimal_text(blank.value)} {absorbance_unit}"
        ),
        inputs={"standards": standards, "blank": blank},
        intermediates={"corrected_rows": adjusted, "concentration_unit": concentration_unit, "absorbance_unit": absorbance_unit},
        trace_value=str(len(adjusted)),
        trace_unit=None,
    )


def _subtract(inputs: dict[str, Any], params: dict[str, Any]) -> PrimitiveResult:
    a, b = _quantity(inputs["a"]), _quantity(inputs["b"])
    if not a.unit.compatible_with(b.unit):
        raise CalculationError("CALC_UNIT_INCOMPATIBLE: subtraction requires matching dimensions")
    b = b.to_unit(a.unit.symbol)
    value = Quantity(subtract_calculation_decimals(a.value, b.value), a.unit)
    return PrimitiveResult(
        values={"value": value}, expression="a - b", substitution=(
            f"{calculation_decimal_text(a.value)} - "
            f"{calculation_decimal_text(b.value)} = "
            f"{calculation_decimal_text(value.value)}"
        ),
        inputs={"a": a, "b": b}, intermediates={}, trace_value=calculation_decimal_text(value.value), trace_unit=value.unit.symbol,
    )


def _linear_inverse(inputs: dict[str, Any], params: dict[str, Any]) -> PrimitiveResult:
    y, slope, intercept = _quantity(inputs["y"]), _quantity(inputs["slope"]), _quantity(inputs["intercept"])
    if not y.unit.compatible_with(intercept.unit):
        raise CalculationError("CALC_UNIT_INCOMPATIBLE: inverse y and intercept units differ")
    intercept = intercept.to_unit(y.unit.symbol)
    if slope.value == 0:
        raise CalculationError("Cannot invert a zero slope")
    unit = divide_units(y.unit, slope.unit)
    adjusted_y = subtract_calculation_decimals(y.value, intercept.value)
    value = Quantity(
        divide_calculation_decimals(adjusted_y, slope.value),
        unit,
    )
    return PrimitiveResult(
        values={"value": value}, expression="x = (y - intercept) / slope",
        substitution=(
            f"({calculation_decimal_text(y.value)} - "
            f"{calculation_decimal_text(intercept.value)}) / "
            f"{calculation_decimal_text(slope.value)} = "
            f"{calculation_decimal_text(value.value)}"
        ),
        inputs={"y": y, "slope": slope, "intercept": intercept},
        intermediates={"adjusted_y": adjusted_y},
        trace_value=calculation_decimal_text(value.value), trace_unit=unit.symbol,
    )


def _multiply(inputs: dict[str, Any], params: dict[str, Any]) -> PrimitiveResult:
    a, b = _quantity(inputs["a"]), _quantity(inputs["b"])
    if a.unit.dimensions and b.unit.dimensions:
        raise CalculationError("Multiplication is restricted to one dimensional quantity and one scalar")
    dimensional = a if a.unit.dimensions else b
    scalar = b if a.unit.dimensions else a
    result = Quantity(
        multiply_calculation_decimals(a.value, b.value), dimensional.unit
    )
    return PrimitiveResult(
        values={"value": result}, expression="a * b", substitution=(
            f"{calculation_decimal_text(a.value)} * "
            f"{calculation_decimal_text(b.value)} = "
            f"{calculation_decimal_text(result.value)}"
        ),
        inputs={"a": a, "b": b}, intermediates={"result_unit": result.unit.symbol},
        trace_value=calculation_decimal_text(result.value), trace_unit=result.unit.symbol,
    )


def _divide(inputs: dict[str, Any], params: dict[str, Any]) -> PrimitiveResult:
    numerator, denominator = _quantity(inputs["numerator"]), _quantity(inputs["denominator"])
    if denominator.value == 0:
        raise CalculationError("Division by zero is not allowed")
    unit = divide_units(numerator.unit, denominator.unit)
    result = Quantity(
        divide_calculation_decimals(numerator.value, denominator.value), unit
    )
    return PrimitiveResult(
        values={"value": result}, expression="numerator / denominator",
        substitution=(
            f"{calculation_decimal_text(numerator.value)} {numerator.unit.symbol} / "
            f"{calculation_decimal_text(denominator.value)} {denominator.unit.symbol} = "
            f"{calculation_decimal_text(result.value)} {unit.symbol}"
        ),
        inputs={"numerator": numerator, "denominator": denominator},
        intermediates={"result_unit": unit.symbol}, trace_value=calculation_decimal_text(result.value), trace_unit=unit.symbol,
    )


def _qc_range(inputs: dict[str, Any], params: dict[str, Any]) -> PrimitiveResult:
    expected_unit = params.get("unit")
    if expected_unit is not None and not isinstance(expected_unit, str):
        raise CalculationError("QC unit must be a registered unit name")
    value = _quantity(inputs["x"], expected_unit)
    low = _quantity(inputs["low"], expected_unit)
    high = _quantity(inputs["high"], expected_unit)
    if not value.unit.compatible_with(low.unit) or not value.unit.compatible_with(high.unit):
        raise CalculationError("CALC_UNIT_INCOMPATIBLE: range limits must use the input unit")
    low, high = low.to_unit(value.unit.symbol), high.to_unit(value.unit.symbol)
    if low.value > high.value:
        raise CalculationError("Range lower bound must not exceed its upper bound")
    in_range = low.value <= value.value <= high.value
    warning_text = params.get("warning", "Value is outside the configured range")
    warnings = [] if in_range else [str(warning_text)]
    return PrimitiveResult(
        values={"in_range": in_range}, expression="low <= value <= high",
        substitution=(
            f"{calculation_decimal_text(low.value)} <= "
            f"{calculation_decimal_text(value.value)} <= "
            f"{calculation_decimal_text(high.value)}"
        ),
        inputs={"x": value, "low": low, "high": high}, intermediates={},
        trace_value=str(in_range).lower(), trace_unit=None, warnings=tuple(warnings),
    )


def _export_table(inputs: dict[str, Any], params: dict[str, Any]) -> PrimitiveResult:
    rows = _require_rows(inputs["rows"])
    serialized = canonical_json(rows)
    return PrimitiveResult(
        values={"json": serialized}, expression="rows serialized as canonical JSON for host AssetStore export",
        substitution=f"{len(rows)} rows serialized; host must create a new derived Asset",
        inputs={"rows": rows}, intermediates={"row_count": len(rows)},
        trace_value=str(len(rows)), trace_unit=None,
        warnings=("AssetStore must assign the output SHA-256 and preserve source lineage",),
    )


def _wb_normalize_ratio(inputs: dict[str, Any], params: dict[str, Any]) -> PrimitiveResult:
    target_value = _quantity(inputs["target_intensity"], "intensity")
    reference_value = _quantity(inputs["reference_intensity"], "intensity")
    if not target_value.unit.compatible_with(reference_value.unit):
        raise CalculationError("CALC_UNIT_INCOMPATIBLE: WB target and reference intensities differ")
    target = target_value.to_unit("intensity").value
    reference = reference_value.to_unit("intensity").value
    if reference <= 0:
        raise CalculationError("WB normalization denominator must be greater than zero")
    ratio = divide_calculation_decimals(target, reference)
    if "calibrator_ratio" in inputs:
        calibrator = as_decimal(inputs["calibrator_ratio"])
        if calibrator <= 0:
            raise CalculationError("WB calibrator ratio must be greater than zero")
        relative = divide_calculation_decimals(ratio, calibrator)
        values: dict[str, Any] = {"ratio": Quantity(ratio, parse_unit("1")), "relative_ratio": Quantity(relative, parse_unit("1"))}
        trace_value = relative
        expression = "relative_normalized = (target_intensity / reference_intensity) / calibrator_ratio"
        substitution = (
            f"({calculation_decimal_text(target)} / "
            f"{calculation_decimal_text(reference)}) / "
            f"{calculation_decimal_text(calibrator)} = "
            f"{calculation_decimal_text(relative)}"
        )
        intermediates = {"sample_ratio": ratio, "calibrator_ratio": calibrator}
    else:
        values = {"value": Quantity(ratio, parse_unit("1"))}
        trace_value = ratio
        expression = "normalized_ratio = target_intensity / reference_intensity"
        substitution = (
            f"{calculation_decimal_text(target)} / "
            f"{calculation_decimal_text(reference)} = "
            f"{calculation_decimal_text(ratio)}"
        )
        intermediates = {"target_to_reference_ratio": ratio}
    caution = params.get("method_warning", "Confirm the loading control and normalization method in the experiment SOP.")
    return PrimitiveResult(
        values=values, expression=expression, substitution=substitution,
        inputs={key: value for key, value in inputs.items()}, intermediates=intermediates,
        trace_value=calculation_decimal_text(trace_value), trace_unit="1", warnings=(str(caution),),
    )


def _prim(
    name: str,
    required: set[str],
    optional: set[str],
    params: set[str],
    description: str,
    apply: PrimitiveFunction,
) -> PrimitiveDefinition:
    return PrimitiveDefinition(
        primitive_id=name,
        required_inputs=frozenset(required),
        optional_inputs=frozenset(optional),
        allowed_params=frozenset(params),
        description=description,
        apply=apply,
    )


PRIMITIVES: dict[str, PrimitiveDefinition] = {
    item.primitive_id: item
    for item in (
        _prim("csv.parse_table@1", {"text"}, set(), {"delimiter", "has_header", "column_map"}, "Parse a bounded CSV text snapshot.", _parse_csv),
        _prim("table.select@1", {"rows"}, set(), {"equals"}, "Select rows by exact declared values.", _table_select),
        _prim("table.group_by@1", {"rows"}, set(), {"keys"}, "Group rows by explicit columns.", _table_group_by),
        _prim("math.unit_convert@1", {"value"}, set(), {"from", "to", "factor"}, "Convert registered compatible units.", _unit_convert),
        _prim("stats.mean@1", {"values"}, set(), {"unit"}, "Mean of compatible decimal quantities.", _mean),
        _prim("stats.sd@1", {"values"}, set(), {"unit"}, "Sample standard deviation (n-1 denominator).", _sd),
        _prim("stats.linear_regression@1", {"standards"}, {"points"}, {"x_key", "y_key", "x_unit", "y_unit"}, "Unweighted ordinary least-squares linear fit.", _linear_regression),
        _prim("bca.blank_adjust@1", {"standards", "blank"}, set(), {"concentration_key", "absorbance_key", "concentration_unit", "absorbance_unit"}, "Subtract a user-configured blank from each standard absorbance.", _blank_adjust),
        _prim("math.linear_inverse@1", {"y", "slope", "intercept"}, set(), set(), "Invert a registered linear model.", _linear_inverse),
        _prim("math.multiply@1", {"a", "b"}, set(), set(), "Multiply a quantity by a scalar.", _multiply),
        _prim("math.divide@1", {"numerator", "denominator"}, set(), set(), "Divide quantities with registered resulting units.", _divide),
        _prim("data.qc_range@1", {"x", "low", "high"}, set(), {"warning", "unit"}, "Check a value against explicit limits without deleting it.", _qc_range),
        _prim("data.qc_limits@1", {"x", "low", "high"}, set(), {"warning", "unit"}, "Alias for explicit QC range limits.", _qc_range),
        _prim("data.export_table@1", {"rows"}, set(), set(), "Serialize a typed table for host AssetStore export.", _export_table),
        _prim("wb.normalize_ratio@1", {"target_intensity", "reference_intensity"}, {"calibrator_ratio"}, {"method_warning"}, "Normalize confirmed ROI intensities using a user-selected denominator.", _wb_normalize_ratio),
    )
}
