import 'dart:convert';

import 'package:lab_core/src/application/task_reminder_service.dart';
import 'package:lab_core/src/domain/commands.dart';
import 'package:lab_core/src/domain/ids.dart';
import 'package:lab_core/src/domain/records.dart';
import 'package:lab_core/src/integrations/microsoft_todo_sync_service.dart';
import 'package:lab_core/src/persistence/workspace_database.dart';

/// Explicit, opt-in Graph delta import. Task mutations, link revisions, conflict
/// snapshots and the delta cursor commit together so a failed page never loses
/// changes and imported rows do not loop back into the push queue.
final class MicrosoftTodoImportService {
  MicrosoftTodoImportService({
    required this.database,
    required this.tasks,
    required this.repository,
    required this.graph,
    required this.currentDeviceId,
  });

  final WorkspaceDatabase database;
  final TaskService tasks;
  final MicrosoftTodoRepository repository;
  final MicrosoftGraphTodoClient graph;
  final String currentDeviceId;

  Future<MicrosoftTodoImportPreview> previewPull() async {
    final batch = await _readDelta();
    final open = await openConflicts();
    return MicrosoftTodoImportPreview(
      changeCount: batch.changes.length,
      deletionCount: batch.changes.where((task) => task.deleted).length,
      pageCount: batch.pageCount,
      pendingConflicts: open.length,
    );
  }

