import '../domain/commands.dart';
import '../domain/errors.dart';
import '../domain/events.dart';
import '../domain/ids.dart';
import '../domain/records.dart';
import '../domain/vault.dart';
import '../persistence/workspace_database.dart';
import '_service_support.dart';

final class TaskService {
  const TaskService(this.vault);

  final VaultContext vault;
  WorkspaceDatabase get _database => vault.database;

  TaskRecord createTask({
    required String title,
    String? stepId,
    DateTime? dueAtUtc,
    CommandMetadata? command,
  }) {
    return _database.transaction(
      (tx) => createTaskInTransaction(
        tx,
        title: title,
        stepId: stepId,
        dueAtUtc: dueAtUtc,
        command: command,
      ),
    );
  }

  TaskRecord completeTask({
    required String taskId,
    required int expectedRevision,
    CommandMetadata? command,
  }) {
    final actualCommand = serviceCommand(command: command);
    return _database.transaction((tx) {
      final rows = tx.query('SELECT * FROM local_tasks WHERE task_id=?', [
        taskId,
      ]);
      if (rows.isEmpty) throw MissingEntityException('Task', taskId);
      final row = rows.single;
      final revision = intFromDb(row['revision']);
      final now = actualCommand.normalizedUtcTime.toIso8601String();
      final payload = <String, Object?>{
        'task_id': taskId,
        'revision': expectedRevision,
        'completed_at_utc': now,
      };
      final prior = replayMutation(
        tx: tx,
        command: actualCommand,
        entityType: 'task',
        entityId: taskId,
        eventType: 'task.completed',
        action: MutationAction.patch,
        payload: payload,
      );
      if (prior != null)
        return _taskFromRow(
          tx.query('SELECT * FROM local_tasks WHERE task_id=?', [
            taskId,
          ]).single,
        );
      if (revision != expectedRevision) {
        throw RevisionConflictException(
          entityType: 'task',
          entityId: taskId,
          expectedRevision: expectedRevision,
          actualRevision: revision,
        );
      }
      final mutationCommand = serviceCommandAtRevision(
        actualCommand,
        entityType: 'task',
        entityId: taskId,
        revision: revision,
      );
      if (row['state'] == 'completed' || row['state'] == 'cancelled') {
        throw ValidationException(
          'TASK_TERMINAL',
          'A completed or cancelled task cannot be completed again.',
        );
      }
      tx.execute(
        "UPDATE local_tasks SET state='completed',completed_at_utc=?,revision=revision+1 WHERE task_id=? AND revision=?",
        [now, taskId, expectedRevision],
      );
      appendServiceMutation(
        tx: tx,
        command: mutationCommand,
        deviceId: vault.deviceId,
        entityType: 'task',
        entityId: taskId,
        eventType: 'task.completed',
        action: MutationAction.patch,
        payload: payload,
      );
      return _taskFromRow(
        tx.query('SELECT * FROM local_tasks WHERE task_id=?', [taskId]).single,
      );
    });
  }

  /// Creates an imported or local Task within a caller-owned transaction.
  /// The caller can atomically write an integration link and delta cursor too.
  TaskRecord createTaskInTransaction(
    WorkspaceTransaction tx, {
    required String title,
    String? stepId,
    DateTime? dueAtUtc,
    bool completed = false,
    DateTime? completedAtUtc,
    CommandMetadata? command,
  }) {
    final actualCommand = serviceCommand(command: command);
    final cleanTitle = normalizedText(title, 'title');
    final due = dueAtUtc?.toUtc();
    final completedAt = completed
        ? (completedAtUtc ?? actualCommand.normalizedUtcTime).toUtc()
        : null;
    final state = completed ? 'completed' : 'open';
    final payload = <String, Object?>{
      'title': cleanTitle,
      'step_id': stepId,
      'due_at_utc': due?.toIso8601String(),
      'state': state,
      'completed_at_utc': completedAt?.toIso8601String(),
    };
    final prior = replayMutation(
      tx: tx,
      command: actualCommand,
      entityType: 'task',
      eventType: 'task.created',
      action: MutationAction.create,
      payload: payload,
    );
    if (prior != null) {
      final rows = tx.query('SELECT * FROM local_tasks WHERE task_id=?', [
        prior.entityId,
      ]);
      if (rows.isEmpty) throw MissingEntityException('Task', prior.entityId);
      return _taskFromRow(rows.single);
    }
    if (stepId != null &&
        tx.query('SELECT 1 FROM step_executions WHERE step_id=?', [
          stepId,
        ]).isEmpty) {
      throw MissingEntityException('Step', stepId);
    }
    final taskId = newUuidV7(at: actualCommand.normalizedUtcTime);
    final now = actualCommand.normalizedUtcTime.toIso8601String();
    tx.execute(
      '''INSERT INTO local_tasks
         (task_id,step_id,title,due_at_utc,state,revision,created_at_utc,
          completed_at_utc,command_id,deleted_at_utc)
         VALUES(?,?,?,?,?,1,?,?,?,NULL)''',
      [
        taskId,
        stepId,
        cleanTitle,
        due?.toIso8601String(),
        state,
        now,
        completedAt?.toIso8601String(),
        actualCommand.commandId,
      ],
    );
    appendServiceMutation(
      tx: tx,
      command: actualCommand,
      deviceId: vault.deviceId,
      entityType: 'task',
      entityId: taskId,
      eventType: 'task.created',
      action: MutationAction.create,
      payload: payload,
    );
    return _taskFromRow(
      tx.query('SELECT * FROM local_tasks WHERE task_id=?', [taskId]).single,
    );
  }

