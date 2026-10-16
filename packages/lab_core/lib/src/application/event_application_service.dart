import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../domain/errors.dart';
import '../domain/events.dart';
import '../domain/ids.dart';
import '../domain/json_value.dart';
import '../domain/protocol_document.dart';
import '../domain/vault.dart';
import '../persistence/workspace_database.dart';
import '_service_support.dart';
import 'remote_event_projection.dart';

enum RemoteEventApplicationState { applied, conflicted, blocked }

final class RemoteEventApplicationResult {
  const RemoteEventApplicationResult({
    required this.eventId,
    required this.state,
    this.errorCode,
    this.message,
    this.entityType,
    this.entityId,
  });

  final String eventId;
  final RemoteEventApplicationState state;
  final String? errorCode;
  final String? message;
  final String? entityType;
  final String? entityId;
}

final class _DecodedRemoteEvent {
  const _DecodedRemoteEvent({
    required this.schemaVersion,
    required this.action,
    required this.payload,
    required this.assetShaRefs,
    required this.occurredAtUtc,
    required this.eventType,
  });

  final String schemaVersion;
  final MutationAction action;
  final Map<String, Object?> payload;
  final List<String> assetShaRefs;
  final DateTime occurredAtUtc;
  final String eventType;
}

/// Applies a received immutable envelope to the local domain projection.
/// Every operation is an explicit allowlisted handler. Payloads are data only;
/// they are never interpreted as SQL or executable instructions.
final class EventApplicationService {
  EventApplicationService(
    this.vault, {
    Iterable<RemoteEventProjectionHandler> handlers = const [],
  }) : handlers = List<RemoteEventProjectionHandler>.unmodifiable(handlers);

  final VaultContext vault;
  final List<RemoteEventProjectionHandler> handlers;

  RemoteEventApplicationResult applyReceived(
    WorkspaceTransaction tx, {
    required String eventId,
    required String targetId,
    DateTime? atUtc,
  }) {
    final rows = tx.query('SELECT * FROM sync_remote_events WHERE event_id=?', [
      eventId,
    ]);
    if (rows.isEmpty) throw MissingEntityException('RemoteEvent', eventId);
    final row = rows.single;
    final targetRows = tx.query(
      'SELECT 1 FROM sync_remote_event_targets WHERE target_id=? AND event_id=?',
      [targetId, eventId],
    );
    if (targetRows.isEmpty) {
      throw const ValidationException(
        'REMOTE_EVENT_TARGET_MISSING',
        'RemoteEvent has not been recorded for the requested target.',
      );
    }
    final entityType = row['entity_kind']! as String;
    final entityId = row['entity_id']! as String;
    final currentState = row['application_state'] as String? ?? 'received';
    if (currentState == 'applied') {
      _setOutcome(tx, eventId, targetId, 'applied', null);
      return RemoteEventApplicationResult(
        eventId: eventId,
        state: RemoteEventApplicationState.applied,
        entityType: entityType,
        entityId: entityId,
      );
    }

    if (_hasOpenConflict(tx, eventId)) {
      _setOutcome(tx, eventId, targetId, 'conflicted', 'SYNC_CONFLICT_OPEN');
      return RemoteEventApplicationResult(
        eventId: eventId,
        state: RemoteEventApplicationState.conflicted,
        errorCode: 'SYNC_CONFLICT_OPEN',
        message: 'This event has an unresolved conflict and remains unapplied.',
        entityType: entityType,
        entityId: entityId,
      );
    }

    late final _DecodedRemoteEvent decoded;
    try {
      decoded = _decodeRemoteEvent(row);
    } on _ProjectionBlocked catch (error) {
      _setOutcome(tx, eventId, targetId, 'blocked', error.code);
      return RemoteEventApplicationResult(
        eventId: eventId,
        state: RemoteEventApplicationState.blocked,
        errorCode: error.code,
        message: error.message,
        entityType: entityType,
        entityId: entityId,
      );
    } on FormatException catch (error) {
      _setOutcome(tx, eventId, targetId, 'blocked', 'REMOTE_EVENT_INVALID');
      return RemoteEventApplicationResult(
        eventId: eventId,
        state: RemoteEventApplicationState.blocked,
        errorCode: 'REMOTE_EVENT_INVALID',
        message: error.message.toString(),
        entityType: entityType,
        entityId: entityId,
      );
    } on TypeError catch (error) {
      _setOutcome(tx, eventId, targetId, 'blocked', 'REMOTE_EVENT_INVALID');
      return RemoteEventApplicationResult(
        eventId: eventId,
        state: RemoteEventApplicationState.blocked,
        errorCode: 'REMOTE_EVENT_INVALID',
        message: error.toString(),
        entityType: entityType,
        entityId: entityId,
      );
    }
    final payload = decoded.payload;
    final action = decoded.action;
    final baseRevision = row['base_revision'] == null
        ? null
        : intFromDb(row['base_revision']);
    final occurredAt = decoded.occurredAtUtc;
    final eventType = decoded.eventType;
    if (eventType == 'approval.issued' || eventType == 'approval.revoked') {
      const errorCode = 'REMOTE_EVENT_LOCAL_ONLY';
      _setOutcome(tx, eventId, targetId, 'blocked', errorCode);
      return RemoteEventApplicationResult(
        eventId: eventId,
        state: RemoteEventApplicationState.blocked,
        errorCode: errorCode,
        message: 'Approval receipts and revocations are device-local authority.',
        entityType: entityType,
        entityId: entityId,
      );
    }
    if (!_eventTypeMatchesEnvelope(
      entityType,
      action,
      payload,
      eventType,
      schemaVersion: decoded.schemaVersion,
    )) {
      const errorCode = 'REMOTE_EVENT_TYPE_INVALID';
      _setOutcome(tx, eventId, targetId, 'blocked', errorCode);
      return RemoteEventApplicationResult(
        eventId: eventId,
        state: RemoteEventApplicationState.blocked,
        errorCode: errorCode,
        message: 'Event type does not match the entity, action, and payload.',
        entityType: entityType,
        entityId: entityId,
      );
    }
    final isCoreEvent = _isCoreEvent(eventType);
    final externalHandler = isCoreEvent
        ? null
        : _findHandler(entityType, action, payload);
    final actionInvalid = isCoreEvent && !_actionMatches(eventType, action);
    final handlerMissing = !isCoreEvent && externalHandler == null;
    if (actionInvalid || handlerMissing) {
      final errorCode = actionInvalid
          ? 'REMOTE_EVENT_ACTION_INVALID'
          : 'REMOTE_EVENT_HANDLER_UNAVAILABLE';
      final message = actionInvalid
          ? 'Remote action ${action.wireValue} does not match $eventType.'
          : 'No safe projection handler is registered for $entityType/${action.wireValue}.';
      _setOutcome(tx, eventId, targetId, 'blocked', errorCode);
      return RemoteEventApplicationResult(
        eventId: eventId,
        state: RemoteEventApplicationState.blocked,
        errorCode: errorCode,
        message: message,
        entityType: entityType,
        entityId: entityId,
      );
    }
    try {
      tx.savepoint(() {
        _applyProjection(
          tx,
          eventId: eventId,
          entityType: entityType,
          entityId: entityId,
          eventType: eventType,
          action: action,
          baseRevision: baseRevision,
          payload: payload,
          occurredAtUtc: occurredAt,
          externalHandler: externalHandler,
          envelope: RemoteEventEnvelope(
            eventId: eventId,
            targetId: targetId,
            deviceId: row['device_id']! as String,
            sequence: intFromDb(row['sequence']),
            lamport: intFromDb(row['lamport']),
            entityType: entityType,
            entityId: entityId,
            baseRevision: baseRevision,
            action: action,
            payload: payload,
            assetShaRefs: stringListFromDb(row['asset_sha_refs_json']),
            occurredAtUtc: occurredAt,
          ),
        );
      });
      _setOutcome(tx, eventId, targetId, 'applied', null);
      return RemoteEventApplicationResult(
        eventId: eventId,
        state: RemoteEventApplicationState.applied,
        entityType: entityType,
        entityId: entityId,
      );
    } on _ProjectionConflict catch (error) {
      final counterpart =
          error.counterpartEventId ??
          _findCounterpart(tx, entityType, entityId, eventId);
      if (counterpart == null || counterpart == eventId) {
        _setOutcome(tx, eventId, targetId, 'blocked', error.code);
        return RemoteEventApplicationResult(
          eventId: eventId,
          state: RemoteEventApplicationState.blocked,
          errorCode: error.code,
          message:
              '${error.message} No matching prior event was available for conflict review.',
          entityType: entityType,
          entityId: entityId,
        );
      }
      _recordConflict(tx, row, counterpart, occurredAt);
      _setOutcome(tx, eventId, targetId, 'conflicted', error.code);
      return RemoteEventApplicationResult(
        eventId: eventId,
        state: RemoteEventApplicationState.conflicted,
        errorCode: error.code,
        message: error.message,
        entityType: entityType,
        entityId: entityId,
      );
    } on RemoteProjectionConflict catch (error) {
      final counterpart =
          error.counterpartEventId ??
          _findCounterpart(tx, entityType, entityId, eventId);
      if (counterpart == null || counterpart == eventId) {
        _setOutcome(tx, eventId, targetId, 'blocked', error.code);
        return RemoteEventApplicationResult(
          eventId: eventId,
          state: RemoteEventApplicationState.blocked,
          errorCode: error.code,
          message:
              '${error.message} No matching prior event was available for conflict review.',
          entityType: entityType,
          entityId: entityId,
        );
      }
      _recordConflict(tx, row, counterpart, occurredAt);
      _setOutcome(tx, eventId, targetId, 'conflicted', error.code);
      return RemoteEventApplicationResult(
        eventId: eventId,
        state: RemoteEventApplicationState.conflicted,
        errorCode: error.code,
        message: error.message,
        entityType: entityType,
        entityId: entityId,
      );
    } on _ProjectionBlocked catch (error) {
      _setOutcome(tx, eventId, targetId, 'blocked', error.code);
      return RemoteEventApplicationResult(
        eventId: eventId,
        state: RemoteEventApplicationState.blocked,
        errorCode: error.code,
        message: error.message,
        entityType: entityType,
        entityId: entityId,
      );
    } on RemoteProjectionBlocked catch (error) {
      _setOutcome(tx, eventId, targetId, 'blocked', error.code);
      return RemoteEventApplicationResult(
        eventId: eventId,
        state: RemoteEventApplicationState.blocked,
        errorCode: error.code,
        message: error.message,
        entityType: entityType,
        entityId: entityId,
      );
    } on ValidationException catch (error) {
      _setOutcome(tx, eventId, targetId, 'blocked', error.code);
      return RemoteEventApplicationResult(
        eventId: eventId,
        state: RemoteEventApplicationState.blocked,
        errorCode: error.code,
        message: error.message,
        entityType: entityType,
        entityId: entityId,
      );
    } on FormatException catch (error) {
      _setOutcome(tx, eventId, targetId, 'blocked', 'REMOTE_EVENT_INVALID');
      return RemoteEventApplicationResult(
        eventId: eventId,
        state: RemoteEventApplicationState.blocked,
        errorCode: 'REMOTE_EVENT_INVALID',
        message: error.message.toString(),
        entityType: entityType,
        entityId: entityId,
      );
    }
  }

  void _applyProjection(
    WorkspaceTransaction tx, {
    required String eventId,
    required String entityType,
    required String entityId,
    required String eventType,
    required MutationAction action,
    required int? baseRevision,
    required Map<String, Object?> payload,
    required DateTime occurredAtUtc,
    required RemoteEventProjectionHandler? externalHandler,
    required RemoteEventEnvelope envelope,
  }) {
    _validateAssetReferences(tx, entityId, eventType, payload, envelope);
    switch (eventType) {
      case 'project.created':
        _createProject(tx, entityId, payload, occurredAtUtc);
      case 'project.updated':
        _updateProject(tx, entityId, payload, baseRevision);
      case 'experiment.created':
        _createExperiment(tx, entityId, payload, occurredAtUtc);
      case 'experiment.updated':
        _updateExperiment(tx, entityId, payload, baseRevision);
      case 'group.created':
        _createGroup(tx, entityId, payload);
      case 'group.updated':
        _updateGroup(tx, entityId, payload, baseRevision);
      case 'protocol.draft_saved':
        _saveProtocolDraft(tx, entityId, payload, occurredAtUtc);
      case 'protocol.approved':
        _approveProtocol(tx, entityId, payload);
      case 'run.created':
        _createRun(tx, entityId, payload, occurredAtUtc);
      case 'run.sample_attached':
        _attachSample(tx, payload);
      case 'run.closed':
        _closeRun(tx, eventId, entityId, payload, baseRevision);
      case 'schedule.rebuilt':
        _rebuildSchedule(
          tx,
          eventId,
          entityId,
          payload,
          baseRevision,
          occurredAtUtc,
        );
      case 'step.added':
        _addStep(tx, entityId, payload);
      case 'step.started':
        _startStep(tx, eventId, entityId, payload, baseRevision, occurredAtUtc);
      case 'step.completed':
        _completeStep(
          tx,
          eventId,
          entityId,
          payload,
          baseRevision,
          occurredAtUtc,
        );
      case 'sample.created':
        _createSample(tx, eventId, entityId, payload, occurredAtUtc);
      case 'treatment.recorded':
      case 'treatment.corrected':
        _recordTreatment(tx, entityId, payload, occurredAtUtc, eventId);
      case 'measurement.recorded':
        _recordMeasurement(
          tx,
          eventId,
          envelope.deviceId,
          envelope.assetShaRefs,
          entityId,
          payload,
          occurredAtUtc,
        );
      case 'measurement.confirmed':
        _confirmMeasurement(tx, entityId, payload, baseRevision);
      case 'measurement.corrected':
        _correctMeasurement(
          tx,
          eventId,
          envelope.deviceId,
          envelope.assetShaRefs,
          entityId,
          payload,
          occurredAtUtc,
          baseRevision,
        );
      case 'measurement.external_reviewed':
        _recordExternalMeasurementReview(
          tx,
          eventId,
          envelope.deviceId,
          payload,
          occurredAtUtc,
        );
      case 'task.created':
        _createTask(tx, entityId, payload, occurredAtUtc, eventId);
      case 'task.updated':
        _updateTask(tx, entityId, payload, baseRevision, occurredAtUtc);
      case 'task.completed':
        _completeTask(tx, entityId, payload, baseRevision);
      case 'task.deleted':
        _deleteTask(tx, entityId, payload, baseRevision);
      case 'reminder.created':
        _createReminder(tx, entityId, payload, occurredAtUtc, eventId);
      case 'reminder.delivery_updated':
        _updateReminder(tx, entityId, payload);
      case 'approval.issued':
        _issueApproval(tx, entityId, payload, occurredAtUtc, eventId);
      case 'approval.revoked':
        _revokeApproval(tx, entityId, payload);
      case 'setting.updated':
        _updateSetting(tx, entityId, payload, occurredAtUtc, baseRevision);
      default:
        if (externalHandler == null) {
          throw _ProjectionBlocked(
            'REMOTE_EVENT_HANDLER_UNAVAILABLE',
            'No safe projection handler is registered for $eventType.',
          );
        }
        externalHandler.apply(tx, envelope);
    }
  }