  Future<MicrosoftTodoImportResult> pull() async {
    final batch = await _readDelta();
    final profile = await _requireImportEnabled();
    final now = DateTime.now().toUtc();
    var created = 0;
    var updated = 0;
    var deleted = 0;
    var linked = 0;
    var conflicts = 0;
    database.transaction((tx) {
      final stateRows = tx.query(
        'SELECT primary_device_id,profile_json,secret_ref,delta_cursor,authority_generation,needs_reauthorization FROM todo_integration_state WHERE integration_id=?',
        [_integrationId],
      );
      if (stateRows.isEmpty || stateRows.single['primary_device_id'] != currentDeviceId ||
          currentDeviceId != database.activeDeviceId ||
          _asInt(stateRows.single['authority_generation']) != database.authorityGeneration ||
          stateRows.single['needs_reauthorization'] == 1) {
        throw const MicrosoftTodoException('TODO_IMPORT_PRIMARY_DEVICE_REQUIRED', 'Only the approved primary device may import remote tasks.');
      }
      final state = stateRows.single;
      if (state['delta_cursor'] != batch.startCursor) {
        throw const MicrosoftTodoException('TODO_IMPORT_CURSOR_CHANGED', 'The To Do delta cursor changed during import; preview and retry.');
      }
      final savedProfile = _decodeProfile(state['profile_json']);
      if (!savedProfile.enabled || !savedProfile.importRemoteTasks ||
          savedProfile.listId != profile.listId ||
          savedProfile.clientId != profile.clientId ||
          savedProfile.tenantId != profile.tenantId ||
          state['secret_ref'] != profile.secretRef?.value ||
          state['secret_ref'] != batch.secretRef) {
        throw const MicrosoftTodoException('TODO_IMPORT_OPT_IN_REQUIRED', 'Remote import was disabled or its account/list changed before commit.');
      }

      // Graph does not guarantee delta order and may return an entity more than
      // once. Identical repeats are harmless; distinct snapshots require review.
      final latest = <String, MicrosoftTodoRemoteTask>{};
      final variants = <String, Map<String, MicrosoftTodoRemoteTask>>{};
      for (final change in batch.changes) {
        latest[change.taskId] = change;
        variants.putIfAbsent(change.taskId, () => {})[
          jsonEncode(_remoteSnapshot(change, accountScopeId: profile.accountScopeId!))
        ] = change;
      }
      for (final remote in latest.values) {
        final taskVariants = variants[remote.taskId]!.values.toList(growable: false);
        if (taskVariants.length > 1) {
          final existing = tx.query(
            '''SELECT 1 FROM todo_import_conflicts c
               LEFT JOIN todo_conflict_resolutions r ON r.conflict_id=c.conflict_id
               WHERE c.integration_id=? AND c.account_scope_id=? AND c.ms_list_id=? AND c.ms_task_id=? AND r.conflict_id IS NULL''',
            [_integrationId, profile.accountScopeId, profile.listId, remote.taskId],
          );
          if (existing.isEmpty) {
            final linked = tx.query(
              'SELECT task_id FROM todo_links WHERE ms_account_id=? AND ms_list_id=? AND ms_task_id=?',
              [profile.accountScopeId, profile.listId, remote.taskId],
            );
            final localRows = linked.isEmpty
                ? const <DbRow>[]
                : tx.query('SELECT * FROM local_tasks WHERE task_id=?', [linked.single['task_id']]);
            _appendConflict(
              tx,
              remote,
              accountScopeId: profile.accountScopeId!,
              taskId: linked.isEmpty ? null : linked.single['task_id'] as String,
              localRevision: localRows.isEmpty ? null : _asInt(localRows.single['revision']),
              localSnapshot: {
                'delta_ambiguous': true,
                'local': localRows.isEmpty ? const {} : _localSnapshot(localRows.single),
                'delta_variants': taskVariants.map((task) => _remoteSnapshot(task, accountScopeId: profile.accountScopeId!)).toList(growable: false),
              },
              now: now,
            );
          }
          conflicts++;
          continue;
        }
        final linkRows = tx.query(
          'SELECT task_id,ms_etag,local_revision,status FROM todo_links WHERE ms_account_id=? AND ms_list_id=? AND ms_task_id=?',
          [profile.accountScopeId, profile.listId, remote.taskId],
        );
        if (linkRows.length > 1) {
          _appendConflict(tx, remote, accountScopeId: profile.accountScopeId!, taskId: null, localRevision: null,
              localSnapshot: {'error': 'duplicate_local_links', 'task_ids': linkRows.map((row) => row['task_id']).toList()}, now: now);
          conflicts++;
          continue;
        }
        if (linkRows.isEmpty) {
          final correlationId = remote.correlationId;
          final correlated = correlationId == null
              ? const <DbRow>[]
              : tx.query('SELECT * FROM local_tasks WHERE task_id=?', [correlationId]);
          if (correlated.isNotEmpty) {
            final localRow = correlated.single;
            final localId = localRow['task_id']! as String;
            final localRevision = _asInt(localRow['revision']);
            final isLocallyDeleted = localRow['deleted_at_utc'] != null;
            if (remote.deleted) {
              _appendConflict(tx, remote, accountScopeId: profile.accountScopeId!, taskId: localId, localRevision: localRevision,
                  localSnapshot: _localSnapshot(localRow), now: now);
              conflicts++;
              continue;
            }
            final same = !remote.deleted && !isLocallyDeleted &&
                localRow['title'] == remote.title &&
                _sameDate(localRow['due_at_utc'], remote.dueAtUtc) &&
                ((localRow['state'] == 'completed') == remote.completed);
            _saveLink(tx, taskId: localId, remote: remote, accountScopeId: profile.accountScopeId!,
              status: remote.deleted ? 'remote_deleted' : (same ? 'synced' : 'pending'),
              localRevision: same || remote.deleted ? localRevision : 0,
              now: now);
            linked++;
            continue;
          }
          if (remote.deleted) continue;
          if (remote.title.trim().isEmpty) {
            _appendConflict(tx, remote, accountScopeId: profile.accountScopeId!, taskId: null, localRevision: null,
                localSnapshot: const {'state': 'not_imported'}, now: now);
            conflicts++;
            continue;
          }
          final task = tasks.createTaskInTransaction(
            tx,
            title: remote.title,
            dueAtUtc: remote.dueAtUtc,
            completed: remote.completed,
            completedAtUtc: remote.completedAtUtc,
            command: _command(remote.taskId, now),
          );
          _saveLink(tx, taskId: task.taskId, remote: remote, accountScopeId: profile.accountScopeId!,
            status: 'synced', localRevision: task.revision, now: now);
          created++;
          continue;
        }

        final link = linkRows.single;
        final localId = link['task_id']! as String;
        final localRows = tx.query('SELECT * FROM local_tasks WHERE task_id=?', [localId]);
        if (localRows.isEmpty) {
          _appendConflict(tx, remote, accountScopeId: profile.accountScopeId!, taskId: localId, localRevision: null,
              localSnapshot: const {'error': 'linked_local_task_missing'}, now: now);
          conflicts++;
          continue;
        }
        final local = localRows.single;
        final localRevision = _asInt(local['revision']);
        final linkedRevision = _asInt(link['local_revision']);
        final etagChanged = remote.deleted || remote.etag.isNotEmpty && remote.etag != link['ms_etag'];
        if (localRevision > linkedRevision) {
          if (etagChanged) {
            _appendConflict(tx, remote, accountScopeId: profile.accountScopeId!, taskId: localId, localRevision: localRevision,
                localSnapshot: _localSnapshot(local), now: now);
            conflicts++;
          }
          continue;
        }
        if (!etagChanged) continue;
        if (!remote.deleted && remote.title.trim().isEmpty) {
          _appendConflict(tx, remote, accountScopeId: profile.accountScopeId!, taskId: localId, localRevision: localRevision,
              localSnapshot: _localSnapshot(local), now: now);
          conflicts++;
          continue;
        }
        if (!remote.deleted && local['deleted_at_utc'] != null) {
          final restored = tasks.createTaskInTransaction(
            tx,
            title: remote.title,
            dueAtUtc: remote.dueAtUtc,
            completed: remote.completed,
            completedAtUtc: remote.completedAtUtc,
            command: _command(remote.taskId, now),
          );
          tx.execute(
            '''UPDATE todo_links SET ms_task_id=NULL,ms_etag=NULL,status='superseded',updated_at_utc=?
               WHERE task_id=?''',
            [now.toIso8601String(), localId],
          );
          _saveLink(tx, taskId: restored.taskId, remote: remote, accountScopeId: profile.accountScopeId!, status: 'synced', localRevision: restored.revision, now: now);
          created++;
          continue;
        }

        TaskRecord changed;
        if (remote.deleted) {
          if (local['deleted_at_utc'] != null) {
            _saveLink(tx, taskId: localId, remote: remote, accountScopeId: profile.accountScopeId!, status: 'remote_deleted', localRevision: localRevision, now: now);
            continue;
          }
          changed = tasks.deleteTaskInTransaction(
            tx,
            taskId: localId,
            expectedRevision: localRevision,
            command: _command(remote.taskId, now),
          );
          deleted++;
          _saveLink(tx, taskId: localId, remote: remote, accountScopeId: profile.accountScopeId!, status: 'remote_deleted', localRevision: changed.revision, now: now);
          continue;
        }
        final same = local['title'] == remote.title &&
            _sameDate(local['due_at_utc'], remote.dueAtUtc) &&
            ((local['state'] == 'completed') == remote.completed);
        if (same) {
          _saveLink(tx, taskId: localId, remote: remote, accountScopeId: profile.accountScopeId!, status: 'synced', localRevision: localRevision, now: now);
          continue;
        }
        changed = tasks.updateTaskInTransaction(
          tx,
          taskId: localId,
          expectedRevision: localRevision,
          title: remote.title,
          stepId: local['step_id'] as String?,
          dueAtUtc: remote.dueAtUtc,
          completed: remote.completed,
          completedAtUtc: remote.completedAtUtc,
          command: _command(remote.taskId, now),
        );
        _saveLink(tx, taskId: localId, remote: remote, accountScopeId: profile.accountScopeId!, status: 'synced', localRevision: changed.revision, now: now);
        updated++;
      }
      if (batch.startCursor == null) {
        final linkedRows = tx.query(
          'SELECT task_id,ms_task_id,ms_etag,local_revision,status FROM todo_links WHERE ms_account_id=? AND ms_list_id=? AND ms_task_id IS NOT NULL',
          [profile.accountScopeId, profile.listId],
        );
        for (final link in linkedRows) {
          final remoteId = link['ms_task_id']! as String;
          if (latest.containsKey(remoteId)) continue;
          final hasOpenConflict = tx.query(
            '''SELECT 1 FROM todo_import_conflicts c LEFT JOIN todo_conflict_resolutions r ON r.conflict_id=c.conflict_id
               WHERE c.integration_id=? AND c.account_scope_id=? AND c.ms_list_id=? AND c.ms_task_id=? AND r.conflict_id IS NULL''',
            [_integrationId, profile.accountScopeId, profile.listId, remoteId],
          ).isNotEmpty;
          if (hasOpenConflict) continue;
          final localId = link['task_id']! as String;
          final localRows = tx.query('SELECT * FROM local_tasks WHERE task_id=?', [localId]);
          if (localRows.isEmpty) continue;
          final local = localRows.single;
          final revision = _asInt(local['revision']);
          final linkedRevision = _asInt(link['local_revision']);
          final tombstone = MicrosoftTodoRemoteTask(
            taskId: remoteId,
            listId: profile.listId,
            title: '',
            etag: link['ms_etag'] as String? ?? '',
            deleted: true,
          );
          if (local['deleted_at_utc'] != null) {
            _saveLink(tx, taskId: localId, remote: tombstone, accountScopeId: profile.accountScopeId!, status: 'remote_deleted', localRevision: revision, now: now);
          } else if (revision > linkedRevision) {
            _appendConflict(tx, tombstone, accountScopeId: profile.accountScopeId!, taskId: localId, localRevision: revision,
                localSnapshot: _localSnapshot(local), now: now);
            conflicts++;
          } else {
            final removed = tasks.deleteTaskInTransaction(
              tx,
              taskId: localId,
              expectedRevision: revision,
              command: _command(remoteId, now),
            );
            _saveLink(tx, taskId: localId, remote: tombstone, accountScopeId: profile.accountScopeId!, status: 'remote_deleted', localRevision: removed.revision, now: now);
            deleted++;
          }
        }
      }
      tx.execute(
        'UPDATE todo_integration_state SET delta_cursor=?,updated_at_utc=?,revision=revision+1 WHERE integration_id=?',
        [batch.nextCursor, now.toIso8601String(), _integrationId],
      );
      return null;
    });
    return MicrosoftTodoImportResult(
      created: created,
      updated: updated,
      deleted: deleted,
      linked: linked,
      conflicts: conflicts,
      pages: batch.pageCount,
    );
  }

