import 'package:flutter/material.dart';
import 'package:lab_core/lab_core.dart';

import '../integrations/microsoft_todo_page.dart';
import '../platform/workspace_services.dart';
import '../src/ai_image/ai_image_page.dart';
import 'calculation_page.dart';
import 'experiments_page.dart';
import 'explorer_page.dart';
import 'provider_settings_page.dart';
import 'protocols_page.dart';
import 'reminders_page.dart';
import 'sync_backup_page.dart';

class WorkspaceShell extends StatefulWidget {
  const WorkspaceShell({required this.core, required this.services, super.key});

  final LabCore core;
  final WorkspaceServices services;

  @override
  State<WorkspaceShell> createState() => _WorkspaceShellState();
}

class _WorkspaceShellState extends State<WorkspaceShell> {
  int _selected = 0;

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 850;
    final pages = <Widget>[
      _OverviewPage(core: widget.core),
      AssetExplorerScreen(
        assets: widget.services.assets,
        approvals: widget.core.approvals,
      ),
      ExperimentsPage(core: widget.core),
      CalculationPage(
        packs: widget.services.packRegistry,
        calculations: widget.services.calculations,
        approvals: widget.core.approvals,
      ),
      AiImagePage(
        core: widget.core,
        assets: widget.services.assets,
        secretStore: widget.services.secretStore,
        packRegistry: widget.services.packRegistry,
      ),
      SyncBackupPage(
        core: widget.core,
        sync: widget.services.sync,
        backups: widget.services.backups,
        secretStore: widget.services.secretStore,
      ),
      MicrosoftTodoPage(
        core: widget.core,
        secretStore: widget.services.secretStore,
      ),
      RemindersPage(
        tasks: widget.services.tasks,
        reminders: widget.services.reminders,
        notifications: widget.services.localNotifications,
      ),
      ProviderSettingsPage(core: widget.core),
      ProtocolsPage(core: widget.core),
    ];
    return Scaffold(
      drawer: wide
          ? null
          : Drawer(
              child: NavigationDrawer(
                selectedIndex: _selected,
                onDestinationSelected: (value) {
                  Navigator.pop(context);
                  setState(() => _selected = value);
                },
                children: const [
                  Padding(
                    padding: EdgeInsets.fromLTRB(28, 16, 16, 10),
                    child: Text('Lab Workspace'),
                  ),
                  NavigationDrawerDestination(
                    icon: Icon(Icons.dashboard_outlined),
                    selectedIcon: Icon(Icons.dashboard),
                    label: Text('概览'),
                  ),
                  NavigationDrawerDestination(
                    icon: Icon(Icons.folder_open_outlined),
                    selectedIcon: Icon(Icons.folder_open),
                    label: Text('文件'),
                  ),
                  NavigationDrawerDestination(
                    icon: Icon(Icons.science_outlined),
                    selectedIcon: Icon(Icons.science),
                    label: Text('实验'),
                  ),
                  NavigationDrawerDestination(
                    icon: Icon(Icons.functions_outlined),
                    selectedIcon: Icon(Icons.functions),
                    label: Text('计算与 Pack'),
                  ),
                  NavigationDrawerDestination(
                    icon: Icon(Icons.image_search_outlined),
                    selectedIcon: Icon(Icons.image_search),
                    label: Text('AI 与图像'),
                  ),
                  NavigationDrawerDestination(
                    icon: Icon(Icons.cloud_sync_outlined),
                    selectedIcon: Icon(Icons.cloud_sync),
                    label: Text('同步与备份'),
                  ),
                  NavigationDrawerDestination(
                    icon: Icon(Icons.checklist_outlined),
                    selectedIcon: Icon(Icons.checklist),
                    label: Text('Microsoft To Do'),
                  ),
                  NavigationDrawerDestination(
                    icon: Icon(Icons.notifications_active_outlined),
                    selectedIcon: Icon(Icons.notifications_active),
                    label: Text('本机提醒'),
                  ),
                  NavigationDrawerDestination(
                    icon: Icon(Icons.tune_outlined),
                    selectedIcon: Icon(Icons.tune),
                    label: Text('AI Provider 设置'),
                  ),
                  NavigationDrawerDestination(
                    icon: Icon(Icons.account_tree_outlined),
                    selectedIcon: Icon(Icons.account_tree),
                    label: Text('Protocols'),
                  ),
                ],
              ),
            ),
      appBar: AppBar(
        title: const Text('Lab Workspace'),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Center(
              child: Tooltip(
                message: '此 Vault 保存在本设备的应用数据目录中。',
                child: Chip(
                  avatar: const Icon(Icons.devices, size: 18),
                  label: Text(
                    '本地 · ${_shortDeviceId(widget.core.vault.context.deviceId)}',
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
      body: Row(
        children: [
          if (wide)
            NavigationRail(
              selectedIndex: _selected,
              onDestinationSelected: (value) =>
                  setState(() => _selected = value),
              labelType: NavigationRailLabelType.all,
              destinations: const [
                NavigationRailDestination(
                  icon: Icon(Icons.dashboard_outlined),
                  selectedIcon: Icon(Icons.dashboard),
                  label: Text('概览'),
                ),
                NavigationRailDestination(
                  icon: Icon(Icons.folder_open_outlined),
                  selectedIcon: Icon(Icons.folder_open),
                  label: Text('文件'),
                ),
                NavigationRailDestination(
                  icon: Icon(Icons.science_outlined),
                  selectedIcon: Icon(Icons.science),
                  label: Text('实验'),
                ),
                NavigationRailDestination(
                  icon: Icon(Icons.functions_outlined),
                  selectedIcon: Icon(Icons.functions),
                  label: Text('计算与 Pack'),
                ),
                NavigationRailDestination(
                  icon: Icon(Icons.image_search_outlined),
                  selectedIcon: Icon(Icons.image_search),
                  label: Text('AI 与图像'),
                ),
                NavigationRailDestination(
                  icon: Icon(Icons.cloud_sync_outlined),
                  selectedIcon: Icon(Icons.cloud_sync),
                  label: Text('同步与备份'),
                ),
                NavigationRailDestination(
                  icon: Icon(Icons.checklist_outlined),
                  selectedIcon: Icon(Icons.checklist),
                  label: Text('To Do'),
                ),
                NavigationRailDestination(
                  icon: Icon(Icons.notifications_active_outlined),
                  selectedIcon: Icon(Icons.notifications_active),
                  label: Text('提醒'),
                ),
                NavigationRailDestination(
                  icon: Icon(Icons.tune_outlined),
                  selectedIcon: Icon(Icons.tune),
                  label: Text('AI Provider'),
                ),
                NavigationRailDestination(
                  icon: Icon(Icons.account_tree_outlined),
                  selectedIcon: Icon(Icons.account_tree),
                  label: Text('Protocols'),
                ),
              ],
            ),
          Expanded(
            child: IndexedStack(index: _selected, children: pages),
          ),
        ],
      ),
    );
  }
}

String _shortDeviceId(String id) => id.length <= 8 ? id : id.substring(0, 8);

class _OverviewPage extends StatefulWidget {
  const _OverviewPage({required this.core});

  final LabCore core;

  @override
  State<_OverviewPage> createState() => _OverviewPageState();
}

class _OverviewPageState extends State<_OverviewPage> {
  DashboardSnapshot? _snapshot;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    try {
      final snapshot = widget.core.dashboard.load();
      setState(() {
        _snapshot = snapshot;
        _error = null;
      });
    } on Object catch (error) {
      setState(() => _error = error);
    }
  }

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(24),
    children: [
      Text(
        '欢迎使用 Lab Workspace',
        style: Theme.of(context).textTheme.headlineMedium,
      ),
      const SizedBox(height: 8),
      const Text('数据保存在此设备的本地 Vault 中。每个设备维护独立数据库和内容寻址文件库。'),
      const SizedBox(height: 24),
      Card(
        child: ListTile(
          leading: const Icon(Icons.storage),
          title: const Text('当前 Vault'),
          subtitle: SelectableText(widget.core.vault.context.rootDirectory),
        ),
      ),
      Card(
        child: ListTile(
          leading: const Icon(Icons.fingerprint),
          title: const Text('设备标识'),
          subtitle: SelectableText(widget.core.vault.context.deviceId),
        ),
      ),
      const SizedBox(height: 12),
      Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          _MetricCard(label: '项目', value: _snapshot?.activeProjectCount),
          _MetricCard(label: '实验', value: _snapshot?.activeExperimentCount),
          _MetricCard(label: '活动运行', value: _snapshot?.activeRunCount),
          _MetricCard(label: '未完成待办', value: _snapshot?.openTaskCount),
        ],
      ),
      if (_error != null)
        MaterialBanner(
          content: Text('仪表板读取失败：$_error'),
          actions: [TextButton(onPressed: _load, child: const Text('重试'))],
        ),
      const SizedBox(height: 16),
      Text('即将进行的步骤', style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 8),
      if (_snapshot?.upcomingSteps.isEmpty ?? true)
        const Card(child: ListTile(title: Text('当前没有已安排的步骤。')))
      else
        for (final step in _snapshot!.upcomingSteps.take(10))
          Card(
            child: ListTile(
              leading: const Icon(Icons.schedule_outlined),
              title: Text(step.title),
              subtitle: Text(
                '${step.runTitle} · ${step.state}${step.dueAtUtc == null ? '' : ' · 到期 ${step.dueAtUtc!.toLocal()}'}',
              ),
            ),
          ),
      const SizedBox(height: 20),
      const _StatusCard(
        icon: Icons.cloud_off_outlined,
        title: '云端服务未启用',
        detail: '文件和数据库不会自动上传。同步和备份必须在设置中明确配置。',
      ),
      const _StatusCard(
        icon: Icons.calculate_outlined,
        title: '计算记录要求',
        detail: '所有派生数值必须保留原始步骤，并提供“展示原始计算”。',
      ),
    ],
  );
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({required this.label, required this.value});

  final String label;
  final int? value;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 160,
    child: Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 6),
            Text(
              value?.toString() ?? '—',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
          ],
        ),
      ),
    ),
  );
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({
    required this.icon,
    required this.title,
    required this.detail,
  });

  final IconData icon;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) => Card(
    child: ListTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle: Text(detail),
    ),
  );
}