  void _validateAssetReferences(
    WorkspaceTransaction tx,
    String entityId,
    String eventType,
    Map<String, Object?> payload,
    RemoteEventEnvelope envelope,
  ) {
    final requiredAssetIds = <String>{};
    if (eventType == 'protocol.draft_saved' ||
        eventType == 'protocol.approved') {
      final document = _object(payload['document'], 'document');
      final sources = document['sources'];
      if (sources is! List) {
        throw _ProjectionBlocked(
          'REMOTE_PROTOCOL_INVALID',
          'Protocol sources must be an array.',
        );
      }
      for (final value in sources) {
        final source = _object(value, 'protocol source');
        final assetId = _text(source, 'asset_id');
        final sha256 = _text(source, 'sha256');
        if (sha256.length != 64 ||
            !RegExp(r'^[0-9a-f]{64}$').hasMatch(sha256)) {
          throw _ProjectionBlocked(
            'REMOTE_PROTOCOL_SOURCE_INVALID',
            'Protocol source SHA-256 is malformed.',
          );
        }
        if (!envelope.assetShaRefs.contains(sha256)) {
          throw _ProjectionBlocked(
            'REMOTE_ASSET_REFERENCE_MISSING',
            'Protocol event omits a source Asset SHA-256 reference.',
          );
        }
        _requireCommittedAsset(tx, assetId, sha256);
      }
      return;
    }
    if (eventType == 'run.created') {
      final snapshot = _object(
        payload['protocol_snapshot'] ?? const <String, Object?>{},
        'protocol_snapshot',
      );
      final sources = snapshot['sources'];
      if (sources == null) return;
      if (sources is! List) {
        throw _ProjectionBlocked(
          'REMOTE_PROTOCOL_INVALID',
          'Run Protocol snapshot sources must be an array.',
        );
      }
      for (final value in sources) {
        final source = _object(value, 'protocol source');
        final assetId = _text(source, 'asset_id');
        final sha256 = _text(source, 'sha256');
        if (!envelope.assetShaRefs.contains(sha256)) {
          throw _ProjectionBlocked(
            'REMOTE_ASSET_REFERENCE_MISSING',
            'Run event omits a Protocol source Asset SHA-256 reference.',
          );
        }
        _requireCommittedAsset(tx, assetId, sha256);
      }
      return;
    }
    if (eventType == 'measurement.recorded' ||
        eventType == 'measurement.corrected') {
      final assetId = _optionalText(payload['raw_asset_id']);
      if (assetId != null) requiredAssetIds.add(assetId);
      if (eventType == 'measurement.corrected') {
        final supersedesId = _text(payload, 'supersedes_measurement_id');
        final original = tx.query(
          'SELECT raw_asset_id FROM measurements WHERE measurement_id=?',
          [supersedesId],
        );
        if (original.isEmpty) {
          throw _ProjectionBlocked(
            'REMOTE_PARENT_MISSING',
            'Corrected Measurement has not arrived yet.',
          );
        }
        final originalAssetId = original.single['raw_asset_id'] as String?;
        if (originalAssetId != null) requiredAssetIds.add(originalAssetId);
      }
    } else if (eventType == 'measurement.confirmed') {
      final existing = tx.query(
        'SELECT raw_asset_id FROM measurements WHERE measurement_id=?',
        [entityId],
      );
      if (existing.isEmpty) {
        throw _ProjectionBlocked(
          'REMOTE_PARENT_MISSING',
          'Confirmed Measurement has not arrived yet.',
        );
      }
      final assetId = existing.single['raw_asset_id'] as String?;
      if (assetId != null) requiredAssetIds.add(assetId);
    }
    for (final assetId in requiredAssetIds) {
      final rows = tx.query(
        '''SELECT a.blob_sha256 FROM assets a JOIN blob_objects b ON b.sha256=a.blob_sha256
           WHERE a.asset_id=? AND a.deleted_at_utc IS NULL AND b.state='committed' ''',
        [assetId],
      );
      if (rows.isEmpty) {
        throw _ProjectionBlocked(
          'REMOTE_PARENT_MISSING',
          'Measurement Asset has not been received and verified.',
        );
      }
      final sha256 = rows.single['blob_sha256']! as String;
      if (!envelope.assetShaRefs.contains(sha256)) {
        throw _ProjectionBlocked(
          'REMOTE_ASSET_REFERENCE_MISSING',
          'Measurement event omits a referenced Asset SHA-256.',
        );
      }
    }
  }

  void _requireCommittedAsset(
    WorkspaceTransaction tx,
    String assetId,
    String sha256,
  ) {
    final rows = tx.query(
      '''SELECT a.blob_sha256 FROM assets a JOIN blob_objects b ON b.sha256=a.blob_sha256
         WHERE a.asset_id=? AND a.deleted_at_utc IS NULL AND b.state='committed' ''',
      [assetId],
    );
    if (rows.isEmpty || rows.single['blob_sha256'] != sha256) {
      throw _ProjectionBlocked(
        'REMOTE_PROTOCOL_SOURCE_MISMATCH',
        'Protocol source Asset is missing, deleted, uncommitted, or has a different SHA-256.',
      );
    }
  }

  RemoteEventProjectionHandler? _findHandler(
    String entityType,
    MutationAction action,
    Map<String, Object?> payload,
  ) {
    final matching = handlers
        .where(
          (handler) => handler.canHandle(
            entityType: entityType,
            action: action,
            payload: payload,
          ),
        )
        .toList(growable: false);
    if (matching.length > 1) {
      throw StateError(
        'More than one remote projection handler claims $entityType/${action.wireValue}.',
      );
    }
    return matching.isEmpty ? null : matching.single;
  }

  static bool _isCoreEvent(String eventType) => const {
    'project.created',
    'project.updated',
    'experiment.created',
    'experiment.updated',
    'group.created',
    'group.updated',
    'protocol.draft_saved',
    'protocol.approved',
    'run.created',
    'run.sample_attached',
    'run.closed',
    'step.added',
    'step.started',
    'step.completed',
    'schedule.rebuilt',
    'sample.created',
    'treatment.recorded',
    'treatment.corrected',
    'measurement.recorded',
    'measurement.confirmed',
    'measurement.corrected',
    'measurement.external_reviewed',
    'task.created',
    'task.updated',
    'task.completed',
    'task.deleted',
    'reminder.created',
    'reminder.delivery_updated',
    'approval.issued',
    'approval.revoked',
    'setting.updated',
  }.contains(eventType);

  _DecodedRemoteEvent _decodeRemoteEvent(DbRow row) {
    final wireJson = row['wire_json'];
    if (wireJson is! String || wireJson.isEmpty) {
      throw const _ProjectionBlocked(
        'REMOTE_EVENT_WIRE_MISSING',
        'The original immutable event envelope is unavailable.',
      );
    }
    if (sha256.convert(utf8.encode(wireJson)).toString() !=
        row['content_sha256']) {
      throw const _ProjectionBlocked(
        'REMOTE_EVENT_HASH_MISMATCH',
        'The retained event envelope does not match its content hash.',
      );
    }
    final document = _object(jsonDecode(wireJson), 'wire envelope');
    final schemaVersion = _text(document, 'schema_version');
    final v2Fields = const {
      'schema_version',
      'vault_id',
      'device_id',
      'seq',
      'lamport',
      'event_id',
      'entity_kind',
      'entity_id',
      'base_revision',
      'action',
      'payload',
      'sha_refs',
      'created_at_utc',
    };
    final v3Fields = {...v2Fields, 'command_id', 'event_type'};
    final expectedFields = switch (schemaVersion) {
      '2.0' => v2Fields,
      '3.0' => v3Fields,
      _ => throw const _ProjectionBlocked(
        'REMOTE_EVENT_VERSION_UNSUPPORTED',
        'Remote event schema version is unsupported.',
      ),
    };
    final actualFields = document.keys.toSet();
    if (actualFields.length != expectedFields.length ||
        !actualFields.containsAll(expectedFields)) {
      throw const _ProjectionBlocked(
        'REMOTE_EVENT_FIELDS_INVALID',
        'Remote event fields do not match the selected strict schema.',
      );
    }
    final eventId = _text(document, 'event_id');
    final deviceId = _text(document, 'device_id');
    final entityType = _text(document, 'entity_kind');
    final entityId = _text(document, 'entity_id');
    final vaultId = _text(document, 'vault_id');
    final sequence = _int(document, 'seq');
    final lamport = _int(document, 'lamport');
    final action = _action(document['action']);
    final payload = _object(document['payload'], 'payload');
    final baseRevision = _optionalInt(document['base_revision']);
    final createdAtText = _dateText(document, 'created_at_utc');
    final occurredAt = DateTime.parse(createdAtText).toUtc();
    final rawRefs = document['sha_refs'];
    if (rawRefs is! List || rawRefs.any((value) => value is! String)) {
      throw const _ProjectionBlocked(
        'REMOTE_EVENT_INVALID',
        'sha_refs must be an array of strings.',
      );
    }
    final assetShaRefs = rawRefs.cast<String>();
    if (assetShaRefs.any(
      (sha) => !RegExp(r'^[a-f0-9]{64}$').hasMatch(sha),
    )) {
      throw const _ProjectionBlocked(
        'REMOTE_EVENT_INVALID',
        'sha_refs contains a malformed SHA-256 value.',
      );
    }
    final rowBaseRevision = row['base_revision'] == null
        ? null
        : intFromDb(row['base_revision']);
    if (vaultId != vault.vaultId ||
        eventId != row['event_id'] ||
        deviceId != row['device_id'] ||
        sequence != intFromDb(row['sequence']) ||
        lamport != intFromDb(row['lamport']) ||
        entityType != row['entity_kind'] ||
        entityId != row['entity_id'] ||
        baseRevision != rowBaseRevision ||
        action.wireValue != row['action'] ||
        createdAtText != row['created_at_utc'] ||
        canonicalJson(payload) != canonicalJson(_payload(row['payload_json'])) ||
        canonicalJson(assetShaRefs) !=
            canonicalJson(stringListFromDb(row['asset_sha_refs_json']))) {
      throw const _ProjectionBlocked(
        'REMOTE_EVENT_INDEX_MISMATCH',
        'Indexed remote event fields differ from the immutable envelope.',
      );
    }

    String eventType;
    if (schemaVersion == '3.0') {
      eventType = _text(document, 'event_type');
      final commandId = _text(document, 'command_id');
      if (commandId != row['command_id'] || eventType != row['event_type']) {
        throw const _ProjectionBlocked(
          'REMOTE_EVENT_INDEX_MISMATCH',
          'Indexed command or event type differs from the v3 envelope.',
        );
      }
    } else {
      if (row['command_id'] != eventId) {
        throw const _ProjectionBlocked(
          'REMOTE_EVENT_INDEX_MISMATCH',
          'Legacy v2 command id must use its event id for local idempotency.',
        );
      }
      final inferredType = _inferEventType(entityType, action, payload);
      if (inferredType == null) {
        throw const _ProjectionBlocked(
          'REMOTE_EVENT_TYPE_AMBIGUOUS',
          'The v2 envelope does not identify an event type that can be inferred safely.',
        );
      }
      eventType = inferredType;
    }
    return _DecodedRemoteEvent(
      schemaVersion: schemaVersion,
      action: action,
      payload: payload,
      assetShaRefs: List<String>.unmodifiable(assetShaRefs),
      occurredAtUtc: occurredAt,
      eventType: eventType,
    );
  }

  static bool _eventTypeMatchesEnvelope(
    String entity,
    MutationAction action,
    Map<String, Object?> payload,
    String eventType, {
    required String schemaVersion,
  }) {
    final inferred = _inferEventType(entity, action, payload);
    if (_isCoreEvent(eventType)) {
      return inferred == eventType && _actionMatches(eventType, action);
    }
    if (schemaVersion == '2.0') return inferred == eventType;
    return _externalEventType(entity, action, payload) == eventType;
  }

  static String? _inferEventType(
    String entity,
    MutationAction action,
    Map<String, Object?> payload,
  ) {
    if (entity == 'remote_measurement_review' &&
        payload['record_kind'] == 'remote_measurement_review_v1') {
      return 'measurement.external_reviewed';
    }
    if (entity == 'run' && payload.containsKey('sample_id')) {
      return 'run.sample_attached';
    }
    if (entity == 'run' && payload.containsKey('start_at_utc')) {
      return 'schedule.rebuilt';
    }
    if (entity == 'run' &&
        payload.containsKey('state') &&
        payload.containsKey('finished_at_utc')) {
      return 'run.closed';
    }
    if (entity == 'step' && action == MutationAction.create) {
      return 'step.added';
    }
    if (entity == 'step' && payload.containsKey('started_at_utc')) {
      return 'step.started';
    }
    if (entity == 'step' && payload.containsKey('completed_at_utc')) {
      return 'step.completed';
    }
    final protocolDocument = payload['document'] is Map
        ? payload['document'] as Map
        : const <Object?, Object?>{};
    final protocolStatus = payload['status'] ?? protocolDocument['status'];
    if (entity == 'protocol_version' && protocolStatus == 'draft') {
      return 'protocol.draft_saved';
    }
    if (entity == 'protocol_version' && protocolStatus == 'approved') {
      return 'protocol.approved';
    }
    if (entity == 'measurement' && action == MutationAction.create) {
      return 'measurement.recorded';
    }
    if (entity == 'measurement' &&
        payload.containsKey('supersedes_measurement_id')) {
      return 'measurement.corrected';
    }
    if (entity == 'measurement' && payload['to_state'] == 'user_confirmed') {
      return 'measurement.confirmed';
    }
    if (entity == 'project' && action == MutationAction.create) {
      return 'project.created';
    }
    if (entity == 'project' && action == MutationAction.patch) {
      return 'project.updated';
    }
    if (entity == 'experiment' && action == MutationAction.create) {
      return 'experiment.created';
    }
    if (entity == 'experiment' && action == MutationAction.patch) {
      return 'experiment.updated';
    }
    if (entity == 'experimental_group' && action == MutationAction.create) {
      return 'group.created';
    }
    if (entity == 'experimental_group' && action == MutationAction.patch) {
      return 'group.updated';
    }
    if (entity == 'run' && action == MutationAction.create) {
      return 'run.created';
    }
    if (entity == 'sample' && action == MutationAction.create) {
      return 'sample.created';
    }
    if (entity == 'treatment' && payload['corrected_from'] != null) {
      return 'treatment.corrected';
    }
    if (entity == 'treatment' && action == MutationAction.append) {
      return 'treatment.recorded';
    }
    if (entity == 'task' && action == MutationAction.create) {
      return 'task.created';
    }
    if (entity == 'task' && action == MutationAction.patch) {
      if (payload.containsKey('deleted_at_utc')) return 'task.deleted';
      if (payload.containsKey('title')) return 'task.updated';
      if (payload.containsKey('completed_at_utc')) return 'task.completed';
      return null;
    }
    if (entity == 'reminder' && action == MutationAction.create) {
      return 'reminder.created';
    }
    if (entity == 'reminder' && action == MutationAction.patch) {
      return 'reminder.delivery_updated';
    }
    if (entity == 'approval' && action == MutationAction.create) {
      return 'approval.issued';
    }
    if (entity == 'approval' && action == MutationAction.tombstone) {
      return 'approval.revoked';
    }
    if (entity == 'setting' && action == MutationAction.patch) {
      return 'setting.updated';
    }
    return _externalEventType(entity, action, payload);
  }

  static String? _externalEventType(
    String entity,
    MutationAction action,
    Map<String, Object?> payload,
  ) {
    if (entity == 'calculation' &&
        action == MutationAction.create &&
        payload['record_kind'] == 'calculation_run_v2') {
      final declared = payload['event_type'];
      final status = _asMap(payload['calculation'])?['status'];
      if (declared == 'calculation.completed' && status == 'completed') {
        return declared as String;
      }
      if (declared == 'calculation.failed' && status == 'failed') {
        return declared as String;
      }
      return null;
    }
    if (entity == 'calculation_pack' &&
        action == MutationAction.create &&
        payload['record_kind'] == 'calculation_pack_install_v2' &&
        payload['event_type'] == 'calculation_pack.installed') {
      return 'calculation_pack.installed';
    }
    if (entity == 'asset') {
      if (action == MutationAction.create &&
          payload.containsKey('blob_sha256') &&
          payload.containsKey('byte_size')) {
        return 'AssetImported';
      }
      if (action == MutationAction.patch &&
          payload.containsKey('restored_at_utc')) {
        return 'AssetRestored';
      }
      if (action == MutationAction.tombstone) {
        return switch (payload['scope']) {
          'trash' => 'AssetTrashed',
          'purge' => 'AssetPurged',
          _ => null,
        };
      }
      if (action == MutationAction.append &&
          payload.containsKey('physical_bytes_released')) {
        return 'AssetBlobReleased';
      }
      if (action == MutationAction.append &&
          (payload['status'] == 'missing' || payload['status'] == 'mismatch')) {
        return payload.containsKey('deletion_id')
            ? 'AssetPurgeRecoveryRequired'
            : 'AssetIntegrityFailed';
      }
    }
    if (entity == 'asset_folder' &&
        action == MutationAction.create &&
        payload.containsKey('folder_id')) {
      return 'AssetFolderCreated';
    }
    if (entity == 'asset_folder_membership' &&
        action == MutationAction.append &&
        payload.containsKey('folder_id') &&
        payload.containsKey('asset_id')) {
      return 'AssetAddedToFolder';
    }
    if (entity == 'asset_folder_membership' &&
        action == MutationAction.tombstone &&
        payload.containsKey('folder_id') &&
        payload.containsKey('asset_id')) {
      return 'AssetRemovedFromFolder';
    }
    if (entity == 'blob' &&
        action == MutationAction.append &&
        payload.containsKey('physical_bytes_released')) {
      return 'AssetBlobReleased';
    }
    if (entity == 'blob' &&
        action == MutationAction.append &&
        (payload['status'] == 'missing' || payload['status'] == 'mismatch')) {
      return 'AssetIntegrityFailed';
    }
    if (entity == 'remote_target') {
      return switch (action) {
        MutationAction.create => 'sync.target.created',
        MutationAction.patch => 'sync.target.updated',
        MutationAction.tombstone => 'sync.target.removed',
        _ => null,
      };
    }
    if (entity == 'backup_snapshot') {
      return switch (action) {
        MutationAction.create => 'BackupSnapshotCreated',
        MutationAction.patch => 'BackupSnapshotStateChanged',
        MutationAction.append when payload['state'] == 'failed' =>
          'BackupSnapshotFailed',
        _ => null,
      };
    }
    if (entity == 'backup_restore' && action == MutationAction.append) {
      return 'BackupRestoreVerified';
    }
    return null;
  }

