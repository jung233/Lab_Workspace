import 'dart:convert';

import '../application/remote_event_projection.dart';
import '../domain/errors.dart';
import '../domain/events.dart';
import '../domain/ids.dart';
import '../persistence/workspace_database.dart';

/// Safe projection adapter for immutable asset, virtual-folder, and folder-link
/// events received from another device. It never deletes CAS bytes. Asset
/// imports can only reference a locally committed, fully verified Blob.
final class AssetRemoteEventProjectionHandler implements RemoteEventProjectionHandler {
  const AssetRemoteEventProjectionHandler();

  static const _linkTypes = <String>{
    'run',
    'step',
    'sample',
    'measurement',
    'calculation',
    'analysis',
  };

  @override
  bool canHandle({
    required String entityType,
    required MutationAction action,
    required Map<String, Object?> payload,
  }) {
    if (entityType == 'asset') {
      if (action == MutationAction.create) return payload.containsKey('blob_sha256');
      if (action == MutationAction.patch) return payload.containsKey('restored_at_utc');
      if (action == MutationAction.tombstone) return payload.containsKey('deletion_id');
      if (action == MutationAction.append) {
        return payload.containsKey('physical_bytes_released') ||
            (payload.containsKey('status') && payload.containsKey('blob_sha256'));
      }
      return false;
    }
    if (entityType == 'asset_folder') {
      return action == MutationAction.create && payload.containsKey('folder_id');
    }
    if (entityType == 'asset_folder_membership') {
      return (action == MutationAction.append || action == MutationAction.tombstone) &&
          payload.containsKey('folder_id') && payload.containsKey('asset_id');
    }
    if (entityType == 'blob') {
      return action == MutationAction.append &&
          (payload.containsKey('physical_bytes_released') || payload.containsKey('status'));
    }
    return false;
  }

  @override
  void apply(WorkspaceTransaction tx, RemoteEventEnvelope event) {
    switch (event.entityType) {
      case 'asset':
        _applyAsset(tx, event);
        return;
      case 'asset_folder':
        _createFolder(tx, event);
        return;
      case 'asset_folder_membership':
        _applyFolderMembership(tx, event);
        return;
      case 'blob':
        // A peer's local GC result is audit information only. It must never
        // delete this device's CAS copy or rewrite this device's Asset state.
        _require(event.action == MutationAction.append, 'REMOTE_BLOB_EVENT_INVALID', 'Blob event action is invalid.');
        if (event.payload.containsKey('status')) {
          _recordRemoteIntegrityWarning(tx, event);
        } else {
          _require(event.payload.containsKey('physical_bytes_released'),
              'REMOTE_BLOB_RELEASE_INVALID', 'Blob release event has an unsupported shape.');
        }
        return;
      default:
        throw const ValidationException('REMOTE_ASSET_EVENT_UNSUPPORTED', 'Unsupported asset event entity.');
    }
  }

  void _applyAsset(WorkspaceTransaction tx, RemoteEventEnvelope event) {
    if (event.action == MutationAction.create) {
      _createAsset(tx, event);
    } else if (event.action == MutationAction.patch && event.payload.containsKey('restored_at_utc')) {
      _restoreAsset(tx, event);
    } else if (event.action == MutationAction.tombstone &&
        event.payload.containsKey('deletion_id')) {
      _tombstoneAsset(tx, event, purge: event.payload['scope'] == 'purge');
    } else if (event.action == MutationAction.append &&
        event.payload.containsKey('physical_bytes_released')) {
      // This device preserves its own bytes. The immutable remote event remains
      // the record that another device released its copy.
      return;
    } else if (event.action == MutationAction.append && event.payload.containsKey('status')) {
      _recordRemoteIntegrityWarning(tx, event);
    } else {
      throw const ValidationException('REMOTE_ASSET_EVENT_UNSUPPORTED', 'Asset event action is unsupported.');
    }
  }

