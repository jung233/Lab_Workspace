import 'dart:convert';

import 'package:decimal/decimal.dart';

import '../calculation/decimal_support.dart';
import '../calculation/calculation_engine.dart';
import '../calculation/primitive_registry.dart';
import '../calculation/unit_registry.dart';
import '../domain/json_value.dart';
import 'calculation_pack.dart';

final class CalculationPackValidator {
  CalculationPackValidator._();

  static const _packIdPattern = r'^[a-z0-9][a-z0-9._-]*$';
  static const _versionPattern = r'^[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?$';
  static const maxDocumentBytes = 2 * 1024 * 1024;
  static final RegExp _referencePattern =
      RegExp(r'^\$(inputs|steps)(?:\.[A-Za-z_][A-Za-z0-9_-]*)+$');
  static final RegExp _identifierPattern =
      RegExp(r'^[A-Za-z_][A-Za-z0-9_-]*$');

  /// Declared output keys for a trusted primitive. Workflow binding and trace
  /// verification use the same allowlist as Pack validation.
  static Set<String> outputKeysFor(String operationId) =>
      Set<String>.unmodifiable(_outputsFor(operationId));

  static PackValidationReport validate(
    Map<String, Object?> document, {
    bool trustedBuiltIn = false,
  }) {
    final errors = <String>[];
    final warnings = <String>[];
    final unsupported = <String>[];
    final requiresUserInput = <String>[];
    try {
      if (utf8.encode(canonicalJson(document)).length > maxDocumentBytes) {
        errors.add('Calculation Pack document exceeds the 2 MiB content limit.');
      }
    } on Object {
      errors.add('Pack document contains values outside the canonical JSON contract.');
    }
    const expectedFields = {
      'schema_version', 'pack_id', 'version', 'kind', 'status', 'title',
      'inputs', 'pipeline', 'outputs', 'quality_gates', 'tests', 'review',
    };
    final extraFields = document.keys.toSet().difference(expectedFields);
    final missingFields = expectedFields.difference(document.keys.toSet());
    if (extraFields.isNotEmpty) {
      errors.add('Unknown top-level fields: ${_sorted(extraFields)}');
    }
    if (missingFields.isNotEmpty) {
      errors.add('Missing fields: ${_sorted(missingFields)}');
    }
    if (document['schema_version'] != '2.0') errors.add('Unsupported Calculation Pack schema_version.');
    if (document['kind'] != 'calculation') errors.add('kind must be calculation.');
    final packId = document['pack_id'];
    if (packId is! String || !RegExp(_packIdPattern).hasMatch(packId)) {
      errors.add('pack_id is invalid.');
    }
    final version = document['version'];
    if (version is! String || !RegExp(_versionPattern).hasMatch(version)) {
      errors.add('version must be a semantic version.');
    }
    if (document['status'] != 'draft' && document['status'] != 'approved') {
      errors.add('status must be draft or approved.');
    }
    if (document['title'] is! String || (document['title'] as String).trim().isEmpty) {
      errors.add('title must be a non-empty string.');
    }
    try {
      _rejectFloatingPoint(document, r'$');
    } on FormatException catch (error) {
      errors.add(error.toString());
    }

    final inputs = _objectList(document['inputs'], 'inputs', errors);
    final declaredInputs = <String, Map<String, Object?>>{};
    const inputFields = {'key', 'kind', 'unit', 'required'};
    const validKinds = {
      'decimal', 'integer', 'text', 'table', 'asset_ref', 'sample_ref', 'boolean',
    };
    for (var index = 0; index < inputs.length; index++) {
      final item = inputs[index];
      final path = 'inputs[$index]';
      _rejectExtraKeys(item, inputFields, path, errors);
      final key = item['key'];
      if (key is! String || !_identifierPattern.hasMatch(key)) {
        errors.add('$path.key must be a valid non-empty identifier.');
      } else if (declaredInputs.containsKey(key)) {
        errors.add('Duplicate input key: $key');
      } else {
        declaredInputs[key] = item;
      }
      if (!validKinds.contains(item['kind'])) errors.add('$path.kind is unsupported.');
      if (item['required'] is! bool) errors.add('$path.required must be boolean.');
      if (item.containsKey('unit') && item['unit'] != null) {
        final unit = item['unit'];
        if (unit is! String) {
          errors.add('$path.unit must be a string or null.');
        } else {
          _checkUnit(unit, '$path.unit', errors);
        }
        if (item['kind'] != 'decimal') {
          errors.add('$path.unit is only valid for decimal inputs.');
        }
      }
    }

    final rawPipeline = document['pipeline'];
    final pipeline = _objectList(rawPipeline, 'pipeline', errors);
    if (pipeline.isEmpty) errors.add('pipeline must be a non-empty array.');
    if (pipeline.length > 512) errors.add('pipeline cannot exceed 512 operations.');
    final stepIds = <String>{};
    final stepOperations = <String, String>{};
    final priorOutputs = <String, Set<String>>{};
    const pipelineFields = {'step_id', 'op', 'inputs', 'params'};
    for (var index = 0; index < pipeline.length; index++) {
      final step = pipeline[index];
      final path = 'pipeline[$index]';
      _rejectExtraKeys(step, pipelineFields, path, errors);
      final stepId = step['step_id'];
      final operationId = step['op'];
      if (stepId is! String || !_identifierPattern.hasMatch(stepId)) {
        errors.add('$path.step_id must be a valid non-empty identifier.');
        continue;
      }
      if (!stepIds.add(stepId)) {
        errors.add('Duplicate step_id: $stepId');
        continue;
      }
      if (operationId is! String) {
        errors.add('$path.op must be a registered operation id.');
        priorOutputs[stepId] = <String>{};
        continue;
      }
      final primitive = PrimitiveRegistry.definitions[operationId];
      if (primitive == null) {
        unsupported.add(operationId);
        errors.add('CALC_PRIMITIVE_MISSING: $operationId');
        priorOutputs[stepId] = <String>{};
        continue;
      }
      stepOperations[stepId] = operationId;
      final stepInputs = _object(step['inputs'], '$path.inputs', errors);
      final params = _object(step['params'], '$path.params', errors);
      final missingInputs = primitive.requiredInputs.difference(stepInputs.keys.toSet());
      final extraInputs = stepInputs.keys.toSet()
          .difference(primitive.requiredInputs)
          .difference(primitive.optionalInputs);
      final extraParams = params.keys.toSet().difference(primitive.allowedParams);
      if (missingInputs.isNotEmpty) {
        errors.add('$path missing primitive inputs: ${_sorted(missingInputs)}');
      }
      if (extraInputs.isNotEmpty) {
        errors.add('$path has unsupported primitive inputs: ${_sorted(extraInputs)}');
      }
      if (extraParams.isNotEmpty) {
        errors.add('$path has unsupported params: ${_sorted(extraParams)}');
      }
      for (final entry in stepInputs.entries) {
        _validateBinding(
          entry.value,
          '$path.inputs.${entry.key}',
          declaredInputs.keys.toSet(),
          priorOutputs,
          errors,
        );
      }
      _validatePrimitiveParams(operationId, params, path, errors);
      priorOutputs[stepId] = _outputsFor(operationId);
    }

    final outputDocs = _objectList(document['outputs'], 'outputs', errors);
    if (outputDocs.isEmpty) errors.add('outputs must be a non-empty array.');
    final outputKeys = <String>{};
    for (var index = 0; index < outputDocs.length; index++) {
      final output = outputDocs[index];
      final path = 'outputs[$index]';
      _rejectExtraKeys(output, const {'key', 'from_ref', 'unit'}, path, errors);
      final key = output['key'];
      if (key is! String || !_identifierPattern.hasMatch(key) || !outputKeys.add(key)) {
        errors.add('$path.key must be unique and valid.');
      }
      _validateOutputReference(output['from_ref'], path, priorOutputs, errors);
      final unit = output['unit'];
      if (unit != null) {
        if (unit is! String) {
          errors.add('$path.unit must be a string or null.');
        } else {
          _checkUnit(unit, '$path.unit', errors);
        }
        final reference = output['from_ref'];
        final parts = reference is String ? reference.substring(1).split('.') : const <String>[];
        final operation = parts.length == 3 ? stepOperations[parts[1]] : null;
        if (operation == null || !_unitBearingOutput(operation, parts[2])) {
          errors.add('$path.unit cannot be assigned to a non-quantity primitive output.');
        }
      }
    }

    final gates = _objectList(document['quality_gates'], 'quality_gates', errors);
    final gateIds = <String>{};
    for (var index = 0; index < gates.length; index++) {
      final gate = gates[index];
      final path = 'quality_gates[$index]';
      _rejectExtraKeys(gate, const {'id', 'expression_ref', 'severity', 'message'}, path, errors);
      final id = gate['id'];
      if (id is! String || !_identifierPattern.hasMatch(id) || !gateIds.add(id)) {
        errors.add('$path.id must be unique and valid.');
      }
      if (gate['severity'] != 'warn' && gate['severity'] != 'block') {
        errors.add('$path.severity must be warn or block.');
      }
      if (gate['message'] is! String) errors.add('$path.message must be a string.');
      _validateOutputReference(gate['expression_ref'], path, priorOutputs, errors);
    }

    final fixtures = _objectList(document['tests'], 'tests', errors);
    if (fixtures.isEmpty) errors.add('tests must contain at least one golden fixture.');
    for (var index = 0; index < fixtures.length; index++) {
      final fixture = fixtures[index];
      final path = 'tests[$index]';
      _rejectExtraKeys(fixture, const {'name', 'inputs', 'expected', 'tolerance'}, path, errors);
      if (fixture['name'] is! String || (fixture['name'] as String).isEmpty) {
        errors.add('$path.name must be a non-empty string.');
      }
      if (fixture['inputs'] is! Map) errors.add('$path.inputs must be an object.');
      if (fixture['expected'] is! Map || (fixture['expected'] as Map).isEmpty) {
        errors.add('$path.expected must be a non-empty object.');
      }
      if (fixture.containsKey('tolerance') && fixture['tolerance'] is! Map) {
        errors.add('$path.tolerance must be an object.');
      }
      final expected = fixture['expected'];
      if (expected is Map) {
        final expectedKeys = expected.keys.whereType<String>().toSet();
        final declaredKeys = outputDocs
            .map((output) => output['key'])
            .whereType<String>()
            .toSet();
        if (!expectedKeys.containsAll(declaredKeys) ||
            !declaredKeys.containsAll(expectedKeys)) {
          errors.add('$path.expected must cover every declared output exactly.');
        }
      }
    }

    final review = _object(document['review'], 'review', errors);
    _rejectExtraKeys(review, const {'approved_by_user', 'warnings'}, 'review', errors);
    if (review['approved_by_user'] is! bool) errors.add('review.approved_by_user must be boolean.');
    if (document['status'] == 'draft' && review['approved_by_user'] == true) {
      errors.add('CALC_PACK_DRAFT_CLAIMS_APPROVAL: a draft cannot claim user approval.');
    }
    final reviewWarnings = review['warnings'];
    if (reviewWarnings is! List || reviewWarnings.any((item) => item is! String)) {
      errors.add('review.warnings must be an array of strings.');
    } else {
      warnings.addAll(reviewWarnings.cast<String>());
    }
    if (!trustedBuiltIn && document['status'] == 'approved' && review['approved_by_user'] != true) {
      errors.add('CALC_PACK_NOT_APPROVED: user Calculation Packs require explicit approval.');
    }

    String? contentSha256;
    try {
      contentSha256 = calculationPackContentSha256(document);
    } on Object {
      errors.add('Pack document contains values outside the canonical JSON contract.');
    }
    return PackValidationReport(
      valid: errors.isEmpty,
      errors: errors,
      warnings: warnings,
      unsupportedOperations: unsupported.toSet().toList()..sort(),
      requiresUserInput: requiresUserInput,
      contentSha256: contentSha256,
    );
  }

