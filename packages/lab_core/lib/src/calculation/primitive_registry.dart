import 'dart:convert';

import 'package:decimal/decimal.dart';

import '../domain/json_value.dart';
import 'decimal_support.dart';
import 'unit_registry.dart';

typedef PrimitiveApply = PrimitiveResult Function(
  Map<String, Object?> inputs,
  Map<String, Object?> params,
);

final class PrimitiveResult {
  PrimitiveResult({
    required Map<String, Object?> values,
    required this.expression,
    required this.substitution,
    required Map<String, Object?> inputs,
    required Map<String, Object?> intermediates,
    required this.traceValue,
    required this.traceUnit,
    List<String> warnings = const [],
  })  : values = Map<String, Object?>.unmodifiable(values),
        inputs = Map<String, Object?>.unmodifiable(inputs),
        intermediates = Map<String, Object?>.unmodifiable(intermediates),
        warnings = List<String>.unmodifiable(warnings);

  final Map<String, Object?> values;
  final String expression;
  final String substitution;
  final Map<String, Object?> inputs;
  final Map<String, Object?> intermediates;
  final Object? traceValue;
  final String? traceUnit;
  final List<String> warnings;
}

final class PrimitiveDefinition {
  const PrimitiveDefinition({
    required this.id,
    required this.requiredInputs,
    this.optionalInputs = const {},
    this.allowedParams = const {},
    required this.description,
    required this.apply,
    this.buildId = 'lab-core-primitives-2.1',
  });

  final String id;
  final Set<String> requiredInputs;
  final Set<String> optionalInputs;
  final Set<String> allowedParams;
  final String description;
  final PrimitiveApply apply;
  final String buildId;

  PrimitiveResult invoke(
    Map<String, Object?> inputs,
    Map<String, Object?> params,
  ) {
    final missing = requiredInputs.difference(inputs.keys.toSet());
    final unknownInputs = inputs.keys.toSet()
      ..removeAll(requiredInputs)
      ..removeAll(optionalInputs);
    final unknownParams = params.keys.toSet()..removeAll(allowedParams);
    if (missing.isNotEmpty) {
      throw FormatException('$id missing inputs: ${missing.toList()..sort()}');
    }
    if (unknownInputs.isNotEmpty) {
      throw FormatException('$id has unknown inputs: ${unknownInputs.toList()..sort()}');
    }
    if (unknownParams.isNotEmpty) {
      throw FormatException('$id has unknown params: ${unknownParams.toList()..sort()}');
    }
    return apply(inputs, params);
  }
}

/// A versioned allowlist. Pack data can select these functions but cannot
/// register code, import libraries, access files, or make network requests.
final class PrimitiveRegistry {
  PrimitiveRegistry._();