  Future<List<MicrosoftTodoImportConflict>> openConflicts() async {
    final rows = database.query(
      '''SELECT c.* FROM todo_import_conflicts c
         LEFT JOIN todo_conflict_resolutions r ON r.conflict_id=c.conflict_id
         WHERE c.integration_id=? AND r.conflict_id IS NULL
         ORDER BY c.created_at_utc DESC,c.conflict_id''',
      [_integrationId],
    );
    return rows.map(_conflictFromRow).toList(growable: false);
  }

  Future<void> resolveConflict({required String conflictId, required String decision}) async {
    if (!{'keep_local', 'accept_remote', 'ignore_remote'}.contains(decision)) {
      throw const MicrosoftTodoException('TODO_CONFLICT_DECISION_INVALID', 'Choose a supported conflict resolution.');
    }
    MicrosoftTodoRemoteTask? refreshedRemote;
    final currentProfile = await repository.profile();
    if (decision != 'ignore_remote') {
      final scope = currentProfile?.accountScopeId;
      if (scope == null) {
        throw const MicrosoftTodoException('TODO_CONFLICT_ACCOUNT_CHANGED', 'Reconnect the original local authorization session before applying this conflict.');
      }
      final initialRows = database.query(
        'SELECT ms_list_id,ms_task_id,remote_snapshot_json FROM todo_import_conflicts WHERE conflict_id=? AND integration_id=?',
        [conflictId, _integrationId],
      );
      if (initialRows.isNotEmpty) {
        final storedRemote = _decodeObject(initialRows.single['remote_snapshot_json'] as String);
        if (storedRemote['account_scope_id'] != scope) {
          throw const MicrosoftTodoException('TODO_CONFLICT_ACCOUNT_CHANGED', 'This conflict belongs to a different local authorization session; only dismiss it or reconnect that session.');
        }
        final listId = initialRows.single['ms_list_id'] as String?;
        final taskId = initialRows.single['ms_task_id'] as String?;
        if (listId != null && taskId != null) {
          try {
            refreshedRemote = await graph.getTask(listId: listId, taskId: taskId);
          } on MicrosoftTodoException catch (error) {
            if (error.code != 'TODO_REMOTE_NOT_FOUND') rethrow;
            final previous = _remoteFromSnapshot(_decodeObject(initialRows.single['remote_snapshot_json'] as String));
            refreshedRemote = MicrosoftTodoRemoteTask(
              taskId: taskId,
              listId: listId,
              title: '',
              etag: previous.etag,
              deleted: true,
            );
          }
        }
      }
    }
    final now = DateTime.now().toUtc();
    database.transaction((tx) {
      final rows = tx.query(
        '''SELECT c.* FROM todo_import_conflicts c
           LEFT JOIN todo_conflict_resolutions r ON r.conflict_id=c.conflict_id
           WHERE c.conflict_id=? AND c.integration_id=? AND r.conflict_id IS NULL''',
        [conflictId, _integrationId],
      );
      if (rows.isEmpty) throw const MicrosoftTodoException('TODO_CONFLICT_NOT_OPEN', 'This To Do conflict is already resolved or unavailable.');
      final conflict = rows.single;
      final remoteMap = _decodeObject(conflict['remote_snapshot_json'] as String);
      final stateRows = tx.query('SELECT secret_ref FROM todo_integration_state WHERE integration_id=?', [_integrationId]);
      if (decision != 'ignore_remote' &&
          (stateRows.isEmpty || stateRows.single['secret_ref'] != currentProfile?.secretRef?.value)) {
        throw const MicrosoftTodoException('TODO_CONFLICT_ACCOUNT_CHANGED', 'The local authorization session changed while reviewing this conflict.');
      }
      final remote = refreshedRemote ?? _remoteFromSnapshot(remoteMap);
      final localId = conflict['task_id'] as String?;
      final localRows = localId == null ? const <DbRow>[] : tx.query('SELECT * FROM local_tasks WHERE task_id=?', [localId]);
      final local = localRows.isEmpty ? null : localRows.single;
      final expectedRevision = conflict['local_revision'] == null ? null : _asInt(conflict['local_revision']);
      if (local != null && expectedRevision != null && _asInt(local['revision']) != expectedRevision) {
        throw const MicrosoftTodoException('TODO_CONFLICT_STALE', 'The local task changed since this conflict was captured; pull again and review the new version.');
      }
      TaskRecord? resultingTask;
      var linkTaskId = localId;
      var linkStatus = 'pending';
      if (decision == 'accept_remote') {
        if (remote.deleted) {
          if (local != null && local['deleted_at_utc'] == null) {
            resultingTask = tasks.deleteTaskInTransaction(
              tx,
              taskId: localId!,
              expectedRevision: _asInt(local['revision']),
              command: _command(remote.taskId, now),
            );
          }
          linkStatus = 'remote_deleted';
        } else {
          if (remote.title.trim().isEmpty) {
            throw const MicrosoftTodoException('TODO_REMOTE_TASK_INVALID', 'This remote task has no title and cannot be accepted.');
          }
          if (local == null || local['deleted_at_utc'] != null) {
            resultingTask = tasks.createTaskInTransaction(
              tx,
              title: remote.title,
              dueAtUtc: remote.dueAtUtc,
              completed: remote.completed,
              completedAtUtc: remote.completedAtUtc,
              command: _command(remote.taskId, now),
            );
            if (localId != null && local != null) {
              tx.execute(
                '''UPDATE todo_links SET ms_task_id=NULL,ms_etag=NULL,status='superseded',
                     updated_at_utc=? WHERE task_id=?''',
                [now.toIso8601String(), localId],
              );
            }
            linkTaskId = resultingTask.taskId;
          } else {
            resultingTask = tasks.updateTaskInTransaction(
              tx,
              taskId: localId!,
              expectedRevision: _asInt(local['revision']),
              title: remote.title,
              stepId: local['step_id'] as String?,
              dueAtUtc: remote.dueAtUtc,
              completed: remote.completed,
              completedAtUtc: remote.completedAtUtc,
              command: _command(remote.taskId, now),
            );
          }
          linkStatus = 'synced';
        }
      } else if (decision == 'keep_local' && remote.deleted) {
        // Keeping a local copy of a remotely deleted item means the next
        // explicit push creates a new remote item, rather than patching a 404.
        final link = tx.query('SELECT task_id FROM todo_links WHERE task_id=?', [localId]).firstOrNull;
        if (linkTaskId != null && link != null) {
          tx.execute(
            '''UPDATE todo_links SET ms_list_id=?,ms_task_id=NULL,ms_etag=NULL,status='pending',
                 local_revision=0,updated_at_utc=? WHERE task_id=?''',
            [remote.listId, now.toIso8601String(), linkTaskId],
          );
        }
      } else if (decision == 'keep_local' && local != null) {
        _saveLink(tx, taskId: localId!, remote: remote, accountScopeId: currentProfile!.accountScopeId!, status: 'pending',
            localRevision: _asInt(local['revision']) - 1, now: now);
      }

      if (decision == 'accept_remote' && linkTaskId != null) {
        _saveLink(tx, taskId: linkTaskId, remote: remote, accountScopeId: currentProfile!.accountScopeId!, status: linkStatus,
            localRevision: resultingTask?.revision ?? (local == null ? 0 : _asInt(local['revision'])), now: now);
      }
      final selected = decision == 'accept_remote'
          ? _remoteSnapshot(remote, accountScopeId: currentProfile!.accountScopeId!)
          : _localSnapshot(local ?? const {});
      tx.execute(
        '''INSERT INTO todo_conflict_resolutions(
             resolution_id,conflict_id,decision,selected_snapshot_json,
             expected_local_revision,created_at_utc,command_id)
           VALUES(?,?,?,?,?,?,?)''',
        [newUuidV7(at: now), conflictId, decision, jsonEncode(selected), expectedRevision, now.toIso8601String(), newUuidV7(at: now)],
      );
      return null;
    });
  }

