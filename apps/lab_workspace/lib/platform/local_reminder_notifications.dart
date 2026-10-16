import 'dart:io';
import 'dart:math';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:lab_core/lab_core.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

/// Connects durable local reminder records to each platform's OS scheduler.
/// Permission is requested only from an explicit user action in the UI.
final class LocalReminderNotifications {
  LocalReminderNotifications({
    required this.reminders,
    FlutterLocalNotificationsPlugin? plugin,
  }) : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final ReminderService reminders;
  final FlutterLocalNotificationsPlugin _plugin;
  final Random _random = Random.secure();
  final Set<int> _allocatedIds = <int>{};
  bool _initialized = false;

  Future<void> initialize() async {
    if (_initialized) return;
    tz_data.initializeTimeZones();
    await _plugin.initialize(
      settings: InitializationSettings(
        android: const AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: const DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
        ),
        windows: const WindowsInitializationSettings(
          appName: 'Lab Workspace',
          appUserModelId: 'org.labworkspace.app',
          guid: 'e9e4ad33-7a84-4e02-a1c0-7b7b2e0f5036',
        ),
      ),
      onDidReceiveNotificationResponse: _onNotificationResponse,
    );
    _initialized = true;
    await reconcileAlreadyScheduled();
  }

  /// Returns `granted`, `denied`, or `unknown` without claiming delivery.
  Future<String> requestPermission() async {
    await initialize();
    if (Platform.isAndroid) {
      final result = await _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.requestNotificationsPermission();
      return result == null
          ? 'unknown'
          : result
          ? 'granted'
          : 'denied';
    }
    if (Platform.isIOS) {
      final result = await _plugin
          .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin
          >()
          ?.requestPermissions(alert: true, sound: true, badge: false);
      return result == null
          ? 'unknown'
          : result
          ? 'granted'
          : 'denied';
    }
    // Windows permissions are controlled by OS notification settings. The
    // scheduling API returning successfully means scheduled, never delivered.
    if (Platform.isWindows) return 'unknown';
    return 'denied';
  }

  Future<List<ReminderRecord>> listPlanned() async {
    await initialize();
    return reminders.listPending(
      beforeUtc: DateTime.now().toUtc().add(const Duration(days: 366 * 5)),
      limit: 500,
    );
  }

  Future<List<ReminderRecord>> listHistory() async {
    await initialize();
    return reminders.listReminders(limit: 500);
  }

  /// Schedules unexpired local records after an explicit permission action.
  /// Existing OS schedules are matched by opaque reminder id payload and are
  /// not duplicated after app or device restart.
  Future<ReminderScheduleSummary> schedulePending({
    required String permissionState,
  }) async {
    await initialize();
    final pending = await _plugin.pendingNotificationRequests();
    final scheduledByReminder = <String, PendingNotificationRequest>{
      for (final request in pending)
        if (request.payload != null) request.payload!: request,
    };
    final planned = await listPlanned();
    var scheduled = 0;
    var failed = 0;
    var denied = 0;
    var alreadyScheduled = 0;
    for (final reminder in planned) {
      final existing = scheduledByReminder[reminder.reminderId];
      if (existing != null) {
        reminders.updateDelivery(
          reminderId: reminder.reminderId,
          deliveryState: 'scheduled',
          status: 'scheduled',
          permissionState: permissionState,
          deviceNotificationId: existing.id.toString(),
        );
        alreadyScheduled++;
        continue;
      }
      if (permissionState == 'denied') {
        reminders.updateDelivery(
          reminderId: reminder.reminderId,
          deliveryState: 'denied',
          status: 'failed',
          permissionState: 'denied',
        );
        denied++;
        continue;
      }
      if (!reminder.fireAtUtc.isAfter(DateTime.now().toUtc())) {
        reminders.updateDelivery(
          reminderId: reminder.reminderId,
          deliveryState: 'failed',
          status: 'failed',
          permissionState: permissionState,
        );
        failed++;
        continue;
      }
      if (Platform.isIOS && pending.length + scheduled >= 60) {
        reminders.updateDelivery(
          reminderId: reminder.reminderId,
          deliveryState: 'failed',
          status: 'failed',
          permissionState: permissionState,
        );
        failed++;
        continue;
      }
      try {
        final id = _allocateId(pending);
        await _plugin.zonedSchedule(
          id: id,
          title: 'Lab Workspace 提醒',
          body: '有一个本地实验任务需要处理。',
          scheduledDate: tz.TZDateTime.from(reminder.fireAtUtc, tz.UTC),
          notificationDetails: const NotificationDetails(
            android: AndroidNotificationDetails(
              'lab_workspace_reminders',
              '实验提醒',
              channelDescription: '此设备上的本地任务和实验步骤提醒。',
              importance: Importance.defaultImportance,
              priority: Priority.defaultPriority,
            ),
            iOS: DarwinNotificationDetails(),
            windows: WindowsNotificationDetails(),
          ),
          androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
          payload: reminder.reminderId,
        );
        reminders.updateDelivery(
          reminderId: reminder.reminderId,
          deliveryState: 'scheduled',
          status: 'scheduled',
          permissionState: permissionState,
          deviceNotificationId: id.toString(),
        );
        scheduled++;
      } on Object {
        reminders.updateDelivery(
          reminderId: reminder.reminderId,
          deliveryState: 'failed',
          status: 'failed',
          permissionState: permissionState,
        );
        failed++;
      }
    }
    return ReminderScheduleSummary(
      scheduled: scheduled,
      alreadyScheduled: alreadyScheduled,
      denied: denied,
      failed: failed,
    );
  }

  /// On startup, reconcile DB status with notifications restored by the OS.
  /// This performs no permission prompt and does not claim unscheduled rows.
  Future<void> reconcileAlreadyScheduled() async {
    final current = await _plugin.pendingNotificationRequests();
    final byPayload = <String, PendingNotificationRequest>{
      for (final request in current)
        if (request.payload != null) request.payload!: request,
    };
    final planned = reminders.listPending(
      beforeUtc: DateTime.now().toUtc().add(const Duration(days: 366 * 5)),
      limit: 500,
    );
    for (final reminder in planned) {
      final request = byPayload[reminder.reminderId];
      if (request == null) continue;
      reminders.updateDelivery(
        reminderId: reminder.reminderId,
        deliveryState: 'scheduled',
        status: 'scheduled',
        permissionState: reminder.permissionState ?? 'unknown',
        deviceNotificationId: request.id.toString(),
      );
    }
  }

  void _onNotificationResponse(NotificationResponse response) {
    final reminderId = response.payload;
    if (reminderId == null || reminderId.isEmpty) return;
    try {
      reminders.updateDelivery(
        reminderId: reminderId,
        deliveryState: 'delivered',
        status: 'sent',
        permissionState: 'granted',
        deviceNotificationId: response.id?.toString(),
      );
    } on Object {
      // A stale tap must not crash the OS callback.
    }
  }

  int _allocateId(List<PendingNotificationRequest> pending) {
    final occupied = <int>{
      ...pending.map((request) => request.id),
      ..._allocatedIds,
    };
    while (true) {
      final candidate = _random.nextInt(0x7fffffff);
      if (occupied.add(candidate)) {
        _allocatedIds.add(candidate);
        return candidate;
      }
    }
  }
}

final class ReminderScheduleSummary {
  const ReminderScheduleSummary({
    required this.scheduled,
    required this.alreadyScheduled,
    required this.denied,
    required this.failed,
  });

  final int scheduled;
  final int alreadyScheduled;
  final int denied;
  final int failed;
}