  void _createAsset(WorkspaceTransaction tx, RemoteEventEnvelope event) {
    final payload = event.payload;
    final assetId = _text(payload, 'asset_id');
    final sha = _text(payload, 'blob_sha256');
    final size = _integer(payload, 'byte_size');
    _require(assetId == event.entityId, 'REMOTE_ASSET_ID_INVALID', 'Asset identity does not match its event.');
    _require(RegExp(r'^[a-f0-9]{64}$').hasMatch(sha), 'REMOTE_ASSET_SHA_INVALID', 'Asset Blob SHA-256 is invalid.');
    _require(event.assetShaRefs.contains(sha), 'REMOTE_ASSET_SHA_REFERENCE_MISSING', 'Asset event does not reference its Blob SHA.');
    _require(size >= 0, 'REMOTE_ASSET_SIZE_INVALID', 'Asset byte size cannot be negative.');
    final displayName = _text(payload, 'display_name').trim();
    _require(displayName.isNotEmpty, 'REMOTE_ASSET_NAME_INVALID', 'Asset display name is empty.');
    final kind = _text(payload, 'kind');
    _require(const {'raw', 'derived', 'report', 'thumbnail', 'export'}.contains(kind),
        'REMOTE_ASSET_KIND_INVALID', 'Asset kind is unsupported.');
    final createdAt = _date(payload, 'created_at_utc');
    final parentId = _optionalText(payload['parent_asset_id']);
    final metadata = _object(payload['metadata'] ?? const <String, Object?>{}, 'metadata');
    final links = _links(payload['links']);

    final blobs = tx.query('SELECT byte_size,state FROM blob_objects WHERE sha256=?', [sha]);
    if (blobs.isEmpty || blobs.single['state'] != 'committed') {
      throw const ValidationException('REMOTE_PARENT_MISSING', 'Asset Blob has not been received and verified.');
    }
    _require(_dbInteger(blobs.single['byte_size']) == size,
        'REMOTE_ASSET_SIZE_MISMATCH', 'Asset size does not match the committed Blob.');
    if (parentId != null && tx.query('SELECT 1 FROM assets WHERE asset_id=?', [parentId]).isEmpty) {
      throw const ValidationException('REMOTE_PARENT_MISSING', 'Parent Asset has not arrived yet.');
    }

    final existing = tx.query('SELECT blob_sha256,display_name,kind FROM assets WHERE asset_id=?', [assetId]);
    if (existing.isNotEmpty) {
      _require(existing.single['blob_sha256'] == sha && existing.single['display_name'] == displayName &&
          existing.single['kind'] == kind, 'REMOTE_ASSET_ID_COLLISION', 'Asset id already refers to different content.');
    } else {
      tx.execute(
        '''INSERT INTO assets(asset_id,blob_sha256,display_name,media_type,kind,parent_asset_id,
             created_at_utc,deleted_at_utc,metadata_json,origin)
           VALUES(?,?,?,?,?,?,?,NULL,?,'managed_import')''',
        [assetId, sha, displayName, _optionalText(payload['media_type']), kind, parentId,
          createdAt.toIso8601String(), jsonEncode(metadata)],
      );
    }
    for (final link in links) {
      final entityType = link['entity_type']! as String;
      final entityId = link['entity_id']! as String;
      if (!_targetExists(tx, entityType, entityId)) {
        throw const ValidationException('REMOTE_PARENT_MISSING', 'Asset link target has not arrived yet.');
      }
      final exists = tx.query(
        '''SELECT 1 FROM asset_links WHERE asset_id=? AND entity_type=? AND entity_id=?
             AND relation=? AND removed_at_utc IS NULL''',
        [assetId, entityType, entityId, link['relation']],
      );
      if (exists.isEmpty) {
        tx.execute(
          '''INSERT INTO asset_links(link_id,asset_id,entity_type,entity_id,relation,removed_at_utc,
               created_at_utc,metadata_json) VALUES(?,?,?,?,?,NULL,?,?)''',
          [newUuidV7(at: createdAt), assetId, entityType, entityId, link['relation'], createdAt.toIso8601String(),
            jsonEncode(link['metadata'])],
        );
      }
    }
  }

