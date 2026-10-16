import 'package:decimal/decimal.dart';

import 'decimal_support.dart';

final class ScientificUnit {
  ScientificUnit({
    required this.symbol,
    required Map<String, int> dimensions,
    required this.scale,
  }) : dimensions = Map<String, int>.unmodifiable(dimensions);

  final String symbol;
  final Map<String, int> dimensions;
  final Decimal scale;

  bool compatibleWith(ScientificUnit other) =>
      dimensions.length == other.dimensions.length &&
      dimensions.entries.every((entry) => other.dimensions[entry.key] == entry.value);

  Map<String, Object?> toJson() => {
        'symbol': symbol,
        'dimensions': dimensions,
        'scale': calculationDecimalText(scale),
      };
}

final class UnitRegistry {
  UnitRegistry._();

  static const Map<String, int> _none = {};
  static const Map<String, int> _mass = {'mass': 1};
  static const Map<String, int> _volume = {'volume': 1};
  static const Map<String, int> _concentration = {'mass': 1, 'volume': -1};
  static const Map<String, int> _absorbance = {'absorbance': 1};
  static const Map<String, int> _intensity = {'intensity': 1};
  static const Map<String, int> _area = {'pixel': 2};
  static const Map<String, int> _integratedIntensity = {
    'intensity': 1,
    'pixel': 2,
  };

  static final Map<String, ScientificUnit> _units = {
    '1': _unit('1', _none, '1'),
    'g': _unit('g', _mass, '1'),
    'mg': _unit('mg', _mass, '0.001'),
    'ug': _unit('ug', _mass, '0.000001'),
    'ng': _unit('ng', _mass, '0.000000001'),
    'kg': _unit('kg', _mass, '1000'),
    'L': _unit('L', _volume, '1'),
    'mL': _unit('mL', _volume, '0.001'),
    'uL': _unit('uL', _volume, '0.000001'),
    'nL': _unit('nL', _volume, '0.000000001'),
    'g/L': _unit('g/L', _concentration, '1'),
    'mg/mL': _unit('mg/mL', _concentration, '1'),
    'ug/uL': _unit('ug/uL', _concentration, '1'),
    'ug/mL': _unit('ug/mL', _concentration, '0.001'),
    'mg/L': _unit('mg/L', _concentration, '0.001'),
    'ng/uL': _unit('ng/uL', _concentration, '0.001'),
    'mg/uL': _unit('mg/uL', _concentration, '1000'),
    'ug/L': _unit('ug/L', _concentration, '0.000001'),
    'AU': _unit('AU', _absorbance, '1'),
    'intensity': _unit('intensity', _intensity, '1'),
    'pixel': _unit('pixel', {'pixel': 1}, '1'),
    'pixel^2': _unit('pixel^2', _area, '1'),
    'intensity*pixel^2': _unit('intensity*pixel^2', _integratedIntensity, '1'),
  };

  static ScientificUnit parse(String? source) {
    if (source == null || source.trim().isEmpty) return _units['1']!;
    final normalized = source
        .trim()
        .replaceAll('µ', 'u')
        .replaceAll('μ', 'u')
        .replaceAll(' ', '');
    if (normalized == 'ratio' || normalized == 'dimensionless') {
      return _units['1']!;
    }
    final unit = _units[normalized];
    if (unit == null) throw FormatException('Unsupported unit: $source');
    return unit;
  }

  static Decimal conversionFactor(String source, String target) {
    final from = parse(source);
    final to = parse(target);
    if (!from.compatibleWith(to)) {
      throw FormatException('CALC_UNIT_INCOMPATIBLE: $source cannot convert to $target');
    }
    return divideCalculationDecimals(from.scale, to.scale);
  }

  static ScientificUnit multiply(ScientificUnit left, ScientificUnit right) {
    final dimensions = _combineDimensions(left.dimensions, right.dimensions, 1);
    final scale = multiplyCalculationDecimals(left.scale, right.scale);
    final registered = _findRegistered(dimensions, scale);
    if (registered != null) return registered;
    throw const FormatException(
      'The resulting unit is outside the registered unit set.',
    );
  }

  static ScientificUnit divide(ScientificUnit left, ScientificUnit right) {
    final dimensions = _combineDimensions(left.dimensions, right.dimensions, -1);
    final scale = divideCalculationDecimals(left.scale, right.scale);
    final registered = _findRegistered(dimensions, scale);
    if (registered != null) return registered;
    throw const FormatException(
      'The resulting unit is outside the registered unit set.',
    );
  }

  static ScientificUnit quotientUnit(ScientificUnit yUnit, ScientificUnit slopeUnit) {
    final dimensions = _combineDimensions(yUnit.dimensions, slopeUnit.dimensions, -1);
    final scale = divideCalculationDecimals(yUnit.scale, slopeUnit.scale);
    return _findRegistered(dimensions, scale) ??
        ScientificUnit(
          symbol: '${yUnit.symbol}/(${slopeUnit.symbol})',
          dimensions: dimensions,
          scale: scale,
        );
  }

  static ScientificUnit? _findRegistered(
    Map<String, int> dimensions,
    Decimal scale,
  ) {
    for (final unit in _units.values) {
      if (unit.compatibleWith(ScientificUnit(
            symbol: '_',
            dimensions: dimensions,
            scale: scale,
          )) &&
          unit.scale == scale) {
        return unit;
      }
    }
    return null;
  }

  static Map<String, int> _combineDimensions(
    Map<String, int> left,
    Map<String, int> right,
    int rightFactor,
  ) {
    final result = <String, int>{...left};
    for (final entry in right.entries) {
      final next = (result[entry.key] ?? 0) + entry.value * rightFactor;
      if (next == 0) {
        result.remove(entry.key);
      } else {
        result[entry.key] = next;
      }
    }
    return Map<String, int>.unmodifiable(result);
  }

  static ScientificUnit _unit(
    String symbol,
    Map<String, int> dimensions,
    String scale,
  ) =>
      ScientificUnit(
        symbol: symbol,
        dimensions: dimensions,
        scale: Decimal.parse(scale),
      );
}

final class ScientificQuantity {
  const ScientificQuantity(this.value, this.unit);

  final Decimal value;
  final ScientificUnit unit;

  ScientificQuantity toUnit(String target) {
    final targetUnit = UnitRegistry.parse(target);
    if (!unit.compatibleWith(targetUnit)) {
      throw FormatException(
        'CALC_UNIT_INCOMPATIBLE: ${unit.symbol} cannot convert to $target.',
      );
    }
    return ScientificQuantity(
      multiplyCalculationDecimals(
        value,
        UnitRegistry.conversionFactor(unit.symbol, target),
      ),
      targetUnit,
    );
  }

  Map<String, Object?> toJson() => {
        'value': calculationDecimalText(value),
        'unit': unit.symbol,
      };
}
