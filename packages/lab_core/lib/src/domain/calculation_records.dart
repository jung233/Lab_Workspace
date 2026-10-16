import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'errors.dart';
import 'ids.dart';
import 'json_value.dart';
import 'json_value.dart' as json_helpers;

enum CalculationStatus {
  completed,
  failed;

  String get wireValue => name;
}

/// Immutable trace-v2 document attached to one completed calculation.
final class CalculationTrace {
  CalculationTrace({required Map<String, Object?> document})
      : document = freezeJsonObject(document) {
    _validateDocument(this.document);
    canonicalJson = _canonicalTraceJson(this.document);
    contentSha256 = sha256.convert(utf8.encode(canonicalJson)).toString();
  }

  final Map<String, Object?> document;
  late final String canonicalJson;
  late final String contentSha256;

  CalculationTraceId get traceId => document['trace_id']! as String;
  CalculationId get calculationId => document['calculation_id']! as String;

  static CalculationTrace fromJson(String json) {
    final decoded = jsonDecode(json);
    return CalculationTrace(
      document: requireJsonObject(decoded, 'calculation trace'),
    );
  }

  static void _validateDocument(Map<String, Object?> document) {
    const required = {
      'schema_version', 'trace_id', 'calculation_id', 'pack_ref', 'engine',
      'inputs', 'steps', 'outputs', 'source_assets', 'warnings', 'user_confirmed',
    };
    final missing = required.where((key) => !document.containsKey(key)).toList();
    if (missing.isNotEmpty) {
      throw ValidationException(
        'CALCULATION_TRACE_INVALID',
        'CalculationTrace is missing required trace-v2 fields.',
        details: {'missing': missing},
      );
    }
    if (document['schema_version'] != '2.0' ||
        document['trace_id'] is! String ||
        (document['trace_id'] as String).isEmpty ||
        document['calculation_id'] is! String ||
        (document['calculation_id'] as String).isEmpty ||
        document['pack_ref'] is! String ||
        document['engine'] is! Map ||
        document['user_confirmed'] is! bool) {
      throw const ValidationException(
        'CALCULATION_TRACE_INVALID',
        'CalculationTrace identity or required fields are invalid.',
      );
    }
    _validateScalarList(document['inputs'], 'inputs', requireKey: true);
    _validateScalarList(document['outputs'], 'outputs', requireKey: true);

    final rawSteps = document['steps'];
    if (rawSteps is! List || rawSteps.isEmpty) {
      throw const ValidationException(
        'CALCULATION_TRACE_INVALID',
        'CalculationTrace steps must contain at least one step.',
      );
    }
    for (var index = 0; index < rawSteps.length; index++) {
      final step = requireJsonObject(rawSteps[index], 'steps[$index]');
      for (final key in const {
        'seq', 'op', 'expression', 'substitution', 'inputs', 'intermediates',
        'result', 'warnings',
      }) {
        if (!step.containsKey(key)) {
          throw ValidationException(
            'CALCULATION_TRACE_INVALID',
            'Trace step $index is missing $key.',
          );
        }
      }
      if (step['seq'] is! int || (step['seq'] as int) != index + 1 ||
          step['op'] is! String || step['expression'] is! String ||
          step['substitution'] is! String || step['inputs'] is! Map ||
          step['intermediates'] is! Map || step['warnings'] is! List) {
        throw ValidationException(
          'CALCULATION_TRACE_INVALID',
          'Trace step $index has invalid fields or sequence number.',
        );
      }
      _validateScalarObject(step['result'], 'steps[$index].result');
    }

    final assets = document['source_assets'];
    if (assets is! List) {
      throw const ValidationException(
        'CALCULATION_TRACE_INVALID',
        'source_assets must be an array.',
      );
    }
    final shaPattern = RegExp(r'^[a-f0-9]{64}$');
    for (var index = 0; index < assets.length; index++) {
      final asset = requireJsonObject(assets[index], 'source_assets[$index]');
      if (asset['asset_id'] is! String ||
          asset['sha256'] is! String ||
          !shaPattern.hasMatch(asset['sha256'] as String)) {
        throw ValidationException(
          'CALCULATION_TRACE_INVALID',
          'source_assets[$index] needs an Asset id and lowercase SHA-256.',
        );
      }
    }
    if (document['warnings'] is! List ||
        (document['warnings'] as List).any((value) => value is! String)) {
      throw const ValidationException(
        'CALCULATION_TRACE_INVALID',
        'warnings must be an array of strings.',
      );
    }

    _rejectFloatingPoint(document, r'$');
  }

