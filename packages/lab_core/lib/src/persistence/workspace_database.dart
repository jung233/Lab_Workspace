import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../domain/errors.dart';
import '../domain/events.dart';
import '../domain/ids.dart';
import '../domain/json_value.dart';
import '../domain/security.dart';
import 'migrations.dart';

typedef DbRow = Map<String, Object?>;

/// Synchronous SQLite access for a single device-local Vault.
///
/// Callers must pass a transaction object to repositories so business rows,
/// mutation events, and outbox entries commit or roll back together.
final class WorkspaceDatabase {
  WorkspaceDatabase._(this._database, this.filePath);

  final Database _database;
  final String filePath;
  bool _closed = false;
  bool _transactionOpen = false;

  static Future<WorkspaceDatabase> open({required String filePath}) async {
    final absolutePath = p.normalize(p.absolute(filePath));
    await Directory(p.dirname(absolutePath)).create(recursive: true);
    final database = sqlite3.open(absolutePath);
    final result = WorkspaceDatabase._(database, absolutePath);
    try {
      database.execute('PRAGMA foreign_keys = ON');
      database.execute('PRAGMA journal_mode = WAL');
      result._applyMigrations();
      return result;
    } on Object {
      database.close();
      rethrow;
    }
  }

  /// Opens an existing Vault database only after validating its SQLite header
  /// and required metadata tables in read-only mode. It never creates a file.
  static Future<WorkspaceDatabase> openExisting({
    required String filePath,
  }) async {
    final absolutePath = p.normalize(p.absolute(filePath));
    final file = File(absolutePath);
    if (!await file.exists()) {
      throw FileSystemException('Vault database does not exist.', absolutePath);
    }
    final probe = sqlite3.open(absolutePath, mode: OpenMode.readOnly);
    try {
      final tables = probe
          .select(
            "SELECT name FROM sqlite_master WHERE type='table' AND name IN('vaults','devices')",
          )
          .map((row) => row['name'] as String)
          .toSet();
      if (!tables.contains('vaults') || !tables.contains('devices')) {
        throw const ValidationException(
          'VAULT_DATABASE_INVALID',
          'The selected database does not contain Lab Workspace Vault metadata.',
        );
      }
      final vaults = probe.select('SELECT vault_id FROM vaults');
      if (vaults.length != 1 || (vaults.single['vault_id'] as String).isEmpty) {
        throw const ValidationException(
          'VAULT_METADATA_INVALID',
          'The selected database must contain exactly one valid Vault identity.',
        );
      }
    } finally {
      probe.close();
    }
    return open(filePath: absolutePath);
  }

  int get schemaVersion => _database.userVersion;

  String get activeDeviceId {
    _ensureOpen();
    final rows = _database.select(
      'SELECT active_device_id FROM local_installation_identity WHERE singleton_id=1',
    );
    if (rows.isEmpty)
      throw StateError('Local installation identity has not been initialized.');
    return rows.single['active_device_id'] as String;
  }

  int get authorityGeneration {
    _ensureOpen();
    final rows = _database.select(
      'SELECT authority_generation FROM local_installation_identity WHERE singleton_id=1',
    );
    if (rows.isEmpty)
      throw StateError('Local installation identity has not been initialized.');
    return _asInt(rows.single['authority_generation']);
  }

  bool get isClosed => _closed;

  List<DbRow> query(String sql, [List<Object?> bindings = const <Object?>[]]) {
    _ensureOpen();
    return _rows(_database.select(sql, bindings));
  }

  int execute(String sql, [List<Object?> bindings = const <Object?>[]]) {
    _ensureOpen();
    _database.execute(sql, bindings);
    return _database.updatedRows;
  }

  T transaction<T>(T Function(WorkspaceTransaction tx) callback) {
    _ensureOpen();
    if (_transactionOpen) {
      throw StateError(
        'Nested WorkspaceDatabase transactions are not allowed.',
      );
    }
    _transactionOpen = true;
    try {
      _database.execute('BEGIN IMMEDIATE');
      final value = callback(WorkspaceTransaction._(this, _database));
      _database.execute('COMMIT');
      return value;
    } on Object {
      if (!_database.autocommit) {
        _database.execute('ROLLBACK');
      }
      rethrow;
    } finally {
      _transactionOpen = false;
    }
  }

