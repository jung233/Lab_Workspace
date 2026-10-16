import '../domain/calculation_records.dart';
import '../domain/commands.dart';
import '../domain/errors.dart';
import '../domain/events.dart';
import '../domain/ids.dart';
import '../domain/records.dart';
import '../domain/security.dart';
import '../domain/vault.dart';
import '../persistence/workspace_database.dart';
import '_service_support.dart';

/// Device-local review and import controls for external Calculation-backed
/// Measurements. Remote values remain quarantined until this device approves.
final class RemoteMeasurementReviewService {
  const RemoteMeasurementReviewService(this.vault);

  final VaultContext vault;
  WorkspaceDatabase get _database => vault.database;

  List<RemoteMeasurementImportRecord> listImports({
    String? reviewState,
    int limit = 100,
    int offset = 0,
  }) {
    validatePagination(limit: limit, offset: offset);
    const states = {'pending', 'imported', 'rejected'};
    if (reviewState != null && !states.contains(reviewState)) {
      throw ValidationException(
        'REMOTE_MEASUREMENT_REVIEW_STATE_INVALID',
        'Unsupported review state: $reviewState.',
      );
    }
    final reviewFilter = reviewState == null
        ? ''
        : reviewState == 'pending'
        ? ' AND r.action IS NULL'
        : ' AND r.action=?';
    final bindings = <Object?>[vault.deviceId];
    if (reviewState != null && reviewState != 'pending')
      bindings.add(reviewState);
    bindings
      ..add(limit)
      ..add(offset);
    final rows = _database.query(
      '''SELECT i.*,
                r.action AS review_action,r.local_measurement_id,r.approval_ref,
                r.created_at_utc AS reviewed_at_utc,r.reason AS review_reason
         FROM remote_measurement_imports i
         LEFT JOIN remote_measurement_reviews r
           ON r.source_event_id=i.source_event_id AND r.reviewer_device_id=?
         WHERE 1=1$reviewFilter
         ORDER BY i.imported_at_utc DESC,i.source_event_id LIMIT ? OFFSET ?''',
      bindings,
    );
    return rows.map(_recordFromRow).toList(growable: false);
  }

  RemoteMeasurementImportRecord? get(String sourceEventId) {
    final rows = _database.query(
      '''SELECT i.*,
                r.action AS review_action,r.local_measurement_id,r.approval_ref,
                r.created_at_utc AS reviewed_at_utc,r.reason AS review_reason
         FROM remote_measurement_imports i
         LEFT JOIN remote_measurement_reviews r
           ON r.source_event_id=i.source_event_id AND r.reviewer_device_id=?
         WHERE i.source_event_id=?''',
      [vault.deviceId, sourceEventId],
    );
    return rows.isEmpty ? null : _recordFromRow(rows.single);
  }

  CalculationTrace getTrace(String sourceEventId) {
    final rows = _database.query(
      '''SELECT c.trace_json,c.trace_sha256,i.calculation_trace_sha256
         FROM remote_measurement_imports i
         JOIN remote_calculation_run_imports c ON c.calculation_id=i.calculation_id
         WHERE i.source_event_id=? AND c.status='completed' ''',
      [sourceEventId],
    );
    if (rows.isEmpty)
      throw MissingEntityException('RemoteMeasurementImport', sourceEventId);
    final traceJson = rows.single['trace_json'];
    final storedHash = rows.single['trace_sha256'];
    if (traceJson is! String ||
        storedHash is! String ||
        storedHash != rows.single['calculation_trace_sha256']) {
      throw const ValidationException(
        'REMOTE_MEASUREMENT_TRACE_MISSING',
        'The remote Measurement does not have a matching completed CalculationTrace.',
      );
    }
    final trace = CalculationTrace.fromJson(traceJson);
    if (trace.contentSha256 != storedHash) {
      throw const ValidationException(
        'REMOTE_MEASUREMENT_TRACE_HASH_MISMATCH',
        'The remote CalculationTrace failed its canonical SHA-256 check.',
      );
    }
    return trace;
  }