  Future<_TodoDeltaBatch> _readDelta() async {
    final profile = await _requireImportEnabled();
    final cursorRows = database.query('SELECT delta_cursor FROM todo_integration_state WHERE integration_id=?', [_integrationId]);
    if (cursorRows.isEmpty) throw const MicrosoftTodoException('TODO_PROFILE_REQUIRED', 'Configure Microsoft To Do before importing tasks.');
    final cursor = cursorRows.single['delta_cursor'] as String?;
    var requestUrl = cursor;
    var pages = 0;
    final changes = <MicrosoftTodoRemoteTask>[];
    String? finalCursor;
    try {
      while (true) {
        if (++pages > 200) throw const MicrosoftTodoException('TODO_IMPORT_PAGE_LIMIT', 'Remote task delta exceeded the local page limit.');
        final page = await graph.listTaskDeltaPage(listId: profile.listId, requestUrl: requestUrl);
        changes.addAll(page.changes);
        if (changes.length > 20000) throw const MicrosoftTodoException('TODO_IMPORT_CHANGE_LIMIT', 'Remote task delta exceeded the local change limit.');
        if (page.deltaLink != null) {
          finalCursor = page.deltaLink;
          break;
        }
        requestUrl = page.nextLink;
        if (requestUrl == null) throw const MicrosoftTodoException('TODO_GRAPH_DELTA_CURSOR_INVALID', 'Graph delta round ended without a next or delta cursor.');
      }
    } on MicrosoftTodoException catch (error) {
      if (error.code != 'TODO_GRAPH_DELTA_RESET_REQUIRED') rethrow;
      database.transaction((tx) {
        tx.execute(
          '''UPDATE todo_integration_state SET delta_cursor=NULL,updated_at_utc=?,revision=revision+1
             WHERE integration_id=? AND delta_cursor IS ? AND secret_ref=?''',
          [DateTime.now().toUtc().toIso8601String(), _integrationId, cursor, profile.secretRef!.value],
        );
        return null;
      });
      throw const MicrosoftTodoException(
        'TODO_GRAPH_DELTA_CURSOR_RESET',
        'Microsoft Graph expired its change cursor. It was cleared safely; preview again to rebuild the list state.',
      );
    }
    if (cursor == finalCursor) {
      // A completed server round may return the same state token when nothing
      // changed; this is still a valid atomic commit.
    }
    return _TodoDeltaBatch(
      startCursor: cursor,
      nextCursor: finalCursor!,
      changes: changes,
      pageCount: pages,
      secretRef: profile.secretRef!.value,
    );
  }

