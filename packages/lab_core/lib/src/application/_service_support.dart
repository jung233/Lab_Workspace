import 'dart:convert';

import '../domain/commands.dart';
import '../domain/calculation_records.dart';
import '../domain/errors.dart';
import '../domain/events.dart';
import '../domain/ids.dart';
import '../domain/json_value.dart';
import '../persistence/workspace_database.dart';

CommandMetadata serviceCommand({
  CommandMetadata? command,
  String? commandId,
  DateTime? atUtc,
}) => command ?? CommandMetadata(
  commandId: commandId ?? newUuidV7(at: atUtc),
  utcTime: atUtc ?? DateTime.now().toUtc(),
);

/// Returns a previously applied command after comparing its intent. This is
/// used before changing business rows so retries cannot apply a mutation twice.
MutationEvent? replayMutation({
  required WorkspaceTransaction tx,
  required CommandMetadata command,
  required String entityType,
  String? entityId,
  required String eventType,
  required MutationAction action,
  required Map<String, Object?> payload,
}) {
  final prior = tx.findMutationByCommandId(command.commandId);
  if (prior == null) return null;
  final same = prior.entityType == entityType &&
      (entityId == null || prior.entityId == entityId) &&
      prior.eventType == eventType &&
      prior.action == action &&
      canonicalJson(prior.payload) == canonicalJson(payload);
  if (!same) throw CommandAlreadyAppliedException(command.commandId);
  return prior;
}

MutationEvent appendServiceMutation({
  required WorkspaceTransaction tx,
  required CommandMetadata command,
  required DeviceId deviceId,
  required String entityType,
  required String entityId,
  required String eventType,
  required MutationAction action,
  required Map<String, Object?> payload,
  List<String> assetShaRefs = const [],
}) => tx.appendMutation(
  MutationEventDraft(
    command: command,
    deviceId: deviceId,
    entityType: entityType,
    entityId: entityId,
    eventType: eventType,
    action: action,
    payloadJson: jsonEncode(payload),
    assetShaRefs: assetShaRefs,
  ),
);

DateTime dateFromDb(Object? value) => DateTime.parse(value! as String).toUtc();
DateTime? optionalDateFromDb(Object? value) =>
    value == null ? null : dateFromDb(value);