  /// Imports the original exact value as a locally confirmed Measurement while
  /// retaining its external CalculationRun and source event references.
  MeasurementRecord importMeasurement({
    required String sourceEventId,
    required ApprovalRef approvalRef,
    CommandMetadata? command,
  }) {
    final actualCommand = serviceCommand(command: command);
    return _database.transaction((tx) {
      final sourceRows = tx.query(
        'SELECT * FROM remote_measurement_imports WHERE source_event_id=?',
        [sourceEventId],
      );
      if (sourceRows.isEmpty)
        throw MissingEntityException('RemoteMeasurementImport', sourceEventId);
      final source = sourceRows.single;
      final priorReview = _reviewForDevice(tx, sourceEventId);
      if (priorReview != null) {
        if (priorReview['action'] == 'imported' &&
            priorReview['command_id'] == actualCommand.commandId) {
          return _measurementFromRow(
            tx.query('SELECT * FROM measurements WHERE measurement_id=?', [
              priorReview['local_measurement_id'],
            ]).single,
          );
        }
        throw const ValidationException(
          'REMOTE_MEASUREMENT_ALREADY_REVIEWED',
          'This device already has an immutable review decision for this source Measurement.',
        );
      }
      _requireLocalApproval(
        tx,
        approvalRef,
        sourceEventId,
        actualCommand.normalizedUtcTime,
      );
      final payload = objectFromDb(source['payload_json']);
      final calculationId = source['calculation_id']! as String;
      final runId = source['run_id']! as String;
      final stepId = source['step_id'] as String?;
      final sampleId = source['sample_id'] as String?;
      final analyte = source['analyte']! as String;
      final valueText = source['value_text']! as String;
      final unit = source['unit'] as String?;
      final rawAssetId = source['raw_asset_id'] as String?;
      final outputKey = requireRemoteCalculationOutputForMeasurement(
        tx: tx,
        calculationId: calculationId,
        runId: runId,
        stepId: stepId,
        sampleId: sampleId,
        analyte: analyte,
        valueText: valueText,
        unit: unit,
        rawAssetId: rawAssetId,
      );
      _requireMeasurementContext(tx, runId, stepId, sampleId);
      _requireAssetRefsAvailable(tx, source);
      final sourceType = source['source_event_type']! as String;
      if (sourceType == 'measurement.corrected') {
        return _importCorrection(
          tx: tx,
          source: source,
          sourcePayload: payload,
          sourceEventId: sourceEventId,
          approvalRef: approvalRef,
          outputKey: outputKey,
          command: actualCommand,
        );
      }
      final localMeasurementId = newUuidV7(at: actualCommand.normalizedUtcTime);
      final traceHash = source['calculation_trace_sha256']! as String;
      final importedPayload = <String, Object?>{
        'measurement_id': localMeasurementId,
        'run_id': runId,
        'step_id': stepId,
        'sample_id': sampleId,
        'analyte': analyte,
        'value_text': valueText,
        'unit': unit,
        'raw_asset_id': rawAssetId,
        'state': 'user_confirmed',
        'source_method': 'remote_calculation_import',
        'source_ref': 'Remote CalculationRun $calculationId; trace $traceHash',
        'calculation_id': null,
        'remote_calculation_id': calculationId,
        'remote_calculation_output_key': outputKey,
        'remote_calculation_trace_sha256': traceHash,
        'remote_source_event_id': sourceEventId,
        'remote_measurement_id': source['remote_measurement_id'],
        'approval_ref': approvalRef.value,
      };
      tx.execute(
        '''INSERT INTO measurements
           (measurement_id,run_id,step_id,sample_id,analyte,value_text,unit,raw_asset_id,state,
            superseded_by,created_at_utc,source_method,source_ref,confirmed_at_utc,confirmed_by,
            revision,calculation_id,remote_calculation_id,remote_calculation_output_key,
            remote_source_event_id,remote_measurement_id)
           VALUES(?,?,?,?,?,?,?,?,'user_confirmed',NULL,?,?,?,?,?,1,NULL,?,?,?,?)''',
        [
          localMeasurementId,
          runId,
          stepId,
          sampleId,
          analyte,
          valueText,
          unit,
          rawAssetId,
          actualCommand.normalizedUtcTime.toIso8601String(),
          'remote_calculation_import',
          importedPayload['source_ref'],
          actualCommand.normalizedUtcTime.toIso8601String(),
          actualCommand.actor,
          calculationId,
          outputKey,
          sourceEventId,
          source['remote_measurement_id'],
        ],
      );
      _insertReview(
        tx,
        sourceEventId,
        'imported',
        approvalRef.value,
        localMeasurementId,
        null,
        actualCommand,
      );
      appendServiceMutation(
        tx: tx,
        command: actualCommand,
        deviceId: vault.deviceId,
        entityType: 'measurement',
        entityId: localMeasurementId,
        eventType: 'measurement.recorded',
        action: MutationAction.create,
        payload: importedPayload,
        assetShaRefs: _assetShaRefs(source),
      );
      return _measurementFromRow(
        tx.query('SELECT * FROM measurements WHERE measurement_id=?', [
          localMeasurementId,
        ]).single,
      );
    });
  }