  static final Map<String, PrimitiveDefinition> definitions =
      Map<String, PrimitiveDefinition>.unmodifiable({
    for (final definition in <PrimitiveDefinition>[
      _definition(
        'csv.parse_table@1',
        {'text'},
        {'delimiter', 'has_header', 'column_map'},
        'Parse a bounded CSV text snapshot into typed rows.',
        _parseCsv,
      ),
      _definition(
        'table.select@1',
        {'rows'},
        {'equals'},
        'Select rows by exact declared values.',
        _tableSelect,
      ),
      _definition(
        'table.group_by@1',
        {'rows'},
        {'keys'},
        'Group rows by explicitly selected columns.',
        _tableGroupBy,
      ),
      _definition(
        'math.unit_convert@1',
        {'value'},
        {'from', 'to', 'factor'},
        'Convert values between registered compatible units.',
        _unitConvert,
      ),
      _definition(
        'stats.mean@1',
        {'values'},
        {'unit'},
        'Arithmetic mean of compatible exact decimal observations.',
        _mean,
      ),
      _definition(
        'stats.sd@1',
        {'values'},
        {'unit'},
        'Sample standard deviation with n-1 denominator.',
        _sampleSd,
      ),
      _definitionWithOptional(
        'stats.linear_regression@1',
        {'standards'},
        {'points'},
        {'x_key', 'y_key', 'x_unit', 'y_unit'},
        'Unweighted ordinary least-squares linear fit.',
        _linearRegression,
      ),
      _definitionWithOptional(
        'bca.blank_adjust@1',
        {'standards', 'blank'},
        {},
        {'concentration_key', 'absorbance_key', 'concentration_unit', 'absorbance_unit'},
        'Subtract a declared blank from each standard absorbance.',
        _bcaBlankAdjust,
      ),
      _definitionWithOptional(
        'math.linear_inverse@1',
        {'y', 'slope', 'intercept'},
        {},
        {},
        'Invert a fitted linear model for standard curve interpolation.',
        _linearInverse,
      ),
      _definitionWithOptional(
        'math.subtract@1',
        {'a', 'b'},
        {},
        {},
        'Subtract compatible quantities.',
        _subtract,
      ),
      _definitionWithOptional(
        'math.multiply@1',
        {'a', 'b'},
        {},
        {},
        'Multiply a quantity by one dimensionless scalar.',
        _multiply,
      ),
      _definitionWithOptional(
        'math.divide@1',
        {'numerator', 'denominator'},
        {},
        {},
        'Divide quantities only when the result is a registered unit.',
        _divide,
      ),
      _definitionWithOptional(
        'data.qc_range@1',
        {'x', 'low', 'high'},
        {},
        {'warning', 'unit'},
        'Check a value against explicit limits without deleting it.',
        _qcRange,
      ),
      _definitionWithOptional(
        'data.qc_limits@1',
        {'x', 'low', 'high'},
        {},
        {'warning', 'unit'},
        'Check explicit quality limits without removing out-of-range values.',
        _qcRange,
      ),
      _definitionWithOptional(
        'data.export_table@1',
        {'rows'},
        {},
        {},
        'Serialize rows for the host AssetStore to save as a new derived Asset.',
        _exportTable,
      ),
      _definitionWithOptional(
        'wb.normalize_ratio@1',
        {'target_intensity', 'reference_intensity'},
        {'calibrator_ratio'},
        {'method_warning'},
        'Normalize explicitly confirmed ROI intensities by a selected reference.',
        _wbNormalizeRatio,
      ),
    ])
      definition.id: definition,
  });

  static const int maxRows = 100000;
  static const int maxCsvBytes = 8 * 1024 * 1024;

  static PrimitiveDefinition _definition(
    String id,
    Set<String> required,
    Set<String> params,
    String description,
    PrimitiveApply apply,
  ) =>
      PrimitiveDefinition(
        id: id,
        requiredInputs: Set<String>.unmodifiable(required),
        allowedParams: Set<String>.unmodifiable(params),
        description: description,
        apply: apply,
      );

  static PrimitiveDefinition _definitionWithOptional(
    String id,
    Set<String> required,
    Set<String> optional,
    Set<String> params,
    String description,
    PrimitiveApply apply,
  ) =>
      PrimitiveDefinition(
        id: id,
        requiredInputs: Set<String>.unmodifiable(required),
        optionalInputs: Set<String>.unmodifiable(optional),
        allowedParams: Set<String>.unmodifiable(params),
        description: description,
        apply: apply,
      );
}

PrimitiveResult _result({
  required Map<String, Object?> values,
  required String expression,
  required String substitution,
  required Map<String, Object?> inputs,
  Map<String, Object?> intermediates = const {},
  required Object? traceValue,
  String? traceUnit,
  List<String> warnings = const [],
}) =>
    PrimitiveResult(
      values: values,
      expression: expression,
      substitution: substitution,
      inputs: inputs,
      intermediates: intermediates,
      traceValue: traceValue,
      traceUnit: traceUnit,
      warnings: warnings,
    );

ScientificQuantity _quantity(Object? value, [String? expectedUnit]) {
  if (value is ScientificQuantity) {
    return expectedUnit == null ? value : value.toUnit(expectedUnit);
  }
  return ScientificQuantity(
    parseCalculationDecimal(value),
    UnitRegistry.parse(expectedUnit),
  );
}

List<Map<String, Object?>> _rows(Object? value) {
  if (value is! List || value.length > PrimitiveRegistry.maxRows) {
    throw const FormatException('Expected a bounded table of rows.');
  }
  return value.map((row) {
    if (row is! Map) throw const FormatException('Table rows must be objects.');
    return requireJsonObject(row, 'table row');
  }).toList(growable: false);
}

Object? traceScalar(Object? value) {
  if (value is ScientificQuantity) return calculationDecimalText(value.value);
  if (value is Decimal) return calculationDecimalText(value);
  if (value is bool) return value ? 'true' : 'false';
  if (value == null || value is String || value is int) return value;
  if (value is List || value is Map) return canonicalJson(value);
  throw FormatException('Unsupported trace value ${value.runtimeType}.');
}