void requireCalculationOutputForMeasurement({
  required WorkspaceTransaction tx,
  required String calculationId,
  required String runId,
  required String? stepId,
  required String? sampleId,
  required String analyte,
  required String valueText,
  required String? unit,
  required String? rawAssetId,
}) {
  final rows = tx.query(
    '''SELECT run_id,step_id,sample_id,output_json,trace_json,trace_sha256
       FROM calculation_runs WHERE calculation_id=? AND status='completed' ''',
    [calculationId],
  );
  if (rows.isEmpty) {
    throw const ValidationException(
      'CALCULATION_NOT_PUBLISHABLE',
      'Only a completed local CalculationRun can back a Measurement.',
    );
  }
  final row = rows.single;
  if (row['run_id'] != runId || row['step_id'] != stepId || row['sample_id'] != sampleId) {
    throw const ValidationException(
      'MEASUREMENT_CALCULATION_CONTEXT_MISMATCH',
      'Measurement and CalculationRun must have the same Run, Step, and Sample context.',
    );
  }
  final traceJson = row['trace_json'];
  final outputJson = row['output_json'];
  if (traceJson is! String || outputJson is! String) {
    throw const ValidationException(
      'MEASUREMENT_CALCULATION_TRACE_MISSING',
      'A linked CalculationRun must retain its output and CalculationTrace.',
    );
  }
  final trace = CalculationTrace.fromJson(traceJson);
  if (trace.calculationId != calculationId || trace.contentSha256 != row['trace_sha256']) {
    throw const ValidationException(
      'MEASUREMENT_CALCULATION_TRACE_INVALID',
      'A linked CalculationRun has an invalid trace identity or content hash.',
    );
  }
  final output = requireJsonObject(jsonDecode(outputJson), 'CalculationRun output');
  final outputRows = output['outputs'];
  final traceOutputs = trace.document['outputs'];
  if (outputRows is! List || traceOutputs is! List ||
      canonicalJson(outputRows) != canonicalJson(traceOutputs)) {
    throw const ValidationException(
      'MEASUREMENT_CALCULATION_OUTPUT_MISMATCH',
      'CalculationRun output does not match its trace outputs.',
    );
  }
  final matches = outputRows.where((value) =>
      value is Map && value['key'] == analyte).toList(growable: false);
  if (matches.length != 1) {
    throw const ValidationException(
      'MEASUREMENT_CALCULATION_OUTPUT_MISSING',
      'Measurement analyte must identify exactly one named CalculationRun output.',
    );
  }
  final outputValue = matches.single as Map;
  final exactValue = outputValue['value'];
  if ((exactValue is! String && exactValue is! int) ||
      exactValue.toString() != valueText || outputValue['unit'] != unit) {
    throw const ValidationException(
      'MEASUREMENT_CALCULATION_VALUE_MISMATCH',
      'Measurement value and unit must exactly match the selected CalculationRun output.',
    );
  }
  if (rawAssetId != null) {
    final assets = tx.query(
      '''SELECT blob_sha256 FROM assets WHERE asset_id=? AND deleted_at_utc IS NULL''',
      [rawAssetId],
    );
    if (assets.isEmpty) {
      throw const ValidationException(
        'MEASUREMENT_CALCULATION_ASSET_MISSING',
        'Measurement source Asset is not active.',
      );
    }
    final assetSha = assets.single['blob_sha256'];
    final traceAssets = trace.document['source_assets'];
    final matchingAsset = traceAssets is List && traceAssets.any((value) =>
        value is Map && value['asset_id'] == rawAssetId && value['sha256'] == assetSha);
    if (!matchingAsset) {
      throw const ValidationException(
        'MEASUREMENT_CALCULATION_ASSET_MISMATCH',
        'Measurement source Asset must be bound to the CalculationTrace.',
      );
    }
  }
}