  /// Creates a consistent SQLite snapshot through SQLite's Online Backup API.
  /// The destination is first written to a sibling temporary file, then
  /// atomically renamed once the backup stream completes.
  Future<void> backupToFile(String destination) async {
    _ensureOpen();
    if (_transactionOpen) {
      throw StateError('A backup cannot start inside a write transaction.');
    }
    final targetPath = p.normalize(p.absolute(destination));
    final target = File(targetPath);
    if (await target.exists()) {
      throw FileSystemException(
        'Backup destination already exists.',
        targetPath,
      );
    }
    await target.parent.create(recursive: true);
    final stagingPath = targetPath + '.partial-' + newUuidV7();
    final stagingFile = File(stagingPath);
    final destinationDatabase = sqlite3.open(stagingPath);
    var destinationClosed = false;
    try {
      await for (final _ in _database.backup(destinationDatabase)) {
        // The API yields progress as it copies bounded page batches.
      }
      destinationDatabase.close();
      destinationClosed = true;
      await stagingFile.rename(targetPath);
    } on Object {
      if (!destinationClosed) destinationDatabase.close();
      if (await stagingFile.exists()) {
        await stagingFile.delete();
      }
      rethrow;
    }
  }

  /// Ensures a first-install or same-device identity is recorded. A persisted
  /// identity mismatch is a hard error; callers must use the restore handoff
  /// when activating a restored copy.
  void ensureLocalInstallationIdentity({
    required String deviceId,
    required DateTime atUtc,
  }) {
    transaction((tx) {
      final existing = tx.query(
        'SELECT active_device_id FROM local_installation_identity WHERE singleton_id=1',
      );
      if (existing.isEmpty) {
        tx.execute(
          '''INSERT INTO local_installation_identity
             (singleton_id,active_device_id,authority_generation,initialized_at_utc)
             VALUES(1,?,1,?)''',
          [deviceId, atUtc.toUtc().toIso8601String()],
        );
        return;
      }
      if (existing.single['active_device_id'] != deviceId) {
        throw const ValidationException(
          'LOCAL_DEVICE_IDENTITY_MISMATCH',
          'The Vault identity marker differs from its active database identity. Restore or rebind the Vault explicitly.',
        );
      }
    });
  }

  /// Establishes a new local identity and authorization generation in a
  /// validated staging Vault before a backup restore is published.
  /// Historical devices, events, approvals, profiles, and remote epochs are
  /// retained for audit, but their credentials and approvals lose authority.
  Future<String> prepareRestoredInstallation({
    required String restoredFromBackupId,
    required DateTime atUtc,
  }) async {
    final cleanBackupId = restoredFromBackupId.trim();
    if (cleanBackupId.isEmpty) {
      throw ArgumentError.value(restoredFromBackupId, 'restoredFromBackupId');
    }
    final instant = atUtc.toUtc();
    final newDeviceId = newUuidV7(at: instant);
    final newGeneration = transaction((tx) {
      final vaultRows = tx.query(
        'SELECT vault_id FROM vaults ORDER BY created_at_utc',
      );
      if (vaultRows.length != 1) {
        throw const ValidationException(
          'RESTORE_VAULT_METADATA_INVALID',
          'A restored database must contain exactly one Vault identity.',
        );
      }
      final identityRows = tx.query(
        'SELECT authority_generation FROM local_installation_identity WHERE singleton_id=1',
      );
      final previousGeneration = identityRows.isEmpty
          ? 1
          : _asInt(identityRows.single['authority_generation']);
      final generation = previousGeneration + 1;
      final deviceRows = tx.query(
        'SELECT COALESCE(MAX(lamport),0) AS max_lamport FROM devices',
      );
      final eventRows = tx.query('''SELECT MAX(lamport) AS max_lamport FROM (
             SELECT lamport FROM mutation_events
             UNION ALL SELECT lamport FROM sync_remote_events
           )''');
      final lamport = [
        _asInt(deviceRows.single['max_lamport']),
        eventRows.single['max_lamport'] == null
            ? 0
            : _asInt(eventRows.single['max_lamport']),
      ].reduce((left, right) => left > right ? left : right);
      tx.execute(
        '''INSERT INTO devices(device_id,vault_id,display_name,seq,lamport)
           VALUES(?,?,?,0,?)''',
        [newDeviceId, vaultRows.single['vault_id'], 'This device', lamport],
      );
      if (identityRows.isEmpty) {
        tx.execute(
          '''INSERT INTO local_installation_identity
             (singleton_id,active_device_id,authority_generation,initialized_at_utc,restored_from_backup_id)
             VALUES(1,?,?,?,?)''',
          [newDeviceId, generation, instant.toIso8601String(), cleanBackupId],
        );
      } else {
        tx.execute(
          '''UPDATE local_installation_identity
             SET active_device_id=?,authority_generation=?,initialized_at_utc=?,restored_from_backup_id=?
             WHERE singleton_id=1''',
          [newDeviceId, generation, instant.toIso8601String(), cleanBackupId],
        );
      }
      tx.execute(
        '''UPDATE approval_receipts SET revoked_at_utc=COALESCE(revoked_at_utc,?)
           WHERE revoked_at_utc IS NULL''',
        [instant.toIso8601String()],
      );
      tx.execute(
        '''UPDATE ai_provider_profiles SET enabled=0,secret_ref=NULL
           WHERE authority_generation<>?''',
        [generation],
      );
      tx.execute(
        '''UPDATE ai_consent_receipts SET revoked_at_utc=COALESCE(revoked_at_utc,?)
           WHERE revoked_at_utc IS NULL''',
        [instant.toIso8601String()],
      );
      tx.execute(
        '''UPDATE todo_integration_state
           SET primary_device_id=?,secret_ref=NULL,delta_cursor=NULL,takeover_approval_ref=NULL,
               needs_reauthorization=1
           WHERE integration_id IS NOT NULL''',
        [newDeviceId],
      );
      tx.execute('UPDATE remote_targets SET secret_ref=NULL');
      return generation;
    });

    final markerPath = p.join(p.dirname(filePath), '.local-device-id');
    final markerFile = File(markerPath);
    final temporary = File('$markerPath.partial-${newUuidV7(at: instant)}');
    await temporary.writeAsString(newDeviceId, flush: true);
    try {
      if (await markerFile.exists()) await markerFile.delete();
      await temporary.rename(markerPath);
    } on Object {
      if (await temporary.exists()) await temporary.delete();
      rethrow;
    }
    if (activeDeviceId != newDeviceId || authorityGeneration != newGeneration) {
      throw StateError(
        'Restored installation identity failed read-back validation.',
      );
    }
    return newDeviceId;
  }

