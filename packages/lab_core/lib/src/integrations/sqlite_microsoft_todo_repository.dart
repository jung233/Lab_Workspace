import 'dart:convert';

import 'package:lab_core/src/domain/security.dart';
import 'package:lab_core/src/domain/ids.dart';
import 'package:lab_core/src/integrations/microsoft_todo_sync_service.dart';
import 'package:lab_core/src/persistence/workspace_database.dart';

/// Local SQLite storage for the single-device Microsoft To Do connector.
/// Account authorization remains in the platform identity adapter; the only
/// credential-like value in SQLite is an opaque secure-store reference.
final class SqliteMicrosoftTodoRepository implements MicrosoftTodoRepository {
  SqliteMicrosoftTodoRepository({required this.database, required this.currentDeviceId});

  final WorkspaceDatabase database;
  final String currentDeviceId;
  static const _integrationId = 'microsoft_todo';

  Future<void> saveProfile(MicrosoftTodoProfile profile) async {
    final existing = database.query(
      'SELECT primary_device_id,profile_json,secret_ref FROM todo_integration_state WHERE integration_id=?',
      [_integrationId],
    );
    final primary = existing.isEmpty ? currentDeviceId : existing.single['primary_device_id'] as String;
    var resetDeltaCursor = false;
    if (existing.isNotEmpty && existing.single['profile_json'] is String) {
      try {
        final previous = jsonDecode(existing.single['profile_json'] as String);
      resetDeltaCursor = previous is! Map ||
            previous['list_id'] != profile.listId ||
            previous['client_id'] != profile.clientId ||
            previous['tenant_id'] != profile.tenantId ||
            existing.single['secret_ref'] != profile.secretRef?.value;
      } on FormatException {
        resetDeltaCursor = true;
      }
    }
    database.transaction((tx) {
      tx.execute(
        '''INSERT INTO todo_integration_state(
           integration_id,primary_device_id,profile_json,secret_ref,updated_at_utc,revision,authority_generation,needs_reauthorization)
         VALUES(?,?,?,?,?,1,?,0)
         ON CONFLICT(integration_id) DO UPDATE SET
           profile_json=excluded.profile_json,secret_ref=excluded.secret_ref,
           updated_at_utc=excluded.updated_at_utc,revision=todo_integration_state.revision+1,
           authority_generation=excluded.authority_generation,needs_reauthorization=0,
           delta_cursor=CASE WHEN ?=1 THEN NULL ELSE todo_integration_state.delta_cursor END''',
      [
        _integrationId,
        primary,
        jsonEncode({
          'profile_id': profile.profileId,
          'list_id': profile.listId,
          'enabled': profile.enabled,
          'client_id': profile.clientId,
          'tenant_id': profile.tenantId,
          'import_remote_tasks': profile.importRemoteTasks,
        }),
        profile.secretRef?.value,
        DateTime.now().toUtc().toIso8601String(),
        database.authorityGeneration,
        resetDeltaCursor ? 1 : 0,
        ],
      );
      return null;
    });
  }

  @override
  Future<MicrosoftTodoProfile?> profile() async {
    final rows = database.query(
      'SELECT profile_json,secret_ref,authority_generation,needs_reauthorization FROM todo_integration_state WHERE integration_id=?',
      [_integrationId],
    );
    if (rows.isEmpty) return null;
    if (_asInt(rows.single['authority_generation']) != database.authorityGeneration ||
        rows.single['needs_reauthorization'] == 1) return null;
    final profile = jsonDecode(rows.single['profile_json'] as String);
    if (profile is! Map) return null;
    return MicrosoftTodoProfile(
      profileId: profile['profile_id'] as String? ?? _integrationId,
      listId: profile['list_id'] as String? ?? '',
      secretRef: rows.single['secret_ref'] is String ? SecretRef(rows.single['secret_ref'] as String) : null,
      enabled: profile['enabled'] == true,
      clientId: profile['client_id'] as String? ?? '',
      tenantId: profile['tenant_id'] as String? ?? 'common',
      importRemoteTasks: profile['import_remote_tasks'] == true,
    );
  }

  @override
  Future<String?> primaryDeviceId() async {
    final rows = database.query(
      'SELECT primary_device_id,authority_generation,needs_reauthorization FROM todo_integration_state WHERE integration_id=?',
      [_integrationId],
    );
    if (rows.isEmpty || _asInt(rows.single['authority_generation']) != database.authorityGeneration ||
        rows.single['needs_reauthorization'] == 1) return null;
    return rows.single['primary_device_id'] as String?;
  }

  @override
  Future<List<LocalTodoTask>> pendingTasks({String? accountScopeId}) async => database
      .query(
        '''SELECT t.task_id,t.title,t.due_at_utc,t.state,t.revision
           FROM local_tasks t LEFT JOIN todo_links l ON l.task_id=t.task_id
           WHERE t.state NOT IN('cancelled','deleted')
             AND (l.task_id IS NULL OR l.ms_account_id IS NOT ? OR COALESCE(l.status,'pending')<>'synced'
                  OR t.revision>COALESCE(l.local_revision,0))
           ORDER BY t.due_at_utc,t.task_id''',
        [accountScopeId],
      )
      .map((row) => LocalTodoTask(
            taskId: row['task_id'] as String,
            title: row['title'] as String,
            dueAtUtc: row['due_at_utc'] is String ? DateTime.parse(row['due_at_utc'] as String).toUtc() : null,
            revision: _asInt(row['revision']),
            completed: const {'completed', 'done'}.contains(row['state']),
          ))
      .toList(growable: false);