  static PackGoldenTestReport testPack(
    Map<String, Object?> document, {
    bool trustedBuiltIn = false,
  }) {
    final validation = validate(document, trustedBuiltIn: trustedBuiltIn);
    final contentHash = validation.contentSha256;
    if (!validation.valid || contentHash == null) {
      return PackGoldenTestReport(
        passed: false,
        cases: const [],
        errors: validation.errors.isEmpty
            ? const ['Pack cannot be hashed for golden tests.']
            : validation.errors,
        contentSha256: contentHash ?? '',
      );
    }
    final rawFixtures = document['tests'];
    if (rawFixtures is! List || rawFixtures.isEmpty) {
      return PackGoldenTestReport(
        passed: false,
        cases: const [],
        errors: const ['Pack has no golden fixtures.'],
        contentSha256: contentHash,
      );
    }
    final cases = <Map<String, Object?>>[];
    final errors = <String>[];
    for (var index = 0; index < rawFixtures.length; index++) {
      final rawFixture = rawFixtures[index];
      if (rawFixture is! Map) {
        errors.add('tests[$index] is not an object.');
        continue;
      }
      final fixture = requireJsonObject(rawFixture, 'tests[$index]');
      final name = fixture['name'];
      final inputs = fixture['inputs'];
      final expected = fixture['expected'];
      final tolerance = fixture['tolerance'];
      if (name is! String || inputs is! Map || expected is! Map ||
          (tolerance != null && tolerance is! Map)) {
        errors.add('tests[$index] has invalid golden fixture fields.');
        continue;
      }
      try {
        final actual = const CalculationEngine().execute(
          pack: document,
          inputSnapshot: requireJsonObject(inputs, 'tests[$index].inputs'),
          calculationId: 'golden-test-$index',
          traceId: 'golden-trace-$index',
          packSha256: contentHash,
          sourceAssets: const [],
          approvalReference: 'golden-test',
          approvalKind: trustedBuiltIn ? 'trusted_builtin' : 'user_approval',
          executorId: 'lab-core-dart-golden-test',
          platform: 'test-fixture',
          createdAtUtc: DateTime.utc(2000, 1, 1),
        );
        var passed = true;
        final mismatches = <String>[];
        for (final entry in requireJsonObject(expected, 'tests[$index].expected').entries) {
          final outputRecord = actual.outputs[entry.key];
          if (outputRecord is! Map) {
            passed = false;
            mismatches.add('${entry.key}: output missing');
            continue;
          }
          final actualValue = outputRecord['value'];
          final allowedTolerance = tolerance is Map ? tolerance[entry.key] : null;
          if (!_matchesExpected(actualValue, entry.value, allowedTolerance)) {
            passed = false;
            mismatches.add('${entry.key}: expected ${entry.value}, observed $actualValue');
          }
        }
        cases.add({'name': name, 'passed': passed, 'mismatches': mismatches});
        errors.addAll(mismatches.map((item) => '$name: $item'));
      } on Object catch (error) {
        cases.add({'name': name, 'passed': false, 'error': error.toString()});
        errors.add('$name: $error');
      }
    }
    return PackGoldenTestReport(
      passed: errors.isEmpty && cases.length == rawFixtures.length,
      cases: cases,
      errors: errors,
      contentSha256: contentHash,
    );
  }