  Future<MicrosoftTodoProfile> _requireImportEnabled() async {
    final profile = await repository.profile();
    if (profile == null || !profile.enabled || profile.secretRef == null || profile.listId.trim().isEmpty) {
      throw const MicrosoftTodoException('TODO_PROFILE_REQUIRED', 'Microsoft To Do must be connected and a list selected.');
    }
    if (!profile.importRemoteTasks) {
      throw const MicrosoftTodoException('TODO_IMPORT_OPT_IN_REQUIRED', 'Enable remote task import before accessing the Graph delta feed.');
    }
    if (await repository.primaryDeviceId() != currentDeviceId) {
      throw const MicrosoftTodoException('TODO_IMPORT_PRIMARY_DEVICE_REQUIRED', 'Approve this device as primary before importing remote tasks.');
    }
    return profile;
  }

  void _appendConflict(
    WorkspaceTransaction tx,
    MicrosoftTodoRemoteTask remote, {
    required String accountScopeId,
    required String? taskId,
    required int? localRevision,
    required Map<String, Object?> localSnapshot,
    required DateTime now,
  }) {
    tx.execute(
      '''INSERT INTO todo_import_conflicts(
           conflict_id,integration_id,account_scope_id,task_id,ms_list_id,ms_task_id,
           local_snapshot_json,remote_snapshot_json,local_revision,remote_etag,created_at_utc,command_id)
         VALUES(?,?,?,?,?,?,?,?,?,?,?,?)''',
      [newUuidV7(at: now), _integrationId, accountScopeId, taskId, remote.listId, remote.taskId,
       jsonEncode(localSnapshot), jsonEncode(_remoteSnapshot(remote, accountScopeId: accountScopeId)), localRevision,
       remote.etag, now.toIso8601String(), newUuidV7(at: now)],
    );
  }