  static Map<String, Object?>? _asMap(Object? value) => value is Map
      ? value.map((key, item) => MapEntry(key.toString(), item))
      : null;

  void _createProject(
    WorkspaceTransaction tx,
    String id,
    Map<String, Object?> payload,
    DateTime time,
  ) {
    _ensureAbsent(tx, 'projects', 'project_id', id);
    tx.execute(
      'INSERT INTO projects(project_id,title,note,revision,created_at_utc) VALUES(?,?,?,1,?)',
      [
        id,
        _text(payload, 'title'),
        _optionalText(payload['note']) ?? '',
        time.toIso8601String(),
      ],
    );
  }

  void _updateProject(
    WorkspaceTransaction tx,
    String id,
    Map<String, Object?> payload,
    int? base,
  ) {
    final row = _requireRow(tx, 'projects', 'project_id', id, 'Project');
    final revision = intFromDb(row['revision']);
    _requireRevision(
      tx,
      'project',
      id,
      base ?? _optionalInt(payload['revision']),
      revision,
    );
    final changed = tx.execute(
      'UPDATE projects SET title=?,note=?,revision=revision+1 WHERE project_id=? AND revision=? AND deleted_at_utc IS NULL',
      [
        _text(payload, 'title'),
        _optionalText(payload['note']) ?? '',
        id,
        revision,
      ],
    );
    if (changed != 1)
      throw _ProjectionConflict(
        'REMOTE_REVISION_CONFLICT',
        'Project changed before the remote update could apply.',
      );
  }

  void _createExperiment(
    WorkspaceTransaction tx,
    String id,
    Map<String, Object?> payload,
    DateTime time,
  ) {
    _ensureAbsent(tx, 'experiments', 'experiment_id', id);
    final projectId = _optionalText(payload['project_id']);
    if (projectId != null &&
        tx.query(
          'SELECT 1 FROM projects WHERE project_id=? AND deleted_at_utc IS NULL',
          [projectId],
        ).isEmpty) {
      throw _ProjectionBlocked(
        'REMOTE_PARENT_MISSING',
        'Experiment references a Project that is not present locally.',
      );
    }
    tx.execute(
      'INSERT INTO experiments(experiment_id,project_id,title,note,revision,created_at_utc) VALUES(?,?,?,?,1,?)',
      [
        id,
        projectId,
        _text(payload, 'title'),
        _optionalText(payload['note']) ?? '',
        time.toIso8601String(),
      ],
    );
  }

  void _updateExperiment(
    WorkspaceTransaction tx,
    String id,
    Map<String, Object?> payload,
    int? base,
  ) {
    final row = _requireRow(
      tx,
      'experiments',
      'experiment_id',
      id,
      'Experiment',
    );
    final revision = intFromDb(row['revision']);
    _requireRevision(
      tx,
      'experiment',
      id,
      base ?? _optionalInt(payload['revision']),
      revision,
    );
    final changed = tx.execute(
      'UPDATE experiments SET title=?,note=?,revision=revision+1 WHERE experiment_id=? AND revision=? AND deleted_at_utc IS NULL',
      [
        _text(payload, 'title'),
        _optionalText(payload['note']) ?? '',
        id,
        revision,
      ],
    );
    if (changed != 1)
      throw _ProjectionConflict(
        'REMOTE_REVISION_CONFLICT',
        'Experiment changed before the remote update could apply.',
      );
  }

  void _createGroup(
    WorkspaceTransaction tx,
    String id,
    Map<String, Object?> payload,
  ) {
    _ensureAbsent(tx, 'experimental_groups', 'group_id', id);
    final runId = _text(payload, 'run_id');
    if (tx.query('SELECT 1 FROM experiment_runs WHERE run_id=?', [
      runId,
    ]).isEmpty) {
      throw _ProjectionBlocked(
        'REMOTE_PARENT_MISSING',
        'ExperimentalGroup Run has not arrived yet.',
      );
    }
    tx.execute(
      'INSERT INTO experimental_groups(group_id,run_id,title,conditions_json,revision) VALUES(?,?,?,?,1)',
      [
        id,
        runId,
        _text(payload, 'title'),
        jsonEncode(_object(payload['conditions'], 'conditions')),
      ],
    );
  }

  void _updateGroup(
    WorkspaceTransaction tx,
    String id,
    Map<String, Object?> payload,
    int? base,
  ) {
    final row = _requireRow(
      tx,
      'experimental_groups',
      'group_id',
      id,
      'ExperimentalGroup',
    );
    final revision = intFromDb(row['revision']);
    _requireRevision(
      tx,
      'experimental_group',
      id,
      base ?? _optionalInt(payload['revision']),
      revision,
    );
    final changed = tx.execute(
      'UPDATE experimental_groups SET title=?,conditions_json=?,revision=revision+1 WHERE group_id=? AND revision=?',
      [
        _text(payload, 'title'),
        jsonEncode(_object(payload['conditions'], 'conditions')),
        id,
        revision,
      ],
    );
    if (changed != 1) {
      throw _ProjectionConflict(
        'REMOTE_REVISION_CONFLICT',
        'ExperimentalGroup changed before the remote update could apply.',
      );
    }
  }

  void _saveProtocolDraft(
    WorkspaceTransaction tx,
    String entityId,
    Map<String, Object?> payload,
    DateTime time,
  ) {
    final protocolId = _text(payload, 'protocol_id');
    final version = _text(payload, 'version');
    if (entityId != '$protocolId@$version') {
      throw _ProjectionBlocked(
        'REMOTE_PROTOCOL_ID_INVALID',
        'Protocol event identity does not match its payload.',
      );
    }
    final document = _object(payload['document'], 'document');
    if (document['status'] != 'draft' ||
        document['protocol_id'] != protocolId ||
        document['version'] != version) {
      throw _ProjectionBlocked(
        'REMOTE_PROTOCOL_INVALID',
        'Remote Protocol draft identity or status is invalid.',
      );
    }
    final report = ProtocolDocument.validate(document);
    if (!report.isValid) {
      throw _ProjectionBlocked(
        'REMOTE_PROTOCOL_INVALID',
        'Remote Protocol draft failed schema validation.',
      );
    }
    final digest = ProtocolDocument.contentSha256(document);
    if (digest != _text(payload, 'payload_sha256')) {
      throw _ProjectionBlocked(
        'REMOTE_PROTOCOL_HASH_MISMATCH',
        'Remote Protocol content hash does not match its document.',
      );
    }
    final protocol = tx.query(
      'SELECT protocol_id FROM protocols WHERE protocol_id=?',
      [protocolId],
    );
    if (protocol.isEmpty) {
      tx.execute(
        'INSERT INTO protocols(protocol_id,title,current_version,revision) VALUES(?,?,NULL,1)',
        [protocolId, _text(payload, 'title')],
      );
    }
    final existing = tx.query(
      'SELECT status,approved_at_utc FROM protocol_versions WHERE protocol_id=? AND version=?',
      [protocolId, version],
    );
    if (existing.isNotEmpty &&
        (existing.single['status'] == 'approved' ||
            existing.single['approved_at_utc'] != null)) {
      throw _ProjectionConflict(
        'APPROVED_PROTOCOL_IMMUTABLE',
        'Remote update targets an already approved ProtocolVersion.',
      );
    }
    final validationJson = jsonEncode({
      'errors': report.errors,
      'warnings': report.warnings,
    });
    final provenance = jsonEncode(
      payload['provenance'] is Map
          ? payload['provenance']
          : const <String, Object?>{},
    );
    if (existing.isEmpty) {
      tx.execute(
        '''INSERT INTO protocol_versions(protocol_id,version,payload_json,status,payload_sha256,
             approved_at_utc,created_at_utc,validation_report_json,provenance_json)
           VALUES(?,?,?,'draft',?,NULL,?,?,?)''',
        [
          protocolId,
          version,
          jsonEncode(document),
          digest,
          time.toIso8601String(),
          validationJson,
          provenance,
        ],
      );
    } else {
      tx.execute(
        '''UPDATE protocol_versions SET payload_json=?,status='draft',payload_sha256=?,
             validation_report_json=?,provenance_json=?
           WHERE protocol_id=? AND version=? AND status='draft' AND approved_at_utc IS NULL''',
        [
          jsonEncode(document),
          digest,
          validationJson,
          provenance,
          protocolId,
          version,
        ],
      );
    }
    tx.execute(
      'UPDATE protocols SET title=?,revision=revision+1 WHERE protocol_id=?',
      [_text(payload, 'title'), protocolId],
    );
  }

  void _approveProtocol(
    WorkspaceTransaction tx,
    String entityId,
    Map<String, Object?> payload,
  ) {
    final protocolId = _text(payload, 'protocol_id');
    final version = _text(payload, 'version');
    if (entityId != '$protocolId@$version') {
      throw _ProjectionBlocked(
        'REMOTE_PROTOCOL_ID_INVALID',
        'Protocol approval identity does not match its payload.',
      );
    }
    final approvalRef = _text(payload, 'approval_ref');
    final approvedAt = _dateText(payload, 'approved_at_utc');
    final receipts = tx.query(
      '''SELECT action,subject_type,subject_id,approved_at_utc,expires_at_utc,revoked_at_utc
         FROM approval_receipts WHERE approval_ref=?''',
      [approvalRef],
    );
    if (receipts.isEmpty) {
      throw _ProjectionBlocked(
        'REMOTE_PARENT_MISSING',
        'Protocol approval receipt has not arrived yet.',
      );
    }
    final receipt = receipts.single;
    if (receipt['action'] != 'protocol.approve' ||
        receipt['subject_type'] != 'protocol_version' ||
        receipt['subject_id'] != entityId ||
        receipt['revoked_at_utc'] != null ||
        DateTime.parse(
          receipt['approved_at_utc']! as String,
        ).toUtc().isAfter(DateTime.parse(approvedAt).toUtc()) ||
        (receipt['expires_at_utc'] != null &&
            !DateTime.parse(
              receipt['expires_at_utc']! as String,
            ).toUtc().isAfter(DateTime.parse(approvedAt).toUtc()))) {
      throw _ProjectionBlocked(
        'REMOTE_APPROVAL_SCOPE_INVALID',
        'Protocol approval receipt does not match the event or is expired/revoked.',
      );
    }
    final document = _object(payload['document'], 'document');
    if (document['protocol_id'] != protocolId ||
        document['version'] != version ||
        document['status'] != 'approved' ||
        _object(document['review'], 'review')['approved_by_user'] != true) {
      throw _ProjectionBlocked(
        'REMOTE_PROTOCOL_INVALID',
        'Approved Protocol document has an invalid identity or status.',
      );
    }
    final report = ProtocolDocument.validate(document);
    if (!report.isValid ||
        ProtocolDocument.contentSha256(document) !=
            _text(payload, 'payload_sha256')) {
      throw _ProjectionBlocked(
        'REMOTE_PROTOCOL_HASH_MISMATCH',
        'Approved Protocol is invalid or its content hash mismatches.',
      );
    }
    final rows = tx.query(
      'SELECT status,approved_at_utc FROM protocol_versions WHERE protocol_id=? AND version=?',
      [protocolId, version],
    );
    if (rows.isEmpty)
      throw _ProjectionBlocked(
        'REMOTE_PARENT_MISSING',
        'Approved Protocol draft has not arrived yet.',
      );
    if (rows.single['approved_at_utc'] != null ||
        rows.single['status'] == 'approved') {
      throw _ProjectionConflict(
        'APPROVED_PROTOCOL_IMMUTABLE',
        'ProtocolVersion already has a different approval state.',
      );
    }
    if (rows.single['status'] != 'draft') {
      throw _ProjectionBlocked(
        'REMOTE_PROTOCOL_STATE_INVALID',
        'Only a draft can be approved.',
      );
    }
    tx.execute(
      '''UPDATE protocol_versions SET payload_json=?,status='approved',payload_sha256=?,
           approval_ref=?,approved_at_utc=?,validation_report_json=?
         WHERE protocol_id=? AND version=? AND status='draft' AND approved_at_utc IS NULL''',
      [
        jsonEncode(document),
        _text(payload, 'payload_sha256'),
        approvalRef,
        approvedAt,
        jsonEncode({'errors': <String>[], 'warnings': report.warnings}),
        protocolId,
        version,
      ],
    );
    tx.execute(
      'UPDATE protocols SET current_version=?,revision=revision+1 WHERE protocol_id=?',
      [version, protocolId],
    );
  }

  void _createRun(
    WorkspaceTransaction tx,
    String runId,
    Map<String, Object?> payload,
    DateTime time,
  ) {
    _ensureAbsent(tx, 'experiment_runs', 'run_id', runId);
    final experimentId = _text(payload, 'experiment_id');
    if (tx.query(
      'SELECT 1 FROM experiments WHERE experiment_id=? AND deleted_at_utc IS NULL',
      [experimentId],
    ).isEmpty) {
      throw _ProjectionBlocked(
        'REMOTE_PARENT_MISSING',
        'Run references an Experiment that is not present locally.',
      );
    }
    final parameters = _object(
      payload['parameter_snapshot'],
      'parameter_snapshot',
    );
    final protocolSnapshot = _object(
      payload['protocol_snapshot'],
      'protocol_snapshot',
    );
    final rawInstances = payload['step_instances'];
    final state = _text(payload, 'state');
    if (!const {'draft', 'planned'}.contains(state)) {
      throw _ProjectionBlocked(
        'REMOTE_RUN_STATE_INVALID',
        'New Run has an unsupported initial state.',
      );
    }
    final protocolId = _optionalText(payload['protocol_id']);
    final version = _optionalText(payload['protocol_version']);
    if ((protocolId == null) != (version == null)) {
      throw _ProjectionBlocked(
        'REMOTE_PROTOCOL_VERSION_REQUIRED',
        'Run must identify both Protocol id and version.',
      );
    }
    if (protocolId != null) {
      final protocol = tx.query(
        '''SELECT payload_json,status FROM protocol_versions WHERE protocol_id=? AND version=?''',
        [protocolId, version],
      );
      if (protocol.isEmpty || protocol.single['status'] != 'approved') {
        throw _ProjectionBlocked(
          'REMOTE_PROTOCOL_NOT_APPROVED',
          'Run requires an approved ProtocolVersion already present locally.',
        );
      }
      if (canonicalJson(_objectFromJson(protocol.single['payload_json'])) !=
          canonicalJson(protocolSnapshot)) {
        throw _ProjectionBlocked(
          'REMOTE_PROTOCOL_SNAPSHOT_MISMATCH',
          'Run Protocol snapshot differs from the approved version.',
        );
      }
      ProtocolDocument.requireValidParameterSnapshot(
        protocolSnapshot,
        parameters,
      );
    }
    final instances = _validatedRunStepInstances(
      rawInstances,
      protocolSnapshot: protocolSnapshot,
      protocolBacked: protocolId != null,
    );
    tx.execute(
      '''INSERT INTO experiment_runs(run_id,experiment_id,protocol_id,protocol_version,title,state,revision,
           parameter_snapshot_json,created_at_utc,started_at_utc,finished_at_utc,protocol_snapshot_json,planned_start_utc)
         VALUES(?,?,?,?,?,?,1,?,?,NULL,NULL,?,?)''',
      [
        runId,
        experimentId,
        protocolId,
        version,
        _text(payload, 'title'),
        state,
        jsonEncode(parameters),
        time.toIso8601String(),
        jsonEncode(protocolSnapshot),
        _optionalDateText(payload['planned_start_utc']),
      ],
    );
    if (instances.isEmpty) return;
    final ids = <String>{};
    for (final step in instances) {
      final id = _text(step, 'step_id');
      if (!ids.add(id))
        throw _ProjectionBlocked(
          'REMOTE_RUN_STEPS_INVALID',
          'Run Step ids are duplicated.',
        );
    }
    for (final step in instances) {
      final dependencies = _stringList(
        step['depends_on_step_ids'],
        'depends_on_step_ids',
      );
      if (dependencies.any((id) => !ids.contains(id))) {
        throw _ProjectionBlocked(
          'REMOTE_RUN_STEPS_INVALID',
          'Run Step dependency references an unknown Step.',
        );
      }
      tx.execute(
        '''INSERT INTO step_executions(step_id,run_id,protocol_step_id,kind,title,state,planned_start_utc,
             started_at_utc,due_at_utc,completed_at_utc,expected_seconds,revision,captured_json,instructions,
             parameters_json,human_gate,repeat_index,resource_key,duration_origin,duration_min_seconds,
             duration_max_seconds,planned_end_utc)
           VALUES(?,?,?,?,?, ?,NULL,NULL,NULL,NULL,?,1,'{}',?,?,?,?,?,?,?,?,NULL)''',
        [
          _text(step, 'step_id'),
          runId,
          _optionalText(step['protocol_step_id']),
          _text(step, 'kind'),
          _text(step, 'title'),
          dependencies.isEmpty ? 'ready' : 'pending',
          _optionalInt(step['expected_seconds']),
          _optionalText(step['instructions']) ?? '',
          jsonEncode(
            _object(
              step['parameters'] ?? const <String, Object?>{},
              'parameters',
            ),
          ),
          _boolInt(step['human_gate']),
          _optionalInt(step['repeat_index']) ?? 0,
          _optionalText(step['resource_key']),
          _text(step, 'duration_origin'),
          _optionalInt(step['duration_min_seconds']),
          _optionalInt(step['duration_max_seconds']),
        ],
      );
    }
    for (final step in instances) {
      for (final dependency in _stringList(
        step['depends_on_step_ids'],
        'depends_on_step_ids',
      )) {
        tx.execute(
          'INSERT INTO step_dependencies(step_id,required_step_id) VALUES(?,?)',
          [_text(step, 'step_id'), dependency],
        );
      }
    }
    _assertAcyclic(tx, runId);
  }

