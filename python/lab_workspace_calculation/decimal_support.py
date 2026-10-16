"""Shared deterministic Decimal context for trusted calculation arithmetic."""

from __future__ import annotations

from contextlib import contextmanager
from decimal import Context, Decimal, ROUND_HALF_EVEN, localcontext
from typing import Iterator

DECIMAL_PRECISION = 28
ROUNDING_POLICY = (
    "28 significant decimal digits; ROUND_HALF_EVEN after every arithmetic operation; "
    "original input strings are preserved"
)


def calculation_decimal_text(value: Decimal) -> str:
    """Format a finite value like Dart Decimal.toString, without exponents."""
    if not value.is_finite():
        raise ArithmeticError("Non-finite decimal values are not supported")
    if value.is_zero():
        return "0"
    text = format(value, "f")
    if "." in text:
        text = text.rstrip("0").rstrip(".")
    return text


@contextmanager
def calculation_decimal_context() -> Iterator[Context]:
    with localcontext() as context:
        context.prec = DECIMAL_PRECISION
        context.rounding = ROUND_HALF_EVEN
        yield context


def add_calculation_decimals(left: Decimal, right: Decimal) -> Decimal:
    with calculation_decimal_context():
        return left + right


def subtract_calculation_decimals(left: Decimal, right: Decimal) -> Decimal:
    with calculation_decimal_context():
        return left - right


def multiply_calculation_decimals(left: Decimal, right: Decimal) -> Decimal:
    with calculation_decimal_context():
        return left * right


def divide_calculation_decimals(left: Decimal, right: Decimal) -> Decimal:
    if right == 0:
        raise ArithmeticError("Division by zero is not allowed")
    with calculation_decimal_context():
        return left / right


def square_root_calculation_decimal(value: Decimal) -> Decimal:
    if value < 0:
        raise ArithmeticError("Square root requires a non-negative value")
    with calculation_decimal_context():
        return value.sqrt()