  void _tombstoneAsset(WorkspaceTransaction tx, RemoteEventEnvelope event, {required bool purge}) {
    final payload = event.payload;
    final assetId = _text(payload, 'asset_id');
    final sha = _text(payload, 'blob_sha256');
    _require(assetId == event.entityId, 'REMOTE_ASSET_ID_INVALID', 'Asset tombstone identity is invalid.');
    _require(event.assetShaRefs.contains(sha), 'REMOTE_ASSET_SHA_REFERENCE_MISSING',
        'Asset tombstone does not reference its Blob SHA.');
    final rows = tx.query('SELECT blob_sha256,deleted_at_utc FROM assets WHERE asset_id=?', [assetId]);
    if (rows.isEmpty) throw const ValidationException('REMOTE_PARENT_MISSING', 'Asset has not arrived yet.');
    _require(rows.single['blob_sha256'] == sha, 'REMOTE_ASSET_SHA_MISMATCH', 'Asset tombstone SHA does not match its Asset.');
    final deletionId = _text(payload, 'deletion_id');
    final requestedAt = _date(payload, 'deleted_at_utc');
    final scope = _text(payload, 'scope');
    _require((scope == 'purge') == purge && (scope == 'purge' || scope == 'trash'),
        'REMOTE_ASSET_DELETE_SCOPE_INVALID', 'Asset delete scope is invalid.');
    final reason = _optionalText(payload['reason']) ?? 'Deleted on a synchronized device';
    // The source receipt is retained only as immutable provenance. It cannot
    // authorize an action on this device. Trash requests enter a local review
    // queue; purge events are retained as audit-only and never delete CAS data.
    final sourceApprovalRef = _optionalText(payload['approval_ref']);
    final status = purge ? 'audit_only' : 'pending';
    final resolutionNote = purge ? 'REMOTE_PURGE_IS_AUDIT_ONLY' : null;
    tx.execute(
      '''INSERT OR IGNORE INTO remote_asset_deletion_reviews
         (source_event_id,target_id,asset_id,source_deletion_id,blob_sha256,requested_scope,
          source_approval_ref,reason,requested_at_utc,status,reviewed_at_utc,resolution_note)
         VALUES(?,?,?,?,?,?,?,?,?,?,?,?)''',
      [event.eventId, event.targetId, assetId, deletionId, sha, scope, sourceApprovalRef,
        reason, requestedAt.toIso8601String(), status,
        purge ? requestedAt.toIso8601String() : null, resolutionNote],
    );
    final saved = tx.query(
      '''SELECT target_id,asset_id,source_deletion_id,blob_sha256,requested_scope
         FROM remote_asset_deletion_reviews WHERE source_event_id=?''',
      [event.eventId],
    );
    _require(saved.isNotEmpty && saved.single['target_id'] == event.targetId &&
        saved.single['asset_id'] == assetId && saved.single['source_deletion_id'] == deletionId &&
        saved.single['blob_sha256'] == sha && saved.single['requested_scope'] == scope,
        'REMOTE_ASSET_DELETE_EVENT_COLLISION', 'Remote asset deletion event has conflicting review metadata.');
  }

  void _recordRemoteIntegrityWarning(WorkspaceTransaction tx, RemoteEventEnvelope event) {
    final payload = event.payload;
    final sha = _text(payload, 'blob_sha256');
    final status = _text(payload, 'status');
    _require(RegExp(r'^[a-f0-9]{64}$').hasMatch(sha),
        'REMOTE_ASSET_SHA_INVALID', 'Integrity warning Blob SHA-256 is invalid.');
    _require(event.assetShaRefs.contains(sha),
        'REMOTE_ASSET_SHA_REFERENCE_MISSING', 'Integrity warning does not reference its Blob SHA.');
    _require(status == 'missing' || status == 'mismatch',
        'REMOTE_ASSET_INTEGRITY_STATUS_INVALID', 'Only missing or mismatch reports are accepted.');
    final blob = tx.query('SELECT 1 FROM blob_objects WHERE sha256=?', [sha]);
    if (blob.isEmpty) throw const ValidationException('REMOTE_PARENT_MISSING', 'Integrity warning Blob has not arrived.');
    final modeValue = payload['mode'];
    final mode = modeValue is String &&
            const {'full_sha256', 'metadata_quick', 'transfer_checksum'}.contains(modeValue)
        ? modeValue
        : 'full_sha256';
    final details = <String, Object?>{
      'source': 'remote_device_report',
      'source_device_id': event.deviceId,
      'reported_status': status,
      'remote_verification_level': payload['verification_level'],
      'expected_sha256': payload['expected_sha256'],
      'actual_sha256': payload['actual_sha256'],
      'message': payload['message'],
      if (modeValue == null) 'remote_mode_unknown': true,
    };
    final at = event.occurredAtUtc.toIso8601String();
    tx.execute(
      '''INSERT OR IGNORE INTO integrity_checks
         (check_id,blob_sha256,mode,status,started_at_utc,finished_at_utc,details_json,verification_level)
         VALUES (?,?,?,'failed',?,?,?,'remote_report')''',
      [event.eventId, sha, mode, at, at, jsonEncode(details)],
    );
  }