  List<Map<String, Object?>> _validatedRunStepInstances(
    Object? rawInstances, {
    required Map<String, Object?> protocolSnapshot,
    required bool protocolBacked,
  }) {
    if (rawInstances is! List) {
      if (protocolBacked) {
        throw _ProjectionBlocked(
          'REMOTE_RUN_STEPS_MISSING',
          'Protocol-backed Run lacks immutable Step instance identities.',
        );
      }
      return const [];
    }
    final instances = rawInstances
        .map((value) => _object(value, 'step_instances[]'))
        .toList(growable: false);
    final allowedFields = const {
      'step_id',
      'protocol_step_id',
      'kind',
      'title',
      'instructions',
      'parameters',
      'human_gate',
      'expected_seconds',
      'duration_origin',
      'duration_min_seconds',
      'duration_max_seconds',
      'repeat_index',
      'resource_key',
      'depends_on_step_ids',
    };
    final ids = <String>{};
    final byProtocolId = <String, Map<String, Object?>>{};
    for (final step in instances) {
      if (step.keys.any((key) => !allowedFields.contains(key))) {
        throw _ProjectionBlocked(
          'REMOTE_RUN_STEPS_INVALID',
          'Run Step contains unsupported fields.',
        );
      }
      final id = _text(step, 'step_id');
      if (!ids.add(id)) {
        throw _ProjectionBlocked(
          'REMOTE_RUN_STEPS_INVALID',
          'Run Step ids are duplicated.',
        );
      }
      final kind = _text(step, 'kind');
      if (!const {
        'action',
        'wait',
        'measure',
        'calculate',
        'image',
        'record',
        'decision',
        'repeat',
        'sample',
        'review',
      }.contains(kind)) {
        throw _ProjectionBlocked(
          'REMOTE_RUN_STEPS_INVALID',
          'Run Step kind is unsupported.',
        );
      }
      _text(step, 'title');
      if (step['human_gate'] is! bool) {
        throw _ProjectionBlocked(
          'REMOTE_RUN_STEPS_INVALID',
          'Run Step human_gate must be boolean.',
        );
      }
      final expected = step['expected_seconds'];
      if (expected != null && (expected is! int || expected < 0)) {
        throw _ProjectionBlocked(
          'REMOTE_RUN_STEPS_INVALID',
          'Run Step duration must be null or a non-negative integer.',
        );
      }
      if (!const {
        'user',
        'sop',
        'historical',
        'ai_estimate',
        'unknown',
      }.contains(step['duration_origin'])) {
        throw _ProjectionBlocked(
          'REMOTE_RUN_STEPS_INVALID',
          'Run Step duration origin is unsupported.',
        );
      }
      _object(step['parameters'] ?? const <String, Object?>{}, 'parameters');
      final dependencies = _stringList(
        step['depends_on_step_ids'],
        'depends_on_step_ids',
      );
      if (dependencies.toSet().length != dependencies.length ||
          dependencies.contains(id)) {
        throw _ProjectionBlocked(
          'REMOTE_RUN_STEPS_INVALID',
          'Run Step dependencies must be unique and cannot include itself.',
        );
      }
      final protocolStepId = _optionalText(step['protocol_step_id']);
      if (protocolBacked && protocolStepId == null) {
        throw _ProjectionBlocked(
          'REMOTE_RUN_STEPS_INVALID',
          'Protocol-backed Run Step lacks its source Protocol step id.',
        );
      }
      if (protocolStepId != null &&
          byProtocolId.putIfAbsent(protocolStepId, () => step) != step) {
        throw _ProjectionBlocked(
          'REMOTE_RUN_STEPS_INVALID',
          'Run maps multiple instances to one Protocol step.',
        );
      }
    }
    for (final step in instances) {
      final dependencies = _stringList(
        step['depends_on_step_ids'],
        'depends_on_step_ids',
      );
      if (dependencies.any((dependency) => !ids.contains(dependency))) {
        throw _ProjectionBlocked(
          'REMOTE_RUN_STEPS_INVALID',
          'Run Step dependency references an unknown Step.',
        );
      }
    }
    if (!protocolBacked) return instances;

    final protocolStepsValue = protocolSnapshot['steps'];
    if (protocolStepsValue is! List ||
        protocolStepsValue.length != instances.length) {
      throw _ProjectionBlocked(
        'REMOTE_RUN_STEPS_INVALID',
        'Protocol-backed Run must contain exactly one instance per Protocol step.',
      );
    }
    final protocolSteps = protocolStepsValue
        .map((value) => _object(value, 'protocol_snapshot.steps[]'))
        .toList(growable: false);
    final protocolIds = <String>{};
    final instanceIdByProtocolId = <String, String>{};
    for (final protocolStep in protocolSteps) {
      final protocolStepId = _text(protocolStep, 'step_id');
      if (!protocolIds.add(protocolStepId)) {
        throw _ProjectionBlocked(
          'REMOTE_PROTOCOL_INVALID',
          'Protocol snapshot contains duplicate step identities.',
        );
      }
      final instance = byProtocolId[protocolStepId];
      if (instance == null) {
        throw _ProjectionBlocked(
          'REMOTE_RUN_STEPS_INVALID',
          'Run omits a Step from its approved Protocol snapshot.',
        );
      }
      instanceIdByProtocolId[protocolStepId] = _text(instance, 'step_id');
    }
    for (final protocolStep in protocolSteps) {
      final protocolStepId = _text(protocolStep, 'step_id');
      final instance = byProtocolId[protocolStepId]!;
      final duration = _object(protocolStep['duration'], 'duration');
      final source = _text(duration, 'source');
      final expectedDurationOrigin = switch (source) {
        'history' => 'historical',
        'ai_suggestion' => 'ai_estimate',
        _ => source,
      };
      final protocolDependencies = _stringList(
        protocolStep['depends_on'],
        'protocol step depends_on',
      );
      final expectedInstanceDependencies = protocolDependencies
          .map((dependency) => instanceIdByProtocolId[dependency])
          .toList(growable: false);
      final parameters = _object(
        protocolStep['params'] ?? const <String, Object?>{},
        'protocol step params',
      );
      if (_text(instance, 'kind') != _text(protocolStep, 'kind') ||
          _text(instance, 'title') != _text(protocolStep, 'title') ||
          (_optionalText(instance['instructions']) ?? '') !=
              (_optionalText(protocolStep['instructions']) ?? '') ||
          canonicalJson(_object(instance['parameters'], 'parameters')) !=
              canonicalJson(parameters) ||
          instance['human_gate'] != protocolStep['human_gate'] ||
          instance['expected_seconds'] != duration['expected_seconds'] ||
          instance['duration_origin'] != expectedDurationOrigin ||
          instance['duration_min_seconds'] != null ||
          instance['duration_max_seconds'] != null ||
          instance['repeat_index'] != 0 ||
          instance['resource_key'] != null ||
          canonicalJson(
                _stringList(
                  instance['depends_on_step_ids'],
                  'depends_on_step_ids',
                ),
              ) !=
              canonicalJson(expectedInstanceDependencies)) {
        throw _ProjectionBlocked(
          'REMOTE_RUN_STEPS_PROTOCOL_MISMATCH',
          'Run Step instance differs from its approved Protocol definition.',
        );
      }
    }
    return instances;
  }

  void _closeRun(
    WorkspaceTransaction tx,
    String eventId,
    String runId,
    Map<String, Object?> payload,
    int? base,
  ) {
    final row = _requireRow(tx, 'experiment_runs', 'run_id', runId, 'Run');
    final revision = intFromDb(row['revision']);
    _requireRevision(tx, 'run', runId, base, revision);
    if (const {'completed', 'failed', 'cancelled'}.contains(row['state'])) {
      throw _ProjectionConflict(
        'REMOTE_RUN_TERMINAL',
        'Run is already terminal.',
      );
    }
    final outcome = _text(payload, 'state');
    if (!const {'completed', 'failed', 'cancelled'}.contains(outcome)) {
      throw _ProjectionBlocked(
        'REMOTE_RUN_STATE_INVALID',
        'Run close outcome is invalid.',
      );
    }
    final active = tx.query(
      "SELECT step_id,state FROM step_executions WHERE run_id=? AND state NOT IN('completed','skipped') ORDER BY step_id",
      [runId],
    );
    if (outcome == 'completed' && active.isNotEmpty) {
      throw _ProjectionBlocked(
        'REMOTE_RUN_INCOMPLETE',
        'A Run cannot complete while Steps remain unfinished.',
      );
    }
    if (outcome != 'completed') {
      final reason = _text(payload, 'reason');
      for (final step in active) {
        final stepId = step['step_id']! as String;
        if (step['state'] == 'failed') continue;
        final wasActive = const {'running', 'waiting'}.contains(step['state']);
        final stepState = wasActive && outcome == 'failed'
            ? 'failed'
            : 'skipped';
        tx.execute(
          'UPDATE step_executions SET state=?,completed_at_utc=?,due_at_utc=NULL,revision=revision+1 WHERE step_id=?',
          [stepState, _dateText(payload, 'finished_at_utc'), stepId],
        );
        tx.execute(
          '''INSERT INTO step_events(event_id,step_id,event_type,event_data_json,occurred_at_utc,recorded_at_utc,command_id)
             VALUES(?,?,?,?,?,?,?)''',
          [
            newUuidV7(
              at: DateTime.parse(_dateText(payload, 'finished_at_utc')),
            ),
            stepId,
            wasActive && outcome == 'failed' ? 'failed' : 'skipped',
            jsonEncode({'run_outcome': outcome, 'reason': reason}),
            _dateText(payload, 'finished_at_utc'),
            _dateText(payload, 'finished_at_utc'),
            eventId,
          ],
        );
      }
    }
    final changed = tx.execute(
      'UPDATE experiment_runs SET state=?,finished_at_utc=?,revision=revision+1 WHERE run_id=? AND revision=?',
      [outcome, _dateText(payload, 'finished_at_utc'), runId, revision],
    );
    if (changed != 1)
      throw _ProjectionConflict(
        'REMOTE_REVISION_CONFLICT',
        'Run changed before the remote close could apply.',
      );
  }