  Future<void> close() async {
    if (_closed) return;
    if (_transactionOpen) {
      throw StateError('Cannot close the database during a transaction.');
    }
    _database.close();
    _closed = true;
  }

  void _applyMigrations() {
    var version = _database.userVersion;
    if (version > currentSchemaVersion) {
      throw UnsupportedSchemaVersionException(version, currentSchemaVersion);
    }

    if (version == 0) {
      final hasLegacyTables = _database
          .select(
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name='projects'",
          )
          .isNotEmpty;
      if (hasLegacyTables) {
        final hasVaults = _database
            .select(
              "SELECT 1 FROM sqlite_master WHERE type='table' AND name='vaults'",
            )
            .isNotEmpty;
        if (!hasVaults) {
          throw const ValidationException(
            'MIGRATION_STATE_UNRECOGNIZED',
            'The existing database has project data but no Vault table.',
          );
        }
      } else {
        transaction((tx) {
          for (final statement in initialSchemaStatements) {
            tx.execute(statement);
          }
          return null;
        });
      }
      _database.userVersion = 1;
      version = 1;
    }

    if (version < 2) {
      transaction((tx) {
        for (final statement in schemaV2Statements) {
          tx.execute(statement);
        }
        return null;
      });
      _database.userVersion = 2;
      version = 2;
    }

    if (version < 3) {
      transaction((tx) {
        for (final statement in schemaV3Statements) {
          tx.execute(statement);
        }
        return null;
      });
      _database.userVersion = 3;
      version = 3;
    }

    if (version < 4) {
      transaction((tx) {
        for (final statement in schemaV4Statements) {
          tx.execute(statement);
        }
        return null;
      });
      _database.userVersion = 4;
      version = 4;
    }

    if (version < 5) {
      transaction((tx) {
        for (final statement in schemaV5Statements) {
          tx.execute(statement);
        }
        return null;
      });
      _database.userVersion = 5;
    }
  }

  void _ensureOpen() {
    if (_closed) throw StateError('WorkspaceDatabase is closed.');
  }

  static List<DbRow> _rows(ResultSet result) => result
      .map(
        (row) => Map<String, Object?>.unmodifiable(
          row.map((key, value) => MapEntry(key, value as Object?)),
        ),
      )
      .toList(growable: false);
}

final class WorkspaceTransaction {
  WorkspaceTransaction._(this._owner, this._database);

  final WorkspaceDatabase _owner;
  final Database _database;
  int _savepointSequence = 0;