  @override
  Future<MicrosoftTodoLink?> linkFor(String taskId) async {
    final rows = database.query(
      'SELECT task_id,ms_list_id,ms_task_id,ms_etag,status,local_revision,ms_account_id FROM todo_links WHERE task_id=?',
      [taskId],
    );
    if (rows.isEmpty) return null;
    final row = rows.single;
    return MicrosoftTodoLink(
      localTaskId: row['task_id'] as String,
      listId: row['ms_list_id'] as String? ?? '',
      remoteTaskId: row['ms_task_id'] as String?,
      etag: row['ms_etag'] as String?,
      state: row['status'] as String,
      localRevision: _asInt(row['local_revision']),
      accountScopeId: row['ms_account_id'] as String?,
    );
  }

  @override
  Future<void> saveLink(MicrosoftTodoLink link) async {
    database.execute(
      '''INSERT INTO todo_links(task_id,ms_list_id,ms_task_id,ms_etag,status,updated_at_utc,local_revision,ms_account_id)
         VALUES(?,?,?,?,?,?,?,?)
         ON CONFLICT(task_id) DO UPDATE SET ms_list_id=excluded.ms_list_id,
           ms_task_id=excluded.ms_task_id,ms_etag=excluded.ms_etag,
           status=excluded.status,updated_at_utc=excluded.updated_at_utc,
           local_revision=excluded.local_revision,ms_account_id=excluded.ms_account_id''',
      [link.localTaskId, link.listId, link.remoteTaskId, link.etag, link.state,
       DateTime.now().toUtc().toIso8601String(), link.localRevision, link.accountScopeId],
    );
  }

  @override
  Future<void> recordConflict(String taskId, Map<String, Object?> local, Map<String, Object?> remote) async {
    // Preserve conflict status without copying task text or provider payloads
    // into sync diagnostics. The next review fetches the current remote record.
    final old = await linkFor(taskId);
    await saveLink(MicrosoftTodoLink(
      localTaskId: taskId,
      listId: old?.listId ?? '',
      remoteTaskId: old?.remoteTaskId,
      etag: old?.etag,
      state: 'conflict',
      localRevision: old?.localRevision ?? 0,
      accountScopeId: old?.accountScopeId,
    ));
  }

  @override
  Future<void> enqueueRetry(String taskId, String safeErrorCode) async {
    final now = DateTime.now().toUtc();
    final id = newUuidV7(at: now);
    database.execute(
      '''INSERT INTO outbox(outbox_id,event_type,payload_json,idempotency_key,next_attempt_at_utc,state,attempts,last_error)
         VALUES(?,?,?,?,?,'pending',0,?)''',
      [id, 'todo.sync_retry', jsonEncode({'task_id': taskId, 'error_code': safeErrorCode}), id, now.toIso8601String(), safeErrorCode],
    );
  }

  @override
  Future<void> setPrimaryDevice(String deviceId, ApprovalRef approvalRef) async {
    final now = DateTime.now().toUtc();
    database.transaction((tx) {
      tx.requireApproval(
        approvalRef: approvalRef,
        action: 'todo.primary_device.takeover',
        subjectType: 'todo_integration',
        subjectId: _integrationId,
        atUtc: now,
        requiredScope: {'device_id': deviceId},
      );
      final approvalRows = tx.query(
        'SELECT scope_json FROM approval_receipts WHERE approval_ref=?',
        [approvalRef.value],
      );
      if (approvalRows.isEmpty) {
        throw const MicrosoftTodoException('TODO_PRIMARY_DEVICE_APPROVAL_REQUIRED', 'A current primary-device approval is required.');
      }
      final scope = jsonDecode(approvalRows.single['scope_json'] as String);
      if (scope is! Map || scope['device_id'] != deviceId) {
        throw const MicrosoftTodoException('TODO_PRIMARY_DEVICE_APPROVAL_SCOPE_MISMATCH', 'Approval does not name this device.');
      }
      final row = tx.query(
        'SELECT revision FROM todo_integration_state WHERE integration_id=?',
        [_integrationId],
      );
      if (row.isEmpty) {
        tx.execute(
          '''INSERT INTO todo_integration_state(
               integration_id,primary_device_id,profile_json,updated_at_utc,revision,takeover_approval_ref,authority_generation,needs_reauthorization)
             VALUES(?,?,'{}',?,1,?,?,0)''',
          [_integrationId, deviceId, now.toIso8601String(), approvalRef.value, database.authorityGeneration],
        );
      } else {
        tx.execute(
          '''UPDATE todo_integration_state SET primary_device_id=?,updated_at_utc=?,
               revision=?,takeover_approval_ref=?,authority_generation=?,needs_reauthorization=0 WHERE integration_id=?''',
          [deviceId, now.toIso8601String(), _asInt(row.single['revision']) + 1, approvalRef.value, database.authorityGeneration, _integrationId],
        );
      }
      return null;
    });
  }
}

int _asInt(Object? value) => switch (value) {
      int number => number,
      BigInt number => number.toInt(),
      _ => int.parse(value.toString()),
    };