  TaskRecord updateTask({
    required String taskId,
    required int expectedRevision,
    required String title,
    String? stepId,
    DateTime? dueAtUtc,
    bool? completed,
    DateTime? completedAtUtc,
    CommandMetadata? command,
  }) {
    return _database.transaction(
      (tx) => updateTaskInTransaction(
        tx,
        taskId: taskId,
        expectedRevision: expectedRevision,
        title: title,
        stepId: stepId,
        dueAtUtc: dueAtUtc,
        completed: completed,
        completedAtUtc: completedAtUtc,
        command: command,
      ),
    );
  }

  /// Applies a complete remote Task snapshot in a caller-owned transaction.
  /// Set [completed] to true/false to import completion or reopen the Task.
  TaskRecord updateTaskInTransaction(
    WorkspaceTransaction tx, {
    required String taskId,
    required int expectedRevision,
    required String title,
    String? stepId,
    DateTime? dueAtUtc,
    bool? completed,
    DateTime? completedAtUtc,
    CommandMetadata? command,
  }) {
    final actualCommand = serviceCommand(command: command);
    final cleanTitle = normalizedText(title, 'title');
    final due = dueAtUtc?.toUtc();
    final completedAt = completed == true
        ? (completedAtUtc ?? actualCommand.normalizedUtcTime).toUtc()
        : completed == false
        ? null
        : null;
    final payload = <String, Object?>{
      'task_id': taskId,
      'expected_revision': expectedRevision,
      'title': cleanTitle,
      'step_id': stepId,
      'due_at_utc': due?.toIso8601String(),
      'completed': completed,
      'completed_at_utc': completedAt?.toIso8601String(),
    };
    final prior = replayMutation(
      tx: tx,
      command: actualCommand,
      entityType: 'task',
      entityId: taskId,
      eventType: 'task.updated',
      action: MutationAction.patch,
      payload: payload,
    );
    if (prior != null) {
      return _taskFromRow(
        tx.query('SELECT * FROM local_tasks WHERE task_id=?', [taskId]).single,
      );
    }
    final rows = tx.query('SELECT * FROM local_tasks WHERE task_id=?', [
      taskId,
    ]);
    if (rows.isEmpty) throw MissingEntityException('Task', taskId);
    final row = rows.single;
    final revision = intFromDb(row['revision']);
    if (revision != expectedRevision) {
      throw RevisionConflictException(
        entityType: 'task',
        entityId: taskId,
        expectedRevision: expectedRevision,
        actualRevision: revision,
      );
    }
    if (row['deleted_at_utc'] != null) {
      throw const ValidationException(
        'TASK_DELETED',
        'A soft-deleted Task cannot be edited.',
      );
    }
    if (stepId != null &&
        tx.query('SELECT 1 FROM step_executions WHERE step_id=?', [
          stepId,
        ]).isEmpty) {
      throw MissingEntityException('Step', stepId);
    }
    final newState = completed == null
        ? row['state']! as String
        : completed
        ? 'completed'
        : 'open';
    final newCompletedAt = completed == null
        ? row['completed_at_utc']
        : completedAt?.toIso8601String();
    final mutationCommand = serviceCommandAtRevision(
      actualCommand,
      entityType: 'task',
      entityId: taskId,
      revision: revision,
    );
    tx.execute(
      '''UPDATE local_tasks SET title=?,step_id=?,due_at_utc=?,state=?,
           completed_at_utc=?,revision=revision+1 WHERE task_id=? AND revision=?''',
      [
        cleanTitle,
        stepId,
        due?.toIso8601String(),
        newState,
        newCompletedAt,
        taskId,
        revision,
      ],
    );
    appendServiceMutation(
      tx: tx,
      command: mutationCommand,
      deviceId: vault.deviceId,
      entityType: 'task',
      entityId: taskId,
      eventType: 'task.updated',
      action: MutationAction.patch,
      payload: payload,
    );
    return _taskFromRow(
      tx.query('SELECT * FROM local_tasks WHERE task_id=?', [taskId]).single,
    );
  }

