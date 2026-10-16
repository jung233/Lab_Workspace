import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:lab_core/src/domain/security.dart';

class MicrosoftTodoProfile {
  const MicrosoftTodoProfile({
    required this.profileId,
    required this.listId,
    required this.secretRef,
    required this.enabled,
    this.clientId = '',
    this.tenantId = 'common',
    this.importRemoteTasks = false,
  });
  final String profileId;
  final String listId;
  final SecretRef? secretRef;
  final bool enabled;
  /// Public OAuth application ID; it is configuration, never a credential.
  final String clientId;
  /// Tenant name or ID for Microsoft identity endpoints.
  final String tenantId;
  /// Pull/import is separate from the default local-to-Graph push behavior.
  final bool importRemoteTasks;
  /// Opaque local authorization-session scope; never a Microsoft account ID.
  String? get accountScopeId {
    final reference = secretRef?.value;
    if (reference == null) return null;
    return sha256.convert(utf8.encode('$tenantId|$clientId|$listId|$reference')).toString();
  }
}

class LocalTodoTask {
  const LocalTodoTask({
    required this.taskId,
    required this.title,
    required this.revision,
    this.dueAtUtc,
    this.completed = false,
  });
  final String taskId;
  final String title;
  final int revision;
  final DateTime? dueAtUtc;
  final bool completed;
}

class MicrosoftTodoLink {
  const MicrosoftTodoLink({
    required this.localTaskId,
    required this.listId,
    this.remoteTaskId,
    this.etag,
    this.state = 'pending',
    this.localRevision = 0,
    this.accountScopeId,
  });
  final String localTaskId;
  final String listId;
  final String? remoteTaskId;
  final String? etag;
  final String state;
  final int localRevision;
  final String? accountScopeId;
}

class MicrosoftTodoRemoteTask {
  const MicrosoftTodoRemoteTask({
    required this.taskId,
    required this.listId,
    required this.title,
    required this.etag,
    this.completed = false,
    this.correlationId,
    this.dueAtUtc,
    this.completedAtUtc,
    this.deleted = false,
  });
  final String taskId;
  final String listId;
  final String title;
  final String etag;
  final bool completed;
  final String? correlationId;
  final DateTime? dueAtUtc;
  final DateTime? completedAtUtc;
  final bool deleted;
}

class MicrosoftTodoDeltaPage {
  const MicrosoftTodoDeltaPage({required this.changes, this.nextLink, this.deltaLink});

  final List<MicrosoftTodoRemoteTask> changes;
  final String? nextLink;
  final String? deltaLink;
}

class MicrosoftTodoRemoteList {
  const MicrosoftTodoRemoteList({required this.listId, required this.displayName});

  final String listId;
  final String displayName;
}

class MicrosoftTodoSyncPreview {
  const MicrosoftTodoSyncPreview({required this.primaryDevice, required this.pendingCreate, required this.pendingUpdate, required this.conflicts});
  final bool primaryDevice;
  final int pendingCreate;
  final int pendingUpdate;
  final List<String> conflicts;
}

class MicrosoftTodoSyncResult {
  const MicrosoftTodoSyncResult({required this.created, required this.updated, required this.pending, required this.conflicts});
  final int created;
  final int updated;
  final int pending;
  final List<String> conflicts;
}

abstract interface class MicrosoftTodoRepository {
  Future<MicrosoftTodoProfile?> profile();
  Future<String?> primaryDeviceId();
  Future<List<LocalTodoTask>> pendingTasks({String? accountScopeId});
  Future<MicrosoftTodoLink?> linkFor(String taskId);
  Future<void> saveLink(MicrosoftTodoLink link);
  Future<void> recordConflict(String taskId, Map<String, Object?> local, Map<String, Object?> remote);
  Future<void> enqueueRetry(String taskId, String safeErrorCode);
  Future<void> setPrimaryDevice(String deviceId, ApprovalRef approvalRef);
}

abstract interface class MicrosoftGraphTodoClient {
  Future<List<MicrosoftTodoRemoteList>> listLists();
  Future<MicrosoftTodoRemoteTask> getTask({required String listId, required String taskId});
  Future<List<MicrosoftTodoRemoteTask>> findByCorrelationId(String listId, String correlationId);
  Future<MicrosoftTodoRemoteTask> createTask({required String listId, required String title, required String correlationId, DateTime? dueAtUtc});
  Future<MicrosoftTodoRemoteTask> updateTask({
    required String listId,
    required String taskId,
    required String ifMatchEtag,
    required String title,
    required bool completed,
    DateTime? dueAtUtc,
  });
  Future<MicrosoftTodoDeltaPage> listTaskDeltaPage({required String listId, String? requestUrl});
}

class MicrosoftTodoSyncService {
  MicrosoftTodoSyncService({
    required MicrosoftTodoRepository repository,
    required MicrosoftGraphTodoClient graph,
    required String currentDeviceId,
  })  : _repository = repository,
        _graph = graph,
        _currentDeviceId = currentDeviceId;

  final MicrosoftTodoRepository _repository;
  final MicrosoftGraphTodoClient _graph;
  final String _currentDeviceId;

  Future<MicrosoftTodoProfile?> profileStatus() => _repository.profile();