Object? traceJsonValue(Object? value) {
  if (value is ScientificQuantity) return value.toJson();
  if (value is Decimal) return calculationDecimalText(value);
  if (value is bool || value == null || value is String || value is int) return value;
  if (value is List) return value.map(traceJsonValue).toList(growable: false);
  if (value is Map) {
    final result = <String, Object?>{};
    for (final entry in value.entries) {
      if (entry.key is! String) {
        throw const FormatException('Trace object keys must be strings.');
      }
      result[entry.key as String] = traceJsonValue(entry.value);
    }
    return result;
  }
  throw FormatException('Unsupported trace JSON value ${value.runtimeType}.');
}

PrimitiveResult _parseCsv(
  Map<String, Object?> inputs,
  Map<String, Object?> params,
) {
  final text = inputs['text'];
  if (text is! String || utf8.encode(text).length > PrimitiveRegistry.maxCsvBytes) {
    throw const FormatException('CSV text must be UTF-8 text no larger than 8 MiB.');
  }
  final delimiter = params['delimiter'] ?? ',';
  if (delimiter is! String || delimiter.length != 1 || '\r\n"'.contains(delimiter)) {
    throw const FormatException('CSV delimiter must be one safe character.');
  }
  final hasHeader = params['has_header'] ?? true;
  if (hasHeader is! bool) throw const FormatException('has_header must be boolean.');
  final rawRows = _parseCsvRows(text, delimiter);
  if (rawRows.isEmpty || rawRows.length > PrimitiveRegistry.maxRows + 1) {
    throw const FormatException('CSV is empty or exceeds the maximum row count.');
  }
  final headers = hasHeader
      ? rawRows.removeAt(0)
      : List<String>.generate(rawRows.first.length, (index) => 'column_${index + 1}');
  if (headers.isEmpty ||
      headers.any((header) => header.trim().isEmpty) ||
      headers.toSet().length != headers.length ||
      rawRows.any((row) => row.length != headers.length)) {
    throw const FormatException('CSV headers must be unique and all rows the same width.');
  }
  final rawMap = params['column_map'] ?? const <String, Object?>{};
  if (rawMap is! Map) throw const FormatException('column_map must be an object.');
  final columnMap = requireJsonObject(rawMap, 'column_map');
  if (columnMap.entries.any((entry) =>
      entry.key.isEmpty || entry.value is! String || (entry.value as String).isEmpty)) {
    throw const FormatException('column_map must map source names to non-empty names.');
  }
  if (columnMap.keys.any((key) => !headers.contains(key))) {
    throw const FormatException('column_map references a missing source column.');
  }
  final mapped = headers.map((header) => columnMap[header] as String? ?? header).toList();
  if (mapped.toSet().length != mapped.length) {
    throw const FormatException('column_map creates duplicate output columns.');
  }
  final rows = rawRows
      .map((row) => <String, Object?>{
            for (var index = 0; index < mapped.length; index++) mapped[index]: row[index],
          })
      .toList(growable: false);
  return _result(
    values: {'rows': rows},
    expression: 'CSV text parsed into rows using the declared delimiter and column map',
    substitution: 'rows=${rows.length}; columns=${mapped.length}; delimiter=$delimiter',
    inputs: {'text_bytes': utf8.encode(text).length},
    intermediates: {'columns': mapped, 'row_count': rows.length},
    traceValue: rows.length,
  );
}

List<List<String>> _parseCsvRows(String text, String delimiter) {
  final rows = <List<String>>[];
  var row = <String>[];
  final field = StringBuffer();
  var quoted = false;
  for (var index = 0; index < text.length; index++) {
    final char = text[index];
    if (quoted) {
      if (char == '"') {
        if (index + 1 < text.length && text[index + 1] == '"') {
          field.write('"');
          index++;
        } else {
          quoted = false;
        }
      } else {
        field.write(char);
      }
    } else if (char == '"') {
      if (field.length != 0) throw const FormatException('Unexpected CSV quote.');
      quoted = true;
    } else if (char == delimiter) {
      row.add(field.toString());
      field.clear();
    } else if (char == '\n' || char == '\r') {
      row.add(field.toString());
      field.clear();
      rows.add(row);
      row = <String>[];
      if (char == '\r' && index + 1 < text.length && text[index + 1] == '\n') index++;
    } else {
      field.write(char);
    }
  }
  if (quoted) throw const FormatException('CSV has an unterminated quoted field.');
  if (field.length > 0 || row.isNotEmpty || text.isEmpty || !'\r\n'.contains(text.substring(text.length - 1))) {
    row.add(field.toString());
    rows.add(row);
  }
  return rows;
}