  static void _saveLink(
    WorkspaceTransaction tx, {
    required String taskId,
    required MicrosoftTodoRemoteTask remote,
    required String accountScopeId,
    required String status,
    required int localRevision,
    required DateTime now,
  }) {
    tx.execute(
      '''INSERT INTO todo_links(task_id,ms_list_id,ms_task_id,ms_etag,status,updated_at_utc,local_revision,ms_account_id)
         VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(task_id) DO UPDATE SET
           ms_list_id=excluded.ms_list_id,ms_task_id=excluded.ms_task_id,ms_etag=excluded.ms_etag,
           status=excluded.status,updated_at_utc=excluded.updated_at_utc,local_revision=excluded.local_revision,
           ms_account_id=excluded.ms_account_id''',
      [taskId, remote.listId, remote.taskId, remote.etag,
       status, now.toIso8601String(), localRevision, accountScopeId],
    );
  }

  static CommandMetadata _command(String remoteTaskId, DateTime now) => CommandMetadata(
        commandId: newUuidV7(at: now),
        utcTime: now,
        actor: 'microsoft_todo_import',
        sourceRef: 'microsoft_graph_task:$remoteTaskId',
      );

  static Map<String, Object?> _remoteSnapshot(MicrosoftTodoRemoteTask task, {required String accountScopeId}) => {
        'account_scope_id': accountScopeId,
        'task_id': task.taskId,
        'list_id': task.listId,
        'title': task.title,
        'etag': task.etag,
        'completed': task.completed,
        'completed_at_utc': task.completedAtUtc?.toUtc().toIso8601String(),
        'due_at_utc': task.dueAtUtc?.toUtc().toIso8601String(),
        'correlation_id': task.correlationId,
        'deleted': task.deleted,
      };

