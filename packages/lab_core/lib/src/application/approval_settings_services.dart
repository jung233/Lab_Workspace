import 'dart:convert';

import '../domain/commands.dart';
import '../domain/errors.dart';
import '../domain/events.dart';
import '../domain/ids.dart';
import '../domain/json_value.dart';
import '../domain/security.dart';
import '../domain/vault.dart';
import '../persistence/workspace_database.dart';
import '_service_support.dart';

/// Records the user's explicit approval after the client has presented the
/// action and scope. A reference is not authority outside that exact scope.
final class ApprovalService {
  const ApprovalService(this.vault);

  final VaultContext vault;
  WorkspaceDatabase get _database => vault.database;

  ApprovalRef issue({
    required String action,
    required String subjectType,
    required String subjectId,
    Map<String, Object?> scope = const <String, Object?>{},
    DateTime? expiresAtUtc,
    String? commandId,
    CommandMetadata? command,
  }) {
    final actualCommand = serviceCommand(
      command: command,
      commandId: commandId,
    );
    final cleanAction = normalizedText(action, 'action');
    final cleanSubjectType = normalizedText(subjectType, 'subjectType');
    final cleanSubjectId = normalizedText(subjectId, 'subjectId');
    if (cleanSubjectType == '*' || cleanSubjectId == '*') {
      throw const ValidationException(
        'APPROVAL_SCOPE_TOO_BROAD',
        'Approval receipts must name one exact subject.',
      );
    }
    final frozenScope = freezeJsonObject(scope);
    final expires = expiresAtUtc?.toUtc();
    if (expires != null && !expires.isAfter(actualCommand.normalizedUtcTime)) {
      throw const ValidationException(
        'APPROVAL_EXPIRY_INVALID',
        'Approval expiration must be later than approval time.',
      );
    }
    final intent = <String, Object?>{
      'action': cleanAction,
      'subject_type': cleanSubjectType,
      'subject_id': cleanSubjectId,
      'scope': frozenScope,
      'expires_at_utc': expires?.toIso8601String(),
    };
    return _database.transaction((tx) {
      final prior = tx.findMutationByCommandId(actualCommand.commandId);
      if (vault.deviceId != _database.activeDeviceId) {
        throw const ValidationException(
          'LOCAL_DEVICE_IDENTITY_MISMATCH',
          'Approval cannot be issued by a Vault context that is not the active local device.',
        );
      }
      if (prior != null) {
        final priorPayload = prior.payload;
        final priorIntent = <String, Object?>{
          'action': priorPayload['action'],
          'subject_type': priorPayload['subject_type'],
          'subject_id': priorPayload['subject_id'],
          'scope': priorPayload['scope'],
          'expires_at_utc': priorPayload['expires_at_utc'],
        };
        if (prior.entityType != 'approval' ||
            prior.eventType != 'approval.issued' ||
            prior.action != MutationAction.create ||
            canonicalJson(priorIntent) != canonicalJson(intent)) {
          throw CommandAlreadyAppliedException(actualCommand.commandId);
        }
        final existing = tx.query(
          'SELECT approval_ref,issuer_device_id,authority_generation FROM approval_receipts WHERE approval_ref=?',
          [prior.entityId],
        );
        if (existing.isEmpty)
          throw MissingEntityException('ApprovalRef', prior.entityId);
        if (existing.single['issuer_device_id'] != _database.activeDeviceId ||
            existing.single['authority_generation'] !=
                _database.authorityGeneration) {
          throw CommandAlreadyAppliedException(actualCommand.commandId);
        }
        return ApprovalRef(existing.single['approval_ref']! as String);
      }
      final approvalRef = ApprovalRef(
        newUuidV7(at: actualCommand.normalizedUtcTime),
      );
      final approvedAt = actualCommand.normalizedUtcTime.toIso8601String();
      tx.execute(
        '''INSERT INTO approval_receipts
           (approval_ref,action,subject_type,subject_id,scope_json,approved_at_utc,
            expires_at_utc,revoked_at_utc,command_id,issuer_device_id,authority_generation)
           VALUES(?,?,?,?,?,?,?,NULL,?,?,?)''',
        [
          approvalRef.value,
          cleanAction,
          cleanSubjectType,
          cleanSubjectId,
          jsonEncode(frozenScope),
          approvedAt,
          expires?.toIso8601String(),
          actualCommand.commandId,
          _database.activeDeviceId,
          _database.authorityGeneration,
        ],
      );
      appendServiceMutation(
        tx: tx,
        command: actualCommand,
        deviceId: vault.deviceId,
        entityType: 'approval',
        entityId: approvalRef.value,
        eventType: 'approval.issued',
        action: MutationAction.create,
        payload: <String, Object?>{
          ...intent,
          'approval_ref': approvalRef.value,
          'approved_at_utc': approvedAt,
        },
      );
      return approvalRef;
    });
  }