PrimitiveResult _tableSelect(Map<String, Object?> inputs, Map<String, Object?> params) {
  final rows = _rows(inputs['rows']);
  final rawEquals = params['equals'] ?? const <String, Object?>{};
  if (rawEquals is! Map) throw const FormatException('table.select filters must be an object.');
  final equals = requireJsonObject(rawEquals, 'equals');
  for (final key in equals.keys) {
    if (key.isEmpty || rows.any((row) => !row.containsKey(key))) {
      throw FormatException('Filter column $key is absent from a table row.');
    }
  }
  final selected = rows
      .where((row) => equals.entries.every((entry) => row[entry.key] == entry.value))
      .toList(growable: false);
  return _result(
    values: {'rows': selected},
    expression: 'rows retained where each declared column equals its configured value',
    substitution: '${selected.length} of ${rows.length} rows match ${canonicalJson(equals)}',
    inputs: {'row_count': rows.length, 'equals': equals},
    intermediates: {'selected_row_count': selected.length},
    traceValue: selected.length,
  );
}

PrimitiveResult _tableGroupBy(Map<String, Object?> inputs, Map<String, Object?> params) {
  final rows = _rows(inputs['rows']);
  final keys = params['keys'];
  if (keys is! List || keys.isEmpty || keys.any((key) => key is! String || key.isEmpty)) {
    throw const FormatException('table.group_by keys must be a non-empty string list.');
  }
  final groups = <String, Map<String, Object?>>{};
  for (final row in rows) {
    if (keys.any((key) => !row.containsKey(key))) {
      throw const FormatException('A group key is missing from a row.');
    }
    final keyValues = <String, Object?>{for (final key in keys.cast<String>()) key: row[key]};
    final token = canonicalJson(keyValues);
    groups.putIfAbsent(token, () => {'key': keyValues, 'rows': <Map<String, Object?>>[]});
    (groups[token]!['rows'] as List<Map<String, Object?>>).add(row);
  }
  final resultGroups = groups.values.toList(growable: false);
  return _result(
    values: {'groups': resultGroups},
    expression: 'rows grouped by the declared key columns',
    substitution: '${rows.length} rows -> ${resultGroups.length} groups by ${keys.join(', ')}',
    inputs: {'row_count': rows.length, 'keys': keys},
    intermediates: {
      'group_sizes': resultGroups.map((group) => (group['rows'] as List).length).toList(),
    },
    traceValue: resultGroups.length,
  );
}

PrimitiveResult _unitConvert(Map<String, Object?> inputs, Map<String, Object?> params) {
  final source = params['from'];
  final target = params['to'];
  if (source is! String || target is! String) {
    throw const FormatException('unit_convert requires string from and to units.');
  }
  final factor = parseCalculationDecimal(params['factor'], field: 'factor');
  final registered = UnitRegistry.conversionFactor(source, target);
  if (factor != registered) {
    throw const FormatException('AI-supplied factor conflicts with the registered unit conversion.');
  }
  final input = _quantity(inputs['value'], source);
  final converted = ScientificQuantity(
    multiplyCalculationDecimals(input.value, factor),
    UnitRegistry.parse(target),
  );
  return _result(
    values: {'value': converted},
    expression: 'value * registered_unit_conversion_factor',
    substitution: '${input.value} $source * $factor = ${converted.value} $target',
    inputs: {'value': input, 'from': source, 'to': target, 'factor': factor},
    intermediates: {'source_scale': input.unit.scale, 'target_scale': converted.unit.scale},
    traceValue: converted.value,
    traceUnit: target,
  );
}

PrimitiveResult _mean(Map<String, Object?> inputs, Map<String, Object?> params) {
  final rawValues = inputs['values'];
  if (rawValues is! List || rawValues.isEmpty) {
    throw const FormatException('stats.mean requires a non-empty list.');
  }
  final unitParam = params['unit'];
  if (unitParam != null && unitParam is! String) {
    throw const FormatException('stats.mean unit must be a string.');
  }
  final values = rawValues.map((value) => _quantity(value, unitParam as String?)).toList();
  final first = values.first;
  if (values.any((item) => !first.unit.compatibleWith(item.unit))) {
    throw const FormatException('CALC_UNIT_INCOMPATIBLE: mean inputs have different units.');
  }
  final converted = values.map((item) => item.toUnit(first.unit.symbol).value).toList();
  final total = converted.fold(
    Decimal.zero,
    addCalculationDecimals,
  );
  final average = divideCalculationDecimals(total, Decimal.fromInt(converted.length));
  final result = ScientificQuantity(average, first.unit);
  return _result(
    values: {'value': result},
    expression: 'mean = sum(values) / n',
    substitution: '$total / ${converted.length} = $average',
    inputs: {'values': values},
    intermediates: {'n': converted.length, 'sum': total},
    traceValue: average,
    traceUnit: first.unit.symbol,
  );
}