  void reject({
    required String sourceEventId,
    required String reason,
    CommandMetadata? command,
  }) {
    final cleanReason = normalizedText(reason, 'reason');
    final actualCommand = serviceCommand(command: command);
    _database.transaction((tx) {
      final source = tx.query(
        'SELECT 1 FROM remote_measurement_imports WHERE source_event_id=?',
        [sourceEventId],
      );
      if (source.isEmpty)
        throw MissingEntityException('RemoteMeasurementImport', sourceEventId);
      final priorReview = _reviewForDevice(tx, sourceEventId);
      if (priorReview != null) {
        if (priorReview['action'] == 'rejected' &&
            priorReview['reason'] == cleanReason &&
            priorReview['command_id'] == actualCommand.commandId)
          return;
        throw const ValidationException(
          'REMOTE_MEASUREMENT_ALREADY_REVIEWED',
          'This device already has an immutable review decision for this source Measurement.',
        );
      }
      _insertReview(
        tx,
        sourceEventId,
        'rejected',
        null,
        null,
        cleanReason,
        actualCommand,
      );
      appendServiceMutation(
        tx: tx,
        command: actualCommand,
        deviceId: vault.deviceId,
        entityType: 'remote_measurement_review',
        entityId: sourceEventId,
        eventType: 'measurement.external_reviewed',
        action: MutationAction.create,
        payload: {
          'record_kind': 'remote_measurement_review_v1',
          'source_event_id': sourceEventId,
          'decision': 'rejected',
          'reason': cleanReason,
        },
      );
    });
  }

  MeasurementRecord _importCorrection({
    required WorkspaceTransaction tx,
    required DbRow source,
    required Map<String, Object?> sourcePayload,
    required String sourceEventId,
    required ApprovalRef approvalRef,
    required String outputKey,
    required CommandMetadata command,
  }) {
    final originalRemoteId =
        source['original_remote_measurement_id']! as String;
    final originals = tx.query(
      'SELECT * FROM measurements WHERE measurement_id=? OR remote_measurement_id=? LIMIT 1',
      [originalRemoteId, originalRemoteId],
    );
    if (originals.isEmpty) {
      throw const ValidationException(
        'REMOTE_MEASUREMENT_ORIGINAL_REVIEW_REQUIRED',
        'Import the original Measurement on this device before importing its correction.',
      );
    }
    final original = originals.single;
    if (original['superseded_by'] != null ||
        original['state'] == 'superseded') {
      throw const ValidationException(
        'REMOTE_MEASUREMENT_ORIGINAL_ALREADY_CORRECTED',
        'The original Measurement already has a correction on this device.',
      );
    }
    final revision = intFromDb(original['revision']);
    final localMeasurementId = newUuidV7(at: command.normalizedUtcTime);
    final calculationId = source['calculation_id']! as String;
    final traceHash = source['calculation_trace_sha256']! as String;
    final reason = normalizedText(
      sourcePayload['correction_reason'] is String
          ? sourcePayload['correction_reason']! as String
          : 'Reviewed remote Measurement correction',
      'correction_reason',
    );
    final payload = <String, Object?>{
      'measurement_id': localMeasurementId,
      'supersedes_measurement_id': originalRemoteId,
      'replacement_measurement_id': localMeasurementId,
      'run_id': source['run_id'],
      'step_id': source['step_id'],
      'sample_id': source['sample_id'],
      'analyte': source['analyte'],
      'value_text': source['value_text'],
      'unit': source['unit'],
      'raw_asset_id': source['raw_asset_id'],
      'calculation_id': null,
      'remote_calculation_id': calculationId,
      'remote_calculation_output_key': outputKey,
      'remote_calculation_trace_sha256': traceHash,
      'remote_source_event_id': sourceEventId,
      'remote_measurement_id': source['remote_measurement_id'],
      'correction_reason': reason,
      'created_at_utc': command.normalizedUtcTime.toIso8601String(),
      'approval_ref': approvalRef.value,
    };
    tx.execute(
      '''INSERT INTO measurements
         (measurement_id,run_id,step_id,sample_id,analyte,value_text,unit,raw_asset_id,state,
          superseded_by,created_at_utc,source_method,source_ref,confirmed_at_utc,confirmed_by,
          revision,calculation_id,remote_calculation_id,remote_calculation_output_key,
          remote_source_event_id,remote_measurement_id)
         VALUES(?,?,?,?,?,?,?,?,'user_confirmed',NULL,?,'remote_calculation_import',?,?,?,1,NULL,?,?,?,?)''',
      [
        localMeasurementId,
        source['run_id'],
        source['step_id'],
        source['sample_id'],
        source['analyte'],
        source['value_text'],
        source['unit'],
        source['raw_asset_id'],
        command.normalizedUtcTime.toIso8601String(),
        'Remote CalculationRun $calculationId; trace $traceHash',
        command.normalizedUtcTime.toIso8601String(),
        command.actor,
        calculationId,
        outputKey,
        sourceEventId,
        source['remote_measurement_id'],
      ],
    );
    tx.execute(
      '''UPDATE measurements SET state='superseded',superseded_by=?,revision=revision+1
         WHERE measurement_id=? AND revision=? AND superseded_by IS NULL''',
      [localMeasurementId, original['measurement_id'], revision],
    );
    tx.execute(
      '''INSERT INTO measurement_corrections
         (correction_id,measurement_id,replacement_measurement_id,reason,created_at_utc,command_id)
         VALUES(?,?,?,?,?,?)''',
      [
        newUuidV7(at: command.normalizedUtcTime),
        original['measurement_id'],
        localMeasurementId,
        reason,
        command.normalizedUtcTime.toIso8601String(),
        command.commandId,
      ],
    );
    _insertReview(
      tx,
      sourceEventId,
      'imported',
      approvalRef.value,
      localMeasurementId,
      null,
      command,
    );
    appendServiceMutation(
      tx: tx,
      command: CommandMetadata(
        commandId: command.commandId,
        utcTime: command.utcTime,
        baseRevision: revision,
        actor: command.actor,
        sourceRef: command.sourceRef,
        approvalRef: approvalRef,
      ),
      deviceId: vault.deviceId,
      entityType: 'measurement',
      entityId: originalRemoteId,
      eventType: 'measurement.corrected',
      action: MutationAction.append,
      payload: payload,
      assetShaRefs: _assetShaRefs(source),
    );
    return _measurementFromRow(
      tx.query('SELECT * FROM measurements WHERE measurement_id=?', [
        localMeasurementId,
      ]).single,
    );
  }

