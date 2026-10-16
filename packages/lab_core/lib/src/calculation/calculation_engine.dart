import 'dart:convert';

import 'package:decimal/decimal.dart';

import '../domain/calculation_records.dart';
import '../domain/json_value.dart';
import 'decimal_support.dart';
import 'primitive_code_manifest.dart';
import 'primitive_registry.dart';
import 'unit_registry.dart';

/// Executes only steps found in [PrimitiveRegistry]. Pack documents stay data;
/// this engine has no dynamic import, shell, file, or network facility.
final class CalculationEngine {
  const CalculationEngine();

  CalculationExecutionResult execute({
    required Map<String, Object?> pack,
    required Map<String, Object?> inputSnapshot,
    required String calculationId,
    required String traceId,
    required String packSha256,
    required List<Map<String, Object?>> sourceAssets,
    required String approvalReference,
    required String approvalKind,
    required String executorId,
    required String platform,
    required DateTime createdAtUtc,
    String? runId,
    String? sampleId,
    String? stepId,
    String? parentCalculationId,
    Map<String, String> dependencies = const {},
    bool Function()? cancelled,
  }) {
    final typedInputs = _typedInputs(pack, inputSnapshot, sourceAssets);
    final sourceIds = sourceAssets.map((asset) => asset['asset_id']).toSet();
    final context = <String, Object?>{'inputs': typedInputs, 'steps': <String, Object?>{}};
    final steps = pack['pipeline'];
    if (steps is! List || steps.isEmpty) {
      throw const FormatException('Calculation Pack pipeline must be a non-empty list.');
    }
    final stepTraces = <Map<String, Object?>>[];
    final usedOps = <String>{};
    final warnings = <String>[];
    for (var index = 0; index < steps.length; index++) {
      if (cancelled?.call() ?? false) {
        throw const FormatException('CALC_CANCELLED: calculation was cancelled.');
      }
      final rawStep = steps[index];
      if (rawStep is! Map) throw const FormatException('Calculation pipeline step must be an object.');
      final step = requireJsonObject(rawStep, 'pipeline[$index]');
      final operationId = step['op'];
      if (operationId is! String) throw const FormatException('Calculation step op must be a string.');
      final primitive = PrimitiveRegistry.definitions[operationId];
      if (primitive == null) throw FormatException('CALC_PRIMITIVE_MISSING: $operationId');
      final stepIdValue = step['step_id'];
      if (stepIdValue is! String || stepIdValue.isEmpty) {
        throw const FormatException('Calculation step_id must be a non-empty string.');
      }
      final rawBindings = step['inputs'];
      final rawParams = step['params'];
      if (rawBindings is! Map || rawParams is! Map) {
        throw const FormatException('Calculation inputs and params must be objects.');
      }
      final bindings = requireJsonObject(rawBindings, 'pipeline[$index].inputs');
      final params = requireJsonObject(rawParams, 'pipeline[$index].params');
      final resolved = <String, Object?>{
        for (final entry in bindings.entries)
          entry.key: _resolve(entry.value, context),
      };
      final result = primitive.invoke(resolved, params);
      usedOps.add(operationId);
      (context['steps']! as Map<String, Object?>)[stepIdValue] = result.values;
      final resultRows = <Map<String, Object?>>[];
      for (final entry in result.values.entries.toList()..sort((a, b) => a.key.compareTo(b.key))) {
        final value = entry.value;
        resultRows.add({
          'key': entry.key,
          'value': _traceScalar(value),
          'unit': value is ScientificQuantity ? value.unit.symbol : null,
          'source_ref': r'$steps.' + stepIdValue + '.' + entry.key,
        });
      }
      final stepResult = _traceScalar(result.traceValue);
      stepTraces.add({
        'seq': index + 1,
        'op': operationId,
        'expression': result.expression,
        'substitution': result.substitution,
        'inputs': traceJsonValue(result.inputs),
        'intermediates': traceJsonValue(result.intermediates),
        'result': {
          'key': stepIdValue,
          'value': stepResult,
          'unit': result.traceUnit,
          'source_ref': null,
        },
        'results': resultRows,
        'warnings': result.warnings,
      });
      warnings.addAll(result.warnings);
    }

    final outputDefinitions = pack['outputs'];
    if (outputDefinitions is! List || outputDefinitions.isEmpty) {
      throw const FormatException('Calculation Pack outputs must be a non-empty list.');
    }
    final outputRows = <Map<String, Object?>>[];
    final outputValues = <String, Object?>{};
    for (var index = 0; index < outputDefinitions.length; index++) {
      final rawOutput = outputDefinitions[index];
      if (rawOutput is! Map) throw const FormatException('Calculation output must be an object.');
      final definition = requireJsonObject(rawOutput, 'outputs[$index]');
      final key = definition['key'];
      final fromRef = definition['from_ref'];
      final requestedUnit = definition['unit'];
      if (key is! String || key.isEmpty || fromRef is! String ||
          (requestedUnit != null && requestedUnit is! String)) {
        throw const FormatException('Calculation output definition is invalid.');
      }
      var value = _resolve(fromRef, context);
      if (value is ScientificQuantity && requestedUnit is String) {
        value = value.toUnit(requestedUnit);
      }
      final exactValue = _traceScalar(value);
      final unit = value is ScientificQuantity ? value.unit.symbol : requestedUnit;
      outputValues[key] = {
        'value': exactValue,
        'unit': unit,
        'source_ref': fromRef,
      };
      outputRows.add({
        'key': key,
        'value': exactValue,
        'unit': unit,
        'source_ref': fromRef,
      });
    }

    final qualityGates = pack['quality_gates'];
    if (qualityGates is! List) throw const FormatException('quality_gates must be an array.');
    for (final rawGate in qualityGates) {
      if (rawGate is! Map) throw const FormatException('Quality gate must be an object.');
      final gate = requireJsonObject(rawGate, 'quality_gate');
      final reference = gate['expression_ref'];
      if (reference is! String) throw const FormatException('Quality gate reference must be a string.');
      final condition = _resolve(reference, context);
      final passed = condition is ScientificQuantity
          ? condition.value != Decimal.zero
          : condition == true;
      if (!passed) {
        final message = gate['message'];
        final severity = gate['severity'];
        if (message is! String || (severity != 'warn' && severity != 'block')) {
          throw const FormatException('Quality gate fields are invalid.');
        }
        if (severity == 'block') throw FormatException('CALC_QUALITY_GATE_BLOCKED: $message');
        warnings.add(message);
      }
    }

    final inputRows = <Map<String, Object?>>[];
    for (final entry in typedInputs.entries) {
      final value = entry.value;
      final rawValue = inputSnapshot[entry.key];
      final sourceRef = value is String && sourceIds.contains(value) ? value : null;
      inputRows.add({
        'key': entry.key,
        'value': value is ScientificQuantity && rawValue is String
            ? rawValue
            : _traceInput(value),
        'unit': value is ScientificQuantity ? value.unit.symbol : null,
        'source_ref': sourceRef,
      });
    }
    final primitiveVersions = <String, String>{
      for (final operation in usedOps.toList()..sort()) operation: '1',
    };
    final buildVersions = <String, String>{
      for (final operation in usedOps.toList()..sort())
        operation: PrimitiveRegistry.definitions[operation]!.buildId,
    };
    final primitiveCodeHashes = <String, String>{
      for (final operation in usedOps.toList()..sort())
        operation: dartCalculationPrimitiveCodeSha256,
    };
    final trace = CalculationTrace(document: <String, Object?>{
      'schema_version': '2.0',
      'trace_id': traceId,
      'calculation_id': calculationId,
      'pack_ref': '${pack['pack_id']}@${pack['version']}',
      'engine': {
        'executor_id': executorId,
        'python_version': 'not_applicable',
        'primitive_versions': primitiveVersions,
        'primitive_code_sha256': primitiveCodeHashes,
        'platform': platform,
      },
      'inputs': inputRows,
      'steps': stepTraces,
      'outputs': outputRows,
      'source_assets': sourceAssets,
      'warnings': warnings.toSet().toList(growable: false),
      'user_confirmed': false,
      'created_at_utc': createdAtUtc.toUtc().toIso8601String(),
      'pack_sha256': packSha256,
      'primitive_build_versions': buildVersions,
      'execution_context': {
        'run_id': runId,
        'sample_id': sampleId,
        'step_id': stepId,
      },
      'approval': {
        'reference': approvalReference,
        'kind': approvalKind,
      },
      'ai_provenance': const <Object?>[],
      'recalculation_parent_id': parentCalculationId,
      'precision': {
        'decimal_precision': calculationDecimalPrecision,
        'rounding': calculationRoundingPolicy,
        'float_inputs_allowed': false,
      },
      'execution_environment': {
        'runtime': executorId,
        'platform': platform,
        'dependencies': {
          ...dependencies,
          'calculation_source_manifest_version': calculationSourceManifestVersion,
          'calculation_runtime_source_sha256': dartCalculationRuntimeSourceSha256,
        },
      },
    });
    return CalculationExecutionResult(
      outputs: Map<String, Object?>.unmodifiable(outputValues),
      trace: trace,
    );
  }