  static void _validateScalarList(
    Object? value,
    String field, {
    required bool requireKey,
  }) {
    if (value is! List) {
      throw ValidationException('CALCULATION_TRACE_INVALID', '$field must be an array.');
    }
    for (var index = 0; index < value.length; index++) {
      final item = requireJsonObject(value[index], '$field[$index]');
      if (requireKey && (item['key'] is! String || (item['key'] as String).isEmpty)) {
        throw ValidationException(
          'CALCULATION_TRACE_INVALID',
          '$field[$index].key must be a non-empty string.',
        );
      }
      if (!item.containsKey('value') ||
          !(item['value'] is String || item['value'] is int)) {
        throw ValidationException(
          'CALCULATION_TRACE_INVALID',
          '$field[$index].value must be stored as an exact decimal string or integer.',
        );
      }
      if (!item.containsKey('unit') ||
          (item['unit'] != null && item['unit'] is! String)) {
        throw ValidationException(
          'CALCULATION_TRACE_INVALID',
          '$field[$index].unit must be string or null.',
        );
      }
    }
  }

  static void _validateScalarObject(Object? value, String field) {
    final object = requireJsonObject(value, field);
    if (object['key'] is! String ||
        object['key'] == '' ||
        !(object['value'] is String || object['value'] is int) ||
        !(object['unit'] == null || object['unit'] is String)) {
      throw ValidationException(
        'CALCULATION_TRACE_INVALID',
        '$field must contain a key, exact value, and optional unit.',
      );
    }
  }

  static void _rejectFloatingPoint(Object? value, String path) {
    if (value is double) {
      throw ValidationException(
        'CALCULATION_TRACE_FLOAT_INPUT',
        'CalculationTrace does not accept floating-point values at $path.',
      );
    }
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

  static String _canonicalTraceJson(Map<String, Object?> value) =>
      json_helpers.canonicalJson(value);
}

/// Terminal, immutable calculation result. Work-in-progress execution is kept
/// in memory; only completed or failed outcomes enter the durable ledger.
final class CalculationRun {
  CalculationRun({
    required this.calculationId,
    this.parentCalculationId,
    this.runId,
    this.sampleId,
    this.stepId,
    required this.packId,
    required this.packVersion,
    required this.packSha256,
    required this.status,
    required Map<String, Object?> inputSnapshot,
    List<Map<String, Object?>> sourceAssets = const [],
    Map<String, Object?>? output,
    this.trace,
    this.errorCode,
    required this.createdAtUtc,
    this.completedAtUtc,
    this.revision = 1,
  }) : inputSnapshot = freezeJsonObject(inputSnapshot),
       sourceAssets = List.unmodifiable(
         sourceAssets.map(freezeJsonObject),
       ),
       output = output == null ? null : freezeJsonObject(output) {
    _validate();
  }

  final CalculationId calculationId;
  final CalculationId? parentCalculationId;
  final String? runId;
  final String? sampleId;
  final String? stepId;
  final String packId;
  final String packVersion;
  final String packSha256;
  final CalculationStatus status;
  final Map<String, Object?> inputSnapshot;
  final List<Map<String, Object?>> sourceAssets;
  final Map<String, Object?>? output;
  final CalculationTrace? trace;
  final String? errorCode;
  final DateTime createdAtUtc;
  final DateTime? completedAtUtc;
  final int revision;

  bool get isPublishable =>
      status == CalculationStatus.completed && output != null && trace != null;

  void _validate() {
    final shaPattern = RegExp(r'^[a-f0-9]{64}$');
    if (calculationId.isEmpty || packId.isEmpty || packVersion.isEmpty ||
        !shaPattern.hasMatch(packSha256)) {
      throw const ValidationException(
        'CALCULATION_RUN_INVALID',
        'Calculation identity and pack SHA-256 are required.',
      );
    }
    if (revision < 1 || completedAtUtc == null ||
        completedAtUtc!.toUtc().isBefore(createdAtUtc.toUtc())) {
      throw const ValidationException(
        'CALCULATION_RUN_INVALID',
        'Terminal calculations require a valid completion time and revision.',
      );
    }
    if (trace != null && trace!.calculationId != calculationId) {
      throw const ValidationException(
        'CALCULATION_TRACE_ID_MISMATCH',
        'CalculationTrace must identify its owning CalculationRun.',
      );
    }
    if (status == CalculationStatus.completed &&
        (output == null || trace == null || errorCode != null)) {
      throw const ValidationException(
        'CALCULATION_RUN_INCOMPLETE',
        'A completed CalculationRun requires output and trace and cannot carry an error code.',
      );
    }
    if (status == CalculationStatus.failed &&
        (errorCode == null || errorCode!.isEmpty || output != null)) {
      throw const ValidationException(
        'CALCULATION_RUN_FAILED_INVALID',
        'A failed CalculationRun requires an error code and cannot publish output.',
      );
    }
  }
}
