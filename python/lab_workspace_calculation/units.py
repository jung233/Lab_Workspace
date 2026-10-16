"""Small, explicit SI-derived unit registry for the calculation primitives."""

from __future__ import annotations

from dataclasses import dataclass
from decimal import Decimal

from .canonical import CalculationError
from .decimal_support import divide_calculation_decimals, multiply_calculation_decimals


@dataclass(frozen=True)
class Unit:
    symbol: str
    dimensions: tuple[tuple[str, int], ...]
    scale: Decimal

    def compatible_with(self, other: "Unit") -> bool:
        return self.dimensions == other.dimensions


_MASS = (("mass", 1),)
_VOLUME = (("volume", 1),)
_ABSORBANCE = (("absorbance", 1),)
_INTENSITY = (("intensity", 1),)
_DIMENSIONLESS: tuple[tuple[str, int], ...] = ()
_CONCENTRATION = (("mass", 1), ("volume", -1))
_AREA = (("pixel", 2),)
_INTEGRATED_INTENSITY = (("intensity", 1), ("pixel", 2))


def _unit(symbol: str, dimensions: tuple[tuple[str, int], ...], scale: str) -> Unit:
    return Unit(symbol, dimensions, Decimal(scale))


UNITS: dict[str, Unit] = {
    "1": _unit("1", _DIMENSIONLESS, "1"),
    "dimensionless": _unit("1", _DIMENSIONLESS, "1"),
    "ratio": _unit("1", _DIMENSIONLESS, "1"),
    "g": _unit("g", _MASS, "1"),
    "mg": _unit("mg", _MASS, "0.001"),
    "ug": _unit("ug", _MASS, "0.000001"),
    "ng": _unit("ng", _MASS, "0.000000001"),
    "kg": _unit("kg", _MASS, "1000"),
    "L": _unit("L", _VOLUME, "1"),
    "mL": _unit("mL", _VOLUME, "0.001"),
    "uL": _unit("uL", _VOLUME, "0.000001"),
    "nL": _unit("nL", _VOLUME, "0.000000001"),
    "g/L": _unit("g/L", _CONCENTRATION, "1"),
    "mg/mL": _unit("mg/mL", _CONCENTRATION, "1"),
    "ug/uL": _unit("ug/uL", _CONCENTRATION, "1"),
    "ug/mL": _unit("ug/mL", _CONCENTRATION, "0.001"),
    "mg/L": _unit("mg/L", _CONCENTRATION, "0.001"),
    "ng/uL": _unit("ng/uL", _CONCENTRATION, "0.001"),
    "mg/uL": _unit("mg/uL", _CONCENTRATION, "1000"),
    "ug/L": _unit("ug/L", _CONCENTRATION, "0.000001"),
    "AU": _unit("AU", _ABSORBANCE, "1"),
    "intensity": _unit("intensity", _INTENSITY, "1"),
    "pixel": _unit("pixel", (("pixel", 1),), "1"),
    "pixel^2": _unit("pixel^2", _AREA, "1"),
    "intensity*pixel^2": _unit("intensity*pixel^2", _INTEGRATED_INTENSITY, "1"),
}


def normalize_symbol(symbol: str) -> str:
    return symbol.strip().replace("µ", "u").replace("μ", "u").replace(" ", "")


def parse_unit(symbol: str | None) -> Unit:
    if symbol is None or not symbol.strip():
        return UNITS["1"]
    normalized = normalize_symbol(symbol)
    try:
        return UNITS[normalized]
    except KeyError as exc:
        raise CalculationError(f"Unsupported unit: {symbol}") from exc


def conversion_factor(source: str, target: str) -> Decimal:
    source_unit, target_unit = parse_unit(source), parse_unit(target)
    if not source_unit.compatible_with(target_unit):
        raise CalculationError(f"CALC_UNIT_INCOMPATIBLE: {source} cannot convert to {target}")
    return divide_calculation_decimals(source_unit.scale, target_unit.scale)


def multiply_units(left: Unit, right: Unit) -> Unit:
    dimensions: dict[str, int] = {}
    for key, exponent in left.dimensions + right.dimensions:
        dimensions[key] = dimensions.get(key, 0) + exponent
    reduced = tuple(sorted((key, exponent) for key, exponent in dimensions.items() if exponent))
    if reduced == _DIMENSIONLESS:
        return UNITS["1"]
    if reduced == _VOLUME:
        scale = multiply_calculation_decimals(left.scale, right.scale)
        for unit in UNITS.values():
            if unit.dimensions == _VOLUME and unit.scale == scale:
                return unit
    raise CalculationError("The resulting unit is outside the registered unit set")


def divide_units(left: Unit, right: Unit) -> Unit:
    dimensions: dict[str, int] = {}
    for key, exponent in left.dimensions + tuple((k, -e) for k, e in right.dimensions):
        dimensions[key] = dimensions.get(key, 0) + exponent
    reduced = tuple(sorted((key, exponent) for key, exponent in dimensions.items() if exponent))
    if reduced == _DIMENSIONLESS:
        return UNITS["1"]
    scale = divide_calculation_decimals(left.scale, right.scale)
    for unit in UNITS.values():
        if unit.dimensions == reduced and unit.scale == scale:
            return unit
    raise CalculationError("The resulting unit is outside the registered unit set")