  void _restoreAsset(WorkspaceTransaction tx, RemoteEventEnvelope event) {
    final payload = event.payload;
    final assetId = _text(payload, 'asset_id');
    final sha = _text(payload, 'blob_sha256');
    _require(assetId == event.entityId, 'REMOTE_ASSET_ID_INVALID', 'Asset restore identity is invalid.');
    final assets = tx.query('SELECT blob_sha256 FROM assets WHERE asset_id=?', [assetId]);
    if (assets.isEmpty) throw const ValidationException('REMOTE_PARENT_MISSING', 'Asset has not arrived yet.');
    _require(assets.single['blob_sha256'] == sha, 'REMOTE_ASSET_SHA_MISMATCH', 'Asset restore SHA does not match its Asset.');
    final blob = tx.query("SELECT state FROM blob_objects WHERE sha256=?", [sha]);
    if (blob.isEmpty || blob.single['state'] != 'committed') {
      throw const ValidationException('REMOTE_PARENT_MISSING', 'Restored Asset Blob has not arrived yet.');
    }
    final restoredAt = _date(payload, 'restored_at_utc');
    tx.execute('UPDATE assets SET deleted_at_utc=NULL WHERE asset_id=?', [assetId]);
    tx.execute("UPDATE deletion_records SET state='recovered' WHERE asset_id=? AND scope='trash' AND state='trashed'", [assetId]);
    tx.execute("DELETE FROM asset_sync_tombstone_acks WHERE asset_id=? AND state='pending'", [assetId]);
    tx.execute(
      '''INSERT OR IGNORE INTO deletion_records(deletion_id,asset_id,scope,impact_json,state,created_at_utc,
           reason,confirmed_at_utc,command_id) VALUES(?,?,'unlink','{}','recovered',?,?,?,?)''',
      [newUuidV7(at: restoredAt), assetId, restoredAt.toIso8601String(), 'Asset restored on a synchronized device',
        restoredAt.toIso8601String(), event.eventId],
    );
  }

  void _createFolder(WorkspaceTransaction tx, RemoteEventEnvelope event) {
    final payload = event.payload;
    final folderId = _text(payload, 'folder_id');
    final name = _text(payload, 'name').trim();
    _require(folderId == event.entityId && name.isNotEmpty,
        'REMOTE_ASSET_FOLDER_INVALID', 'Virtual folder identity or name is invalid.');
    final parent = _optionalText(payload['parent_folder_id']);
    if (parent != null && tx.query('SELECT 1 FROM asset_virtual_folders WHERE folder_id=?', [parent]).isEmpty) {
      throw const ValidationException('REMOTE_PARENT_MISSING', 'Parent virtual folder has not arrived yet.');
    }
    final existing = tx.query('SELECT name,parent_folder_id FROM asset_virtual_folders WHERE folder_id=?', [folderId]);
    if (existing.isNotEmpty) {
      _require(existing.single['name'] == name && existing.single['parent_folder_id'] == parent,
          'REMOTE_ASSET_FOLDER_COLLISION', 'Virtual folder id already refers to different content.');
      return;
    }
    final nameCollision = parent == null
        ? tx.query('SELECT folder_id FROM asset_virtual_folders WHERE parent_folder_id IS NULL AND name=?', [name])
        : tx.query('SELECT folder_id FROM asset_virtual_folders WHERE parent_folder_id=? AND name=?', [parent, name]);
    if (nameCollision.isNotEmpty) {
      throw const ValidationException('REMOTE_ASSET_FOLDER_NAME_COLLISION', 'A sibling virtual folder already has this name.');
    }
    tx.execute('INSERT INTO asset_virtual_folders(folder_id,parent_folder_id,name,created_at_utc) VALUES(?,?,?,?)',
        [folderId, parent, name, _date(payload, 'created_at_utc').toIso8601String()]);
  }