  void _rebuildSchedule(
    WorkspaceTransaction tx,
    String eventId,
    String runId,
    Map<String, Object?> payload,
    int? base,
    DateTime occurredAtUtc,
  ) {
    if (_text(payload, 'run_id') != runId) {
      throw _ProjectionBlocked(
        'REMOTE_SCHEDULE_ID_INVALID',
        'Schedule Run id does not match its event identity.',
      );
    }
    final run = _requireRow(tx, 'experiment_runs', 'run_id', runId, 'Run');
    final revision = intFromDb(run['revision']);
    _requireRevision(tx, 'run', runId, base, revision);
    if (const {'completed', 'failed', 'cancelled'}.contains(run['state'])) {
      throw _ProjectionBlocked(
        'REMOTE_SCHEDULE_RUN_TERMINAL',
        'A terminal Run cannot receive a new schedule.',
      );
    }
    final trace = _object(payload['schedule_trace'], 'schedule_trace');
    final traceId = _text(trace, 'trace_id');
    if (traceId != _text(payload, 'trace_id')) {
      throw _ProjectionBlocked(
        'REMOTE_SCHEDULE_ID_INVALID',
        'Schedule trace id does not match its event payload.',
      );
    }
    final generation = _int(trace, 'generation');
    if (generation != _int(payload, 'generation') || generation < 1) {
      throw _ProjectionBlocked(
        'REMOTE_SCHEDULE_GENERATION_INVALID',
        'Schedule generation is invalid.',
      );
    }
    final input = _object(trace['input'], 'schedule_trace.input');
    final schedule = _object(trace['schedule'], 'schedule_trace.schedule');
    final warnings = _stringList(trace['warnings'], 'schedule_trace.warnings');
    final startAt = _dateText(payload, 'start_at_utc');
    final traceStart = _dateText(input, 'start_at_utc');
    if (_text(input, 'run_id') != runId ||
        _int(input, 'generation') != generation ||
        _text(schedule, 'start_at_utc') != startAt ||
        DateTime.parse(traceStart).toUtc() != DateTime.parse(startAt).toUtc()) {
      throw _ProjectionBlocked(
        'REMOTE_SCHEDULE_INPUT_INVALID',
        'Schedule trace does not match the requested Run and start time.',
      );
    }
    final existingGeneration = intFromDb(
      tx.query(
        'SELECT COALESCE(MAX(generation),0) AS generation FROM schedule_traces WHERE run_id=?',
        [runId],
      ).single['generation'],
    );
    if (generation != existingGeneration + 1) {
      throw _ProjectionConflict(
        'REMOTE_SCHEDULE_GENERATION_CONFLICT',
        'Schedule generation is not the next immutable version.',
      );
    }
    final rows = tx.query(
      'SELECT * FROM step_executions WHERE run_id=? ORDER BY rowid',
      [runId],
    );
    if (_int(input, 'step_count') != rows.length) {
      throw _ProjectionBlocked(
        'REMOTE_SCHEDULE_STEPS_INVALID',
        'Schedule input Step count does not match the Run.',
      );
    }
    final byId = <String, DbRow>{
      for (final row in rows) row['step_id']! as String: row,
    };
    final dependencies = <String, List<String>>{};
    for (final id in byId.keys) {
      dependencies[id] = tx
          .query(
            'SELECT required_step_id FROM step_dependencies WHERE step_id=? ORDER BY required_step_id',
            [id],
          )
          .map((row) => row['required_step_id']! as String)
          .toList(growable: false);
    }
    final order = _topologicalScheduleOrder(dependencies);
    final rawSteps = schedule['steps'];
    if (rawSteps is! List || rawSteps.length != order.length) {
      throw _ProjectionBlocked(
        'REMOTE_SCHEDULE_STEPS_INVALID',
        'Schedule trace must contain every Run Step exactly once.',
      );
    }
    final traceSteps = rawSteps
        .map((value) => _object(value, 'scheduled step'))
        .toList(growable: false);
    final plannedStarts = <String, DateTime?>{};
    final plannedEnds = <String, DateTime?>{};
    final resourceEnds = <String, DateTime?>{};
    final unavailableResources = <String>{};
    final start = DateTime.parse(startAt).toUtc();
    for (var index = 0; index < order.length; index++) {
      final id = order[index];
      final row = byId[id]!;
      final step = traceSteps[index];
      if (_text(step, 'step_id') != id ||
          _optionalText(step['protocol_step_id']) != row['protocol_step_id'] ||
          _text(step, 'title') != row['title'] ||
          _optionalText(step['resource_key']) != row['resource_key'] ||
          _optionalInt(step['expected_seconds']) !=
              (row['expected_seconds'] == null
                  ? null
                  : intFromDb(row['expected_seconds'])) ||
          _text(step, 'duration_origin') != row['duration_origin'] ||
          canonicalJson(
                _stringList(
                  step['dependencies'],
                  'scheduled step dependencies',
                ),
              ) !=
              canonicalJson(dependencies[id])) {
        throw _ProjectionBlocked(
          'REMOTE_SCHEDULE_STEPS_INVALID',
          'Scheduled Step metadata differs from its Run projection.',
        );
      }
      final dependencyIds = dependencies[id]!;
      final terminal = const {
        'completed',
        'skipped',
        'failed',
        'cancelled',
      }.contains(row['state']);
      DateTime? expectedStart;
      if (terminal) {
        // Terminal Step timing is historical state. The sender's schedule
        // trace must carry the same values already stored on this device.
        expectedStart = optionalDateFromDb(row['planned_start_utc']);
      } else if (dependencyIds.isEmpty) {
        expectedStart = start;
      } else if (dependencyIds.every(
        (dependency) => plannedEnds[dependency] != null,
      )) {
        expectedStart = dependencyIds
            .map((dependency) => plannedEnds[dependency]!)
            .reduce((left, right) => left.isAfter(right) ? left : right);
      }
      final resource = row['resource_key'] as String?;
      if (!terminal && resource != null && resource.isNotEmpty) {
        if (unavailableResources.contains(resource)) {
          expectedStart = null;
        } else {
          final resourceEnd = resourceEnds[resource];
          if (resourceEnd != null &&
              (expectedStart == null || resourceEnd.isAfter(expectedStart))) {
            expectedStart = resourceEnd;
          }
        }
      }
      final duration = row['expected_seconds'] == null
          ? null
          : intFromDb(row['expected_seconds']);
      final expectedEnd = terminal
          ? optionalDateFromDb(row['planned_end_utc'])
          : expectedStart == null || duration == null
          ? null
          : expectedStart.add(Duration(seconds: duration));
      final actualStart = _optionalDateText(step['planned_start_utc']);
      final actualEnd = _optionalDateText(step['planned_end_utc']);
      if (!_sameInstant(actualStart, expectedStart) ||
          !_sameInstant(actualEnd, expectedEnd)) {
        throw _ProjectionBlocked(
          'REMOTE_SCHEDULE_RESULT_INVALID',
          'Schedule plan is inconsistent with step durations, dependencies, or shared resources.',
        );
      }
      plannedStarts[id] = expectedStart;
      plannedEnds[id] = expectedEnd;
      if (resource != null && resource.isNotEmpty) {
        if (expectedEnd == null) {
          unavailableResources.add(resource);
        } else {
          final priorEnd = resourceEnds[resource];
          if (priorEnd == null || expectedEnd.isAfter(priorEnd)) {
            resourceEnds[resource] = expectedEnd;
          }
        }
      }
    }
    final createdAt =
        _optionalDateText(trace['created_at_utc']) ??
        occurredAtUtc.toIso8601String();
    if (tx.query(
      'SELECT 1 FROM schedule_traces WHERE trace_id=? OR command_id=?',
      [traceId, eventId],
    ).isNotEmpty) {
      throw _ProjectionConflict(
        'REMOTE_SCHEDULE_TRACE_EXISTS',
        'Schedule trace identity already exists.',
      );
    }
    for (final id in order) {
      final row = byId[id]!;
      if (const {
        'completed',
        'skipped',
        'failed',
        'cancelled',
      }.contains(row['state'])) {
        continue;
      }
      tx.execute(
        'UPDATE step_executions SET planned_start_utc=?,planned_end_utc=? WHERE step_id=?',
        [
          plannedStarts[id]?.toIso8601String(),
          plannedEnds[id]?.toIso8601String(),
          id,
        ],
      );
    }
    tx.execute(
      '''INSERT INTO schedule_traces(trace_id,run_id,generation,input_json,schedule_json,warnings_json,created_at_utc,command_id)
         VALUES(?,?,?,?,?,?,?,?)''',
      [
        traceId,
        runId,
        generation,
        jsonEncode(input),
        jsonEncode(schedule),
        jsonEncode(warnings),
        createdAt,
        eventId,
      ],
    );
    final changed = tx.execute(
      'UPDATE experiment_runs SET planned_start_utc=?,revision=revision+1 WHERE run_id=? AND revision=?',
      [startAt, runId, revision],
    );
    if (changed != 1) {
      throw _ProjectionConflict(
        'REMOTE_REVISION_CONFLICT',
        'Run changed before the remote schedule could apply.',
      );
    }
  }

  static List<String> _topologicalScheduleOrder(
    Map<String, List<String>> dependencies,
  ) {
    final ordered = <String>[];
    final visiting = <String>{};
    final visited = <String>{};
    void visit(String id) {
      if (visiting.contains(id)) {
        throw _ProjectionBlocked(
          'REMOTE_SCHEDULE_DAG_INVALID',
          'Run Steps contain a dependency cycle.',
        );
      }
      if (visited.contains(id)) return;
      visiting.add(id);
      for (final dependency in dependencies[id] ?? const <String>[]) {
        if (!dependencies.containsKey(dependency)) {
          throw _ProjectionBlocked(
            'REMOTE_SCHEDULE_DAG_INVALID',
            'Schedule references a missing prerequisite Step.',
          );
        }
        visit(dependency);
      }
      visiting.remove(id);
      visited.add(id);
      ordered.add(id);
    }

    for (final id in dependencies.keys) {
      visit(id);
    }
    return ordered;
  }

  static bool _sameInstant(String? actual, DateTime? expected) {
    if (actual == null || expected == null)
      return actual == null && expected == null;
    return DateTime.parse(actual).toUtc() == expected.toUtc();
  }

  void _addStep(
    WorkspaceTransaction tx,
    String stepId,
    Map<String, Object?> payload,
  ) {
    _ensureAbsent(tx, 'step_executions', 'step_id', stepId);
    final runId = _text(payload, 'run_id');
    final run = tx.query('SELECT state FROM experiment_runs WHERE run_id=?', [
      runId,
    ]);
    if (run.isEmpty)
      throw _ProjectionBlocked(
        'REMOTE_PARENT_MISSING',
        'Ad hoc Step Run is not present locally.',
      );
    if (const {
      'completed',
      'failed',
      'cancelled',
    }.contains(run.single['state'])) {
      throw _ProjectionBlocked(
        'REMOTE_RUN_TERMINAL',
        'A terminal Run cannot accept an ad hoc Step.',
      );
    }
    final dependencies = _stringList(
      payload['depends_on_step_ids'],
      'depends_on_step_ids',
    );
    for (final dependency in dependencies) {
      if (tx.query(
        'SELECT 1 FROM step_executions WHERE step_id=? AND run_id=?',
        [dependency, runId],
      ).isEmpty) {
        throw _ProjectionBlocked(
          'REMOTE_PARENT_MISSING',
          'Ad hoc Step dependency has not arrived in this Run.',
        );
      }
    }
    tx.execute(
      '''INSERT INTO step_executions(step_id,run_id,protocol_step_id,kind,title,state,planned_start_utc,
           started_at_utc,due_at_utc,completed_at_utc,expected_seconds,revision,captured_json,instructions,
           parameters_json,human_gate,repeat_index,resource_key,duration_origin,duration_min_seconds,
           duration_max_seconds,planned_end_utc)
           VALUES(?,?,NULL,?,?,?, ?,NULL,NULL,NULL,?,1,'{}',?,?,?,?,?,?,?,?,NULL)''',
      [
        stepId,
        runId,
        _text(payload, 'kind'),
        _text(payload, 'title'),
        dependencies.isEmpty ? 'ready' : 'pending',
        _optionalDateText(payload['planned_start_utc']),
        _optionalInt(payload['expected_seconds']),
        _optionalText(payload['instructions']) ?? '',
        jsonEncode(_object(payload['parameters'], 'parameters')),
        _boolInt(payload['human_gate']),
        0,
        _optionalText(payload['resource_key']),
        _text(payload, 'duration_origin'),
        _optionalInt(payload['duration_min_seconds']),
        _optionalInt(payload['duration_max_seconds']),
      ],
    );
    for (final dependency in dependencies) {
      tx.execute(
        'INSERT INTO step_dependencies(step_id,required_step_id) VALUES(?,?)',
        [stepId, dependency],
      );
    }
    if (run.single['state'] == 'draft') {
      tx.execute(
        "UPDATE experiment_runs SET state='planned',revision=revision+1 WHERE run_id=? AND state='draft'",
        [runId],
      );
    }
    _assertAcyclic(tx, runId);
  }

  void _startStep(
    WorkspaceTransaction tx,
    String eventId,
    String stepId,
    Map<String, Object?> payload,
    int? base,
    DateTime time,
  ) {
    final row = _requireRow(tx, 'step_executions', 'step_id', stepId, 'Step');
    final revision = intFromDb(row['revision']);
    _requireRevision(tx, 'step', stepId, base, revision);
    if (!const {'ready', 'pending'}.contains(row['state'])) {
      throw _ProjectionConflict(
        'REMOTE_STEP_STATE_CONFLICT',
        'Step is not ready to start on this device.',
      );
    }
    final blockers = tx.query(
      "SELECT 1 FROM step_dependencies d JOIN step_executions p ON p.step_id=d.required_step_id WHERE d.step_id=? AND p.state NOT IN('completed','skipped') LIMIT 1",
      [stepId],
    );
    if (blockers.isNotEmpty)
      throw _ProjectionBlocked(
        'REMOTE_STEP_DEPENDENCY_BLOCKED',
        'A prerequisite Step has not completed.',
      );
    final start = _dateText(payload, 'started_at_utc');
    final due = _optionalDateText(payload['due_at_utc']);
    final state = row['kind'] == 'wait' ? 'waiting' : 'running';
    tx.execute(
      'UPDATE step_executions SET state=?,started_at_utc=?,due_at_utc=?,revision=revision+1 WHERE step_id=? AND revision=?',
      [state, start, due, stepId, revision],
    );
    tx.execute(
      "UPDATE experiment_runs SET state='running',started_at_utc=COALESCE(started_at_utc,?),revision=revision+1 WHERE run_id=? AND state IN('draft','planned','paused')",
      [start, row['run_id']],
    );
    _insertStepEvent(tx, eventId, stepId, 'started', {'due_at_utc': due}, time);
  }

  void _completeStep(
    WorkspaceTransaction tx,
    String eventId,
    String stepId,
    Map<String, Object?> payload,
    int? base,
    DateTime time,
  ) {
    final row = _requireRow(tx, 'step_executions', 'step_id', stepId, 'Step');
    final revision = intFromDb(row['revision']);
    _requireRevision(tx, 'step', stepId, base, revision);
    final state = row['state'];
    if (state != 'running' && state != 'waiting') {
      throw _ProjectionConflict(
        'REMOTE_STEP_STATE_CONFLICT',
        'Step is not in a completable state.',
      );
    }
    final completedAt = _dateText(payload, 'completed_at_utc');
    final due = optionalDateFromDb(row['due_at_utc']);
    if (state == 'waiting' &&
        due != null &&
        DateTime.parse(completedAt).toUtc().isBefore(due)) {
      throw _ProjectionBlocked(
        'REMOTE_WAIT_STEP_EARLY',
        'A timed wait completed before its due time.',
      );
    }
    final captured = _object(payload['captured'], 'captured');
    _validateRequiredCaptures(tx, row, captured);
    tx.execute(
      "UPDATE step_executions SET state='completed',completed_at_utc=?,captured_json=?,due_at_utc=NULL,revision=revision+1 WHERE step_id=? AND revision=?",
      [completedAt, jsonEncode(captured), stepId, revision],
    );
    tx.execute(
      '''UPDATE step_executions SET state='ready',revision=revision+1 WHERE run_id=? AND state='pending'
           AND NOT EXISTS(SELECT 1 FROM step_dependencies d JOIN step_executions p ON p.step_id=d.required_step_id
             WHERE d.step_id=step_executions.step_id AND p.state NOT IN('completed','skipped'))''',
      [row['run_id']],
    );
    final active = tx.query(
      "SELECT COUNT(*) AS count FROM step_executions WHERE run_id=? AND state NOT IN('completed','skipped')",
      [row['run_id']],
    );
    if (intFromDb(active.single['count']) == 0) {
      tx.execute(
        "UPDATE experiment_runs SET state='completed',finished_at_utc=?,revision=revision+1 WHERE run_id=?",
        [completedAt, row['run_id']],
      );
    }
    _insertStepEvent(tx, eventId, stepId, 'completed', {
      'captured': captured,
    }, time);
  }

  void _createSample(
    WorkspaceTransaction tx,
    String eventId,
    String id,
    Map<String, Object?> payload,
    DateTime time,
  ) {
    _ensureAbsent(tx, 'samples', 'sample_id', id);
    final parentId = _optionalText(payload['parent_sample_id']);
    if (parentId != null &&
        tx.query(
          'SELECT 1 FROM samples WHERE sample_id=? AND deleted_at_utc IS NULL',
          [parentId],
        ).isEmpty) {
      throw _ProjectionBlocked(
        'REMOTE_PARENT_MISSING',
        'Sample parent has not arrived yet.',
      );
    }
    tx.execute(
      'INSERT INTO samples(sample_id,name,parent_sample_id,properties_json,created_at_utc,revision) VALUES(?,?,?,?,?,1)',
      [
        id,
        _text(payload, 'name'),
        parentId,
        jsonEncode(_object(payload['properties'], 'properties')),
        time.toIso8601String(),
      ],
    );
    if (parentId != null) {
      tx.execute(
        "INSERT INTO sample_edges(edge_id,parent_sample_id,child_sample_id,relationship_kind,created_at_utc,command_id) VALUES(?,?,?,'derived_from',?,?)",
        [newUuidV7(at: time), parentId, id, time.toIso8601String(), eventId],
      );
    }
    final runId = _optionalText(payload['run_id']);
    final groupId = _optionalText(payload['group_id']);
    if (runId != null)
      _attachSample(tx, {
        'sample_id': id,
        'run_id': runId,
        'group_id': groupId,
      });
  }

  void _attachSample(WorkspaceTransaction tx, Map<String, Object?> payload) {
    final sampleId = _text(payload, 'sample_id');
    final runId = _text(payload, 'run_id');
    final groupId = _optionalText(payload['group_id']);
    if (tx.query(
          'SELECT 1 FROM samples WHERE sample_id=? AND deleted_at_utc IS NULL',
          [sampleId],
        ).isEmpty ||
        tx.query('SELECT 1 FROM experiment_runs WHERE run_id=?', [
          runId,
        ]).isEmpty) {
      throw _ProjectionBlocked(
        'REMOTE_PARENT_MISSING',
        'Sample or Run has not arrived yet.',
      );
    }
    if (groupId != null &&
        tx.query(
          'SELECT 1 FROM experimental_groups WHERE group_id=? AND run_id=?',
          [groupId, runId],
        ).isEmpty) {
      throw _ProjectionBlocked(
        'REMOTE_PARENT_MISSING',
        'ExperimentalGroup has not arrived in the Run.',
      );
    }
    final existing = tx.query(
      'SELECT group_id FROM run_samples WHERE run_id=? AND sample_id=?',
      [runId, sampleId],
    );
    if (existing.isNotEmpty) {
      if (existing.single['group_id'] == groupId) return;
      throw _ProjectionConflict(
        'REMOTE_SAMPLE_GROUP_CONFLICT',
        'Sample is already assigned to another group.',
      );
    }
    tx.execute(
      'INSERT INTO run_samples(run_id,sample_id,group_id) VALUES(?,?,?)',
      [runId, sampleId, groupId],
    );
  }