  void _requireLocalApproval(
    WorkspaceTransaction tx,
    ApprovalRef reference,
    String sourceEventId,
    DateTime atUtc,
  ) {
    final issuers = tx.query(
      '''SELECT m.device_id FROM approval_receipts a JOIN mutation_events m
           ON m.command_id=a.command_id WHERE a.approval_ref=?''',
      [reference.value],
    );
    if (issuers.isEmpty || issuers.single['device_id'] != vault.deviceId) {
      throw const ValidationException(
        'APPROVAL_NOT_LOCAL',
        'A remote Calculation import requires an approval issued on this device.',
      );
    }
    final importedRows = tx.query(
      '''SELECT calculation_id,calculation_trace_sha256 FROM remote_measurement_imports
         WHERE source_event_id=?''',
      [sourceEventId],
    );
    if (importedRows.isEmpty) {
      throw MissingEntityException(
        'RemoteMeasurementImport',
        'source event',
      );
    }
    final imported = importedRows.single;
    tx.requireApproval(
      approvalRef: reference,
      action: 'measurement.external_import',
      subjectType: 'remote_measurement',
      subjectId: sourceEventId,
      atUtc: atUtc,
      requiredScope: <String, Object?>{
        'source_event_id': sourceEventId,
        'calculation_id': imported['calculation_id'],
        'calculation_trace_sha256': imported['calculation_trace_sha256'],
      },
    );
  }

  void _requireAssetRefsAvailable(WorkspaceTransaction tx, DbRow source) {
    final refs = _assetShaRefs(source);
    for (final sha in refs) {
      if (tx
          .query(
            '''SELECT 1 FROM blob_objects WHERE sha256=? AND state='committed' ''',
            [sha],
          )
          .isEmpty) {
        throw ValidationException(
          'REMOTE_MEASUREMENT_ASSET_MISSING',
          'Source Asset $sha is not available in this Vault.',
        );
      }
    }
    final rawAssetId = source['raw_asset_id'] as String?;
    if (rawAssetId != null &&
        tx
            .query(
              '''SELECT 1 FROM assets a JOIN blob_objects b ON b.sha256=a.blob_sha256
         WHERE a.asset_id=? AND a.deleted_at_utc IS NULL AND b.state='committed' ''',
              [rawAssetId],
            )
            .isEmpty) {
      throw const ValidationException(
        'REMOTE_MEASUREMENT_ASSET_MISSING',
        'The referenced raw source Asset is not available in this Vault.',
      );
    }
  }