  void _applyFolderMembership(WorkspaceTransaction tx, RemoteEventEnvelope event) {
    final payload = event.payload;
    final folderId = _text(payload, 'folder_id');
    final assetId = _text(payload, 'asset_id');
    if (tx.query('SELECT 1 FROM asset_virtual_folders WHERE folder_id=?', [folderId]).isEmpty ||
        tx.query('SELECT 1 FROM assets WHERE asset_id=?', [assetId]).isEmpty) {
      throw const ValidationException('REMOTE_PARENT_MISSING', 'Virtual folder or Asset has not arrived yet.');
    }
    if (event.action == MutationAction.append) {
      tx.execute(
        'INSERT OR IGNORE INTO asset_folder_memberships(folder_id,asset_id,created_at_utc) VALUES(?,?,?)',
        [folderId, assetId, _date(payload, 'created_at_utc').toIso8601String()],
      );
    } else if (event.action == MutationAction.tombstone) {
      tx.execute('DELETE FROM asset_folder_memberships WHERE folder_id=? AND asset_id=?', [folderId, assetId]);
    }
  }

  bool _targetExists(WorkspaceTransaction tx, String type, String id) {
    final tableAndId = switch (type) {
      'run' => ('experiment_runs', 'run_id'),
      'step' => ('step_executions', 'step_id'),
      'sample' => ('samples', 'sample_id'),
      'measurement' => ('measurements', 'measurement_id'),
      'calculation' => ('calculation_runs', 'calculation_id'),
      'analysis' => ('analysis_runs', 'analysis_id'),
      _ => null,
    };
    if (tableAndId == null) return false;
    return tx.query('SELECT 1 FROM ${tableAndId.$1} WHERE ${tableAndId.$2}=?', [id]).isNotEmpty;
  }

  List<Map<String, Object?>> _links(Object? value) {
    if (value == null) return const [];
    if (value is! List) throw const ValidationException('REMOTE_ASSET_LINKS_INVALID', 'Asset links must be a list.');
    return value.map((entry) {
      if (entry is! Map<String, Object?>) {
        throw const ValidationException('REMOTE_ASSET_LINK_INVALID', 'Asset link must be an object.');
      }
      final type = _text(entry, 'entity_type');
      final id = _text(entry, 'entity_id');
      final relation = _text(entry, 'relation');
      _require(_linkTypes.contains(type) && id.isNotEmpty && relation.isNotEmpty,
          'REMOTE_ASSET_LINK_INVALID', 'Asset link target type, id, or role is invalid.');
      return <String, Object?>{
        'entity_type': type,
        'entity_id': id,
        'relation': relation,
        'metadata': _object(entry['metadata'] ?? const <String, Object?>{}, 'link.metadata'),
      };
    }).toList(growable: false);
  }

  static Map<String, Object?> _object(Object? value, String field) {
    if (value is Map<String, Object?>) return value;
    if (value is Map) return value.map((key, item) => MapEntry(key.toString(), item));
    throw ValidationException('REMOTE_ASSET_FIELD_INVALID', '$field must be an object.');
  }

  static String _text(Map<String, Object?> value, String field) {
    final item = value[field];
    if (item is! String || item.isEmpty) {
      throw ValidationException('REMOTE_ASSET_FIELD_INVALID', '$field must be a non-empty string.');
    }
    return item;
  }

  static String? _optionalText(Object? value) {
    if (value == null) return null;
    if (value is String) return value;
    throw const ValidationException('REMOTE_ASSET_FIELD_INVALID', 'Optional text field must be a string or null.');
  }

  static int _integer(Map<String, Object?> value, String field) {
    final item = value[field];
    if (item is! int) throw ValidationException('REMOTE_ASSET_FIELD_INVALID', '$field must be an integer.');
    return item;
  }

  static int _dbInteger(Object? value) => value is int ? value : int.tryParse('$value') ?? -1;

  static DateTime _date(Map<String, Object?> value, String field) {
    final text = _text(value, field);
    try {
      return DateTime.parse(text).toUtc();
    } on FormatException {
      throw ValidationException('REMOTE_ASSET_DATE_INVALID', '$field is not an ISO-8601 timestamp.');
    }
  }

  static void _require(bool condition, String code, String message) {
    if (!condition) throw ValidationException(code, message);
  }
}