  void revoke({required ApprovalRef approvalRef, CommandMetadata? command}) {
    final actualCommand = serviceCommand(command: command);
    _database.transaction((tx) {
      final rows = tx.query(
        'SELECT action,subject_type,subject_id,revoked_at_utc FROM approval_receipts WHERE approval_ref=?',
        [approvalRef.value],
      );
      if (rows.isEmpty)
        throw MissingEntityException('ApprovalRef', approvalRef.value);
      if (rows.single['revoked_at_utc'] != null) return;
      final payload = <String, Object?>{
        'approval_ref': approvalRef.value,
        'action': rows.single['action'],
        'subject_type': rows.single['subject_type'],
        'subject_id': rows.single['subject_id'],
        'revoked_at_utc': actualCommand.normalizedUtcTime.toIso8601String(),
      };
      final prior = replayMutation(
        tx: tx,
        command: actualCommand,
        entityType: 'approval',
        entityId: approvalRef.value,
        eventType: 'approval.revoked',
        action: MutationAction.tombstone,
        payload: payload,
      );
      if (prior != null) return;
      tx.execute(
        'UPDATE approval_receipts SET revoked_at_utc=? WHERE approval_ref=? AND revoked_at_utc IS NULL',
        [actualCommand.normalizedUtcTime.toIso8601String(), approvalRef.value],
      );
      appendServiceMutation(
        tx: tx,
        command: actualCommand,
        deviceId: vault.deviceId,
        entityType: 'approval',
        entityId: approvalRef.value,
        eventType: 'approval.revoked',
        action: MutationAction.tombstone,
        payload: payload,
      );
    });
  }
}

final class SettingsValue {
  SettingsValue({
    required this.key,
    required Map<String, Object?> value,
    required this.revision,
    required this.updatedAtUtc,
  }) : value = freezeJsonObject(value);

  final String key;
  final Map<String, Object?> value;
  final int revision;
  final DateTime updatedAtUtc;
}

final class SettingsService {
  const SettingsService(this.vault);

  final VaultContext vault;
  WorkspaceDatabase get _database => vault.database;

  SettingsValue? get(String key) {
    final rows = _database.query(
      'SELECT * FROM workspace_settings WHERE setting_key=?',
      [key],
    );
    return rows.isEmpty ? null : _settingsFromRow(rows.single);
  }

  SettingsValue set({
    required String key,
    required Map<String, Object?> value,
    int? expectedRevision,
    CommandMetadata? command,
  }) {
    final cleanKey = normalizedText(key, 'setting key');
    final frozenValue = freezeJsonObject(value);
    _rejectSecretMaterial(cleanKey, frozenValue);
    final actualCommand = serviceCommand(command: command);
    final payload = <String, Object?>{
      'setting_key': cleanKey,
      'value': frozenValue,
      'expected_revision': expectedRevision,
    };
    return _database.transaction((tx) {
      final prior = replayMutation(
        tx: tx,
        command: actualCommand,
        entityType: 'setting',
        entityId: cleanKey,
        eventType: 'setting.updated',
        action: MutationAction.patch,
        payload: payload,
      );
      if (prior != null)
        return _settingsFromRow(
          tx.query('SELECT * FROM workspace_settings WHERE setting_key=?', [
            cleanKey,
          ]).single,
        );
      final rows = tx.query(
        'SELECT * FROM workspace_settings WHERE setting_key=?',
        [cleanKey],
      );
      final currentRevision = rows.isEmpty
          ? 0
          : intFromDb(rows.single['revision']);
      if (expectedRevision != currentRevision) {
        throw RevisionConflictException(
          entityType: 'setting',
          entityId: cleanKey,
          expectedRevision: expectedRevision ?? 0,
          actualRevision: currentRevision,
        );
      }
      final updatedAt = actualCommand.normalizedUtcTime.toIso8601String();
      if (rows.isEmpty) {
        tx.execute(
          '''INSERT INTO workspace_settings(setting_key,value_json,revision,updated_at_utc)
             VALUES(?,?,1,?)''',
          [cleanKey, jsonEncode(frozenValue), updatedAt],
        );
      } else {
        tx.execute(
          '''UPDATE workspace_settings SET value_json=?,revision=revision+1,updated_at_utc=?
             WHERE setting_key=? AND revision=?''',
          [jsonEncode(frozenValue), updatedAt, cleanKey, currentRevision],
        );
      }
      appendServiceMutation(
        tx: tx,
        command: actualCommand,
        deviceId: vault.deviceId,
        entityType: 'setting',
        entityId: cleanKey,
        eventType: 'setting.updated',
        action: MutationAction.patch,
        payload: payload,
      );
      return _settingsFromRow(
        tx.query('SELECT * FROM workspace_settings WHERE setting_key=?', [
          cleanKey,
        ]).single,
      );
    });
  }

  void _rejectSecretMaterial(String key, Object? value) {
    final sensitiveKey = RegExp(
      r'(api[_-]?key|password|access[_-]?token|refresh[_-]?token|credential)',
      caseSensitive: false,
    );
    if (sensitiveKey.hasMatch(key)) {
      throw const ValidationException(
        'SECRET_MUST_USE_SECURE_STORE',
        'Credentials belong in SecretStore; store only an opaque SecretRef in settings.',
      );
    }
    if (value is Map) {
      for (final entry in value.entries) {
        if (entry.key is String && sensitiveKey.hasMatch(entry.key as String)) {
          throw ValidationException(
            'SECRET_MUST_USE_SECURE_STORE',
            'Sensitive setting "${entry.key}" must use an opaque SecretRef.',
          );
        }
        _rejectSecretMaterial(key, entry.value);
      }
    } else if (value is List) {
      for (final item in value) {
        _rejectSecretMaterial(key, item);
      }
    }
  }

  SettingsValue _settingsFromRow(DbRow row) => SettingsValue(
    key: row['setting_key']! as String,
    value: objectFromDb(row['value_json']),
    revision: intFromDb(row['revision']),
    updatedAtUtc: dateFromDb(row['updated_at_utc']),
  );
}