PrimitiveResult _sampleSd(Map<String, Object?> inputs, Map<String, Object?> params) {
  final rawValues = inputs['values'];
  if (rawValues is! List || rawValues.length < 2) {
    throw const FormatException('stats.sd requires at least two observations.');
  }
  final unitParam = params['unit'];
  if (unitParam != null && unitParam is! String) {
    throw const FormatException('stats.sd unit must be a string.');
  }
  final values = rawValues.map((value) => _quantity(value, unitParam as String?)).toList();
  final first = values.first;
  if (values.any((item) => !first.unit.compatibleWith(item.unit))) {
    throw const FormatException('CALC_UNIT_INCOMPATIBLE: SD inputs have different units.');
  }
  final converted = values.map((item) => item.toUnit(first.unit.symbol).value).toList();
  final average = meanCalculationDecimals(converted);
  final deviations = converted
      .map((value) => subtractCalculationDecimals(value, average))
      .toList();
  final squared = deviations
      .map((value) => multiplyCalculationDecimals(value, value))
      .toList();
  final squaredTotal = squared.fold(
    Decimal.zero,
    addCalculationDecimals,
  );
  final variance = divideCalculationDecimals(squaredTotal, Decimal.fromInt(converted.length - 1));
  final deviation = squareRootCalculationDecimal(variance);
  final result = ScientificQuantity(deviation, first.unit);
  return _result(
    values: {'value': result},
    expression: 'sample_sd = sqrt(sum((x - mean)^2) / (n - 1))',
    substitution: 'sqrt($squaredTotal / (${converted.length} - 1)) = $deviation',
    inputs: {'values': values},
    intermediates: {
      'n': converted.length,
      'mean': average,
      'deviations': deviations,
      'squared_deviations': squared,
      'sum_squared_deviations': squaredTotal,
      'sample_variance': variance,
    },
    traceValue: deviation,
    traceUnit: first.unit.symbol,
  );
}