  TaskRecord deleteTask({
    required String taskId,
    required int expectedRevision,
    CommandMetadata? command,
  }) {
    return _database.transaction(
      (tx) => deleteTaskInTransaction(
        tx,
        taskId: taskId,
        expectedRevision: expectedRevision,
        command: command,
      ),
    );
  }

  TaskRecord deleteTaskInTransaction(
    WorkspaceTransaction tx, {
    required String taskId,
    required int expectedRevision,
    CommandMetadata? command,
  }) {
    final actualCommand = serviceCommand(command: command);
    final now = actualCommand.normalizedUtcTime;
    final payload = <String, Object?>{
      'task_id': taskId,
      'expected_revision': expectedRevision,
      'deleted_at_utc': now.toIso8601String(),
    };
    final prior = replayMutation(
      tx: tx,
      command: actualCommand,
      entityType: 'task',
      entityId: taskId,
      eventType: 'task.deleted',
      action: MutationAction.patch,
      payload: payload,
    );
    if (prior != null) {
      return _taskFromRow(
        tx.query('SELECT * FROM local_tasks WHERE task_id=?', [taskId]).single,
      );
    }
    final rows = tx.query('SELECT * FROM local_tasks WHERE task_id=?', [
      taskId,
    ]);
    if (rows.isEmpty) throw MissingEntityException('Task', taskId);
    final revision = intFromDb(rows.single['revision']);
    if (revision != expectedRevision) {
      throw RevisionConflictException(
        entityType: 'task',
        entityId: taskId,
        expectedRevision: expectedRevision,
        actualRevision: revision,
      );
    }
    if (rows.single['deleted_at_utc'] != null) {
      throw const ValidationException(
        'TASK_DELETED',
        'Task is already soft-deleted.',
      );
    }
    final mutationCommand = serviceCommandAtRevision(
      actualCommand,
      entityType: 'task',
      entityId: taskId,
      revision: revision,
    );
    tx.execute(
      'UPDATE local_tasks SET deleted_at_utc=?,revision=revision+1 WHERE task_id=? AND revision=?',
      [now.toIso8601String(), taskId, revision],
    );
    appendServiceMutation(
      tx: tx,
      command: mutationCommand,
      deviceId: vault.deviceId,
      entityType: 'task',
      entityId: taskId,
      eventType: 'task.deleted',
      action: MutationAction.patch,
      payload: payload,
    );
    return _taskFromRow(
      tx.query('SELECT * FROM local_tasks WHERE task_id=?', [taskId]).single,
    );
  }

  List<TaskRecord> listTasks({
    String? state,
    bool includeDeleted = false,
    int limit = 100,
    int offset = 0,
  }) {
    validatePagination(limit: limit, offset: offset);
    final bindings = <Object?>[];
    final clauses = <String>[];
    if (state != null) clauses.add('state=?');
    if (!includeDeleted) clauses.add('deleted_at_utc IS NULL');
    final where = clauses.isEmpty ? '' : ' WHERE ${clauses.join(' AND ')}';
    if (state != null) bindings.add(state);
    bindings
      ..add(limit)
      ..add(offset);
    return _database
        .query(
          'SELECT * FROM local_tasks$where ORDER BY (due_at_utc IS NULL),due_at_utc,task_id LIMIT ? OFFSET ?',
          bindings,
        )
        .map(_taskFromRow)
        .toList(growable: false);
  }

  TaskRecord _taskFromRow(DbRow row) => TaskRecord(
    taskId: row['task_id']! as String,
    stepId: row['step_id'] as String?,
    title: row['title']! as String,
    dueAtUtc: optionalDateFromDb(row['due_at_utc']),
    state: row['state']! as String,
    revision: intFromDb(row['revision']),
    createdAtUtc:
        row['created_at_utc'] is String &&
            (row['created_at_utc'] as String).isNotEmpty
        ? dateFromDb(row['created_at_utc'])
        : DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    completedAtUtc: optionalDateFromDb(row['completed_at_utc']),
    deletedAtUtc: optionalDateFromDb(row['deleted_at_utc']),
  );
}