  Future<MicrosoftTodoSyncPreview> preview() async {
    final primary = await _repository.primaryDeviceId() == _currentDeviceId;
    final profile = await _repository.profile();
    final pending = await _repository.pendingTasks(accountScopeId: profile?.accountScopeId);
    var creates = 0;
    var updates = 0;
    final conflicts = <String>[];
    if (profile == null || !profile.enabled) {
      return MicrosoftTodoSyncPreview(primaryDevice: primary, pendingCreate: pending.length, pendingUpdate: 0, conflicts: const []);
    }
    if (profile.listId.trim().isEmpty) {
      throw const MicrosoftTodoException('TODO_LIST_REQUIRED', 'Select a Microsoft To Do list before previewing synchronization.');
    }
    for (final task in pending) {
      final link = await _repository.linkFor(task.taskId);
      if (link == null || link.remoteTaskId == null || link.accountScopeId != profile.accountScopeId) {
        creates++;
      } else {
        updates++;
        if (link.etag == null || link.etag!.isEmpty) conflicts.add(task.taskId);
      }
    }
    return MicrosoftTodoSyncPreview(primaryDevice: primary, pendingCreate: creates, pendingUpdate: updates, conflicts: conflicts);
  }

  Future<void> claimPrimaryDevice(ApprovalRef approvalRef) async {
    // A primary-device handover is explicit; changing it never silently creates
    // tasks on this device. The repository must atomically recheck current owner.
    await _repository.setPrimaryDevice(_currentDeviceId, approvalRef);
  }

  Future<MicrosoftTodoSyncResult> sync() async {
    final primary = await _repository.primaryDeviceId();
    if (primary != _currentDeviceId) {
      return MicrosoftTodoSyncResult(created: 0, updated: 0, pending: (await _repository.pendingTasks()).length, conflicts: const []);
    }
    final profile = await _repository.profile();
    if (profile == null || !profile.enabled || profile.secretRef == null) {
      return MicrosoftTodoSyncResult(created: 0, updated: 0, pending: (await _repository.pendingTasks()).length, conflicts: const []);
    }
    if (profile.listId.trim().isEmpty) {
      throw const MicrosoftTodoException('TODO_LIST_REQUIRED', 'Select a Microsoft To Do list before synchronizing.');
    }
    final tasks = await _repository.pendingTasks(accountScopeId: profile.accountScopeId);
    var created = 0;
    var updated = 0;
    var pending = 0;
    final conflicts = <String>[];
    for (final task in tasks) {
      try {
        final existing = await _repository.linkFor(task.taskId);
        if (existing == null || existing.remoteTaskId == null || existing.accountScopeId != profile.accountScopeId) {
          // Reconcile before create because Graph does not promise cross-device
          // idempotency keys. A retry can adopt a task created before a crash.
          final matches = await _graph.findByCorrelationId(profile.listId, task.taskId);
          if (matches.length > 1) {
            final conflict = 'duplicate_remote_tasks:${task.taskId}';
            conflicts.add(conflict);
            await _repository.recordConflict(task.taskId, _local(task), {'matches': matches.map(_remote).toList()});
            pending++;
            continue;
          }
          final remote = matches.isEmpty
              ? await _graph.createTask(
                  listId: profile.listId,
                  title: task.title,
                  correlationId: task.taskId,
                  dueAtUtc: task.dueAtUtc,
                )
              : matches.single;
          await _repository.saveLink(MicrosoftTodoLink(
            localTaskId: task.taskId,
            listId: profile.listId,
            remoteTaskId: remote.taskId,
            etag: remote.etag,
            state: 'synced',
            localRevision: task.revision,
            accountScopeId: profile.accountScopeId,
          ));
          created++;
          continue;
        }
        if (existing.etag == null || existing.etag!.isEmpty) {
          conflicts.add(task.taskId);
          await _repository.recordConflict(task.taskId, _local(task), {'error': 'missing_etag'});
          pending++;
          continue;
        }
        final remote = await _graph.updateTask(
          listId: existing.listId,
          taskId: existing.remoteTaskId!,
          ifMatchEtag: existing.etag!,
          title: task.title,
          completed: task.completed,
          dueAtUtc: task.dueAtUtc,
        );
        await _repository.saveLink(MicrosoftTodoLink(
          localTaskId: task.taskId,
          listId: remote.listId,
          remoteTaskId: remote.taskId,
          etag: remote.etag,
          state: 'synced',
          localRevision: task.revision,
          accountScopeId: profile.accountScopeId,
        ));
        updated++;
      } on MicrosoftTodoPreconditionFailed {
        conflicts.add(task.taskId);
        await _repository.recordConflict(task.taskId, _local(task), {'error': 'etag_conflict'});
        pending++;
      } on Object catch (error) {
        // The caught value is not persisted: it might contain request data.
        await _repository.enqueueRetry(task.taskId, _safeErrorCode(error));
        pending++;
      }
    }
    return MicrosoftTodoSyncResult(created: created, updated: updated, pending: pending, conflicts: conflicts);
  }

  static Map<String, Object?> _local(LocalTodoTask task) => {
        'task_id': task.taskId,
        'title': task.title,
        'revision': task.revision,
        'completed': task.completed,
        'due_at_utc': task.dueAtUtc?.toUtc().toIso8601String(),
      };

  static Map<String, Object?> _remote(MicrosoftTodoRemoteTask task) => {
        'task_id': task.taskId,
        'list_id': task.listId,
        'title': task.title,
        'etag': task.etag,
        'completed': task.completed,
      };

  static String _safeErrorCode(Object error) => error is MicrosoftTodoException ? error.code : 'TODO_SYNC_FAILED';
}

class MicrosoftTodoException implements Exception {
  const MicrosoftTodoException(this.code, this.message);
  final String code;
  final String message;
  @override
  String toString() => '$code: $message';
}

class MicrosoftTodoPreconditionFailed extends MicrosoftTodoException {
  const MicrosoftTodoPreconditionFailed() : super('TODO_ETAG_CONFLICT', 'The remote task changed.');
}