  List<DbRow> query(String sql, [List<Object?> bindings = const <Object?>[]]) {
    _owner._ensureOpen();
    return WorkspaceDatabase._rows(_database.select(sql, bindings));
  }

  int execute(String sql, [List<Object?> bindings = const <Object?>[]]) {
    _owner._ensureOpen();
    _database.execute(sql, bindings);
    return _database.updatedRows;
  }

  /// Runs one projection step inside a nested SQLite savepoint.
  ///
  /// Remote event appliers use this so a blocked or conflicting payload cannot
  /// leave partial domain rows behind while the outer transaction records its
  /// review state.
  T savepoint<T>(T Function() callback) {
    _owner._ensureOpen();
    final name = 'workspace_sp_${_savepointSequence++}';
    _database.execute('SAVEPOINT $name');
    try {
      final result = callback();
      _database.execute('RELEASE SAVEPOINT $name');
      return result;
    } on Object {
      try {
        _database.execute('ROLLBACK TO SAVEPOINT $name');
      } finally {
        _database.execute('RELEASE SAVEPOINT $name');
      }
      rethrow;
    }
  }

  MutationEvent? findMutationByCommandId(String commandId) {
    final rows = query(
      'SELECT event_id, command_id, device_id, seq, lamport, entity_kind, '
      'entity_id, base_revision, event_type, action, payload_json, '
      'asset_sha_refs_json, created_at_utc FROM mutation_events '
      'WHERE command_id = ? LIMIT 1',
      [commandId],
    );
    return rows.isEmpty ? null : _mutationFromRow(rows.single);
  }

  /// Appends one immutable mutation and a matching outbox record. Reusing the
  /// same command id with the same event returns the original event; reusing it
  /// for a different event is rejected.
  MutationEvent appendMutation(MutationEventDraft draft) {
    final payload = draft.payload;
    final prior = findMutationByCommandId(draft.command.commandId);
    if (prior != null) {
      final sameEvent =
          prior.entityType == draft.entityType &&
          prior.entityId == draft.entityId &&
          prior.eventType == draft.eventType &&
          prior.action == draft.action &&
          prior.payloadJson == jsonEncode(payload);
      if (!sameEvent) {
        throw ValidationException(
          'COMMAND_ID_REUSED',
          'Command ' +
              draft.command.commandId +
              ' was already used for another event.',
          details: {'command_id': draft.command.commandId},
        );
      }
      return prior;
    }

    if (draft.entityType.isEmpty ||
        draft.entityId.isEmpty ||
        draft.eventType.isEmpty) {
      throw const ValidationException(
        'MUTATION_EVENT_INVALID',
        'Mutation entity type, entity id, and event type are required.',
      );
    }
    final shaPattern = RegExp(r'^[a-f0-9]{64}$');
    if (draft.assetShaRefs.any((sha) => !shaPattern.hasMatch(sha))) {
      throw const ValidationException(
        'MUTATION_SHA_INVALID',
        'Mutation asset SHA references must be lowercase SHA-256 digests.',
      );
    }

    final deviceRows = query(
      'SELECT d.seq, d.lamport, d.vault_id FROM devices d WHERE d.device_id = ?',
      [draft.deviceId],
    );
    if (deviceRows.isEmpty) {
      throw MissingEntityException('Device', draft.deviceId);
    }
    final currentSeq = _asInt(deviceRows.single['seq']);
    final currentLamport = _asInt(deviceRows.single['lamport']);
    final nextSeq = currentSeq + 1;
    final nextLamport = currentLamport + 1;
    final changed = execute(
      'UPDATE devices SET seq = ?, lamport = ? WHERE device_id = ? AND seq = ?',
      [nextSeq, nextLamport, draft.deviceId, currentSeq],
    );
    if (changed != 1) {
      throw const ValidationException(
        'DEVICE_SEQUENCE_CONFLICT',
        'The local device event sequence changed during the transaction.',
      );
    }

    final eventId = newUuidV7(at: draft.command.normalizedUtcTime);
    final event = MutationEvent(
      eventId: eventId,
      commandId: draft.command.commandId,
      deviceId: draft.deviceId,
      sequence: nextSeq,
      lamport: nextLamport,
      entityType: draft.entityType,
      entityId: draft.entityId,
      baseRevision: draft.command.baseRevision,
      eventType: draft.eventType,
      action: draft.action,
      payloadJson: jsonEncode(payload),
      assetShaRefs: List.unmodifiable(draft.assetShaRefs),
      createdAtUtc: draft.command.normalizedUtcTime,
    );

    execute(
      'INSERT INTO mutation_events '
      '(event_id,device_id,seq,lamport,entity_kind,entity_id,base_revision,'
      'action,payload_json,created_at_utc,command_id,asset_sha_refs_json,event_type) '
      'VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)',
      [
        event.eventId,
        event.deviceId,
        event.sequence,
        event.lamport,
        event.entityType,
        event.entityId,
        event.baseRevision,
        event.action.wireValue,
        event.payloadJson,
        event.createdAtUtc.toUtc().toIso8601String(),
        event.commandId,
        jsonEncode(event.assetShaRefs),
        event.eventType,
      ],
    );
    if (event.eventType != 'approval.issued' &&
        event.eventType != 'approval.revoked') {
      final vaultId = deviceRows.single['vault_id'] as String;
      execute(
        'INSERT INTO outbox '
        '(outbox_id,event_type,payload_json,idempotency_key,next_attempt_at_utc,state,attempts) '
        'VALUES(?,?,?,?,?,?,0)',
        [
          event.eventId,
          event.eventType,
          jsonEncode(event.toSyncDocument(vaultId)),
          event.commandId,
          event.createdAtUtc.toUtc().toIso8601String(),
          'pending',
        ],
      );
    }
    return event;
  }