  void _recordTreatment(
    WorkspaceTransaction tx,
    String id,
    Map<String, Object?> payload,
    DateTime time,
    String eventId,
  ) {
    _ensureAbsent(tx, 'treatments', 'treatment_id', id);
    final sampleId = _text(payload, 'sample_id');
    final runId = _text(payload, 'run_id');
    if (tx.query('SELECT 1 FROM run_samples WHERE run_id=? AND sample_id=?', [
      runId,
      sampleId,
    ]).isEmpty) {
      throw _ProjectionBlocked(
        'REMOTE_PARENT_MISSING',
        'Treatment Sample has not been assigned to this Run.',
      );
    }
    final correctedFrom = _optionalText(payload['corrected_from']);
    final reason = _optionalText(payload['correction_reason']);
    if (correctedFrom != null) {
      final previous = tx.query(
        'SELECT sample_id,run_id FROM treatments WHERE treatment_id=?',
        [correctedFrom],
      );
      if (previous.isEmpty ||
          previous.single['sample_id'] != sampleId ||
          previous.single['run_id'] != runId) {
        throw _ProjectionBlocked(
          'REMOTE_TREATMENT_CORRECTION_INVALID',
          'Treatment correction parent is missing or out of scope.',
        );
      }
      if (reason == null || reason.trim().isEmpty) {
        throw _ProjectionBlocked(
          'REMOTE_TREATMENT_CORRECTION_INVALID',
          'Treatment correction needs a reason.',
        );
      }
    }
    tx.execute(
      '''INSERT INTO treatments(treatment_id,sample_id,run_id,conditions_json,applied_at_utc,corrected_from,recorded_at_utc,correction_reason)
         VALUES(?,?,?,?,?,?,?,?)''',
      [
        id,
        sampleId,
        runId,
        jsonEncode(_object(payload['conditions'], 'conditions')),
        _optionalDateText(payload['applied_at_utc']),
        correctedFrom,
        time.toIso8601String(),
        reason,
      ],
    );
    if (correctedFrom != null) {
      tx.execute(
        'INSERT INTO treatment_corrections(correction_id,treatment_id,replacement_treatment_id,reason,created_at_utc,command_id) VALUES(?,?,?,?,?,?)',
        [
          newUuidV7(at: time),
          correctedFrom,
          id,
          reason,
          time.toIso8601String(),
          eventId,
        ],
      );
    }
  }

  void _recordMeasurement(
    WorkspaceTransaction tx,
    String eventId,
    String sourceDeviceId,
    List<String> assetShaRefs,
    String id,
    Map<String, Object?> payload,
    DateTime time,
  ) {
    if (payload['remote_source_event_id'] != null) {
      _applyReviewedExternalMeasurement(tx, assetShaRefs, id, payload);
      return;
    }
    final calculationId = _optionalText(payload['calculation_id']);
    if (calculationId != null &&
        tx.query(
          'SELECT 1 FROM calculation_runs WHERE calculation_id=? AND status=\'completed\'',
          [calculationId],
        ).isEmpty) {
      if (tx.query(
        'SELECT 1 FROM remote_calculation_run_imports WHERE calculation_id=?',
        [calculationId],
      ).isEmpty) {
        throw _ProjectionBlocked(
          'REMOTE_PARENT_MISSING',
          'The remote CalculationRun has not arrived yet.',
        );
      }
      _quarantineRemoteMeasurement(
        tx,
        eventId,
        sourceDeviceId,
        assetShaRefs,
        'measurement.recorded',
        id,
        payload,
        time,
      );
      return;
    }
    _ensureAbsent(tx, 'measurements', 'measurement_id', id);
    final runId = _text(payload, 'run_id');
    final sampleId = _optionalText(payload['sample_id']);
    final stepId = _optionalText(payload['step_id']);
    if (tx.query('SELECT 1 FROM experiment_runs WHERE run_id=?', [
      runId,
    ]).isEmpty) {
      throw _ProjectionBlocked(
        'REMOTE_PARENT_MISSING',
        'Measurement Run has not arrived yet.',
      );
    }
    if (stepId != null &&
        tx.query('SELECT 1 FROM step_executions WHERE step_id=? AND run_id=?', [
          stepId,
          runId,
        ]).isEmpty) {
      throw _ProjectionBlocked(
        'REMOTE_PARENT_MISSING',
        'Measurement Step has not arrived in its Run.',
      );
    }
    if (sampleId != null &&
        tx.query('SELECT 1 FROM run_samples WHERE run_id=? AND sample_id=?', [
          runId,
          sampleId,
        ]).isEmpty) {
      throw _ProjectionBlocked(
        'REMOTE_PARENT_MISSING',
        'Measurement Sample has not arrived in its Run.',
      );
    }
    final rawAssetId = _optionalText(payload['raw_asset_id']);
    if (rawAssetId != null &&
        tx.query(
          "SELECT 1 FROM assets a JOIN blob_objects b ON b.sha256=a.blob_sha256 WHERE a.asset_id=? AND b.state='committed'",
          [rawAssetId],
        ).isEmpty) {
      throw _ProjectionBlocked(
        'REMOTE_PARENT_MISSING',
        'Measurement raw Asset has not been received and verified.',
      );
    }
    final state = _text(payload, 'state');
    if (!const {'draft_ai', 'recorded', 'user_confirmed'}.contains(state)) {
      throw _ProjectionBlocked(
        'REMOTE_MEASUREMENT_STATE_INVALID',
        'Measurement initial state is unsupported.',
      );
    }
    if (calculationId != null) {
      requireCalculationOutputForMeasurement(
        tx: tx,
        calculationId: calculationId,
        runId: runId,
        stepId: stepId,
        sampleId: sampleId,
        analyte: _text(payload, 'analyte'),
        valueText: _text(payload, 'value_text'),
        unit: _optionalText(payload['unit']),
        rawAssetId: rawAssetId,
      );
    }
    tx.execute(
      '''INSERT INTO measurements(measurement_id,run_id,step_id,sample_id,analyte,value_text,unit,raw_asset_id,state,
           superseded_by,created_at_utc,source_method,source_ref,confirmed_at_utc,confirmed_by,revision,calculation_id)
         VALUES(?,?,?,?,?,?,?,?,?,NULL,?,?,?,?,?,1,?)''',
      [
        id,
        runId,
        stepId,
        sampleId,
        _text(payload, 'analyte'),
        _text(payload, 'value_text'),
        _optionalText(payload['unit']),
        rawAssetId,
        state,
        time.toIso8601String(),
        _optionalText(payload['source_method']),
        _optionalText(payload['source_ref']),
        state == 'user_confirmed' ? time.toIso8601String() : null,
        state == 'user_confirmed' ? 'remote_user' : null,
        calculationId,
      ],
    );
  }

