import 'package:decimal/decimal.dart';

const int calculationDecimalPrecision = 28;
const String calculationRoundingPolicy =
    '28 significant decimal digits; ROUND_HALF_EVEN after every arithmetic operation; original input strings are preserved';

Decimal parseCalculationDecimal(Object? value, {String field = 'value'}) {
  if (value is bool || value is double || value == null) {
    throw FormatException('$field must be a decimal string or integer.');
  }
  if (value is Decimal) return value;
  if (value is int) return Decimal.fromInt(value);
  if (value is String) {
    try {
      final parsed = Decimal.parse(value);
      if (parsed.toString().length > 256) {
        throw FormatException('$field exceeds the 256 character numeric bound.');
      }
      return parsed;
    } on FormatException {
      rethrow;
    } on Object {
      throw FormatException('$field is not a valid finite decimal.');
    }
  }
  throw FormatException('$field must be a decimal string or integer.');
}

String calculationDecimalText(Decimal value) {
  if (value == Decimal.zero) return '0';
  final source = value.toString();
  if (!source.contains('.')) return source;
  final normalized = source.replaceFirst(RegExp(r'0+$'), '').replaceFirst(
        RegExp(r'\.$'),
        '',
      );
  return normalized == '-0' ? '0' : normalized;
}

Decimal roundCalculationDecimal(Decimal value) {
  if (value == Decimal.zero) return Decimal.zero;
  final places = calculationDecimalPrecision - 1 - _decimalOrderOfMagnitude(value);
  final scaled = value.abs().shift(places);
  final truncated = scaled.toBigInt();
  final remainder = scaled - Decimal.fromBigInt(truncated);
  final half = Decimal.parse('0.5');
  final roundsUp = remainder > half || (remainder == half && truncated.isOdd);
  final rounded = roundsUp ? truncated + BigInt.one : truncated;
  final signed = value.sign < 0 ? -rounded : rounded;
  return Decimal.fromBigInt(signed).shift(-places);
}

Decimal addCalculationDecimals(Decimal left, Decimal right) =>
    roundCalculationDecimal(left + right);

Decimal subtractCalculationDecimals(Decimal left, Decimal right) =>
    roundCalculationDecimal(left - right);

Decimal multiplyCalculationDecimals(Decimal left, Decimal right) =>
    roundCalculationDecimal(left * right);

Decimal divideCalculationDecimals(Decimal numerator, Decimal denominator) {
  if (denominator == Decimal.zero) {
    throw const FormatException('Division by zero is not allowed.');
  }
  if (numerator == Decimal.zero) return Decimal.zero;

  final absoluteNumerator = numerator.abs();
  final absoluteDenominator = denominator.abs();
  var exponent = _decimalOrderOfMagnitude(absoluteNumerator) -
      _decimalOrderOfMagnitude(absoluteDenominator);
  if (absoluteNumerator < absoluteDenominator.shift(exponent)) exponent--;

  final scaledNumerator = exponent < 0
      ? absoluteNumerator.shift(-exponent)
      : absoluteNumerator;
  final scaledDenominator = exponent >= 0
      ? absoluteDenominator.shift(exponent)
      : absoluteDenominator;
  final normalized = (scaledNumerator / scaledDenominator).toDecimal(
    scaleOnInfinitePrecision: calculationDecimalPrecision - 1,
    toBigInt: (scaled) {
      final scaledNumerator = scaled.numerator.abs();
      final quotient = scaledNumerator ~/ scaled.denominator;
      final remainder = scaledNumerator % scaled.denominator;
      final comparison = (remainder * BigInt.from(2)).compareTo(scaled.denominator);
      final roundsUp = comparison > 0 || (comparison == 0 && quotient.isOdd);
      return roundsUp ? quotient + BigInt.one : quotient;
    },
  );
  final sign = numerator.sign == denominator.sign ? 1 : -1;
  final magnitude = roundCalculationDecimal(normalized).shift(exponent).abs();
  return sign < 0 ? -magnitude : magnitude;
}

Decimal meanCalculationDecimals(Iterable<Decimal> values) {
  final items = values.toList(growable: false);
  if (items.isEmpty) throw const FormatException('Mean requires observations.');
  var total = Decimal.zero;
  for (final value in items) {
    total = addCalculationDecimals(total, value);
  }
  return divideCalculationDecimals(total, Decimal.fromInt(items.length));
}

Decimal squareRootCalculationDecimal(Decimal value) {
  if (value < Decimal.zero) {
    throw const FormatException('Square root requires a non-negative value.');
  }
  if (value == Decimal.zero) return Decimal.zero;

  final valueExponent = _decimalOrderOfMagnitude(value);
  final rootExponent = _floorHalf(valueExponent);
  final places = calculationDecimalPrecision - 1 - rootExponent;
  final scaledRadicand = value.shift(2 * places);
  var root = _integerSquareRoot(scaledRadicand.toBigInt());
  final oddMidpoint = root * BigInt.two + BigInt.one;
  final midpointSquareTimesFour = oddMidpoint * oddMidpoint;
  final midpointComparison =
      (scaledRadicand * Decimal.fromInt(4)).compareTo(
    Decimal.fromBigInt(midpointSquareTimesFour),
  );
  if (midpointComparison > 0 ||
      (midpointComparison == 0 && root.isOdd)) {
    root += BigInt.one;
  }
  return roundCalculationDecimal(
    Decimal.fromBigInt(root).shift(-places),
  );
}

int _decimalOrderOfMagnitude(Decimal value) {
  final absolute = value.abs();
  if (absolute == Decimal.zero) return 0;
  final integerPart = absolute.toBigInt();
  if (integerPart != BigInt.zero) {
    return integerPart.toString().length - 1;
  }
  final scale = absolute.scale;
  final coefficient = absolute.shift(scale).toBigInt();
  return coefficient.toString().length - scale - 1;
}

int _floorHalf(int value) {
  if (value >= 0) return value ~/ 2;
  return -((-value + 1) ~/ 2);
}

BigInt _integerSquareRoot(BigInt value) {
  if (value < BigInt.zero) throw ArgumentError.value(value, 'value');
  if (value < BigInt.from(2)) return value;
  var estimate = BigInt.one << ((value.bitLength + 1) >> 1);
  while (true) {
    final next = (estimate + value ~/ estimate) >> 1;
    if (next >= estimate) return estimate;
    estimate = next;
  }
}