  void requireApproval({
    required ApprovalRef approvalRef,
    required String action,
    required String subjectType,
    required String subjectId,
    required DateTime atUtc,
    Map<String, Object?> requiredScope = const <String, Object?>{},
  }) {
    final rows = query(
      'SELECT action,subject_type,subject_id,scope_json,expires_at_utc,revoked_at_utc,'
      'issuer_device_id,authority_generation '
      'FROM approval_receipts WHERE approval_ref = ?',
      [approvalRef.value],
    );
    if (rows.isEmpty) {
      throw const ValidationException(
        'APPROVAL_REQUIRED',
        'A matching user approval is required for this action.',
      );
    }
    final row = rows.single;
    final revokedAt = row['revoked_at_utc'] as String?;
    final expiresAt = row['expires_at_utc'] as String?;
    final approvedAction = row['action'] as String;
    final approvedSubjectType = row['subject_type'] as String;
    final approvedSubjectId = row['subject_id'] as String;
    final issuerDeviceId = row['issuer_device_id'] as String?;
    final issuedGeneration = row['authority_generation'] == null
        ? null
        : _asInt(row['authority_generation']);
    final decodedScope = jsonDecode(row['scope_json'] as String);
    if (decodedScope is! Map) {
      throw const ValidationException(
        'APPROVAL_SCOPE_INVALID',
        'The stored approval scope is invalid.',
      );
    }
    final scopeMatches =
        canonicalJson(decodedScope) == canonicalJson(requiredScope);
    final instant = atUtc.toUtc();
    final expired =
        expiresAt != null &&
        !instant.isBefore(DateTime.parse(expiresAt).toUtc());
    if (revokedAt != null ||
        expired ||
        approvedAction != action ||
        approvedSubjectType != subjectType ||
        approvedSubjectId != subjectId ||
        issuerDeviceId != _owner.activeDeviceId ||
        issuedGeneration != _owner.authorityGeneration ||
        !scopeMatches) {
      throw const ValidationException(
        'APPROVAL_SCOPE_MISMATCH',
        'The stored approval does not cover this action or subject.',
      );
    }
  }
}

MutationEvent _mutationFromRow(DbRow row) => MutationEvent(
  eventId: row['event_id'] as String,
  commandId: row['command_id'] as String,
  deviceId: row['device_id'] as String,
  sequence: _asInt(row['seq']),
  lamport: _asInt(row['lamport']),
  entityType: row['entity_kind'] as String,
  entityId: row['entity_id'] as String,
  baseRevision: row['base_revision'] == null
      ? null
      : _asInt(row['base_revision']),
  eventType: row['event_type'] as String,
  action: MutationAction.values.byName(row['action'] as String),
  payloadJson: row['payload_json'] as String,
  assetShaRefs:
      (jsonDecode(row['asset_sha_refs_json'] as String) as List<dynamic>)
          .cast<String>(),
  createdAtUtc: DateTime.parse(row['created_at_utc'] as String).toUtc(),
);

int _asInt(Object? value) => switch (value) {
  int number => number,
  BigInt number => number.toInt(),
  _ => throw FormatException('Expected integer database value, got $value.'),
};
