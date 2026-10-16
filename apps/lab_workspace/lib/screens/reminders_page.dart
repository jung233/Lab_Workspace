import 'package:flutter/material.dart';
import 'package:lab_core/lab_core.dart';

import '../platform/local_reminder_notifications.dart';

class RemindersPage extends StatefulWidget {
  const RemindersPage({
    required this.tasks,
    required this.reminders,
    required this.notifications,
    super.key,
  });

  final TaskService tasks;
  final ReminderService reminders;
  final LocalReminderNotifications notifications;

  @override
  State<RemindersPage> createState() => _RemindersPageState();
}

class _RemindersPageState extends State<RemindersPage> {
  final TextEditingController _title = TextEditingController();
  DateTime _due = DateTime.now().add(const Duration(hours: 1));
  int _minutesBefore = 0;
  List<TaskRecord> _tasks = const [];
  List<ReminderRecord> _reminders = const [];
  String? _message;
  Object? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    try {
      final tasks = widget.tasks.listTasks(state: 'open', limit: 500);
      final reminders = await widget.notifications.listHistory();
      if (!mounted) return;
      setState(() {
        _tasks = tasks;
        _reminders = reminders;
        _error = null;
      });
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  Future<void> _pickDue() async {
    final now = DateTime.now();
    final selectedDate = await showDatePicker(
      context: context,
      initialDate: _due.isBefore(now) ? now : _due,
      firstDate: DateTime(now.year, now.month, now.day),
      lastDate: DateTime(now.year + 10),
    );
    if (selectedDate == null || !mounted) return;
    final selectedTime = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_due),
    );
    if (selectedTime == null || !mounted) return;
    setState(() {
      _due = DateTime(
        selectedDate.year,
        selectedDate.month,
        selectedDate.day,
        selectedTime.hour,
        selectedTime.minute,
      );
    });
  }

  Future<void> _createTaskAndReminder() async {
    final title = _title.text.trim();
    if (title.isEmpty) {
      setState(() => _error = '请先填写任务名称。');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _message = null;
    });
    try {
      final task = widget.tasks.createTask(
        title: title,
        dueAtUtc: _due.toUtc(),
      );
      final permission = await widget.notifications.requestPermission();
      final reminder = widget.reminders.createReminder(
        taskId: task.taskId,
        dueAtUtc: _due.toUtc(),
        minutesBefore: _minutesBefore,
        permissionState: permission,
      );
      if (permission == 'denied') {
        widget.reminders.updateDelivery(
          reminderId: reminder.reminderId,
          deliveryState: 'denied',
          status: 'failed',
          permissionState: 'denied',
        );
        _message = '任务和提醒计划已保存在本设备；OS 通知权限被拒绝，提醒未排入系统。';
      } else {
        final summary = await widget.notifications.schedulePending(
          permissionState: permission,
        );
        _message = _summaryText(summary, permission);
      }
      _title.clear();
      await _reload();
    } on Object catch (error) {
      setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reschedule() async {
    setState(() {
      _busy = true;
      _error = null;
      _message = null;
    });
    try {
      final permission = await widget.notifications.requestPermission();
      final summary = await widget.notifications.schedulePending(
        permissionState: permission,
      );
      _message = _summaryText(summary, permission);
      await _reload();
    } on Object catch (error) {
      setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _summaryText(ReminderScheduleSummary summary, String permission) {
    final precision = Theme.of(context).platform == TargetPlatform.android
        ? 'Android 使用非精确省电排程，系统可能延迟。'
        : 'OS 可调整或抑制通知时间。';
    return '权限状态：$permission；新增排程 ${summary.scheduled}，已存在 ${summary.alreadyScheduled}，拒绝 ${summary.denied}，失败/过期 ${summary.failed}。$precision';
  }

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(24),
    children: [
      Text('本机任务与提醒', style: Theme.of(context).textTheme.headlineMedium),
      const SizedBox(height: 8),
      const Text(
        '任务、计划时间和提醒状态保存在此设备的 Vault。创建提醒时才会请求 OS 通知权限；被拒绝、过期或排程失败的记录不会显示为已投递。',
      ),
      const SizedBox(height: 16),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('创建本地任务与提醒', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 12),
              TextField(
                controller: _title,
                decoration: const InputDecoration(
                  labelText: '任务名称',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _pickDue,
                    icon: const Icon(Icons.schedule),
                    label: Text('计划时间：${_due.toLocal()}'),
                  ),
                  DropdownButton<int>(
                    value: _minutesBefore,
                    onChanged: _busy
                        ? null
                        : (value) =>
                              setState(() => _minutesBefore = value ?? 0),
                    items: const [0, 5, 15, 30, 60]
                        .map(
                          (minutes) => DropdownMenuItem(
                            value: minutes,
                            child: Text(
                              minutes == 0 ? '到时提醒' : '提前 $minutes 分钟',
                            ),
                          ),
                        )
                        .toList(growable: false),
                  ),
                  FilledButton.icon(
                    onPressed: _busy ? null : _createTaskAndReminder,
                    icon: const Icon(Icons.add_alert),
                    label: const Text('保存并请求提醒权限'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              const Text(
                'Android 使用非精确排程；iOS 和 Windows 仍受系统通知策略、专注模式及后台限制影响。系统接受排程不代表通知已送达。',
              ),
            ],
          ),
        ),
      ),
      Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton.icon(
          onPressed: _busy ? null : _reschedule,
          icon: const Icon(Icons.restore),
          label: const Text('请求权限并恢复缺失的本机排程'),
        ),
      ),
      if (_busy) const LinearProgressIndicator(),
      if (_message != null)
        Card(
          child: ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('提醒状态'),
            subtitle: Text(_message!),
          ),
        ),
      if (_error != null)
        MaterialBanner(
          content: Text('提醒操作失败：$_error'),
          actions: [TextButton(onPressed: _reload, child: const Text('重试'))],
        ),
      const SizedBox(height: 12),
      Text('待办任务', style: Theme.of(context).textTheme.titleLarge),
      if (_tasks.isEmpty)
        const Card(child: ListTile(title: Text('暂无未完成的本地任务。')))
      else
        for (final task in _tasks)
          Card(
            child: ListTile(
              leading: const Icon(Icons.task_alt),
              title: Text(task.title),
              subtitle: Text(
                '状态：${task.state}${task.dueAtUtc == null ? '' : ' · 计划 ${task.dueAtUtc!.toLocal()}'}',
              ),
            ),
          ),
      const SizedBox(height: 12),
      Text('本机提醒队列', style: Theme.of(context).textTheme.titleLarge),
      if (_reminders.isEmpty)
        const Card(child: ListTile(title: Text('暂无待排程提醒。')))
      else
        for (final reminder in _reminders)
          Card(
            child: ListTile(
              leading: Icon(_iconFor(reminder.deliveryState)),
              title: Text(_targetTitle(reminder)),
              subtitle: Text(
                '计划触发 ${reminder.fireAtUtc.toLocal()} · 状态 ${reminder.deliveryState} · 权限 ${reminder.permissionState ?? 'unknown'}${reminder.lastAttemptAtUtc == null ? '' : ' · 最近尝试 ${reminder.lastAttemptAtUtc!.toLocal()}'}',
              ),
            ),
          ),
    ],
  );

  String _targetTitle(ReminderRecord reminder) {
    final taskId = reminder.taskId;
    if (taskId == null) return '实验步骤提醒';
    for (final task in _tasks) {
      if (task.taskId == taskId) return task.title;
    }
    return '本地任务提醒';
  }

  IconData _iconFor(String state) => switch (state) {
    'scheduled' => Icons.notifications_active_outlined,
    'delivered' => Icons.notifications,
    'denied' => Icons.notifications_off_outlined,
    'failed' => Icons.error_outline,
    _ => Icons.notifications_none,
  };
}