  static bool _matchesExpected(Object? actual, Object? expected, Object? tolerance) {
    if (expected is bool) return actual == (expected ? 'true' : 'false');
    if (expected is String || expected is int) {
      try {
        final expectedDecimal = parseCalculationDecimal(expected, field: 'expected');
        final actualDecimal = parseCalculationDecimal(actual, field: 'actual');
        final allowed = tolerance == null
            ? Decimal.zero
            : parseCalculationDecimal(tolerance, field: 'tolerance');
        return (actualDecimal - expectedDecimal).abs() <= allowed;
      } on FormatException {
        return tolerance == null && actual == expected;
      }
    }
    return tolerance == null && actual == expected;
  }

  static Set<String> _outputsFor(String operationId) => switch (operationId) {
        'csv.parse_table@1' || 'table.select@1' => {'rows'},
        'table.group_by@1' => {'groups'},
        'math.unit_convert@1' || 'stats.mean@1' || 'stats.sd@1' ||
        'math.linear_inverse@1' || 'math.subtract@1' || 'math.multiply@1' ||
        'math.divide@1' => {'value'},
        'stats.linear_regression@1' => {'slope', 'intercept', 'r_squared', 'min_x', 'max_x'},
        'bca.blank_adjust@1' => {'standards'},
        'data.qc_range@1' || 'data.qc_limits@1' => {'in_range'},
        'data.export_table@1' => {'json'},
        'wb.normalize_ratio@1' => {'value', 'ratio', 'relative_ratio'},
        _ => <String>{},
      };

