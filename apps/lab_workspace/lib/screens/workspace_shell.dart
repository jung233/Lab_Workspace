import 'package:flutter/material.dart';
import 'package:lab_core/lab_core.dart';

import '../integrations/microsoft_todo_page.dart';
import '../platform/workspace_ai_provider.dart';
import '../platform/workspace_services.dart';
import '../src/ai_image/ai_image_page.dart';
import '../widgets/workspace_ui.dart';
import 'calculation_page.dart';
import 'experiments_page.dart';
import 'explorer_page.dart';
import 'overview_page.dart';
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
  String? _requestedProjectId;
  late final WorkspaceAiProvider _aiProvider;

  @override
  void initState() {
    super.initState();
    _aiProvider = WorkspaceAiProvider(
      core: widget.core,
      secretStore: widget.services.secretStore,
    );
  }

  @override
  void dispose() {
    _aiProvider.dispose();
    super.dispose();
  }

  static const _destinations = <_WorkspaceDestination>[
    _WorkspaceDestination(
      title: '工作台概览',
      shortTitle: '概览',
      icon: Icons.dashboard_outlined,
      selectedIcon: Icons.dashboard_rounded,
      group: '工作区',
    ),
    _WorkspaceDestination(
      title: '项目与实验',
      shortTitle: '实验',
      icon: Icons.science_outlined,
      selectedIcon: Icons.science_rounded,
      group: '工作区',
    ),
    _WorkspaceDestination(
      title: '实验流程库',
      shortTitle: '流程',
      icon: Icons.account_tree_outlined,
      selectedIcon: Icons.account_tree_rounded,
      group: '工作区',
    ),
    _WorkspaceDestination(
      title: '计算与 Pack',
      shortTitle: '计算',
      icon: Icons.functions_outlined,
      selectedIcon: Icons.functions_rounded,
      group: '科研工具',
    ),
    _WorkspaceDestination(
      title: '原始文件',
      shortTitle: '文件',
      icon: Icons.folder_open_outlined,
      selectedIcon: Icons.folder_open_rounded,
      group: '科研工具',
    ),
    _WorkspaceDestination(
      title: '图像与 AI',
      shortTitle: '图像 AI',
      icon: Icons.image_search_outlined,
      selectedIcon: Icons.image_search_rounded,
      group: '科研工具',
    ),
    _WorkspaceDestination(
      title: '任务与提醒',
      shortTitle: '提醒',
      icon: Icons.notifications_active_outlined,
      selectedIcon: Icons.notifications_active_rounded,
      group: '日程与服务',
    ),
    _WorkspaceDestination(
      title: 'Microsoft To Do',
      shortTitle: '待办',
      icon: Icons.checklist_outlined,
      selectedIcon: Icons.checklist_rounded,
      group: '日程与服务',
    ),
    _WorkspaceDestination(
      title: '同步与备份',
      shortTitle: '同步备份',
      icon: Icons.cloud_sync_outlined,
      selectedIcon: Icons.cloud_sync_rounded,
      group: '管理',
    ),
    _WorkspaceDestination(
      title: 'AI 模型设置',
      shortTitle: '模型设置',
      icon: Icons.tune_outlined,
      selectedIcon: Icons.tune_rounded,
      group: '管理',
    ),
  ];

  void _selectPage(int index) {
    if (index < 0 || index >= _destinations.length || index == _selected) {
      return;
    }
    setState(() => _selected = index);
  }

  void _openProject(String? projectId) {
    setState(() {
      _requestedProjectId = projectId;
      _selected = 1;
    });
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final wide = width >= 860;
    final extended = width >= 1220;
    final pages = <Widget>[
      OverviewPage(
        core: widget.core,
        onOpenExperiments: _openProject,
        onOpenExplorer: () => _selectPage(4),
      ),
      ExperimentsPage(
        core: widget.core,
        services: widget.services,
        aiProvider: _aiProvider,
        initialProjectId: _requestedProjectId,
        onOpenProtocolLibrary: () async => _selectPage(2),
        onOpenProviderSettings: () async => _selectPage(9),
      ),
      ProtocolsPage(
        core: widget.core,
        packRegistry: widget.services.packRegistry,
        aiProvider: _aiProvider,
        onOpenProviderSettings: () async => _selectPage(9),
      ),
      CalculationPage(
        packs: widget.services.packRegistry,
        calculations: widget.services.calculations,
        approvals: widget.core.approvals,
      ),
      AssetExplorerScreen(
        assets: widget.services.assets,
        approvals: widget.core.approvals,
      ),
      AiImagePage(
        core: widget.core,
        assets: widget.services.assets,
        secretStore: widget.services.secretStore,
        packRegistry: widget.services.packRegistry,
      ),
      RemindersPage(
        tasks: widget.services.tasks,
        reminders: widget.services.reminders,
        notifications: widget.services.localNotifications,
      ),
      MicrosoftTodoPage(
        core: widget.core,
        secretStore: widget.services.secretStore,
      ),
      SyncBackupPage(
        core: widget.core,
        sync: widget.services.sync,
        backups: widget.services.backups,
        secretStore: widget.services.secretStore,
      ),
      ProviderSettingsPage(core: widget.core),
    ];

    return Scaffold(
      drawer: wide
          ? null
          : Drawer(
              width: 304,
              child: _buildNavigationContent(
                context,
                extended: true,
                mobile: true,
              ),
            ),
      appBar: AppBar(
        title: const Text('Lab Workspace'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 18),
            child: Center(
              child: Tooltip(
                message: '每台设备有自己的本地 Vault。数据仅在你明确配置同步或备份后才会离开本机。',
                child: WorkspaceStatusBadge(
                  label: width < 560
                      ? '本机'
                      : '本机 Vault · ${_shortDeviceId(widget.core.vault.context.deviceId)}',
                  icon: Icons.storage_outlined,
                ),
              ),
            ),
          ),
        ],
      ),
      body: Row(
        children: [
          if (wide)
            SizedBox(
              width: extended ? 256 : 76,
              child: _buildNavigationContent(
                context,
                extended: extended,
                mobile: false,
              ),
            ),
          Expanded(
            child: ColoredBox(
              color: workspaceCanvas,
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1480),
                  child: SizedBox.expand(
                    child: IndexedStack(index: _selected, children: pages),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNavigationContent(
    BuildContext context, {
    required bool extended,
    required bool mobile,
  }) {
    final groups = <String, List<int>>{};
    for (var index = 0; index < _destinations.length; index++) {
      groups.putIfAbsent(_destinations[index].group, () => []).add(index);
    }

    return DecoratedBox(
      decoration: BoxDecoration(
        color: mobile ? Colors.white : workspaceCanvas,
        border: mobile
            ? null
            : const Border(right: BorderSide(color: Color(0xFFDCE6E3))),
      ),
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(
                extended ? 21 : 0,
                20,
                extended ? 16 : 0,
                19,
              ),
              child: extended
                  ? Row(
                      children: [
                        _BrandMark(),
                        const SizedBox(width: 12),
                        const Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Lab Workspace',
                                style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w700,
                                  color: workspaceInk,
                                  letterSpacing: -0.25,
                                ),
                              ),
                              SizedBox(height: 3),
                              Text(
                                '本机科研工作台',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: workspaceMutedInk,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    )
                  : const Center(child: _BrandMark()),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView(
                padding: EdgeInsets.fromLTRB(
                  extended ? 13 : 7,
                  13,
                  extended ? 13 : 7,
                  16,
                ),
                children: [
                  for (final entry in groups.entries) ...[
                    if (extended)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(10, 11, 8, 5),
                        child: Text(
                          entry.key,
                          style: Theme.of(context).textTheme.labelSmall
                              ?.copyWith(
                                color: const Color(0xFF84928F),
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.5,
                              ),
                        ),
                      ),
                    for (final index in entry.value)
                      _NavigationItem(
                        destination: _destinations[index],
                        selected: _selected == index,
                        extended: extended,
                        onTap: () {
                          if (mobile) Navigator.of(context).pop();
                          _selectPage(index);
                        },
                      ),
                    if (extended) const SizedBox(height: 5),
                  ],
                ],
              ),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(
                extended ? 16 : 10,
                7,
                extended ? 16 : 10,
                13,
              ),
              child: extended
                  ? Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFFEAF1EF),
                        borderRadius: BorderRadius.circular(13),
                      ),
                      child: const Row(
                        children: [
                          Icon(
                            Icons.lock_outline,
                            size: 17,
                            color: Color(0xFF57716B),
                          ),
                          SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '离线优先 · 本机保存',
                              style: TextStyle(
                                color: Color(0xFF49625D),
                                fontSize: 11,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ],
                      ),
                    )
                  : const Tooltip(
                      message: '离线优先 · 本机保存',
                      child: Icon(Icons.lock_outline, color: Color(0xFF57716B)),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  String _shortDeviceId(String id) => id.length <= 8 ? id : id.substring(0, 8);
}

class _WorkspaceDestination {
  const _WorkspaceDestination({
    required this.title,
    required this.shortTitle,
    required this.icon,
    required this.selectedIcon,
    required this.group,
  });

  final String title;
  final String shortTitle;
  final IconData icon;
  final IconData selectedIcon;
  final String group;
}

class _NavigationItem extends StatefulWidget {
  const _NavigationItem({
    required this.destination,
    required this.selected,
    required this.extended,
    required this.onTap,
  });

  final _WorkspaceDestination destination;
  final bool selected;
  final bool extended;
  final VoidCallback onTap;

  @override
  State<_NavigationItem> createState() => _NavigationItemState();
}

class _NavigationItemState extends State<_NavigationItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 180);
    final selected = widget.selected;
    final iconColor = selected ? workspaceAccent : const Color(0xFF64746F);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Tooltip(
        message: widget.extended ? '' : widget.destination.title,
        child: MouseRegion(
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: AnimatedContainer(
            duration: duration,
            curve: Curves.easeOut,
            decoration: BoxDecoration(
              color: selected
                  ? const Color(0xFFDDEEEA)
                  : _hovered
                  ? const Color(0xFFEAF0EE)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Material(
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(12),
              child: InkWell(
                onTap: widget.onTap,
                borderRadius: BorderRadius.circular(12),
                child: Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: widget.extended ? 12 : 0,
                    vertical: 11,
                  ),
                  child: widget.extended
                      ? Row(
                          children: [
                            Icon(
                              selected
                                  ? widget.destination.selectedIcon
                                  : widget.destination.icon,
                              color: iconColor,
                              size: 21,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                widget.destination.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 13,
                                  color: selected
                                      ? workspaceAccent
                                      : workspaceInk,
                                  fontWeight: selected
                                      ? FontWeight.w600
                                      : FontWeight.w500,
                                ),
                              ),
                            ),
                            if (selected)
                              Container(
                                width: 5,
                                height: 5,
                                decoration: const BoxDecoration(
                                  color: workspaceAccent,
                                  shape: BoxShape.circle,
                                ),
                              ),
                          ],
                        )
                      : Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              selected
                                  ? widget.destination.selectedIcon
                                  : widget.destination.icon,
                              color: iconColor,
                              size: 21,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              widget.destination.shortTitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 9,
                                color: selected
                                    ? workspaceAccent
                                    : workspaceMutedInk,
                                fontWeight: selected
                                    ? FontWeight.w600
                                    : FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _BrandMark extends StatelessWidget {
  const _BrandMark();

  @override
  Widget build(BuildContext context) => Container(
    width: 38,
    height: 38,
    decoration: BoxDecoration(
      gradient: const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xFF238A7C), Color(0xFF17655F)],
      ),
      borderRadius: BorderRadius.circular(12),
      boxShadow: const [
        BoxShadow(
          color: Color(0x1A14776F),
          blurRadius: 10,
          offset: Offset(0, 4),
        ),
      ],
    ),
    child: const Icon(Icons.biotech_rounded, color: Colors.white, size: 22),
  );
}