  void _requireMeasurementContext(
    WorkspaceTransaction tx,
    String runId,
    String? stepId,
    String? sampleId,
  ) {
    if (tx.query('SELECT 1 FROM experiment_runs WHERE run_id=?', [
      runId,
    ]).isEmpty) {
      throw MissingEntityException('Run', runId);
    }
    if (stepId != null &&
        tx.query('SELECT 1 FROM step_executions WHERE step_id=? AND run_id=?', [
          stepId,
          runId,
        ]).isEmpty) {
      throw const ValidationException(
        'REMOTE_MEASUREMENT_STEP_MISSING',
        'Measurement Step is not present in its Run.',
      );
    }
    if (sampleId != null &&
        tx.query('SELECT 1 FROM run_samples WHERE run_id=? AND sample_id=?', [
          runId,
          sampleId,
        ]).isEmpty) {
      throw const ValidationException(
        'REMOTE_MEASUREMENT_SAMPLE_MISSING',
        'Measurement Sample is not attached to its Run.',
      );
    }
  }

  void _insertReview(
    WorkspaceTransaction tx,
    String sourceEventId,
    String action,
    String? approvalRef,
    String? localMeasurementId,
    String? reason,
    CommandMetadata command,
  ) {
    tx.execute(
      '''INSERT INTO remote_measurement_reviews
         (review_id,source_event_id,reviewer_device_id,action,approval_ref,
          local_measurement_id,reason,command_id,created_at_utc)
         VALUES(?,?,?,?,?,?,?,?,?)''',
      [
        newUuidV7(at: command.normalizedUtcTime),
        sourceEventId,
        vault.deviceId,
        action,
        approvalRef,
        localMeasurementId,
        reason,
        command.commandId,
        command.normalizedUtcTime.toIso8601String(),
      ],
    );
  }

  DbRow? _reviewForDevice(WorkspaceTransaction tx, String sourceEventId) {
    final rows = tx.query(
      '''SELECT * FROM remote_measurement_reviews
         WHERE source_event_id=? AND reviewer_device_id=?''',
      [sourceEventId, vault.deviceId],
    );
    return rows.isEmpty ? null : rows.single;
  }

  List<String> _assetShaRefs(DbRow source) =>
      stringListFromDb(source['asset_sha_refs_json']).toList()..sort();

  RemoteMeasurementImportRecord _recordFromRow(DbRow row) =>
      RemoteMeasurementImportRecord(
        sourceEventId: row['source_event_id']! as String,
        measurementId: row['remote_measurement_id']! as String,
        sourceEventType: row['source_event_type']! as String,
        sourceDeviceId: row['source_device_id']! as String,
        calculationId: row['calculation_id']! as String,
        calculationTraceSha256: row['calculation_trace_sha256']! as String,
        payload: objectFromDb(row['payload_json']),
        assetShaRefs: stringListFromDb(row['asset_sha_refs_json']),
        importedAtUtc: dateFromDb(row['imported_at_utc']),
        reviewState: row['review_action'] as String? ?? 'pending',
        localMeasurementId: row['local_measurement_id'] as String?,
        approvalRef: row['approval_ref'] as String?,
        reviewedAtUtc: optionalDateFromDb(row['reviewed_at_utc']),
        reviewReason: row['review_reason'] as String?,
      );

  MeasurementRecord _measurementFromRow(DbRow row) => MeasurementRecord(
    measurementId: row['measurement_id']! as String,
    runId: row['run_id']! as String,
    stepId: row['step_id'] as String?,
    sampleId: row['sample_id'] as String?,
    analyte: row['analyte']! as String,
    valueText: row['value_text']! as String,
    unit: row['unit'] as String?,
    rawAssetId: row['raw_asset_id'] as String?,
    state: row['state']! as String,
    supersededBy: row['superseded_by'] as String?,
    sourceMethod: row['source_method'] as String?,
    sourceRef: row['source_ref'] as String?,
    calculationId: row['calculation_id'] as String?,
    remoteCalculationId: row['remote_calculation_id'] as String?,
    remoteCalculationOutputKey: row['remote_calculation_output_key'] as String?,
    remoteSourceEventId: row['remote_source_event_id'] as String?,
    remoteMeasurementId: row['remote_measurement_id'] as String?,
    createdAtUtc: dateFromDb(row['created_at_utc']),
    confirmedAtUtc: optionalDateFromDb(row['confirmed_at_utc']),
    revision: intFromDb(row['revision']),
  );
}