  Map<String, Object?> _typedInputs(
    Map<String, Object?> pack,
    Map<String, Object?> values,
    List<Map<String, Object?>> sourceAssets,
  ) {
    final encoded = canonicalJson(values);
    if (utf8.encode(encoded).length > 32 * 1024 * 1024) {
      throw const FormatException('Input snapshot exceeds the 32 MiB calculation limit.');
    }
    final rawDefinitions = pack['inputs'];
    if (rawDefinitions is! List) throw const FormatException('Calculation Pack inputs must be a list.');
    final definitions = <String, Map<String, Object?>>{};
    for (var index = 0; index < rawDefinitions.length; index++) {
      final raw = rawDefinitions[index];
      if (raw is! Map) throw const FormatException('Calculation input definition must be an object.');
      final definition = requireJsonObject(raw, 'inputs[$index]');
      final key = definition['key'];
      if (key is! String) throw const FormatException('Calculation input key must be a string.');
      definitions[key] = definition;
    }
    final extra = values.keys.toSet().difference(definitions.keys.toSet());
    if (extra.isNotEmpty) throw FormatException('Undeclared input keys: ${extra.toList()..sort()}');
    final assetIds = sourceAssets.map((asset) => asset['asset_id']).whereType<String>().toSet();
    final result = <String, Object?>{};
    for (final entry in definitions.entries) {
      final key = entry.key;
      final definition = entry.value;
      final required = definition['required'];
      if (required is! bool) throw FormatException('Input $key has invalid required declaration.');
      if (!values.containsKey(key)) {
        if (required) throw FormatException('Missing required input: $key');
        continue;
      }
      final value = values[key];
      final kind = definition['kind'];
      switch (kind) {
        case 'decimal':
          final decimal = parseCalculationDecimal(value, field: key);
          final unit = definition['unit'];
          if (unit != null && unit is! String) throw FormatException('Input $key unit is invalid.');
          result[key] = ScientificQuantity(decimal, UnitRegistry.parse(unit as String?));
          break;
        case 'integer':
          if (value is! int || value is bool) throw FormatException('Input $key must be an integer.');
          result[key] = value;
          break;
        case 'boolean':
          if (value is! bool) throw FormatException('Input $key must be boolean.');
          result[key] = value;
          break;
        case 'text' || 'asset_ref' || 'sample_ref':
          if (value is! String || value.isEmpty) throw FormatException('Input $key must be a non-empty string.');
          if (kind == 'asset_ref' && !assetIds.contains(value)) {
            throw FormatException('CALC_SOURCE_ASSET_MISSING: input $key is not in source_assets.');
          }
          result[key] = value;
          break;
        case 'table':
          if (value is! List || value.any((row) => row is! Map)) {
            throw FormatException('Input $key must be an array of table rows.');
          }
          final rows = <Map<String, Object?>>[];
          for (var index = 0; index < value.length; index++) {
            final row = requireJsonObject(value[index], '$key[$index]');
            _rejectFloatingPoint(row, '$key[$index]');
            rows.add(freezeJsonObject(row));
          }
          result[key] = List<Map<String, Object?>>.unmodifiable(rows);
          break;
        default:
          throw FormatException('Unsupported Calculation Pack input kind: $kind');
      }
    }
    return Map<String, Object?>.unmodifiable(result);
  }