final class ReminderService {
  const ReminderService(this.vault);

  final VaultContext vault;
  WorkspaceDatabase get _database => vault.database;

  ReminderRecord createReminder({
    required DateTime dueAtUtc,
    required int minutesBefore,
    String? taskId,
    String? stepId,
    String? permissionState,
    CommandMetadata? command,
  }) {
    if (taskId == null && stepId == null) {
      throw const ValidationException(
        'REMINDER_TARGET_REQUIRED',
        'A Reminder needs a Task or Step target.',
      );
    }
    if (minutesBefore < 0 || minutesBefore > 525600) {
      throw const ValidationException(
        'REMINDER_LEAD_INVALID',
        'Reminder lead time must be between 0 and 525600 minutes.',
      );
    }
    if (permissionState != null &&
        !const {'unknown', 'granted', 'denied'}.contains(permissionState)) {
      throw const ValidationException(
        'REMINDER_PERMISSION_INVALID',
        'Unsupported notification permission state.',
      );
    }
    final actualCommand = serviceCommand(command: command);
    final due = dueAtUtc.toUtc();
    final payload = <String, Object?>{
      'task_id': taskId,
      'step_id': stepId,
      'due_at_utc': due.toIso8601String(),
      'minutes_before': minutesBefore,
      'permission_state': permissionState ?? 'unknown',
    };
    return _database.transaction((tx) {
      final prior = replayMutation(
        tx: tx,
        command: actualCommand,
        entityType: 'reminder',
        eventType: 'reminder.created',
        action: MutationAction.create,
        payload: payload,
      );
      if (prior != null)
        return _reminderFromRow(
          tx.query('SELECT * FROM reminders WHERE reminder_id=?', [
            prior.entityId,
          ]).single,
        );
      if (taskId != null &&
          tx.query('SELECT 1 FROM local_tasks WHERE task_id=?', [
            taskId,
          ]).isEmpty) {
        throw MissingEntityException('Task', taskId);
      }
      if (stepId != null &&
          tx.query('SELECT 1 FROM step_executions WHERE step_id=?', [
            stepId,
          ]).isEmpty) {
        throw MissingEntityException('Step', stepId);
      }
      if (taskId != null && stepId != null) {
        final taskStep = tx.query(
          'SELECT step_id FROM local_tasks WHERE task_id=?',
          [taskId],
        ).single['step_id'];
        if (taskStep != null && taskStep != stepId) {
          throw const ValidationException(
            'REMINDER_TARGET_MISMATCH',
            'Task and Step Reminder targets do not match.',
          );
        }
      }
      final reminderId = newUuidV7(at: actualCommand.normalizedUtcTime);
      tx.execute(
        '''INSERT INTO reminders
           (reminder_id,task_id,step_id,due_at_utc,device_notification_id,status,last_attempt_at_utc,
            minutes_before,permission_state,delivery_state,command_id,updated_at_utc)
           VALUES(?,?,?,?,NULL,'pending',NULL,?,?, 'pending',?,?)''',
        [
          reminderId,
          taskId,
          stepId,
          due.toIso8601String(),
          minutesBefore,
          permissionState ?? 'unknown',
          actualCommand.commandId,
          actualCommand.normalizedUtcTime.toIso8601String(),
        ],
      );
      appendServiceMutation(
        tx: tx,
        command: actualCommand,
        deviceId: vault.deviceId,
        entityType: 'reminder',
        entityId: reminderId,
        eventType: 'reminder.created',
        action: MutationAction.create,
        payload: payload,
      );
      return _reminderFromRow(
        tx.query('SELECT * FROM reminders WHERE reminder_id=?', [
          reminderId,
        ]).single,
      );
    });
  }