  static MicrosoftTodoImportConflict _conflictFromRow(DbRow row) => MicrosoftTodoImportConflict(
        conflictId: row['conflict_id']! as String,
        accountScopeId: row['account_scope_id']! as String,
        taskId: row['task_id'] as String?,
        remoteTaskId: row['ms_task_id']! as String,
        listId: row['ms_list_id'] as String?,
        localSnapshot: _decodeObject(row['local_snapshot_json'] as String),
        remoteSnapshot: _decodeObject(row['remote_snapshot_json'] as String),
        localRevision: row['local_revision'] == null ? null : _asInt(row['local_revision']),
        remoteEtag: row['remote_etag'] as String?,
        createdAtUtc: DateTime.parse(row['created_at_utc']! as String).toUtc(),
      );

  static MicrosoftTodoRemoteTask _remoteFromSnapshot(Map<String, Object?> value) => MicrosoftTodoRemoteTask(
        taskId: value['task_id']! as String,
        listId: value['list_id']! as String,
        title: value['title'] as String? ?? '',
        etag: value['etag'] as String? ?? '',
        completed: value['completed'] == true,
        correlationId: value['correlation_id'] as String?,
        dueAtUtc: DateTime.tryParse(value['due_at_utc'] as String? ?? '')?.toUtc(),
        completedAtUtc: DateTime.tryParse(value['completed_at_utc'] as String? ?? '')?.toUtc(),
        deleted: value['deleted'] == true,
      );