  static bool _unitBearingOutput(String operationId, String key) => switch (operationId) {
        'math.unit_convert@1' || 'stats.mean@1' || 'stats.sd@1' ||
        'math.linear_inverse@1' || 'math.subtract@1' || 'math.multiply@1' ||
        'math.divide@1' => key == 'value',
        'stats.linear_regression@1' =>
          const {'slope', 'intercept', 'r_squared', 'min_x', 'max_x'}.contains(key),
        'wb.normalize_ratio@1' => const {'value', 'ratio', 'relative_ratio'}.contains(key),
        _ => false,
      };

  static void _validateBinding(
    Object? value,
    String path,
    Set<String> declaredInputs,
    Map<String, Set<String>> priorOutputs,
    List<String> errors,
  ) {
    if (value is! String || !value.startsWith(r'$')) {
      if (value is Map || value is List || value is double) {
        errors.add('$path must be a JSON scalar or declared reference.');
      }
      return;
    }
    if (!_referencePattern.hasMatch(value)) {
      errors.add('$path contains an invalid reference.');
      return;
    }
    final parts = value.substring(1).split('.');
    if (parts[0] == 'inputs') {
      if (parts.length != 2) {
        errors.add('$path must reference one declared input directly.');
        return;
      }
      if (!declaredInputs.contains(parts[1])) errors.add('$path references undeclared input ${parts[1]}.');
      return;
    }
    if (parts.length != 3) {
      errors.add('$path must reference one declared primitive output directly.');
      return;
    }
    final sourceOutputs = priorOutputs[parts[1]];
    if (sourceOutputs == null) {
      errors.add('$path has a forward or missing step reference: $value');
    } else if (parts.length < 3 || !sourceOutputs.contains(parts[2])) {
      errors.add('$path references an undeclared output: $value');
    }
  }