PrimitiveResult _linearRegression(
  Map<String, Object?> inputs,
  Map<String, Object?> params,
) {
  final rows = _rows(inputs['standards'] ?? inputs['points']);
  if (rows.length < 2) throw const FormatException('Linear regression requires at least two rows.');
  final xKey = params['x_key'] ?? 'concentration';
  final yKey = params['y_key'] ?? 'absorbance';
  final xUnitName = params['x_unit'] ?? '1';
  final yUnitName = params['y_unit'] ?? '1';
  if ([xKey, yKey, xUnitName, yUnitName].any((value) => value is! String || value.isEmpty)) {
    throw const FormatException('Linear regression keys and units must be non-empty strings.');
  }
  final xUnit = UnitRegistry.parse(xUnitName as String);
  final yUnit = UnitRegistry.parse(yUnitName as String);
  final xs = <Decimal>[];
  final ys = <Decimal>[];
  for (final row in rows) {
    if (!row.containsKey(xKey) || !row.containsKey(yKey)) {
      throw const FormatException('Regression rows are missing the configured x or y column.');
    }
    xs.add(parseCalculationDecimal(row[xKey], field: 'regression x'));
    ys.add(parseCalculationDecimal(row[yKey], field: 'regression y'));
  }
  if (xs.toSet().length < 2) {
    throw const FormatException('Linear regression requires at least two distinct x values.');
  }
  final n = Decimal.fromInt(xs.length);
  final xBar = divideCalculationDecimals(
    xs.fold(Decimal.zero, addCalculationDecimals),
    n,
  );
  final yBar = divideCalculationDecimals(
    ys.fold(Decimal.zero, addCalculationDecimals),
    n,
  );
  final centeredX = xs.map((x) => subtractCalculationDecimals(x, xBar)).toList();
  final centeredY = ys.map((y) => subtractCalculationDecimals(y, yBar)).toList();
  final sxx = centeredX.fold(
    Decimal.zero,
    (sum, value) => addCalculationDecimals(
      sum,
      multiplyCalculationDecimals(value, value),
    ),
  );
  final sxy = List<int>.generate(xs.length, (index) => index)
      .fold(Decimal.zero, (sum, index) => addCalculationDecimals(
            sum,
            multiplyCalculationDecimals(centeredX[index], centeredY[index]),
          ));
  if (sxx == Decimal.zero) throw const FormatException('Linear regression has zero Sxx.');
  final slope = divideCalculationDecimals(sxy, sxx);
  final intercept = subtractCalculationDecimals(
    yBar,
    multiplyCalculationDecimals(slope, xBar),
  );
  final residuals = List<int>.generate(xs.length, (index) => index)
      .map((index) => subtractCalculationDecimals(
            ys[index],
            addCalculationDecimals(
              multiplyCalculationDecimals(slope, xs[index]),
              intercept,
            ),
          ))
      .toList();
  final rss = residuals.fold(
    Decimal.zero,
    (sum, value) => addCalculationDecimals(
      sum,
      multiplyCalculationDecimals(value, value),
    ),
  );
  final sst = centeredY.fold(
    Decimal.zero,
    (sum, value) => addCalculationDecimals(
      sum,
      multiplyCalculationDecimals(value, value),
    ),
  );
  final rSquared = sst == Decimal.zero
      ? (rss == Decimal.zero ? Decimal.one : Decimal.zero)
      : subtractCalculationDecimals(
          Decimal.one,
          divideCalculationDecimals(rss, sst),
        );
  final slopeUnit = UnitRegistry.quotientUnit(yUnit, xUnit);
  final resultValues = <String, Object?>{
    'slope': ScientificQuantity(slope, slopeUnit),
    'intercept': ScientificQuantity(intercept, yUnit),
    'r_squared': ScientificQuantity(rSquared, UnitRegistry.parse('1')),
    'min_x': ScientificQuantity(xs.reduce((a, b) => a < b ? a : b), xUnit),
    'max_x': ScientificQuantity(xs.reduce((a, b) => a > b ? a : b), xUnit),
  };
  return _result(
    values: resultValues,
    expression: 'slope=Sxy/Sxx; intercept=ybar-slope*xbar; R2=1-RSS/SST',
    substitution: 'slope=$sxy/$sxx; intercept=$yBar-$slope*$xBar',
    inputs: {'standards': rows, 'x_key': xKey, 'y_key': yKey},
    intermediates: {
      'n': xs.length,
      'xbar': xBar,
      'ybar': yBar,
      'centered_x': centeredX,
      'centered_y': centeredY,
      'sxx': sxx,
      'sxy': sxy,
      'rss': rss,
      'sst': sst,
      'r_squared': rSquared,
      'intercept': intercept,
      'residuals': residuals,
    },
    traceValue: slope,
    traceUnit: slopeUnit.symbol,
  );
}

PrimitiveResult _bcaBlankAdjust(
  Map<String, Object?> inputs,
  Map<String, Object?> params,
) {
  final standards = _rows(inputs['standards']);
  final absorbanceUnit = params['absorbance_unit'] ?? 'AU';
  final concentrationUnit = params['concentration_unit'] ?? 'ug/mL';
  final concentrationKey = params['concentration_key'] ?? 'concentration';
  final absorbanceKey = params['absorbance_key'] ?? 'absorbance';
  if ([absorbanceUnit, concentrationUnit, concentrationKey, absorbanceKey]
      .any((value) => value is! String || value.isEmpty)) {
    throw const FormatException('BCA columns and units must be non-empty strings.');
  }
  final concentrationUnitName = concentrationUnit as String;
  final absorbanceUnitName = absorbanceUnit as String;
  final concentrationColumn = concentrationKey as String;
  final absorbanceColumn = absorbanceKey as String;
  UnitRegistry.parse(concentrationUnitName);
  UnitRegistry.parse(absorbanceUnitName);
  final blank = _quantity(inputs['blank'], absorbanceUnitName);
  final adjusted = <Map<String, Object?>>[];
  for (final row in standards) {
    if (!row.containsKey(concentrationColumn) || !row.containsKey(absorbanceColumn)) {
      throw const FormatException('BCA standards require concentration and absorbance.');
    }
    final rawConcentration = row[concentrationColumn];
    final concentration = parseCalculationDecimal(row[concentrationColumn], field: 'concentration');
    final absorbance = parseCalculationDecimal(row[absorbanceColumn], field: 'absorbance');
    adjusted.add({
      'concentration': rawConcentration is String
          ? rawConcentration
          : calculationDecimalText(concentration),
      'absorbance': calculationDecimalText(
        subtractCalculationDecimals(absorbance, blank.value),
      ),
    });
  }
  return _result(
    values: {'standards': adjusted},
    expression: 'y_i_corrected = y_i - blank',
    substitution: 'each of ${standards.length} absorbances minus ${blank.value} ${blank.unit.symbol}',
    inputs: {'standards': standards, 'blank': blank},
    intermediates: {
      'corrected_rows': adjusted,
      'concentration_unit': concentrationUnitName,
      'absorbance_unit': absorbanceUnitName,
    },
    traceValue: adjusted.length,
  );
}