  static Map<String, Object?> _localSnapshot(Map row) => {
        if (row['task_id'] is String) 'task_id': row['task_id'],
        if (row['title'] is String) 'title': row['title'],
        if (row['state'] is String) 'state': row['state'],
        if (row['revision'] != null) 'revision': _asInt(row['revision']),
        if (row['due_at_utc'] != null) 'due_at_utc': row['due_at_utc'],
        if (row['completed_at_utc'] != null) 'completed_at_utc': row['completed_at_utc'],
        'deleted': row['deleted_at_utc'] != null,
      };

  static Map<String, Object?> _decodeObject(String json) {
    final value = jsonDecode(json);
    if (value is! Map) throw const MicrosoftTodoException('TODO_CONFLICT_SNAPSHOT_INVALID', 'Stored To Do conflict snapshot is malformed.');
    return value.map((key, entry) => MapEntry(key.toString(), entry));
  }

  static MicrosoftTodoProfile _decodeProfile(Object? json) {
    if (json is! String) throw const MicrosoftTodoException('TODO_PROFILE_INVALID', 'Stored Microsoft To Do profile is invalid.');
    final value = _decodeObject(json);
    return MicrosoftTodoProfile(
      profileId: value['profile_id'] as String? ?? _integrationId,
      listId: value['list_id'] as String? ?? '',
      secretRef: null,
      enabled: value['enabled'] == true,
      clientId: value['client_id'] as String? ?? '',
      tenantId: value['tenant_id'] as String? ?? 'common',
      importRemoteTasks: value['import_remote_tasks'] == true,
    );
  }

  static bool _sameDate(Object? local, DateTime? remote) {
    final parsed = local is String ? DateTime.tryParse(local)?.toUtc() : null;
    return parsed?.toIso8601String() == remote?.toUtc().toIso8601String();
  }

  static int _asInt(Object? value) => switch (value) {
        int number => number,
        BigInt number => number.toInt(),
        _ => int.parse(value.toString()),
      };

  static const _integrationId = 'microsoft_todo';
}

final class MicrosoftTodoImportPreview {
  const MicrosoftTodoImportPreview({required this.changeCount, required this.deletionCount, required this.pageCount, required this.pendingConflicts});
  final int changeCount;
  final int deletionCount;
  final int pageCount;
  final int pendingConflicts;
}

final class MicrosoftTodoImportResult {
  const MicrosoftTodoImportResult({required this.created, required this.updated, required this.deleted, required this.linked, required this.conflicts, required this.pages});
  final int created;
  final int updated;
  final int deleted;
  final int linked;
  final int conflicts;
  final int pages;
}

final class MicrosoftTodoImportConflict {
  const MicrosoftTodoImportConflict({required this.conflictId, required this.accountScopeId, required this.taskId, required this.remoteTaskId, required this.listId, required this.localSnapshot, required this.remoteSnapshot, required this.localRevision, required this.remoteEtag, required this.createdAtUtc});
  final String conflictId;
  final String accountScopeId;
  final String? taskId;
  final String remoteTaskId;
  final String? listId;
  final Map<String, Object?> localSnapshot;
  final Map<String, Object?> remoteSnapshot;
  final int? localRevision;
  final String? remoteEtag;
  final DateTime createdAtUtc;
}

final class _TodoDeltaBatch {
  const _TodoDeltaBatch({required this.startCursor, required this.nextCursor, required this.changes, required this.pageCount, required this.secretRef});
  final String? startCursor;
  final String nextCursor;
  final List<MicrosoftTodoRemoteTask> changes;
  final int pageCount;
  final String secretRef;
}

extension _FirstRowOrNull on Iterable<DbRow> {
  DbRow? get firstOrNull => isEmpty ? null : first;
}