  void _quarantineRemoteMeasurement(
    WorkspaceTransaction tx,
    String eventId,
    String sourceDeviceId,
    List<String> assetShaRefs,
    String eventType,
    String entityId,
    Map<String, Object?> payload,
    DateTime time,
  ) {
    final calculationId = _text(payload, 'calculation_id');
    final runId = _text(payload, 'run_id');
    final stepId = _optionalText(payload['step_id']);
    final sampleId = _optionalText(payload['sample_id']);
    final analyte = _text(payload, 'analyte');
    final valueText = _text(payload, 'value_text');
    final unit = _optionalText(payload['unit']);
    final rawAssetId = _optionalText(payload['raw_asset_id']);
    requireRemoteCalculationOutputForMeasurement(
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
    String remoteMeasurementId;
    String? originalRemoteMeasurementId;
    if (eventType == 'measurement.recorded') {
      remoteMeasurementId = entityId;
      if (!const {
        'draft_ai',
        'recorded',
        'user_confirmed',
      }.contains(payload['state'])) {
        throw _ProjectionBlocked(
          'REMOTE_MEASUREMENT_STATE_INVALID',
          'Measurement initial state is unsupported.',
        );
      }
    } else {
      remoteMeasurementId = _text(payload, 'replacement_measurement_id');
      originalRemoteMeasurementId = _text(payload, 'supersedes_measurement_id');
      final original = tx.query(
        'SELECT 1 FROM measurements WHERE measurement_id=? OR remote_measurement_id=? LIMIT 1',
        [originalRemoteMeasurementId, originalRemoteMeasurementId],
      );
      final importedOriginal = tx.query(
        'SELECT 1 FROM remote_measurement_imports WHERE remote_measurement_id=? LIMIT 1',
        [originalRemoteMeasurementId],
      );
      if (original.isEmpty && importedOriginal.isEmpty) {
        throw _ProjectionBlocked(
          'REMOTE_PARENT_MISSING',
          'Corrected Measurement has not arrived yet.',
        );
      }
      if (_optionalText(payload['correction_reason']) == null) {
        throw _ProjectionBlocked(
          'REMOTE_MEASUREMENT_CORRECTION_INVALID',
          'Measurement correction needs a reason.',
        );
      }
    }
    if (tx.query('SELECT 1 FROM sync_remote_events WHERE event_id=?', [
      eventId,
    ]).isEmpty) {
      throw _ProjectionBlocked(
        'REMOTE_EVENT_MISSING',
        'Measurement source event is not retained in the sync inbox.',
      );
    }
    final previous = tx.query(
      'SELECT * FROM remote_measurement_imports WHERE source_event_id=?',
      [eventId],
    );
    final payloadJson = canonicalJson(payload);
    final refsJson = canonicalJson(assetShaRefs.toList()..sort());
    if (previous.isNotEmpty) {
      final row = previous.single;
      if (row['payload_json'] != payloadJson ||
          row['calculation_id'] != calculationId ||
          row['calculation_trace_sha256'] !=
              tx.query(
                'SELECT trace_sha256 FROM remote_calculation_run_imports WHERE calculation_id=?',
                [calculationId],
              ).single['trace_sha256']) {
        throw _ProjectionBlocked(
          'REMOTE_MEASUREMENT_REPLAY_MISMATCH',
          'Remote Measurement source event changed after import.',
        );
      }
      return;
    }
    final traceHash =
        tx.query(
              'SELECT trace_sha256 FROM remote_calculation_run_imports WHERE calculation_id=?',
              [calculationId],
            ).single['trace_sha256']!
            as String;
    tx.execute(
      '''INSERT INTO remote_measurement_imports
         (source_event_id,remote_measurement_id,source_event_type,original_remote_measurement_id,
          source_device_id,run_id,step_id,sample_id,analyte,value_text,unit,raw_asset_id,
          calculation_id,calculation_trace_sha256,payload_json,asset_sha_refs_json,imported_at_utc)
         VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)''',
      [
        eventId,
        remoteMeasurementId,
        eventType,
        originalRemoteMeasurementId,
        sourceDeviceId,
        runId,
        stepId,
        sampleId,
        analyte,
        valueText,
        unit,
        rawAssetId,
        calculationId,
        traceHash,
        payloadJson,
        refsJson,
        time.toIso8601String(),
      ],
    );
  }

  void _applyReviewedExternalMeasurement(
    WorkspaceTransaction tx,
    List<String> assetShaRefs,
    String measurementId,
    Map<String, Object?> payload,
  ) {
    final sourceEventId = _text(payload, 'remote_source_event_id');
    final source = _requireRemoteMeasurementImport(tx, sourceEventId, payload);
    if (source['source_event_type'] != 'measurement.recorded' ||
        _text(payload, 'measurement_id') != measurementId ||
        _text(payload, 'state') != 'user_confirmed') {
      throw _ProjectionBlocked(
        'REMOTE_MEASUREMENT_SOURCE_TYPE_MISMATCH',
        'Reviewed Measurement acknowledgement does not match its source event.',
      );
    }
    final receivedRefs = assetShaRefs.toList()..sort();
    if (canonicalJson(receivedRefs) != source['asset_sha_refs_json']) {
      throw _ProjectionBlocked(
        'REMOTE_MEASUREMENT_ASSET_REFS_MISMATCH',
        'Reviewed Measurement event changed its immutable Asset references.',
      );
    }
    // This event records another device's review decision. It is an
    // acknowledgement only: each receiving device must review and import the
    // immutable source event with its own ApprovalRef.
  }

  DbRow _requireRemoteMeasurementImport(
    WorkspaceTransaction tx,
    String sourceEventId,
    Map<String, Object?> payload,
  ) {
    final rows = tx.query(
      'SELECT * FROM remote_measurement_imports WHERE source_event_id=?',
      [sourceEventId],
    );
    if (rows.isEmpty)
      throw _ProjectionBlocked(
        'REMOTE_PARENT_MISSING',
        'Remote Measurement review source has not arrived.',
      );
    final row = rows.single;
    final expectedMeasurementId = _text(payload, 'remote_measurement_id');
    final calculationId = _text(payload, 'remote_calculation_id');
    if (row['remote_measurement_id'] != expectedMeasurementId ||
        row['calculation_id'] != calculationId ||
        row['calculation_trace_sha256'] !=
            payload['remote_calculation_trace_sha256'] ||
        row['run_id'] != payload['run_id'] ||
        row['step_id'] != payload['step_id'] ||
        row['sample_id'] != payload['sample_id'] ||
        row['analyte'] != payload['analyte'] ||
        row['value_text'] != payload['value_text'] ||
        row['unit'] != payload['unit'] ||
        row['raw_asset_id'] != payload['raw_asset_id']) {
      throw _ProjectionBlocked(
        'REMOTE_MEASUREMENT_BINDING_MISMATCH',
        'Reviewed Measurement does not match its immutable source event.',
      );
    }
    if (row['source_event_type'] == 'measurement.corrected' &&
        row['original_remote_measurement_id'] !=
            payload['supersedes_measurement_id']) {
      throw _ProjectionBlocked(
        'REMOTE_MEASUREMENT_CORRECTION_SCOPE',
        'Reviewed correction does not identify its immutable original Measurement.',
      );
    }
    final key = requireRemoteCalculationOutputForMeasurement(
      tx: tx,
      calculationId: calculationId,
      runId: _text(payload, 'run_id'),
      stepId: _optionalText(payload['step_id']),
      sampleId: _optionalText(payload['sample_id']),
      analyte: _text(payload, 'analyte'),
      valueText: _text(payload, 'value_text'),
      unit: _optionalText(payload['unit']),
      rawAssetId: _optionalText(payload['raw_asset_id']),
    );
    if (key != payload['remote_calculation_output_key'] ||
        row['calculation_trace_sha256'] !=
            tx.query(
              'SELECT trace_sha256 FROM remote_calculation_run_imports WHERE calculation_id=?',
              [calculationId],
            ).single['trace_sha256']) {
      throw _ProjectionBlocked(
        'REMOTE_MEASUREMENT_TRACE_MISMATCH',
        'Reviewed Measurement trace hash or output key is invalid.',
      );
    }
    return row;
  }

  void _insertExternalMeasurementReview(
    WorkspaceTransaction tx,
    String sourceEventId,
    String reviewerDeviceId,
    String action,
    String? approvalRef,
    String? localMeasurementId,
    String? reason,
    String commandId,
    DateTime time,
  ) {
    final previous = tx.query(
      'SELECT action,approval_ref,local_measurement_id,reason FROM remote_measurement_reviews WHERE source_event_id=? AND reviewer_device_id=?',
      [sourceEventId, reviewerDeviceId],
    );
    if (previous.isNotEmpty) {
      final row = previous.single;
      if (row['action'] != action ||
          row['approval_ref'] != approvalRef ||
          row['local_measurement_id'] != localMeasurementId ||
          row['reason'] != reason) {
        throw _ProjectionConflict(
          'REMOTE_MEASUREMENT_REVIEW_EXISTS',
          'This device has already recorded a different review decision.',
        );
      }
      return;
    }
    tx.execute(
      '''INSERT INTO remote_measurement_reviews
         (review_id,source_event_id,reviewer_device_id,action,approval_ref,
          local_measurement_id,reason,command_id,created_at_utc)
         VALUES(?,?,?,?,?,?,?,?,?)''',
      [
        newUuidV7(at: time),
        sourceEventId,
        reviewerDeviceId,
        action,
        approvalRef,
        localMeasurementId,
        reason,
        commandId,
        time.toIso8601String(),
      ],
    );
  }

  void _recordExternalMeasurementReview(
    WorkspaceTransaction tx,
    String eventId,
    String reviewerDeviceId,
    Map<String, Object?> payload,
    DateTime time,
  ) {
    if (_text(payload, 'record_kind') != 'remote_measurement_review_v1' ||
        _text(payload, 'decision') != 'rejected') {
      throw _ProjectionBlocked(
        'REMOTE_MEASUREMENT_REVIEW_INVALID',
        'Only explicit remote Measurement rejections can sync as review events.',
      );
    }
    final sourceEventId = _text(payload, 'source_event_id');
    if (tx.query(
      'SELECT 1 FROM remote_measurement_imports WHERE source_event_id=?',
      [sourceEventId],
    ).isEmpty) {
      throw _ProjectionBlocked(
        'REMOTE_PARENT_MISSING',
        'Remote Measurement review source has not arrived.',
      );
    }
    final reason = normalizedText(_text(payload, 'reason'), 'reason');
    _insertExternalMeasurementReview(
      tx,
      sourceEventId,
      reviewerDeviceId,
      'rejected',
      null,
      null,
      reason,
      eventId,
      time,
    );
  }

  void _confirmMeasurement(
    WorkspaceTransaction tx,
    String id,
    Map<String, Object?> payload,
    int? base,
  ) {
    final row = _requireRow(
      tx,
      'measurements',
      'measurement_id',
      id,
      'Measurement',
    );
    final revision = intFromDb(row['revision']);
    _requireRevision(tx, 'measurement', id, base, revision);
    if (_text(payload, 'to_state') != 'user_confirmed' ||
        !const {'draft_ai', 'recorded'}.contains(row['state'])) {
      throw _ProjectionConflict(
        'REMOTE_MEASUREMENT_STATE_CONFLICT',
        'Measurement cannot be confirmed from its current state.',
      );
    }
    final confirmedAt = _dateText(payload, 'confirmed_at_utc');
    tx.execute(
      "UPDATE measurements SET state='user_confirmed',confirmed_at_utc=?,confirmed_by='remote_user',revision=revision+1 WHERE measurement_id=? AND revision=?",
      [confirmedAt, id, revision],
    );
  }

  void _correctMeasurement(
    WorkspaceTransaction tx,
    String eventId,
    String sourceDeviceId,
    List<String> assetShaRefs,
    String originalId,
    Map<String, Object?> payload,
    DateTime time,
    int? base,
  ) {
    if (payload['remote_source_event_id'] != null) {
      _applyReviewedExternalCorrection(tx, assetShaRefs, originalId, payload);
      return;
    }
    if (_text(payload, 'supersedes_measurement_id') != originalId) {
      throw _ProjectionBlocked(
        'REMOTE_MEASUREMENT_CORRECTION_SCOPE',
        'Measurement correction identity does not match its event.',
      );
    }
    final calculationId = _optionalText(payload['calculation_id']);
    if (calculationId != null &&
        tx.query(
          'SELECT 1 FROM calculation_runs WHERE calculation_id=? AND status=\'completed\'',
          [calculationId],
        ).isEmpty) {
      if (tx.query(
        'SELECT 1 FROM remote_calculation_run_imports WHERE calculation_id=?',
        [calculationId],
      ).isEmpty) {
        throw _ProjectionBlocked(
          'REMOTE_PARENT_MISSING',
          'The remote CalculationRun has not arrived yet.',
        );
      }
      _quarantineRemoteMeasurement(
        tx,
        eventId,
        sourceDeviceId,
        assetShaRefs,
        'measurement.corrected',
        originalId,
        payload,
        time,
      );
      return;
    }
    final id = _text(payload, 'replacement_measurement_id');
    final original = _requireRow(
      tx,
      'measurements',
      'measurement_id',
      originalId,
      'Measurement',
    );
    final revision = intFromDb(original['revision']);
    _requireRevision(tx, 'measurement', originalId, base, revision);
    if (original['superseded_by'] != null ||
        original['state'] == 'superseded') {
      throw _ProjectionConflict(
        'REMOTE_MEASUREMENT_ALREADY_SUPERSEDED',
        'Measurement has already been corrected.',
      );
    }
    _ensureAbsent(tx, 'measurements', 'measurement_id', id);
    if (original['run_id'] != payload['run_id'] ||
        original['step_id'] != payload['step_id'] ||
        original['sample_id'] != payload['sample_id']) {
      throw _ProjectionBlocked(
        'REMOTE_MEASUREMENT_CORRECTION_SCOPE',
        'Measurement correction must retain its Run and Sample.',
      );
    }
    final reason = _text(payload, 'correction_reason');
    final createdAt = _dateText(payload, 'created_at_utc');
    final rawAssetId = _optionalText(payload['raw_asset_id']);
    if (rawAssetId != null &&
        tx.query(
          "SELECT 1 FROM assets a JOIN blob_objects b ON b.sha256=a.blob_sha256 WHERE a.asset_id=? AND a.deleted_at_utc IS NULL AND b.state='committed'",
          [rawAssetId],
        ).isEmpty) {
      throw _ProjectionBlocked(
        'REMOTE_PARENT_MISSING',
        'Measurement correction raw Asset is not available locally.',
      );
    }
    if (calculationId != null) {
      requireCalculationOutputForMeasurement(
        tx: tx,
        calculationId: calculationId,
        runId: _text(payload, 'run_id'),
        stepId: _optionalText(payload['step_id']),
        sampleId: _optionalText(payload['sample_id']),
        analyte: _text(payload, 'analyte'),
        valueText: _text(payload, 'value_text'),
        unit: _optionalText(payload['unit']),
        rawAssetId: rawAssetId,
      );
    }
    tx.execute(
      '''INSERT INTO measurements(measurement_id,run_id,step_id,sample_id,analyte,value_text,unit,raw_asset_id,state,
           superseded_by,created_at_utc,source_method,source_ref,confirmed_at_utc,confirmed_by,revision,calculation_id)
         VALUES(?,?,?,?,?,?,?,?,'recorded',NULL,?,'manual_correction',?,NULL,NULL,1,?)''',
      [
        id,
        original['run_id'],
        original['step_id'],
        original['sample_id'],
        _text(payload, 'analyte'),
        _text(payload, 'value_text'),
        _optionalText(payload['unit']),
        rawAssetId,
        createdAt,
        reason,
        calculationId,
      ],
    );
    tx.execute(
      '''INSERT INTO measurement_corrections
         (correction_id,measurement_id,replacement_measurement_id,reason,created_at_utc,command_id)
         VALUES(?,?,?,?,?,?)''',
      [newUuidV7(at: time), originalId, id, reason, createdAt, eventId],
    );
    tx.execute(
      "UPDATE measurements SET state='superseded',superseded_by=?,revision=revision+1 WHERE measurement_id=? AND revision=?",
      [id, originalId, revision],
    );
  }

  void _applyReviewedExternalCorrection(
    WorkspaceTransaction tx,
    List<String> assetShaRefs,
    String originalId,
    Map<String, Object?> payload,
  ) {
    if (_text(payload, 'supersedes_measurement_id') != originalId) {
      throw _ProjectionBlocked(
        'REMOTE_MEASUREMENT_CORRECTION_SCOPE',
        'Measurement correction identity does not match its event.',
      );
    }
    final sourceEventId = _text(payload, 'remote_source_event_id');
    final source = _requireRemoteMeasurementImport(tx, sourceEventId, payload);
    if (source['source_event_type'] != 'measurement.corrected' ||
        source['original_remote_measurement_id'] != originalId ||
        _text(payload, 'replacement_measurement_id') !=
            _text(payload, 'measurement_id') ||
        _optionalText(payload['correction_reason']) == null) {
      throw _ProjectionBlocked(
        'REMOTE_MEASUREMENT_SOURCE_TYPE_MISMATCH',
        'Reviewed correction acknowledgement does not match its source event.',
      );
    }
    final receivedRefs = assetShaRefs.toList()..sort();
    if (canonicalJson(receivedRefs) != source['asset_sha_refs_json']) {
      throw _ProjectionBlocked(
        'REMOTE_MEASUREMENT_ASSET_REFS_MISMATCH',
        'Reviewed correction changed its immutable Asset references.',
      );
    }
    // A remote device's review acknowledgement never authorizes import here.
    // The receiver reviews the source event using its own ApprovalRef.
  }

  void _createTask(
    WorkspaceTransaction tx,
    String id,
    Map<String, Object?> payload,
    DateTime time,
    String eventId,
  ) {
    _ensureAbsent(tx, 'local_tasks', 'task_id', id);
    final stepId = _optionalText(payload['step_id']);
    if (stepId != null &&
        tx.query('SELECT 1 FROM step_executions WHERE step_id=?', [
          stepId,
        ]).isEmpty) {
      throw _ProjectionBlocked(
        'REMOTE_PARENT_MISSING',
        'Task Step has not arrived yet.',
      );
    }
    final state = _optionalText(payload['state']) ?? 'open';
    if (!const {'open', 'completed'}.contains(state)) {
      throw _ProjectionBlocked(
        'REMOTE_TASK_STATE_INVALID',
        'Created Task state is invalid.',
      );
    }
    final completedAt = state == 'completed'
        ? (_optionalDateText(payload['completed_at_utc']) ??
              time.toIso8601String())
        : null;
    tx.execute(
      '''INSERT INTO local_tasks
         (task_id,step_id,title,due_at_utc,state,revision,created_at_utc,
          completed_at_utc,command_id,deleted_at_utc)
         VALUES(?,?,?,?,?,1,?,?,?,NULL)''',
      [
        id,
        stepId,
        _text(payload, 'title'),
        _optionalDateText(payload['due_at_utc']),
        state,
        time.toIso8601String(),
        completedAt,
        eventId,
      ],
    );
  }

  void _updateTask(
    WorkspaceTransaction tx,
    String id,
    Map<String, Object?> payload,
    int? base,
    DateTime time,
  ) {
    final row = _requireRow(tx, 'local_tasks', 'task_id', id, 'Task');
    final revision = intFromDb(row['revision']);
    _requireRevision(
      tx,
      'task',
      id,
      base ?? _optionalInt(payload['expected_revision']),
      revision,
    );
    if (row['deleted_at_utc'] != null) {
      throw _ProjectionConflict(
        'REMOTE_TASK_DELETED',
        'A soft-deleted Task cannot be updated.',
      );
    }
    final stepId = _optionalText(payload['step_id']);
    if (stepId != null &&
        tx.query('SELECT 1 FROM step_executions WHERE step_id=?', [
          stepId,
        ]).isEmpty) {
      throw _ProjectionBlocked(
        'REMOTE_PARENT_MISSING',
        'Task Step has not arrived yet.',
      );
    }
    final completed = payload['completed'];
    if (completed != null && completed is! bool) {
      throw _ProjectionBlocked(
        'REMOTE_TASK_STATE_INVALID',
        'Task completion state is invalid.',
      );
    }
    final completedValue = completed as bool?;
    final nextState = completedValue == null
        ? row['state']! as String
        : completedValue
        ? 'completed'
        : 'open';
    final nextCompletedAt = completedValue == null
        ? row['completed_at_utc']
        : completedValue
        ? (_optionalDateText(payload['completed_at_utc']) ??
              time.toIso8601String())
        : null;
    final changed = tx.execute(
      '''UPDATE local_tasks SET title=?,step_id=?,due_at_utc=?,state=?,completed_at_utc=?,
           revision=revision+1 WHERE task_id=? AND revision=? AND deleted_at_utc IS NULL''',
      [
        _text(payload, 'title'),
        stepId,
        _optionalDateText(payload['due_at_utc']),
        nextState,
        nextCompletedAt,
        id,
        revision,
      ],
    );
    if (changed != 1) {
      throw _ProjectionConflict(
        'REMOTE_REVISION_CONFLICT',
        'Task changed before the remote update applied.',
      );
    }
  }

  void _completeTask(
    WorkspaceTransaction tx,
    String id,
    Map<String, Object?> payload,
    int? base,
  ) {
    final row = _requireRow(tx, 'local_tasks', 'task_id', id, 'Task');
    final revision = intFromDb(row['revision']);
    _requireRevision(
      tx,
      'task',
      id,
      base ?? _optionalInt(payload['revision']),
      revision,
    );
    if (const {'completed', 'cancelled'}.contains(row['state'])) {
      throw _ProjectionConflict(
        'REMOTE_TASK_TERMINAL',
        'Task is already terminal.',
      );
    }
    if (row['deleted_at_utc'] != null) {
      throw _ProjectionConflict(
        'REMOTE_TASK_DELETED',
        'A soft-deleted Task cannot be completed.',
      );
    }
    tx.execute(
      "UPDATE local_tasks SET state='completed',completed_at_utc=?,revision=revision+1 WHERE task_id=? AND revision=?",
      [_dateText(payload, 'completed_at_utc'), id, revision],
    );
  }

  void _deleteTask(
    WorkspaceTransaction tx,
    String id,
    Map<String, Object?> payload,
    int? base,
  ) {
    final row = _requireRow(tx, 'local_tasks', 'task_id', id, 'Task');
    final revision = intFromDb(row['revision']);
    _requireRevision(
      tx,
      'task',
      id,
      base ?? _optionalInt(payload['expected_revision']),
      revision,
    );
    if (row['deleted_at_utc'] != null) {
      throw _ProjectionConflict(
        'REMOTE_TASK_DELETED',
        'Task is already soft-deleted.',
      );
    }
    final changed = tx.execute(
      'UPDATE local_tasks SET deleted_at_utc=?,revision=revision+1 WHERE task_id=? AND revision=? AND deleted_at_utc IS NULL',
      [_dateText(payload, 'deleted_at_utc'), id, revision],
    );
    if (changed != 1) {
      throw _ProjectionConflict(
        'REMOTE_REVISION_CONFLICT',
        'Task changed before deletion applied.',
      );
    }
  }

  void _createReminder(
    WorkspaceTransaction tx,
    String id,
    Map<String, Object?> payload,
    DateTime time,
    String eventId,
  ) {
    _ensureAbsent(tx, 'reminders', 'reminder_id', id);
    final taskId = _optionalText(payload['task_id']);
    final stepId = _optionalText(payload['step_id']);
    if (taskId == null && stepId == null)
      throw _ProjectionBlocked(
        'REMOTE_REMINDER_TARGET_MISSING',
        'Reminder has no Task or Step target.',
      );
    if (taskId != null &&
        tx.query('SELECT 1 FROM local_tasks WHERE task_id=?', [
          taskId,
        ]).isEmpty) {
      throw _ProjectionBlocked(
        'REMOTE_PARENT_MISSING',
        'Reminder Task has not arrived yet.',
      );
    }
    if (stepId != null &&
        tx.query('SELECT 1 FROM step_executions WHERE step_id=?', [
          stepId,
        ]).isEmpty) {
      throw _ProjectionBlocked(
        'REMOTE_PARENT_MISSING',
        'Reminder Step has not arrived yet.',
      );
    }
    tx.execute(
      '''INSERT INTO reminders(reminder_id,task_id,step_id,due_at_utc,device_notification_id,status,last_attempt_at_utc,
           minutes_before,permission_state,delivery_state,command_id,updated_at_utc)
         VALUES(?,?,?, ?,NULL,'pending',NULL,?,?,'pending',?,?)''',
      [
        id,
        taskId,
        stepId,
        _dateText(payload, 'due_at_utc'),
        _int(payload, 'minutes_before'),
        _optionalText(payload['permission_state']) ?? 'unknown',
        eventId,
        time.toIso8601String(),
      ],
    );
  }

  void _updateReminder(
    WorkspaceTransaction tx,
    String id,
    Map<String, Object?> payload,
  ) {
    final row = _requireRow(tx, 'reminders', 'reminder_id', id, 'Reminder');
    if (const {'delivered', 'cancelled'}.contains(row['delivery_state'])) {
      throw _ProjectionConflict(
        'REMOTE_REMINDER_TERMINAL',
        'Reminder delivery is already terminal.',
      );
    }
    final state = _text(payload, 'delivery_state');
    final status = _text(payload, 'status');
    final permission = _text(payload, 'permission_state');
    if (!const {
          'pending',
          'scheduled',
          'delivered',
          'denied',
          'failed',
          'cancelled',
        }.contains(state) ||
        !const {
          'pending',
          'scheduled',
          'sent',
          'failed',
          'cancelled',
        }.contains(status) ||
        !const {'unknown', 'granted', 'denied'}.contains(permission)) {
      throw _ProjectionBlocked(
        'REMOTE_REMINDER_STATE_INVALID',
        'Reminder delivery fields are invalid.',
      );
    }
    final attempted = _dateText(payload, 'attempted_at_utc');
    tx.execute(
      'UPDATE reminders SET delivery_state=?,status=?,permission_state=?,device_notification_id=COALESCE(?,device_notification_id),last_attempt_at_utc=?,updated_at_utc=? WHERE reminder_id=?',
      [
        state,
        status,
        permission,
        _optionalText(payload['device_notification_id']),
        attempted,
        attempted,
        id,
      ],
    );
  }

  void _issueApproval(
    WorkspaceTransaction tx,
    String id,
    Map<String, Object?> payload,
    DateTime time,
    String eventId,
  ) {
    _ensureAbsent(tx, 'approval_receipts', 'approval_ref', id);
    final subjectType = _text(payload, 'subject_type');
    final subjectId = _text(payload, 'subject_id');
    if (subjectType == '*' || subjectId == '*')
      throw _ProjectionBlocked(
        'REMOTE_APPROVAL_TOO_BROAD',
        'Remote approval scope must name one subject.',
      );
    tx.execute(
      '''INSERT INTO approval_receipts(approval_ref,action,subject_type,subject_id,scope_json,approved_at_utc,
           expires_at_utc,revoked_at_utc,command_id) VALUES(?,?,?,?,?,?,?,NULL,?)''',
      [
        id,
        _text(payload, 'action'),
        subjectType,
        subjectId,
        jsonEncode(
          _object(payload['scope'] ?? const <String, Object?>{}, 'scope'),
        ),
        _dateText(payload, 'approved_at_utc'),
        _optionalDateText(payload['expires_at_utc']),
        eventId,
      ],
    );
  }

  void _revokeApproval(
    WorkspaceTransaction tx,
    String id,
    Map<String, Object?> payload,
  ) {
    final row = tx.query(
      'SELECT revoked_at_utc FROM approval_receipts WHERE approval_ref=?',
      [id],
    );
    if (row.isEmpty)
      throw _ProjectionBlocked(
        'REMOTE_PARENT_MISSING',
        'Approval receipt has not arrived yet.',
      );
    if (row.single['revoked_at_utc'] != null) return;
    tx.execute(
      'UPDATE approval_receipts SET revoked_at_utc=? WHERE approval_ref=? AND revoked_at_utc IS NULL',
      [_dateText(payload, 'revoked_at_utc'), id],
    );
  }

  void _updateSetting(
    WorkspaceTransaction tx,
    String id,
    Map<String, Object?> payload,
    DateTime time,
    int? base,
  ) {
    if (_text(payload, 'setting_key') != id)
      throw _ProjectionBlocked(
        'REMOTE_SETTING_ID_INVALID',
        'Setting key does not match the event identity.',
      );
    final value = _object(payload['value'], 'value');
    _rejectSecretMaterial(value);
    final rows = tx.query(
      'SELECT revision FROM workspace_settings WHERE setting_key=?',
      [id],
    );
    final current = rows.isEmpty ? 0 : intFromDb(rows.single['revision']);
    final expected = base ?? _optionalInt(payload['expected_revision']);
    if (expected != current)
      _throwRevisionConflict(tx, 'setting', id, 'REMOTE_REVISION_CONFLICT');
    if (rows.isEmpty) {
      if (current != 0)
        throw _ProjectionBlocked(
          'REMOTE_SETTING_REVISION_INVALID',
          'New Setting revision is invalid.',
        );
      tx.execute(
        'INSERT INTO workspace_settings(setting_key,value_json,revision,updated_at_utc) VALUES(?,?,1,?)',
        [id, jsonEncode(value), time.toIso8601String()],
      );
    } else {
      tx.execute(
        'UPDATE workspace_settings SET value_json=?,revision=revision+1,updated_at_utc=? WHERE setting_key=? AND revision=?',
        [jsonEncode(value), time.toIso8601String(), id, current],
      );
    }
  }

  void _assertAcyclic(WorkspaceTransaction tx, String runId) {
    final rows = tx.query(
      'SELECT step_id FROM step_executions WHERE run_id=?',
      [runId],
    );
    final ids = rows.map((row) => row['step_id']! as String).toSet();
    final dependencies = <String, List<String>>{};
    for (final id in ids) {
      dependencies[id] = tx
          .query(
            'SELECT required_step_id FROM step_dependencies WHERE step_id=?',
            [id],
          )
          .map((row) => row['required_step_id']! as String)
          .toList();
    }
    final visiting = <String>{};
    final visited = <String>{};
    bool visit(String id) {
      if (visiting.contains(id)) return false;
      if (visited.contains(id)) return true;
      visiting.add(id);
      for (final dependency in dependencies[id] ?? const <String>[]) {
        if (!ids.contains(dependency) || !visit(dependency)) return false;
      }
      visiting.remove(id);
      visited.add(id);
      return true;
    }

    if (!ids.every(visit))
      throw _ProjectionBlocked(
        'REMOTE_STEP_DAG_INVALID',
        'Remote Run Steps contain an invalid dependency DAG.',
      );
  }

  void _validateRequiredCaptures(
    WorkspaceTransaction tx,
    DbRow row,
    Map<String, Object?> captured,
  ) {
    if (row['protocol_step_id'] == null) return;
    final runs = tx.query(
      'SELECT protocol_snapshot_json FROM experiment_runs WHERE run_id=?',
      [row['run_id']],
    );
    if (runs.isEmpty) return;
    final snapshot = objectFromDb(runs.single['protocol_snapshot_json']);
    final steps = snapshot['steps'];
    if (steps is! List) return;
    for (final value in steps) {
      final step = _object(value, 'protocol step');
      if (step['step_id'] != row['protocol_step_id'] ||
          step['captures'] is! List)
        continue;
      for (final captureValue in step['captures'] as List) {
        final capture = _object(captureValue, 'capture');
        if (capture['required'] == true &&
            (capture['key'] is! String ||
                !captured.containsKey(capture['key']))) {
          throw _ProjectionBlocked(
            'REMOTE_REQUIRED_CAPTURE_MISSING',
            'Remote Step is missing required captured data.',
          );
        }
      }
    }
  }

  void _insertStepEvent(
    WorkspaceTransaction tx,
    String eventId,
    String stepId,
    String type,
    Map<String, Object?> data,
    DateTime time,
  ) {
    tx.execute(
      'INSERT INTO step_events(event_id,step_id,event_type,event_data_json,occurred_at_utc,recorded_at_utc,command_id) VALUES(?,?,?,?,?,?,?)',
      [
        eventId,
        stepId,
        type,
        jsonEncode(data),
        time.toIso8601String(),
        DateTime.now().toUtc().toIso8601String(),
        eventId,
      ],
    );
  }

  void _requireRevision(
    WorkspaceTransaction tx,
    String type,
    String id,
    int? expected,
    int actual,
  ) {
    if (expected == null || expected != actual)
      _throwRevisionConflict(tx, type, id, 'REMOTE_REVISION_CONFLICT');
  }

  Never _throwRevisionConflict(
    WorkspaceTransaction tx,
    String type,
    String id,
    String code,
  ) {
    final local = tx.query(
      'SELECT event_id FROM mutation_events WHERE entity_kind=? AND entity_id=? ORDER BY seq DESC LIMIT 1',
      [type, id],
    );
    final remote = tx.query(
      "SELECT event_id FROM sync_remote_events WHERE entity_kind=? AND entity_id=? AND application_state='applied' ORDER BY lamport DESC LIMIT 1",
      [type, id],
    );
    final counterpart = local.isNotEmpty
        ? local.single['event_id']! as String
        : remote.isNotEmpty
        ? remote.first['event_id']! as String
        : null;
    throw _ProjectionConflict(
      code,
      'Remote event base revision does not match the current $type revision.',
      counterpartEventId: counterpart,
    );
  }

  void _recordConflict(
    WorkspaceTransaction tx,
    DbRow row,
    String? counterpartId,
    DateTime time,
  ) {
    if (counterpartId != null && counterpartId != row['event_id']) {
      final pair = [counterpartId, row['event_id']! as String]..sort();
      if (tx
          .query(
            'SELECT 1 FROM sync_conflicts WHERE event_id_a=? AND event_id_b=? AND state=\'open\'',
            pair,
          )
          .isEmpty) {
        tx.execute(
          'INSERT INTO sync_conflicts(conflict_id,entity_kind,entity_id,event_id_a,event_id_b,state,created_at_utc) VALUES(?,?,?,?,?,\'open\',?)',
          [
            newUuidV7(at: time),
            row['entity_kind'],
            row['entity_id'],
            pair[0],
            pair[1],
            time.toIso8601String(),
          ],
        );
      }
    }
  }

  String? _findCounterpart(
    WorkspaceTransaction tx,
    String entityType,
    String entityId,
    String eventId,
  ) {
    final local = tx.query(
      'SELECT event_id FROM mutation_events WHERE entity_kind=? AND entity_id=? ORDER BY seq DESC LIMIT 1',
      [entityType, entityId],
    );
    if (local.isNotEmpty && local.single['event_id'] != eventId) {
      return local.single['event_id']! as String;
    }
    final remote = tx.query(
      "SELECT event_id FROM sync_remote_events WHERE entity_kind=? AND entity_id=? AND event_id<>? AND application_state='applied' ORDER BY lamport DESC LIMIT 1",
      [entityType, entityId, eventId],
    );
    return remote.isEmpty ? null : remote.single['event_id']! as String;
  }

  bool _hasOpenConflict(WorkspaceTransaction tx, String eventId) => tx.query(
    "SELECT 1 FROM sync_conflicts WHERE state='open' AND (event_id_a=? OR event_id_b=?) LIMIT 1",
    [eventId, eventId],
  ).isNotEmpty;

  void _setOutcome(
    WorkspaceTransaction tx,
    String eventId,
    String targetId,
    String state,
    String? error,
  ) {
    tx.execute(
      'UPDATE sync_remote_events SET application_state=?,application_error=? WHERE event_id=?',
      [state, error, eventId],
    );
    tx.execute(
      'UPDATE sync_remote_event_targets SET state=? WHERE target_id=? AND event_id=?',
      [state, targetId, eventId],
    );
  }

  static bool _actionMatches(String eventType, MutationAction action) {
    final expected = switch (eventType) {
      'project.created' ||
      'experiment.created' ||
      'run.created' ||
      'step.added' ||
      'sample.created' ||
      'task.created' ||
      'reminder.created' ||
      'approval.issued' ||
      'group.created' ||
      'measurement.recorded' => const {MutationAction.create},
      'protocol.draft_saved' => const {
        MutationAction.create,
        MutationAction.patch,
      },
      'task.updated' ||
      'task.completed' ||
      'task.deleted' => const {MutationAction.patch},
      'project.updated' ||
      'experiment.updated' ||
      'protocol.approved' ||
      'run.sample_attached' ||
      'run.closed' ||
      'step.started' ||
      'step.completed' ||
      'measurement.confirmed' ||
      'group.updated' ||
      'reminder.delivery_updated' ||
      'setting.updated' ||
      'schedule.rebuilt' => const {MutationAction.patch},
      'measurement.corrected' ||
      'treatment.recorded' ||
      'treatment.corrected' => const {MutationAction.append},
      'measurement.external_reviewed' => const {MutationAction.create},
      'approval.revoked' => const {MutationAction.tombstone},
      _ => const <MutationAction>{},
    };
    return expected.contains(action);
  }

  static void _ensureAbsent(
    WorkspaceTransaction tx,
    String table,
    String keyColumn,
    String id,
  ) {
    if (tx.query('SELECT 1 FROM $table WHERE $keyColumn=?', [id]).isNotEmpty) {
      throw _ProjectionConflict(
        'REMOTE_ENTITY_EXISTS',
        'Remote create targets an entity id that already exists.',
      );
    }
  }

  static DbRow _requireRow(
    WorkspaceTransaction tx,
    String table,
    String keyColumn,
    String id,
    String label,
  ) {
    final rows = tx.query('SELECT * FROM $table WHERE $keyColumn=?', [id]);
    if (rows.isEmpty)
      throw _ProjectionBlocked(
        'REMOTE_PARENT_MISSING',
        '$label $id has not arrived yet.',
      );
    return rows.single;
  }

  static MutationAction _action(Object? value) {
    if (value is! String)
      throw _ProjectionBlocked(
        'REMOTE_EVENT_ACTION_INVALID',
        'Remote action is not a string.',
      );
    try {
      return MutationAction.values.byName(value);
    } on ArgumentError {
      throw _ProjectionBlocked(
        'REMOTE_EVENT_ACTION_INVALID',
        'Remote action is unsupported.',
      );
    }
  }

  static Map<String, Object?> _payload(Object? value) =>
      _object(jsonDecode(value! as String), 'payload');

  static Map<String, Object?> _object(Object? value, String name) {
    try {
      return requireJsonObject(value, name);
    } on FormatException {
      throw _ProjectionBlocked(
        'REMOTE_EVENT_INVALID',
        '$name must be a JSON object.',
      );
    }
  }

  static Map<String, Object?> _objectFromJson(Object? value) =>
      _object(jsonDecode(value! as String), 'document');

  static String _text(Map<String, Object?> value, String key) {
    final item = value[key];
    if (item is! String || item.trim().isEmpty)
      throw _ProjectionBlocked(
        'REMOTE_EVENT_INVALID',
        '$key must be a non-empty string.',
      );
    return item;
  }

  static String? _optionalText(Object? value) => value == null
      ? null
      : value is String
      ? value
      : throw _ProjectionBlocked(
          'REMOTE_EVENT_INVALID',
          'Expected a nullable string value.',
        );

  static int _int(Map<String, Object?> value, String key) {
    final item = value[key];
    if (item is int) return item;
    throw _ProjectionBlocked(
      'REMOTE_EVENT_INVALID',
      '$key must be an integer.',
    );
  }

  static int? _optionalInt(Object? value) => value == null
      ? null
      : value is int
      ? value
      : throw _ProjectionBlocked(
          'REMOTE_EVENT_INVALID',
          'Expected a nullable integer value.',
        );

  static String _dateText(Map<String, Object?> value, String key) {
    final result = _text(value, key);
    try {
      DateTime.parse(result);
      return result;
    } on FormatException {
      throw _ProjectionBlocked(
        'REMOTE_EVENT_INVALID',
        '$key must be an ISO-8601 date-time.',
      );
    }
  }

  static String? _optionalDateText(Object? value) {
    if (value == null) return null;
    if (value is! String)
      throw _ProjectionBlocked(
        'REMOTE_EVENT_INVALID',
        'Expected a nullable date-time string.',
      );
    try {
      DateTime.parse(value);
      return value;
    } on FormatException {
      throw _ProjectionBlocked(
        'REMOTE_EVENT_INVALID',
        'Date-time value is invalid.',
      );
    }
  }

  static int _boolInt(Object? value) => switch (value) {
    bool boolean => boolean ? 1 : 0,
    _ => throw _ProjectionBlocked(
      'REMOTE_EVENT_INVALID',
      'Expected a boolean value.',
    ),
  };

  static List<String> _stringList(Object? value, String name) {
    if (value is! List || value.any((item) => item is! String)) {
      throw _ProjectionBlocked(
        'REMOTE_EVENT_INVALID',
        '$name must be an array of strings.',
      );
    }
    return value.cast<String>();
  }

  static void _rejectSecretMaterial(Object? value) {
    final sensitive = RegExp(
      r'(api[_-]?key|password|access[_-]?token|refresh[_-]?token|credential)',
      caseSensitive: false,
    );
    if (value is Map) {
      for (final entry in value.entries) {
        if (entry.key is String && sensitive.hasMatch(entry.key as String)) {
          throw _ProjectionBlocked(
            'SECRET_MUST_USE_SECURE_STORE',
            'Remote settings cannot contain credential material.',
          );
        }
        _rejectSecretMaterial(entry.value);
      }
    } else if (value is List) {
      for (final item in value) {
        _rejectSecretMaterial(item);
      }
    }
  }
}

final class _ProjectionBlocked implements Exception {
  const _ProjectionBlocked(this.code, this.message);
  final String code;
  final String message;
}

final class _ProjectionConflict implements Exception {
  const _ProjectionConflict(this.code, this.message, {this.counterpartEventId});
  final String code;
  final String message;
  final String? counterpartEventId;
}