PrimitiveResult _linearInverse(Map<String, Object?> inputs, Map<String, Object?> params) {
  final y = _quantity(inputs['y']);
  final slope = _quantity(inputs['slope']);
  var intercept = _quantity(inputs['intercept']);
  if (!y.unit.compatibleWith(intercept.unit)) {
    throw const FormatException('CALC_UNIT_INCOMPATIBLE: inverse y and intercept units differ.');
  }
  intercept = intercept.toUnit(y.unit.symbol);
  if (slope.value == Decimal.zero) throw const FormatException('Cannot invert a zero slope.');
  final resultUnit = UnitRegistry.quotientUnit(y.unit, slope.unit);
  final adjustedY = subtractCalculationDecimals(y.value, intercept.value);
  final value = divideCalculationDecimals(adjustedY, slope.value);
  final result = ScientificQuantity(value, resultUnit);
  return _result(
    values: {'value': result},
    expression: 'x = (y - intercept) / slope',
    substitution: '(${y.value} - ${intercept.value}) / ${slope.value} = $value',
    inputs: {'y': y, 'slope': slope, 'intercept': intercept},
    intermediates: {'adjusted_y': adjustedY},
    traceValue: value,
    traceUnit: resultUnit.symbol,
  );
}

PrimitiveResult _subtract(Map<String, Object?> inputs, Map<String, Object?> params) {
  final a = _quantity(inputs['a']);
  var b = _quantity(inputs['b']);
  if (!a.unit.compatibleWith(b.unit)) {
    throw const FormatException('CALC_UNIT_INCOMPATIBLE: subtraction requires matching dimensions.');
  }
  b = b.toUnit(a.unit.symbol);
  final value = subtractCalculationDecimals(a.value, b.value);
  final result = ScientificQuantity(value, a.unit);
  return _result(
    values: {'value': result},
    expression: 'a - b',
    substitution: '${a.value} - ${b.value} = $value',
    inputs: {'a': a, 'b': b},
    traceValue: value,
    traceUnit: a.unit.symbol,
  );
}

PrimitiveResult _multiply(Map<String, Object?> inputs, Map<String, Object?> params) {
  final a = _quantity(inputs['a']);
  final b = _quantity(inputs['b']);
  if (a.unit.dimensions.isNotEmpty && b.unit.dimensions.isNotEmpty) {
    throw const FormatException('Multiplication is restricted to one dimensional quantity and one scalar.');
  }
  final resultUnit = a.unit.dimensions.isNotEmpty ? a.unit : b.unit;
  final value = multiplyCalculationDecimals(a.value, b.value);
  final result = ScientificQuantity(value, resultUnit);
  return _result(
    values: {'value': result},
    expression: 'a * b',
    substitution: '${a.value} * ${b.value} = $value',
    inputs: {'a': a, 'b': b},
    intermediates: {'result_unit': resultUnit.symbol},
    traceValue: value,
    traceUnit: resultUnit.symbol,
  );
}

PrimitiveResult _divide(Map<String, Object?> inputs, Map<String, Object?> params) {
  final numerator = _quantity(inputs['numerator']);
  final denominator = _quantity(inputs['denominator']);
  if (denominator.value == Decimal.zero) throw const FormatException('Division by zero is not allowed.');
  final unit = UnitRegistry.divide(numerator.unit, denominator.unit);
  final value = divideCalculationDecimals(numerator.value, denominator.value);
  final result = ScientificQuantity(value, unit);
  return _result(
    values: {'value': result},
    expression: 'numerator / denominator',
    substitution: '${numerator.value} ${numerator.unit.symbol} / ${denominator.value} ${denominator.unit.symbol} = $value ${unit.symbol}',
    inputs: {'numerator': numerator, 'denominator': denominator},
    intermediates: {'result_unit': unit.symbol},
    traceValue: value,
    traceUnit: unit.symbol,
  );
}