String requireRemoteCalculationOutputForMeasurement({
  required WorkspaceTransaction tx,
  required String calculationId,
  required String runId,
  required String? stepId,
  required String? sampleId,
  required String analyte,
  required String valueText,
  required String? unit,
  required String? rawAssetId,
}) {
  final rows = tx.query(
    '''SELECT run_id,step_id,sample_id,status,output_json,trace_json,trace_sha256,source_assets_json
       FROM remote_calculation_run_imports WHERE calculation_id=?''',
    [calculationId],
  );
  if (rows.isEmpty) {
    throw const ValidationException(
      'REMOTE_CALCULATION_NOT_AVAILABLE',
      'The referenced remote CalculationRun has not been received.',
    );
  }
  final row = rows.single;
  if (row['status'] != 'completed' || row['run_id'] != runId ||
      row['step_id'] != stepId || row['sample_id'] != sampleId) {
    throw const ValidationException(
      'REMOTE_CALCULATION_CONTEXT_MISMATCH',
      'Only a completed remote CalculationRun with matching Run, Step, and Sample context can back this Measurement.',
    );
  }
  final traceJson = row['trace_json'];
  final outputJson = row['output_json'];
  final expectedTraceSha = row['trace_sha256'];
  if (traceJson is! String || outputJson is! String || expectedTraceSha is! String) {
    throw const ValidationException(
      'REMOTE_CALCULATION_TRACE_MISSING',
      'The remote CalculationRun lacks its output or CalculationTrace.',
    );
  }
  final trace = CalculationTrace.fromJson(traceJson);
  if (trace.calculationId != calculationId || trace.contentSha256 != expectedTraceSha) {
    throw const ValidationException(
      'REMOTE_CALCULATION_TRACE_INVALID',
      'The remote CalculationTrace identity or SHA-256 does not match its stored snapshot.',
    );
  }
  final output = requireJsonObject(jsonDecode(outputJson), 'remote CalculationRun output');
  final outputRows = output['outputs'];
  final traceOutputs = trace.document['outputs'];
  if (outputRows is! List || traceOutputs is! List ||
      canonicalJson(outputRows) != canonicalJson(traceOutputs)) {
    throw const ValidationException(
      'REMOTE_CALCULATION_OUTPUT_MISMATCH',
      'The remote CalculationRun outputs do not match its CalculationTrace.',
    );
  }
  final matches = outputRows.where((value) =>
      value is Map && value['key'] == analyte).toList(growable: false);
  if (matches.length != 1) {
    throw const ValidationException(
      'REMOTE_CALCULATION_OUTPUT_MISSING',
      'Measurement analyte must identify exactly one named remote CalculationRun output.',
    );
  }
  final value = matches.single as Map;
  final exactValue = value['value'];
  if ((exactValue is! String && exactValue is! int) ||
      exactValue.toString() != valueText || value['unit'] != unit) {
    throw const ValidationException(
      'REMOTE_CALCULATION_VALUE_MISMATCH',
      'Measurement value and unit must exactly match the selected remote CalculationRun output.',
    );
  }
  final remoteSources = jsonDecode(row['source_assets_json']! as String);
  if (canonicalJson(remoteSources) != canonicalJson(trace.document['source_assets'])) {
    throw const ValidationException(
      'REMOTE_CALCULATION_ASSETS_MISMATCH',
      'Remote CalculationRun source assets do not match its CalculationTrace.',
    );
  }
  if (rawAssetId != null) {
    final assets = tx.query(
      '''SELECT blob_sha256 FROM assets WHERE asset_id=? AND deleted_at_utc IS NULL''',
      [rawAssetId],
    );
    if (assets.isEmpty) {
      throw const ValidationException(
        'REMOTE_CALCULATION_ASSET_MISSING',
        'Measurement source Asset is not active on this device.',
      );
    }
    final assetSha = assets.single['blob_sha256'];
    final traceAssets = trace.document['source_assets'];
    if (traceAssets is! List || !traceAssets.any((source) =>
        source is Map && source['asset_id'] == rawAssetId && source['sha256'] == assetSha)) {
      throw const ValidationException(
        'REMOTE_CALCULATION_ASSET_MISMATCH',
        'Measurement source Asset must be bound to the remote CalculationTrace.',
      );
    }
  }
  return analyte;
}

int intFromDb(Object? value) => switch (value) {
  int number => number,
  BigInt number => number.toInt(),
  _ => throw FormatException('Expected integer database value, got $value.'),
};

Map<String, Object?> objectFromDb(Object? value) =>
    requireJsonObject(jsonDecode(value! as String), 'database JSON');

List<String> stringListFromDb(Object? value) =>
    (jsonDecode(value! as String) as List<dynamic>).cast<String>();

String normalizedText(String value, String field) {
  final result = value.trim();
  if (result.isEmpty) {
    throw ValidationException('FIELD_REQUIRED', '$field cannot be empty.');
  }
  return result;
}

void validatePagination({required int limit, int? offset}) {
  if (limit < 1 || limit > 1000 || (offset != null && offset < 0)) {
    throw const ValidationException(
      'PAGINATION_INVALID',
      'Limit must be between 1 and 1000 and offset cannot be negative.',
    );
  }
}

CommandMetadata serviceCommandAtRevision(
  CommandMetadata command, {
  required String entityType,
  required String entityId,
  required int revision,
}) {
  if (command.baseRevision != null && command.baseRevision != revision) {
    throw RevisionConflictException(
      entityType: entityType,
      entityId: entityId,
      expectedRevision: command.baseRevision!,
      actualRevision: revision,
    );
  }
  return CommandMetadata(
    commandId: command.commandId,
    utcTime: command.utcTime,
    baseRevision: revision,
    actor: command.actor,
    sourceRef: command.sourceRef,
    approvalRef: command.approvalRef,
  );
}