  static void _validateOutputReference(
    Object? value,
    String path,
    Map<String, Set<String>> priorOutputs,
    List<String> errors,
  ) {
    if (value is! String || !_referencePattern.hasMatch(value)) {
      errors.add('$path must reference a declared step output.');
      return;
    }
    final parts = value.substring(1).split('.');
    if (parts[0] != 'steps' || parts.length != 3) {
      errors.add('$path must reference a step output.');
      return;
    }
    final outputs = priorOutputs[parts[1]];
    if (outputs == null || !outputs.contains(parts[2])) {
      errors.add('$path references an unknown step output.');
    }
  }

  static void _validatePrimitiveParams(
    String operationId,
    Map<String, Object?> params,
    String path,
    List<String> errors,
  ) {
    if (operationId == 'math.unit_convert@1') {
      final source = params['from'];
      final target = params['to'];
      if (source is! String || target is! String) {
        errors.add('$path math.unit_convert requires string from and to units.');
        return;
      }
      try {
        final expected = UnitRegistry.conversionFactor(source, target);
        final supplied = parseCalculationDecimal(params['factor'], field: '$path.params.factor');
        if (supplied != expected) errors.add('$path unit factor does not match registered units.');
      } on Object catch (error) {
        errors.add('$path unit conversion is invalid: $error');
      }
    }
    if (operationId == 'csv.parse_table@1' &&
        params['column_map'] != null && params['column_map'] is! Map) {
      errors.add('$path.params.column_map must be an object.');
    }
    for (final key in const {
      'unit', 'from', 'to', 'x_unit', 'y_unit', 'concentration_unit',
      'absorbance_unit', 'concentration_key', 'absorbance_key', 'x_key', 'y_key',
    }) {
      if (params.containsKey(key) && params[key] != null && params[key] is! String) {
        errors.add('$path.params.$key must be a string.');
      } else if (params[key] case final String unit
          when key.endsWith('_unit') || key == 'unit' || key == 'from' || key == 'to') {
        _checkUnit(unit, '$path.params.$key', errors);
      }
    }
  }

  static void _checkUnit(String unit, String path, List<String> errors) {
    try {
      UnitRegistry.parse(unit);
    } on FormatException {
      errors.add('$path is not in the registered scientific unit set.');
    }
  }

  static List<Map<String, Object?>> _objectList(
    Object? value,
    String field,
    List<String> errors,
  ) {
    if (value is! List) {
      errors.add('$field must be an array.');
      return const [];
    }
    final objects = <Map<String, Object?>>[];
    for (var index = 0; index < value.length; index++) {
      final item = value[index];
      if (item is! Map) {
        errors.add('$field[$index] must be an object.');
      } else {
        try {
          objects.add(requireJsonObject(item, '$field[$index]'));
        } on FormatException {
          errors.add('$field[$index] must use string keys.');
        }
      }
    }
    return objects;
  }

  static Map<String, Object?> _object(
    Object? value,
    String field,
    List<String> errors,
  ) {
    if (value is! Map) {
      errors.add('$field must be an object.');
      return const {};
    }
    try {
      return requireJsonObject(value, field);
    } on FormatException {
      errors.add('$field must use string keys.');
      return const {};
    }
  }

  static void _rejectExtraKeys(
    Map<String, Object?> value,
    Set<String> allowed,
    String path,
    List<String> errors,
  ) {
    final extra = value.keys.toSet().difference(allowed);
    if (extra.isNotEmpty) errors.add('$path contains unknown fields: ${_sorted(extra)}');
  }

  static String _sorted(Iterable<String> values) {
    final result = values.toList()..sort();
    return result.join(', ');
  }

  static void _rejectFloatingPoint(Object? value, String path) {
    if (value is double) throw FormatException('floating-point values are not allowed at $path');
    if (value is List) {
      for (var index = 0; index < value.length; index++) {
        _rejectFloatingPoint(value[index], '$path[$index]');
      }
    } else if (value is Map) {
      for (final entry in value.entries) {
        _rejectFloatingPoint(entry.value, '$path.${entry.key}');
      }
    }
  }
}\n
