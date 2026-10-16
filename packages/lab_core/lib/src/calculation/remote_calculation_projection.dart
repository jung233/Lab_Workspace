import 'dart:convert';

import '../application/remote_event_projection.dart';
import '../domain/calculation_records.dart';
import '../domain/events.dart';
import '../domain/json_value.dart';
import '../persistence/workspace_database.dart';
import '../packs/calculation_pack.dart';
import 'primitive_code_manifest.dart';

/// Imports calculation sync events into immutable, review-only quarantine
/// tables. Remote approvals never install a Pack or publish a local result.
final class CalculationRemoteEventProjection
    implements RemoteEventProjectionHandler {
  CalculationRemoteEventProjection({DateTime Function()? clock})
      : _clock = clock ?? _utcNow;

  final DateTime Function() _clock;

  static const _maxEventBytes = 30 * 1024 * 1024;
  static const _maxPackBytes = 2 * 1024 * 1024;
  static final _sha256Pattern = RegExp(r'^[a-f0-9]{64}$');
  static final _errorCodePattern = RegExp(r'^[A-Z][A-Z0-9_]{1,95}$');

  @override
  bool canHandle({
    required String entityType,
    required MutationAction action,
    required Map<String, Object?> payload,
  }) {
    if (action != MutationAction.create) return false;
    return (entityType == 'calculation_pack' &&
            payload['record_kind'] == 'calculation_pack_install_v2') ||
        (entityType == 'calculation' &&
            payload['record_kind'] == 'calculation_run_v2');
  }

  @override
  void apply(WorkspaceTransaction tx, RemoteEventEnvelope event) {
    _rejectFloatingPoint(event.payload, r'$.payload');
    if (utf8.encode(canonicalJson(event.payload)).length > _maxEventBytes) {
      throw const RemoteProjectionBlocked(
        'REMOTE_CALCULATION_EVENT_TOO_LARGE',
        'The imported calculation event exceeds the immutable snapshot limit.',
      );
    }
    switch (event.payload['record_kind']) {
      case 'calculation_pack_install_v2':
        if (event.entityType != 'calculation_pack' ||
            event.action != MutationAction.create) {
          throw const RemoteProjectionBlocked(
            'REMOTE_PACK_EVENT_KIND_MISMATCH',
            'The imported Pack event has an invalid entity or action.',
          );
        }
        _importPackDraft(tx, event);
        return;
      case 'calculation_run_v2':
        if (event.entityType != 'calculation' ||
            event.action != MutationAction.create) {
          throw const RemoteProjectionBlocked(
            'REMOTE_CALCULATION_EVENT_KIND_MISMATCH',
            'The imported CalculationRun event has an invalid entity or action.',
          );
        }
        _importCalculationRun(tx, event);
        return;
      default:
        throw const RemoteProjectionBlocked(
          'REMOTE_CALCULATION_EVENT_UNSUPPORTED',
          'The imported calculation event kind is not supported.',
        );
    }
  }

  void _importPackDraft(WorkspaceTransaction tx, RemoteEventEnvelope event) {
    if (event.payload['event_type'] != 'calculation_pack.installed') {
      throw const RemoteProjectionBlocked(
        'REMOTE_PACK_EVENT_TYPE_INVALID',
        'The imported Pack event type is invalid.',
      );
    }
    final envelope = _object(event.payload['pack_envelope'], 'pack_envelope');
    final packId = _nonEmptyString(envelope['pack_id'], 'pack_envelope.pack_id');
    final version = _nonEmptyString(envelope['version'], 'pack_envelope.version');
    final contentSha256 = _sha(envelope['content_sha256'], 'pack_envelope.content_sha256');
    final sourceDocument = _object(envelope['document'], 'pack_envelope.document');
    if (sourceDocument['pack_id'] != packId || sourceDocument['version'] != version ||
        calculationPackContentSha256(sourceDocument) != contentSha256 ||
        event.entityId != '$packId@$version') {
      throw const RemoteProjectionBlocked(
        'REMOTE_PACK_SNAPSHOT_MISMATCH',
        'The imported Pack identity or content hash does not match its envelope.',
      );
    }
    final sourceDocumentJson = canonicalJson(sourceDocument);
    if (utf8.encode(sourceDocumentJson).length > _maxPackBytes) {
      throw const RemoteProjectionBlocked(
        'REMOTE_PACK_SNAPSHOT_TOO_LARGE',
        'The imported Pack exceeds the supported draft size.',
      );
    }
    final sourceStatus = sourceDocument['status'];
    if (sourceStatus != 'approved' && sourceStatus != 'draft') {
      throw const RemoteProjectionBlocked(
        'REMOTE_PACK_STATUS_INVALID',
        'The imported Pack does not have a supported source review state.',
      );
    }
    final draftDocument =
        jsonDecode(sourceDocumentJson) as Map<String, Object?>;
    draftDocument['status'] = 'draft';
    final rawReview = draftDocument['review'];
    if (rawReview is! Map) {
      throw const RemoteProjectionBlocked(
        'REMOTE_PACK_REVIEW_MISSING',
        'The imported Pack has no review metadata to quarantine safely.',
      );
    }
    final review = requireJsonObject(rawReview, 'pack_envelope.document.review');
    review['approved_by_user'] = false;
    draftDocument['review'] = review;
    if (calculationPackContentSha256(draftDocument) != contentSha256) {
      throw const RemoteProjectionBlocked(
        'REMOTE_PACK_DRAFT_HASH_MISMATCH',
        'Quarantining the imported Pack changed its algorithm content hash.',
      );
    }

    final sourceProvenance = _sourceProvenance(envelope['source_provenance']);
    final sourceProvenanceJson = canonicalJson(
      sourceProvenance?.toJson() ?? const <String, Object?>{},
    );
    final approvalRef = _optionalString(
      envelope['source_approval_ref'],
      'pack_envelope.source_approval_ref',
      maxLength: 512,
    );
    final signature = _optionalString(
      envelope['signature'],
      'pack_envelope.signature',
      maxLength: 4096,
    );
    final documentJson = canonicalJson(draftDocument);
    _checkIdempotentImport(
      tx,
      table: 'remote_calculation_pack_drafts',
      eventId: event.eventId,
      expected: {
        'pack_id': packId,
        'version': version,
        'content_sha256': contentSha256,
        'document_json': documentJson,
        'source_provenance_json': sourceProvenanceJson,
      },
    );
    if (tx.query(
      'SELECT 1 FROM remote_calculation_pack_drafts WHERE source_event_id=?',
      [event.eventId],
    ).isNotEmpty) {
      return;
    }
    tx.execute(
      '''INSERT INTO remote_calculation_pack_drafts
         (source_event_id,pack_id,version,content_sha256,document_json,
          source_device_id,source_approval_ref,source_signature,
          source_provenance_json,imported_at_utc)
         VALUES(?,?,?,?,?,?,?,?,?,?)''',
      [
        event.eventId,
        packId,
        version,
        contentSha256,
        documentJson,
        event.deviceId,
        approvalRef,
        signature,
        sourceProvenanceJson,
        _clock().toUtc().toIso8601String(),
      ],
    );
  }

  void _importCalculationRun(WorkspaceTransaction tx, RemoteEventEnvelope event) {
    final expectedEventType = event.payload['calculation'] is Map &&
            (event.payload['calculation'] as Map)['status'] == 'completed'
        ? 'calculation.completed'
        : 'calculation.failed';
    if (event.payload['event_type'] != expectedEventType) {
      throw const RemoteProjectionBlocked(
        'REMOTE_CALCULATION_EVENT_TYPE_INVALID',
        'The imported CalculationRun event type does not match its status.',
      );
    }
    final rawRun = _object(event.payload['calculation'], 'calculation');
    const fields = {
      'calculation_id', 'parent_calculation_id', 'run_id', 'sample_id', 'step_id',
      'pack_id', 'pack_version', 'pack_sha256', 'status', 'input_snapshot',
      'source_assets', 'output', 'trace', 'trace_sha256', 'error_code',
      'created_at_utc', 'completed_at_utc', 'revision',
    };
    _requireExactKeys(rawRun, fields, 'calculation');
    final calculationId = _nonEmptyString(rawRun['calculation_id'], 'calculation.calculation_id');
    if (event.entityId != calculationId) {
      throw const RemoteProjectionBlocked(
        'REMOTE_CALCULATION_ID_MISMATCH',
        'The imported CalculationRun entity id does not match its snapshot.',
      );
    }
    final packId = _nonEmptyString(rawRun['pack_id'], 'calculation.pack_id');
    final packVersion = _nonEmptyString(rawRun['pack_version'], 'calculation.pack_version');
    final packSha256 = _sha(rawRun['pack_sha256'], 'calculation.pack_sha256');
    final rawPackEnvelope = _object(event.payload['pack_envelope'], 'pack_envelope');
    final packEnvelope = _validatePackEnvelope(
      rawPackEnvelope,
      packId: packId,
      version: packVersion,
      contentSha256: packSha256,
    );

    final traceDocument = _object(rawRun['trace'], 'calculation.trace');
    final trace = CalculationTrace(document: traceDocument);
    final traceSha256 = _sha(rawRun['trace_sha256'], 'calculation.trace_sha256');
    if (trace.contentSha256 != traceSha256 || trace.calculationId != calculationId ||
        trace.document['pack_ref'] != '$packId@$packVersion' ||
        trace.document['pack_sha256'] != packSha256) {
      throw const RemoteProjectionBlocked(
        'REMOTE_CALCULATION_TRACE_MISMATCH',
        'The imported CalculationTrace hash or identity does not match its result.',
      );
    }

    final statusString = rawRun['status'];
    if (statusString is! String ||
        !CalculationStatus.values.any((status) => status.wireValue == statusString)) {
      throw const RemoteProjectionBlocked(
        'REMOTE_CALCULATION_STATUS_INVALID',
        'The imported CalculationRun status is invalid.',
      );
    }
    final status = CalculationStatus.values.byName(statusString);
    final inputSnapshot = _object(rawRun['input_snapshot'], 'calculation.input_snapshot');
    final sourceAssets = _sourceAssets(rawRun['source_assets']);
    _validateAssetReferences(sourceAssets, event.assetShaRefs);
    final rawOutput = rawRun['output'];
    final output = rawOutput == null ? null : _object(rawOutput, 'calculation.output');
    final errorCode = _optionalString(rawRun['error_code'], 'calculation.error_code', maxLength: 96);
    if (errorCode != null && !_errorCodePattern.hasMatch(errorCode)) {
      throw const RemoteProjectionBlocked(
        'REMOTE_CALCULATION_ERROR_CODE_INVALID',
        'The imported CalculationRun error code is not a safe code identifier.',
      );
    }
    final createdAt = _date(rawRun['created_at_utc'], 'calculation.created_at_utc');
    final completedAt = _date(rawRun['completed_at_utc'], 'calculation.completed_at_utc');
    final revision = rawRun['revision'];
    if (revision is! int || revision < 1) {
      throw const RemoteProjectionBlocked(
        'REMOTE_CALCULATION_REVISION_INVALID',
        'The imported CalculationRun revision must be a positive integer.',
      );
    }
    final run = CalculationRun(
      calculationId: calculationId,
      parentCalculationId: _optionalString(
        rawRun['parent_calculation_id'],
        'calculation.parent_calculation_id',
      ),
      runId: _optionalString(rawRun['run_id'], 'calculation.run_id'),
      sampleId: _optionalString(rawRun['sample_id'], 'calculation.sample_id'),
      stepId: _optionalString(rawRun['step_id'], 'calculation.step_id'),
      packId: packId,
      packVersion: packVersion,
      packSha256: packSha256,
      status: status,
      inputSnapshot: inputSnapshot,
      sourceAssets: sourceAssets,
      output: output,
      trace: trace,
      errorCode: errorCode,
      createdAtUtc: createdAt,
      completedAtUtc: completedAt,
      revision: revision,
    );
    final traceReproducibility = _validateTraceContext(run, packEnvelope);

    final sourceProvenanceJson = canonicalJson({
      'pack': packEnvelope.sourceProvenance?.toJson() ?? const <String, Object?>{},
      'calculation_trace': traceReproducibility,
    });
    final inputJson = canonicalJson(run.inputSnapshot);
    final sourceAssetsJson = canonicalJson(run.sourceAssets);
    final outputJson = run.output == null ? null : canonicalJson(run.output);
    final traceJson = trace.canonicalJson;
    final packSnapshotJson = canonicalJson(packEnvelope.raw);
    _checkIdempotentImport(
      tx,
      table: 'remote_calculation_run_imports',
      eventId: event.eventId,
      expected: {
        'calculation_id': calculationId,
        'pack_sha256': packSha256,
        'input_json': inputJson,
        'source_assets_json': sourceAssetsJson,
        'status': status.wireValue,
        'output_json': outputJson,
        'trace_json': traceJson,
        'trace_sha256': trace.contentSha256,
        'pack_snapshot_json': packSnapshotJson,
        'source_provenance_json': sourceProvenanceJson,
      },
    );
    if (tx.query(
      'SELECT 1 FROM remote_calculation_run_imports WHERE source_event_id=?',
      [event.eventId],
    ).isNotEmpty) {
      return;
    }
    tx.execute(
      '''INSERT INTO remote_calculation_run_imports
         (source_event_id,calculation_id,parent_calculation_id,run_id,sample_id,step_id,
          pack_id,pack_version,pack_sha256,input_json,source_assets_json,status,
          output_json,trace_json,trace_sha256,error_code,pack_snapshot_json,
          source_provenance_json,source_device_id,imported_at_utc)
         VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)''',
      [
        event.eventId,
        run.calculationId,
        run.parentCalculationId,
        run.runId,
        run.sampleId,
        run.stepId,
        run.packId,
        run.packVersion,
        run.packSha256,
        inputJson,
        sourceAssetsJson,
        run.status.wireValue,
        outputJson,
        traceJson,
        trace.contentSha256,
        run.errorCode,
        packSnapshotJson,
        sourceProvenanceJson,
        event.deviceId,
        _clock().toUtc().toIso8601String(),
      ],
    );
  }

  _ValidatedPackEnvelope _validatePackEnvelope(
    Map<String, Object?> envelope, {
    required String packId,
    required String version,
    required String contentSha256,
  }) {
    final envelopePackId = _nonEmptyString(envelope['pack_id'], 'pack_envelope.pack_id');
    final envelopeVersion = _nonEmptyString(envelope['version'], 'pack_envelope.version');
    final envelopeHash = _sha(envelope['content_sha256'], 'pack_envelope.content_sha256');
    final document = _object(envelope['document'], 'pack_envelope.document');
    final origin = _nonEmptyString(envelope['origin'], 'pack_envelope.origin');
    final trustLevel = _nonEmptyString(envelope['trust_level'], 'pack_envelope.trust_level');
    final sourceApprovalRef = _optionalString(
      envelope['source_approval_ref'],
      'pack_envelope.source_approval_ref',
      maxLength: 512,
    );
    final signature = _optionalString(envelope['signature'], 'pack_envelope.signature', maxLength: 4096);
    final sourceProvenance = _sourceProvenance(envelope['source_provenance']);
    final approvedAt = _optionalString(
      envelope['approved_at_utc'],
      'pack_envelope.approved_at_utc',
    );
    if (envelopePackId != packId || envelopeVersion != version ||
        envelopeHash != contentSha256 || document['pack_id'] != packId ||
        document['version'] != version ||
        calculationPackContentSha256(document) != contentSha256 ||
        utf8.encode(canonicalJson(document)).length > _maxPackBytes ||
        (sourceApprovalRef == null) || (origin != 'trusted_builtin' && signature == null)) {
      throw const RemoteProjectionBlocked(
        'REMOTE_CALCULATION_PACK_SNAPSHOT_INVALID',
        'The imported CalculationRun has an invalid or mismatched Pack snapshot.',
      );
    }
    if (approvedAt != null) _date(approvedAt, 'pack_envelope.approved_at_utc');
    return _ValidatedPackEnvelope(
      raw: envelope,
      document: document,
      sourceApprovalRef: sourceApprovalRef,
      sourceProvenance: sourceProvenance,
      origin: origin,
      trustLevel: trustLevel,
      signature: signature,
    );
  }

  Map<String, Object?> _validateTraceContext(
    CalculationRun run,
    _ValidatedPackEnvelope pack,
  ) {
    final trace = run.trace!;
    final outputs = trace.document['outputs'];
    final expectedOutput = run.status == CalculationStatus.completed
        ? {'outputs': outputs}
        : null;
    if (canonicalJson(trace.document['source_assets']) != canonicalJson(run.sourceAssets) ||
        canonicalJson(run.output) != canonicalJson(expectedOutput) ||
        (run.status == CalculationStatus.failed && outputs is List && outputs.isNotEmpty)) {
      throw const RemoteProjectionBlocked(
        'REMOTE_CALCULATION_TRACE_CONTENT_MISMATCH',
        'The imported result does not match its trace outputs or source assets.',
      );
    }
    final context = _object(trace.document['execution_context'], 'trace.execution_context');
    if (context['run_id'] != run.runId ||
        context['sample_id'] != run.sampleId ||
        context['step_id'] != run.stepId ||
        trace.document['recalculation_parent_id'] != run.parentCalculationId) {
      throw const RemoteProjectionBlocked(
        'REMOTE_CALCULATION_TRACE_CONTEXT_MISMATCH',
        'The imported CalculationTrace is bound to a different run, sample, or step.',
      );
    }
    final approval = _object(trace.document['approval'], 'trace.approval');
    if (approval['reference'] != pack.sourceApprovalRef) {
      throw const RemoteProjectionBlocked(
        'REMOTE_CALCULATION_TRACE_APPROVAL_MISMATCH',
        'The imported CalculationTrace approval reference does not match its Pack snapshot.',
      );
    }
    return _validateTraceReproducibility(trace.document, pack.document, run.status);
  }

  Map<String, Object?> _validateTraceReproducibility(
    Map<String, Object?> trace,
    Map<String, Object?> pack,
    CalculationStatus status,
  ) {
    final engine = _object(trace['engine'], 'trace.engine');
    final executorId = _nonEmptyString(engine['executor_id'], 'trace.engine.executor_id');
    final rawHashes = engine['primitive_code_sha256'];
    final sourceState = <String, Object?>{
      'executor_id': executorId,
      'primitive_code_sha256_status': 'legacy_missing',
      'runtime_source_sha256_status': 'legacy_missing',
    };
    if (executorId == 'lab-core-failed-execution') {
      if (status != CalculationStatus.failed ||
          (rawHashes != null && rawHashes is! Map)) {
        throw const RemoteProjectionBlocked(
          'REMOTE_CALCULATION_EXECUTOR_INVALID',
          'A failed execution trace has an invalid executor provenance record.',
        );
      }
      final hashMap = rawHashes is Map ? rawHashes : const <Object?, Object?>{};
      if (hashMap.isNotEmpty) {
        throw const RemoteProjectionBlocked(
          'REMOTE_CALCULATION_FAILED_TRACE_PRIMITIVES_INVALID',
          'A failure trace cannot claim that scientific primitives executed.',
        );
      }
      sourceState['primitive_code_sha256_status'] = 'no_primitive_executed';
      final environment = trace['execution_environment'];
      if (environment is Map && environment['dependencies'] is Map) {
        final dependencies = environment['dependencies'] as Map;
        if (dependencies['calculation_source_manifest_version'] ==
                calculationSourceManifestVersion &&
            dependencies['calculation_runtime_source_sha256'] ==
                dartCalculationRuntimeSourceSha256) {
          sourceState['runtime_source_sha256_status'] = 'verified_failure_trace_service';
        }
      }
      return sourceState;
    }

    if (rawHashes == null) return sourceState;
    if (rawHashes is! Map) {
      throw const RemoteProjectionBlocked(
        'REMOTE_CALCULATION_PRIMITIVE_HASH_INVALID',
        'The imported CalculationTrace primitive source hashes must be an object.',
      );
    }
    final expectedHash = switch (executorId) {
      'lab-core-dart-2.0' => dartCalculationPrimitiveCodeSha256,
      'trusted-python-mobile-v2' || 'trusted-python-stdlib-v2' =>
        pythonCalculationPrimitiveCodeSha256,
      _ => null,
    };
    final pipeline = pack['pipeline'];
    final steps = trace['steps'];
    if (expectedHash == null || pipeline is! List || steps is! List ||
        pipeline.length != steps.length) {
      throw const RemoteProjectionBlocked(
        'REMOTE_CALCULATION_PRIMITIVE_HASH_UNSUPPORTED',
        'The imported calculation has no recognized source bundle for its primitive operations.',
      );
    }
    final expectedOperations = <String>{};
    for (var index = 0; index < pipeline.length; index++) {
      final step = _object(pipeline[index], 'pack.pipeline[$index]');
      final traceStep = _object(steps[index], 'trace.steps[$index]');
      final operation = _nonEmptyString(step['op'], 'pack.pipeline[$index].op');
      if (traceStep['seq'] != index + 1 || traceStep['op'] != operation) {
        throw const RemoteProjectionBlocked(
          'REMOTE_CALCULATION_PRIMITIVE_SEQUENCE_MISMATCH',
          'The imported trace operation sequence differs from its Pack snapshot.',
        );
      }
      expectedOperations.add(operation);
    }
    final versions = _object(engine['primitive_versions'], 'trace.engine.primitive_versions');
    final builds = _object(trace['primitive_build_versions'], 'trace.primitive_build_versions');
    if (rawHashes.length != expectedOperations.length ||
        versions.length != expectedOperations.length ||
        builds.length != expectedOperations.length ||
        !rawHashes.keys.toSet().containsAll(expectedOperations) ||
        !versions.keys.toSet().containsAll(expectedOperations) ||
        !builds.keys.toSet().containsAll(expectedOperations) ||
        rawHashes.values.any((value) => value != expectedHash) ||
        versions.values.any((value) => value != '1') ||
        builds.values.any((value) => value is! String || value.isEmpty)) {
      throw const RemoteProjectionBlocked(
        'REMOTE_CALCULATION_PRIMITIVE_HASH_MISMATCH',
        'The imported trace primitive code hashes or operation metadata do not match its Pack.',
      );
    }
    sourceState['primitive_code_sha256_status'] = 'verified';
    sourceState['primitive_code_sha256'] = Map<String, Object?>.fromEntries(
      expectedOperations.map((operation) => MapEntry(operation, expectedHash)),
    );

    final environment = trace['execution_environment'];
    if (environment is! Map || environment['dependencies'] is! Map) {
      return sourceState;
    }
    final dependencies = environment['dependencies'] as Map;
    if (executorId == 'lab-core-dart-2.0') {
      if (dependencies['calculation_source_manifest_version'] !=
              calculationSourceManifestVersion ||
          dependencies['calculation_runtime_source_sha256'] !=
              dartCalculationRuntimeSourceSha256) {
        throw const RemoteProjectionBlocked(
          'REMOTE_CALCULATION_RUNTIME_HASH_MISMATCH',
          'The imported Dart calculation runtime source hash does not match its pinned manifest.',
        );
      }
      sourceState['runtime_source_sha256_status'] = 'verified';
      return sourceState;
    }
    if (dependencies['runtime_source_manifest_version'] !=
        calculationSourceManifestVersion) {
      return sourceState;
    }
    final target = dependencies['runtime_source_target'];
    if (executorId == 'trusted-python-stdlib-v2') {
      if (target != 'windows' ||
          dependencies['runtime_entry_source_sha256'] !=
              pythonDesktopEntrySourceSha256) {
        throw const RemoteProjectionBlocked(
          'REMOTE_CALCULATION_RUNTIME_HASH_MISMATCH',
          'The imported desktop Python entry source hash does not match its pinned manifest.',
        );
      }
      sourceState['runtime_source_sha256_status'] = 'verified';
      return sourceState;
    }
    if (executorId == 'trusted-python-mobile-v2') {
      final expectedNative = switch (target) {
        'android' => androidPythonRunnerSourceSha256,
        'ios' => iosPythonRunnerSourceSha256,
        _ => null,
      };
      final expectedPreparation = switch (target) {
        'android' => androidPythonPreparationSourceSha256,
        'ios' => iosPythonPreparationSourceSha256,
        _ => null,
      };
      if (expectedNative == null || expectedPreparation == null ||
          dependencies['runtime_entry_source_sha256'] !=
              pythonMobileEntrySourceSha256 ||
          dependencies['native_runner_source_sha256'] != expectedNative ||
          dependencies['runtime_preparation_source_sha256'] != expectedPreparation) {
        throw const RemoteProjectionBlocked(
          'REMOTE_CALCULATION_RUNTIME_HASH_MISMATCH',
          'The imported mobile Python runner or preparation source hash does not match its pinned manifest.',
        );
      }
      sourceState['runtime_source_sha256_status'] = 'verified';
      return sourceState;
    }
    throw const RemoteProjectionBlocked(
      'REMOTE_CALCULATION_RUNTIME_HASH_UNSUPPORTED',
      'The imported executor has no pinned runtime source manifest.',
    );
  }

  List<Map<String, Object?>> _sourceAssets(Object? raw) {
    if (raw is! List) {
      throw const RemoteProjectionBlocked(
        'REMOTE_CALCULATION_SOURCE_ASSETS_INVALID',
        'The imported CalculationRun source assets must be an array.',
      );
    }
    final seenIds = <String>{};
    final result = <Map<String, Object?>>[];
    for (var index = 0; index < raw.length; index++) {
      final item = _object(raw[index], 'calculation.source_assets[$index]');
      _requireExactKeys(item, const {'asset_id', 'sha256', 'validation_level'}, 'source asset');
      final assetId = _nonEmptyString(item['asset_id'], 'source_asset.asset_id');
      final sha = _sha(item['sha256'], 'source_asset.sha256');
      final validationLevel = item['validation_level'];
      if (!seenIds.add(assetId) ||
          !{'verified', 'quick_checked', 'unknown'}.contains(validationLevel)) {
        throw const RemoteProjectionBlocked(
          'REMOTE_CALCULATION_SOURCE_ASSETS_INVALID',
          'The imported CalculationRun source Asset metadata is invalid.',
        );
      }
      result.add({
        'asset_id': assetId,
        'sha256': sha,
        'validation_level': validationLevel,
      });
    }
    return List<Map<String, Object?>>.unmodifiable(result);
  }

  void _validateAssetReferences(List<Map<String, Object?>> sources, List<String> refs) {
    final sourceShas = sources.map((asset) => asset['sha256']! as String).toList()..sort();
    final assetRefs = refs.toList()..sort();
    if (sourceShas.length != assetRefs.length ||
        sourceShas.asMap().entries.any((entry) => entry.value != assetRefs[entry.key]) ||
        assetRefs.any((sha) => !_sha256Pattern.hasMatch(sha))) {
      throw const RemoteProjectionBlocked(
        'REMOTE_CALCULATION_ASSET_REFS_MISMATCH',
        'The imported event Asset references do not match its source snapshot.',
      );
    }
  }

  void _checkIdempotentImport(
    WorkspaceTransaction tx, {
    required String table,
    required String eventId,
    required Map<String, Object?> expected,
  }) {
    // Table names are literals from this class only, never event data.
    final rows = tx.query('SELECT * FROM $table WHERE source_event_id=?', [eventId]);
    if (rows.isEmpty) return;
    final row = rows.single;
    if (expected.entries.any((entry) => row[entry.key] != entry.value)) {
      throw const RemoteProjectionBlocked(
        'REMOTE_CALCULATION_EVENT_REPLAY_MISMATCH',
        'The same remote event id was previously imported with different content.',
      );
    }
  }

  CalculationPackSourceProvenance? _sourceProvenance(Object? value) {
    if (value == null) return null;
    final object = _object(value, 'source_provenance');
    return CalculationPackSourceProvenance.fromJson(object);
  }

  Map<String, Object?> _object(Object? value, String field) {
    if (value is! Map) {
      throw RemoteProjectionBlocked(
        'REMOTE_CALCULATION_FIELD_INVALID',
        '$field must be an object.',
      );
    }
    try {
      return requireJsonObject(value, field);
    } on FormatException {
      throw RemoteProjectionBlocked(
        'REMOTE_CALCULATION_FIELD_INVALID',
        '$field must contain only string keys.',
      );
    }
  }

  void _requireExactKeys(Map<String, Object?> value, Set<String> fields, String field) {
    if (value.keys.toSet().difference(fields).isNotEmpty ||
        fields.difference(value.keys.toSet()).isNotEmpty) {
      throw RemoteProjectionBlocked(
        'REMOTE_CALCULATION_FIELDS_INVALID',
        '$field has missing or unsupported fields.',
      );
    }
  }

  String _nonEmptyString(Object? value, String field) {
    if (value is! String || value.isEmpty || value.length > 1024) {
      throw RemoteProjectionBlocked(
        'REMOTE_CALCULATION_FIELD_INVALID',
        '$field must be a non-empty bounded string.',
      );
    }
    return value;
  }

  String? _optionalString(Object? value, String field, {int maxLength = 1024}) {
    if (value == null) return null;
    if (value is! String || value.isEmpty || value.length > maxLength) {
      throw RemoteProjectionBlocked(
        'REMOTE_CALCULATION_FIELD_INVALID',
        '$field must be null or a bounded string.',
      );
    }
    return value;
  }

  String _sha(Object? value, String field) {
    if (value is! String || !_sha256Pattern.hasMatch(value)) {
      throw RemoteProjectionBlocked(
        'REMOTE_CALCULATION_HASH_INVALID',
        '$field must be a lowercase SHA-256 digest.',
      );
    }
    return value;
  }

  DateTime _date(Object? value, String field) {
    if (value is! String) {
      throw RemoteProjectionBlocked(
        'REMOTE_CALCULATION_TIME_INVALID',
        '$field must be an ISO-8601 timestamp.',
      );
    }
    final date = DateTime.tryParse(value);
    if (date == null || !value.endsWith('Z')) {
      throw RemoteProjectionBlocked(
        'REMOTE_CALCULATION_TIME_INVALID',
        '$field must be a UTC ISO-8601 timestamp.',
      );
    }
    return date.toUtc();
  }

  void _rejectFloatingPoint(Object? value, String path) {
    if (value is double) {
      throw RemoteProjectionBlocked(
        'REMOTE_CALCULATION_FLOAT_UNSUPPORTED',
        'Floating-point values are not accepted in calculation sync snapshots ($path).',
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
}

final class _ValidatedPackEnvelope {
  const _ValidatedPackEnvelope({
    required this.raw,
    required this.document,
    required this.sourceApprovalRef,
    required this.sourceProvenance,
    required this.origin,
    required this.trustLevel,
    required this.signature,
  });

  final Map<String, Object?> raw;
  final Map<String, Object?> document;
  final String sourceApprovalRef;
  final CalculationPackSourceProvenance? sourceProvenance;
  final String origin;
  final String trustLevel;
  final String? signature;
}

DateTime _utcNow() => DateTime.now().toUtc();