PrimitiveResult _qcRange(Map<String, Object?> inputs, Map<String, Object?> params) {
  final rawUnit = params['unit'];
  if (rawUnit != null && rawUnit is! String) throw const FormatException('QC unit must be a string.');
  final unit = rawUnit as String?;
  final value = _quantity(inputs['x'], unit);
  var low = _quantity(inputs['low'], unit);
  var high = _quantity(inputs['high'], unit);
  if (!value.unit.compatibleWith(low.unit) || !value.unit.compatibleWith(high.unit)) {
    throw const FormatException('CALC_UNIT_INCOMPATIBLE: range limits must use the input unit.');
  }
  low = low.toUnit(value.unit.symbol);
  high = high.toUnit(value.unit.symbol);
  if (low.value > high.value) throw const FormatException('Range lower bound exceeds upper bound.');
  final inRange = value.value >= low.value && value.value <= high.value;
  final warning = params['warning'] ?? 'Value is outside the configured range.';
  if (warning is! String) throw const FormatException('QC warning must be a string.');
  return _result(
    values: {'in_range': inRange},
    expression: 'low <= value <= high',
    substitution: '${low.value} <= ${value.value} <= ${high.value}',
    inputs: {'x': value, 'low': low, 'high': high},
    intermediates: {},
    traceValue: inRange,
    warnings: inRange ? const [] : [warning],
  );
}

PrimitiveResult _exportTable(Map<String, Object?> inputs, Map<String, Object?> params) {
  final rows = _rows(inputs['rows']);
  final serialized = canonicalJson(rows);
  return _result(
    values: {'json': serialized},
    expression: 'rows serialized as canonical JSON for host AssetStore export',
    substitution: '${rows.length} rows serialized; host must create a new derived Asset',
    inputs: {'rows': rows},
    intermediates: {'row_count': rows.length},
    traceValue: rows.length,
    warnings: const ['AssetStore must assign the output SHA-256 and preserve source lineage.'],
  );
}

PrimitiveResult _wbNormalizeRatio(
  Map<String, Object?> inputs,
  Map<String, Object?> params,
) {
  final target = _quantity(inputs['target_intensity'], 'intensity');
  final reference = _quantity(inputs['reference_intensity'], 'intensity');
  if (!target.unit.compatibleWith(reference.unit)) {
    throw const FormatException('CALC_UNIT_INCOMPATIBLE: WB target and reference intensities differ.');
  }
  final referenceValue = reference.toUnit('intensity').value;
  if (referenceValue <= Decimal.zero) {
    throw const FormatException('WB normalization denominator must be greater than zero.');
  }
  final ratio = divideCalculationDecimals(target.toUnit('intensity').value, referenceValue);
  final ratioQuantity = ScientificQuantity(ratio, UnitRegistry.parse('1'));
  final values = <String, Object?>{};
  String expression;
  String substitution;
  Object traceValue = ratio;
  final intermediates = <String, Object?>{'target_to_reference_ratio': ratio};
  if (inputs.containsKey('calibrator_ratio')) {
    final calibratorQuantity = _quantity(inputs['calibrator_ratio'], '1');
    final calibrator = calibratorQuantity.value;
    if (calibrator <= Decimal.zero) throw const FormatException('WB calibrator ratio must be greater than zero.');
    final relative = divideCalculationDecimals(ratio, calibrator);
    values['ratio'] = ratioQuantity;
    values['relative_ratio'] = ScientificQuantity(relative, UnitRegistry.parse('1'));
    expression = 'relative_normalized = (target_intensity / reference_intensity) / calibrator_ratio';
    substitution = '(${target.value} / ${reference.value}) / $calibrator = $relative';
    intermediates['calibrator_ratio'] = calibrator;
    traceValue = relative;
  } else {
    values['value'] = ratioQuantity;
    expression = 'normalized_ratio = target_intensity / reference_intensity';
    substitution = '${target.value} / ${reference.value} = $ratio';
  }
  final warning = params['method_warning'] ??
      'Confirm the loading control and normalization method in the experiment procedure.';
  if (warning is! String) throw const FormatException('WB method warning must be a string.');
  return _result(
    values: values,
    expression: expression,
    substitution: substitution,
    inputs: {...inputs, 'target_intensity': target, 'reference_intensity': reference},
    intermediates: intermediates,
    traceValue: traceValue,
    traceUnit: '1',
    warnings: [warning],
  );
}