  ReminderRecord updateDelivery({
    required String reminderId,
    required String deliveryState,
    required String status,
    required String permissionState,
    String? deviceNotificationId,
    CommandMetadata? command,
  }) {
    if (!const {
          'pending',
          'scheduled',
          'delivered',
          'denied',
          'failed',
          'cancelled',
        }.contains(deliveryState) ||
        !const {
          'pending',
          'scheduled',
          'sent',
          'failed',
          'cancelled',
        }.contains(status) ||
        !const {'unknown', 'granted', 'denied'}.contains(permissionState)) {
      throw const ValidationException(
        'REMINDER_DELIVERY_INVALID',
        'Unsupported Reminder delivery transition.',
      );
    }
    final actualCommand = serviceCommand(command: command);
    return _database.transaction((tx) {
      final rows = tx.query('SELECT * FROM reminders WHERE reminder_id=?', [
        reminderId,
      ]);
      if (rows.isEmpty) throw MissingEntityException('Reminder', reminderId);
      final before = rows.single;
      final payload = <String, Object?>{
        'reminder_id': reminderId,
        'delivery_state': deliveryState,
        'status': status,
        'permission_state': permissionState,
        'device_notification_id': deviceNotificationId,
        'attempted_at_utc': actualCommand.normalizedUtcTime.toIso8601String(),
      };
      final prior = replayMutation(
        tx: tx,
        command: actualCommand,
        entityType: 'reminder',
        entityId: reminderId,
        eventType: 'reminder.delivery_updated',
        action: MutationAction.patch,
        payload: payload,
      );
      if (prior != null)
        return _reminderFromRow(
          tx.query('SELECT * FROM reminders WHERE reminder_id=?', [
            reminderId,
          ]).single,
        );
      if (before['delivery_state'] == 'delivered' ||
          before['delivery_state'] == 'cancelled') {
        throw ValidationException(
          'REMINDER_TERMINAL',
          'Reminder delivery is already terminal.',
        );
      }
      tx.execute(
        '''UPDATE reminders SET delivery_state=?,status=?,permission_state=?,
             device_notification_id=COALESCE(?,device_notification_id),last_attempt_at_utc=?,updated_at_utc=?
           WHERE reminder_id=?''',
        [
          deliveryState,
          status,
          permissionState,
          deviceNotificationId,
          actualCommand.normalizedUtcTime.toIso8601String(),
          actualCommand.normalizedUtcTime.toIso8601String(),
          reminderId,
        ],
      );
      appendServiceMutation(
        tx: tx,
        command: actualCommand,
        deviceId: vault.deviceId,
        entityType: 'reminder',
        entityId: reminderId,
        eventType: 'reminder.delivery_updated',
        action: MutationAction.patch,
        payload: payload,
      );
      return _reminderFromRow(
        tx.query('SELECT * FROM reminders WHERE reminder_id=?', [
          reminderId,
        ]).single,
      );
    });
  }

  List<ReminderRecord> listPending({DateTime? beforeUtc, int limit = 100}) {
    validatePagination(limit: limit);
    final boundary = (beforeUtc ?? DateTime.now().toUtc())
        .toUtc()
        .toIso8601String();
    return _database
        .query(
          "SELECT * FROM reminders WHERE delivery_state IN('pending','failed') AND COALESCE(permission_state,'unknown')<>'denied' AND julianday(due_at_utc)-(minutes_before/1440.0)<=julianday(?) ORDER BY (julianday(due_at_utc)-(minutes_before/1440.0)),reminder_id LIMIT ?",
          [boundary, limit],
        )
        .map(_reminderFromRow)
        .toList(growable: false);
  }

  /// Lists reminders across all delivery and permission states for history and
  /// recovery screens. Only [listPending] applies retry-queue filtering.
  List<ReminderRecord> listReminders({
    String? deliveryState,
    int limit = 100,
    int offset = 0,
  }) {
    validatePagination(limit: limit, offset: offset);
    final bindings = <Object?>[];
    final where = deliveryState == null ? '' : ' WHERE delivery_state=?';
    if (deliveryState != null) bindings.add(deliveryState);
    bindings
      ..add(limit)
      ..add(offset);
    return _database
        .query('''SELECT * FROM reminders$where
         ORDER BY (julianday(due_at_utc)-(minutes_before/1440.0)),reminder_id
         LIMIT ? OFFSET ?''', bindings)
        .map(_reminderFromRow)
        .toList(growable: false);
  }

  ReminderRecord _reminderFromRow(DbRow row) => ReminderRecord(
    reminderId: row['reminder_id']! as String,
    taskId: row['task_id'] as String?,
    stepId: row['step_id'] as String?,
    dueAtUtc: dateFromDb(row['due_at_utc']),
    minutesBefore: intFromDb(row['minutes_before']),
    permissionState: row['permission_state'] as String?,
    deliveryState: row['delivery_state'] as String? ?? 'pending',
    status: row['status']! as String,
    lastAttemptAtUtc: optionalDateFromDb(row['last_attempt_at_utc']),
  );
}