  Object? _resolve(Object? binding, Map<String, Object?> context) {
    if (binding is! String || !binding.startsWith(r'$')) return binding;
    final parts = binding.substring(1).split('.');
    final validInputRef = parts.first == 'inputs' && parts.length == 2;
    final validStepRef = parts.first == 'steps' && parts.length == 3;
    if (!validInputRef && !validStepRef) {
      throw FormatException('Invalid Calculation Pack reference: $binding');
    }
    Object? value = context;
    for (final part in parts) {
      if (value is! Map || !value.containsKey(part)) {
        throw FormatException('Missing or forward Calculation Pack reference: $binding');
      }
      value = value[part];
    }
    return value;
  }

  Object? _traceScalar(Object? value) {
    if (value is ScientificQuantity) return calculationDecimalText(value.value);
    if (value is Decimal) return calculationDecimalText(value);
    if (value is bool) return value ? 'true' : 'false';
    if (value == null || value is String || value is int) return value;
    if (value is Map || value is List) return canonicalJson(value);
    throw FormatException('Unsupported scientific trace scalar ${value.runtimeType}.');
  }

  Object? _traceInput(Object? value) {
    if (value is ScientificQuantity || value is Decimal || value is bool) {
      return _traceScalar(value);
    }
    if (value is Map || value is List) return canonicalJson(value);
    return _traceScalar(value);
  }

  void _rejectFloatingPoint(Object? value, String path) {
    if (value is double) throw FormatException('Float inputs are unsupported at $path.');
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
}

final class CalculationExecutionResult {
  CalculationExecutionResult({
    required Map<String, Object?> outputs,
    required this.trace,
  }) : outputs = Map<String, Object?>.unmodifiable(outputs);

  final Map<String, Object?> outputs;
  final CalculationTrace trace;
}\n
