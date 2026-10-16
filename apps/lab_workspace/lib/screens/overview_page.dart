import 'package:flutter/material.dart';
import 'package:lab_core/lab_core.dart';

import '../widgets/workspace_ui.dart';

class OverviewPage extends StatefulWidget {
  const OverviewPage({
    required this.core,
    required this.onOpenExperiments,
    required this.onOpenExplorer,
    super.key,
  });

  final LabCore core;
  final ValueChanged<String?> onOpenExperiments;
  final VoidCallback onOpenExplorer;

  @override
  State<OverviewPage> createState() => _OverviewPageState();
}

class _OverviewPageState extends State<OverviewPage> {
  DashboardSnapshot? _snapshot;
  List<ProjectRecord> _projects = const [];
  List<ExperimentRecord> _experiments = const [];
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    try {
      setState(() {
        _snapshot = widget.core.dashboard.load();
        _projects = widget.core.projects.listProjects();
        _experiments = widget.core.experiments.listExperiments();
        _error = null;
      });
    } on Object catch (error) {
      setState(() => _error = error);
    }
  }

  int _experimentCount(String projectId) => _experiments
      .where((experiment) => experiment.projectId == projectId)
      .length;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final columns = width >= 1200
        ? 4
        : width >= 760
        ? 2
        : 1;
    final metricWidth = (width / columns).clamp(190.0, 340.0);
    return ListView(
      padding: const EdgeInsets.fromLTRB(30, 26, 30, 38),
      children: [
        WorkspacePageHeader(
          title: '今天的工作台',
          subtitle: '从本机 Vault 查看项目、实验步骤和近期记录。',
          icon: Icons.space_dashboard_outlined,
          actions: [
            OutlinedButton.icon(
              onPressed: widget.onOpenExplorer,
              icon: const Icon(Icons.folder_open_outlined),
              label: const Text('浏览文件'),
            ),
            FilledButton.icon(
              onPressed: () => widget.onOpenExperiments(null),
              icon: const Icon(Icons.add),
              label: const Text('打开项目与实验'),
            ),
          ],
        ),
        if (_error != null)
          MaterialBanner(
            content: Text('工作台数据读取失败：$_error'),
            actions: [TextButton(onPressed: _load, child: const Text('重试'))],
          ),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            _MetricCard(
              width: metricWidth,
              label: '项目',
              value: _snapshot?.activeProjectCount,
              icon: Icons.folder_copy_outlined,
              tone: const Color(0xFFEAF3F1),
            ),
            _MetricCard(
              width: metricWidth,
              label: '实验',
              value: _snapshot?.activeExperimentCount,
              icon: Icons.science_outlined,
              tone: const Color(0xFFEAF0F7),
            ),
            _MetricCard(
              width: metricWidth,
              label: '活动运行',
              value: _snapshot?.activeRunCount,
              icon: Icons.play_circle_outline_rounded,
              tone: const Color(0xFFF1EDF8),
            ),
            _MetricCard(
              width: metricWidth,
              label: '未完成待办',
              value: _snapshot?.openTaskCount,
              icon: Icons.checklist_rounded,
              tone: const Color(0xFFFFF2E3),
            ),
          ],
        ),
        WorkspaceSectionHeader(
          title: '近期实验步骤',
          subtitle: '按本机计划列出即将开始或到期的步骤。',
          trailing: TextButton.icon(
            onPressed: () => widget.onOpenExperiments(null),
            icon: const Icon(Icons.arrow_forward, size: 17),
            label: const Text('查看实验'),
          ),
        ),
        if (_snapshot == null)
          const _LoadingCard(label: '正在读取本机计划…')
        else if (_snapshot!.upcomingSteps.isEmpty)
          const WorkspaceEmptyState(
            icon: Icons.event_available_outlined,
            title: '当前没有已安排的步骤',
            description: '创建一次运行并设置计划时间后，相关步骤会显示在这里。',
          )
        else
          for (final step in _snapshot!.upcomingSteps.take(6))
            WorkspaceEntrance(
              child: Card(
                child: ListTile(
                  leading: Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: const Color(0xFFEAF3F1),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(
                      Icons.schedule_outlined,
                      color: workspaceAccent,
                      size: 20,
                    ),
                  ),
                  title: Text(step.title),
                  subtitle: Text(
                    '${step.runTitle} · ${step.state}'
                    '${step.dueAtUtc == null ? '' : ' · 到期 ${step.dueAtUtc!.toLocal()}'}',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => widget.onOpenExperiments(null),
                ),
              ),
            ),
        WorkspaceSectionHeader(
          title: '项目',
          subtitle: '展示本机现有项目及其真实实验数量。',
          trailing: TextButton.icon(
            onPressed: () => widget.onOpenExperiments(null),
            icon: const Icon(Icons.open_in_new, size: 16),
            label: const Text('项目管理'),
          ),
        ),
        if (_projects.isEmpty)
          WorkspaceEmptyState(
            icon: Icons.create_new_folder_outlined,
            title: '还没有项目',
            description: '创建项目后，可以在其中整理实验、运行、样本和原始文件。',
            action: FilledButton.icon(
              onPressed: () => widget.onOpenExperiments(null),
              icon: const Icon(Icons.add),
              label: const Text('创建第一个项目'),
            ),
          )
        else
          LayoutBuilder(
            builder: (context, constraints) {
              final columns = constraints.maxWidth >= 1000
                  ? 3
                  : constraints.maxWidth >= 640
                  ? 2
                  : 1;
              final cardWidth =
                  (constraints.maxWidth - (columns - 1) * 12) / columns;
              return Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  for (final project in _projects.take(9))
                    SizedBox(
                      width: cardWidth,
                      child: WorkspaceHoverCard(
                        onTap: () =>
                            widget.onOpenExperiments(project.projectId),
                        child: Padding(
                          padding: const EdgeInsets.all(17),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Container(
                                width: 40,
                                height: 40,
                                decoration: BoxDecoration(
                                  color: const Color(0xFFEAF3F1),
                                  borderRadius: BorderRadius.circular(13),
                                ),
                                child: const Icon(
                                  Icons.folder_open_rounded,
                                  color: workspaceAccent,
                                  size: 21,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      project.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(
                                        context,
                                      ).textTheme.titleMedium,
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      '${_experimentCount(project.projectId)} 个实验 · 创建于 ${project.createdAtUtc.toLocal().toString().split('.').first}',
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(
                                        context,
                                      ).textTheme.bodySmall,
                                    ),
                                  ],
                                ),
                              ),
                              const Icon(
                                Icons.arrow_outward,
                                size: 17,
                                color: workspaceMutedInk,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        const SizedBox(height: 14),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(17),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: const Color(0xFFEAF3F1),
                    borderRadius: BorderRadius.circular(13),
                  ),
                  child: const Icon(Icons.lock_outline, color: workspaceAccent),
                ),
                const SizedBox(width: 13),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '本机数据与科学记录',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                      SizedBox(height: 4),
                      Text(
                        '文件默认保存在本机 Vault。派生数值保留可回看的原始计算；云传输需要单独配置并逐次确认。',
                        style: TextStyle(
                          color: workspaceMutedInk,
                          height: 1.45,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                const WorkspaceStatusBadge(
                  label: '本机优先',
                  icon: Icons.devices_outlined,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({
    required this.width,
    required this.label,
    required this.value,
    required this.icon,
    required this.tone,
  });

  final double width;
  final String label;
  final int? value;
  final IconData icon;
  final Color tone;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: width,
    child: WorkspaceEntrance(
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(17),
          child: Row(
            children: [
              Container(
                width: 43,
                height: 43,
                decoration: BoxDecoration(
                  color: tone,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(icon, color: workspaceAccent, size: 22),
              ),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label, style: Theme.of(context).textTheme.bodySmall),
                    const SizedBox(height: 3),
                    Text(
                      value?.toString() ?? '—',
                      style: Theme.of(context).textTheme.headlineSmall
                          ?.copyWith(fontSize: 25, height: 1.1),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _LoadingCard extends StatelessWidget {
  const _LoadingCard({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Row(
        children: [
          const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 12),
          Text(label),
        ],
      ),
    ),
  );
}
