import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:lab_core/lab_core.dart';

import '../platform/workspace_ai_provider.dart';
import '../platform/workspace_services.dart';
import '../platform/asset_import_picker.dart';
import '../widgets/ai_protocol_draft_dialog.dart';
import '../widgets/project_storage_settings_dialog.dart';
import '../widgets/protocol_chooser_dialog.dart';
import '../widgets/workspace_ui.dart';

class ExperimentsPage extends StatefulWidget {
  const ExperimentsPage({
    required this.core,
    required this.services,
    required this.aiProvider,
    required this.onOpenProtocolLibrary,
    required this.onOpenProviderSettings,
    this.initialProjectId,
    super.key,
  });

  final LabCore core;
  final WorkspaceServices services;
  final WorkspaceAiProvider aiProvider;
  final String? initialProjectId;
  final Future<void> Function() onOpenProtocolLibrary;
  final Future<void> Function() onOpenProviderSettings;

  @override
  State<ExperimentsPage> createState() => _ExperimentsPageState();
}

class _ExperimentsPageState extends State<ExperimentsPage> {
  List<ProjectRecord> _projects = const [];
  List<ExperimentRecord> _experiments = const [];
  String? _selectedProjectId;
  ExperimentRecord? _selectedExperiment;
  Object? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _selectedProjectId = widget.initialProjectId;
    _reload();
  }

  @override
  void didUpdateWidget(covariant ExperimentsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialProjectId != oldWidget.initialProjectId) {
      _selectedProjectId = widget.initialProjectId;
      _selectedExperiment = null;
      _reload();
    }
  }

  Future<void> _reload() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final projects = widget.core.projects.listProjects();
      final experiments = widget.core.experiments.listExperiments(
        projectId: _selectedProjectId,
      );
      if (mounted) {
        setState(() {
          _projects = projects;
          _experiments = experiments;
        });
      }
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _createProject() async {
    final value = await _textPrompt(title: '新建项目', label: '项目名称');
    if (value == null || value.trim().isEmpty) return;
    try {
      final project = widget.core.projects.createProject(title: value.trim());
      _selectedProjectId = project.projectId;
      await _reload();
    } on Object catch (error) {
      if (mounted) _showError(error);
    }
  }

  Future<String?> _textPrompt({
    required String title,
    required String label,
  }) async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          textInputAction: TextInputAction.done,
          decoration: InputDecoration(labelText: label),
          onSubmitted: (value) => Navigator.of(context).pop(value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    return result;
  }

  Future<void> _createExperiment() async {
    if (_projects.isEmpty) {
      _showError(StateError('请先创建一个项目。'));
      return;
    }
    final request = await showDialog<_ExperimentCreateRequest>(
      context: context,
      builder: (context) => const _ExperimentCreateDialog(),
    );
    if (request == null || request.title.trim().isEmpty) return;
    try {
      final experiment = widget.core.experiments.createExperiment(
        title: request.title.trim(),
        projectId: _selectedProjectId,
      );
      _selectedExperiment = experiment;
      await _reload();
      if (request.startWithProtocol && mounted) {
        final protocol = await _chooseApprovedProtocol(
          initialObjective: '为实验“${experiment.title}”设计可复现的实验流程。',
        );
        if (protocol == null) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('实验已保存。选择已批准 Protocol 后才能创建 Protocol 运行。'),
              ),
            );
          }
          return;
        }
        await _createRunForExperiment(experiment, protocol);
      }
    } on Object catch (error) {
      if (mounted) _showError(error);
    }
  }

  Future<ProtocolVersionRecord?> _chooseApprovedProtocol({
    String? initialObjective,
  }) => showProtocolChooserDialog(
    context: context,
    protocols: widget.core.protocols,
    onOpenProtocolLibrary: widget.onOpenProtocolLibrary,
    onDraftProtocol: () =>
        _createAiProtocolDraft(initialObjective: initialObjective),
  );

  Future<void> _createRunForExperiment(
    ExperimentRecord experiment,
    ProtocolVersionRecord protocol,
  ) async {
    final run = await _promptRunCreation(
      context,
      experiment: experiment,
      runNumber:
          widget.core.runs
              .listRuns(experimentId: experiment.experimentId)
              .length +
          1,
      protocol: protocol,
    );
    if (run == null || run.title.trim().isEmpty) return;
    try {
      final created = await widget.core.runs.createRun(
        experimentId: experiment.experimentId,
        title: run.title.trim(),
        protocolId: protocol.protocolId,
        protocolVersion: protocol.version,
        parameters: run.parameters,
        plannedStartUtc: run.plannedStartUtc,
      );
      if (run.plannedStartUtc != null) {
        widget.core.schedule.rebuildPlan(
          runId: created.runId,
          startAtUtc: run.plannedStartUtc!,
        );
      }
      await _reload();
    } on Object catch (error) {
      if (mounted) _showError(error);
    }
  }

  Future<void> _createAiProtocolDraft({String? initialObjective}) async {
    try {
      final providers = await widget.aiProvider.profiles.list();
      if (!mounted) return;
      final draft = await showAiProtocolDraftDialog(
        context: context,
        service: AiProtocolDraftService(
          ai: widget.aiProvider.ai,
          calculationBinder: WorkflowCalculationPackBinder(
            widget.services.packRegistry,
          ),
        ),
        approvals: widget.core.approvals,
        providers: providers,
        referenceVersions: _protocolVersions(),
        initialObjective: initialObjective,
        onOpenProviderSettings: widget.onOpenProviderSettings,
      );
      if (draft == null) return;
      if (!draft.isValid || draft.unsupportedOperations.isNotEmpty) {
        _showError(StateError('Protocol 草稿包含阻断错误，未保存。'));
        return;
      }
      final saved = widget.core.protocols.saveDraft(
        document: draft.document,
        provenance: <String, Object?>{
          ...draft.provenance,
          'requires_user_input': draft.requiresUserInput,
        },
      );
      if (!mounted) return;
      final remainingInputs = draft.requiresUserInput;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'AI 草稿已保存待审阅：${saved.protocolId} @ ${saved.version}。'
            '${remainingInputs.isEmpty ? '草稿尚未批准，不能用于运行。' : '仍需补充：${remainingInputs.join('、')}。补齐并本地重校验后才能批准。'}',
          ),
        ),
      );
    } on Object catch (error) {
      if (mounted) _showError(error);
    }
  }

  List<ProtocolVersionRecord> _protocolVersions() {
    final protocols = widget.core.protocols.listProtocols(
      includeArchived: true,
    );
    return protocols
        .expand((item) => widget.core.protocols.listVersions(item.protocolId))
        .toList(growable: false);
  }

  ProjectRecord? get _selectedProject {
    final id = _selectedProjectId;
    if (id == null) return null;
    for (final project in _projects) {
      if (project.projectId == id) return project;
    }
    return null;
  }

  void _selectProject(String? projectId) {
    setState(() {
      _selectedProjectId = projectId;
      _selectedExperiment = null;
    });
    _reload();
  }

  Future<void> _openProjectStorage() async {
    final project = _selectedProject;
    if (project == null) return;
    await ProjectStorageSettingsDialog.show(
      context: context,
      service: widget.services.projectStorage,
      projectId: project.projectId,
    );
  }

  void _showError(Object error) => ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text('操作未完成：$error')));

  @override
  Widget build(BuildContext context) {
    final experiment = _selectedExperiment;
    final project = _selectedProject;
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 22, 28, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          WorkspacePageHeader(
            title: experiment?.title ?? project?.title ?? '项目与实验',
            subtitle: experiment == null
                ? '本机项目、实验与运行记录'
                : '实验上下文 · 选择已批准 Protocol，为此实验创建新的运行。',
            icon: Icons.science_outlined,
            breadcrumbs: [
              if (project != null) project.title,
              if (experiment != null) '实验',
            ],
            actions: [
              OutlinedButton.icon(
                onPressed: _busy ? null : _createProject,
                icon: const Icon(Icons.create_new_folder_outlined),
                label: const Text('新建项目'),
              ),
              FilledButton.icon(
                onPressed: _busy ? null : _createExperiment,
                icon: const Icon(Icons.add),
                label: const Text('新建实验'),
              ),
              IconButton(
                onPressed: _busy ? null : _reload,
                tooltip: '刷新',
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          if (_busy) const LinearProgressIndicator(),
          if (_error != null)
            MaterialBanner(
              content: Text('无法读取本地实验数据：$_error'),
              actions: [
                TextButton(onPressed: _reload, child: const Text('重试')),
              ],
            ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                if (constraints.maxWidth < 720) {
                  return experiment == null
                      ? Column(
                          children: [
                            SizedBox(
                              height: 144,
                              child: _mobileProjectSelector(),
                            ),
                            const SizedBox(height: 8),
                            Expanded(child: _experimentList()),
                          ],
                        )
                      : ExperimentRunsPage(
                          core: widget.core,
                          experiment: experiment,
                          onBack: () =>
                              setState(() => _selectedExperiment = null),
                          onOpenProtocolLibrary: widget.onOpenProtocolLibrary,
                          onCreateAiProtocolDraft: () => _createAiProtocolDraft(
                            initialObjective:
                                '为实验“${experiment.title}”设计可复现的实验流程。',
                          ),
                        );
                }
                if (constraints.maxWidth < 1120) {
                  return Row(
                    children: [
                      SizedBox(width: 236, child: _projectList()),
                      const VerticalDivider(width: 1),
                      Expanded(
                        child: experiment == null
                            ? _experimentList()
                            : ExperimentRunsPage(
                                core: widget.core,
                                experiment: experiment,
                                onBack: null,
                                onOpenProtocolLibrary:
                                    widget.onOpenProtocolLibrary,
                                onCreateAiProtocolDraft: () =>
                                    _createAiProtocolDraft(
                                      initialObjective:
                                          '为实验“${experiment.title}”设计可复现的实验流程。',
                                    ),
                              ),
                      ),
                    ],
                  );
                }
                return Row(
                  children: [
                    SizedBox(width: 246, child: _projectList()),
                    const VerticalDivider(width: 1),
                    SizedBox(width: 352, child: _experimentList()),
                    const VerticalDivider(width: 1),
                    Expanded(
                      child: experiment == null
                          ? const WorkspaceEmptyState(
                              icon: Icons.view_sidebar_outlined,
                              title: '选择一个实验',
                              description: '运行、样本、原始测量与执行步骤会在这里按实验上下文显示。',
                            )
                          : ExperimentRunsPage(
                              core: widget.core,
                              experiment: experiment,
                              onBack: null,
                              onOpenProtocolLibrary:
                                  widget.onOpenProtocolLibrary,
                              onCreateAiProtocolDraft: () =>
                                  _createAiProtocolDraft(
                                    initialObjective:
                                        '为实验“${experiment.title}”设计可复现的实验流程。',
                                  ),
                            ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _projectList() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      WorkspaceSectionHeader(
        title: '项目',
        trailing: _selectedProject == null
            ? null
            : IconButton(
                tooltip: '项目目录设置',
                onPressed: _openProjectStorage,
                icon: const Icon(Icons.folder_open_outlined),
              ),
      ),
      Expanded(
        child: ListView(
          padding: const EdgeInsets.only(bottom: 12),
          children: [
            _projectTile(
              title: '所有项目',
              icon: Icons.all_inbox_outlined,
              selected: _selectedProjectId == null,
              onTap: () => _selectProject(null),
            ),
            for (final project in _projects)
              _projectTile(
                title: project.title,
                icon: Icons.folder_outlined,
                selected: _selectedProjectId == project.projectId,
                onTap: () => _selectProject(project.projectId),
              ),
          ],
        ),
      ),
    ],
  );

  Widget _mobileProjectSelector() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      WorkspaceSectionHeader(
        title: '项目',
        trailing: _selectedProject == null
            ? null
            : IconButton(
                tooltip: '项目目录设置',
                onPressed: _openProjectStorage,
                icon: const Icon(Icons.folder_open_outlined),
              ),
      ),
      Expanded(
        child: ListView(
          scrollDirection: Axis.horizontal,
          children: [
            SizedBox(
              width: 170,
              child: _projectTile(
                title: '所有项目',
                icon: Icons.all_inbox_outlined,
                selected: _selectedProjectId == null,
                onTap: () => _selectProject(null),
              ),
            ),
            for (final project in _projects)
              SizedBox(
                width: 190,
                child: _projectTile(
                  title: project.title,
                  icon: Icons.folder_outlined,
                  selected: _selectedProjectId == project.projectId,
                  onTap: () => _selectProject(project.projectId),
                ),
              ),
          ],
        ),
      ),
    ],
  );

  Widget _projectTile({
    required String title,
    required IconData icon,
    required bool selected,
    required VoidCallback onTap,
  }) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 5),
    child: Material(
      color: selected ? const Color(0xFFE4F0ED) : Colors.white,
      borderRadius: BorderRadius.circular(12),
      child: ListTile(
        dense: true,
        selected: selected,
        leading: Icon(icon),
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: selected
            ? const Icon(Icons.check_circle, size: 17, color: workspaceAccent)
            : null,
        onTap: onTap,
      ),
    ),
  );

  Widget _experimentList() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      WorkspaceSectionHeader(
        title: '实验',
        subtitle: _selectedProject == null
            ? '所有项目中的实验'
            : '项目 · ${_selectedProject!.title}',
      ),
      Expanded(
        child: _experiments.isEmpty
            ? WorkspaceEmptyState(
                icon: Icons.science_outlined,
                title: '还没有实验',
                description: _selectedProject == null
                    ? '创建实验后可先保存为草稿，再添加已批准 Protocol 创建运行。'
                    : '在此项目下创建实验，可先保存为草稿，再添加已批准 Protocol 创建运行。',
                action: FilledButton.icon(
                  onPressed: _createExperiment,
                  icon: const Icon(Icons.add),
                  label: const Text('新建实验'),
                ),
              )
            : ListView.separated(
                padding: const EdgeInsets.only(bottom: 12),
                itemCount: _experiments.length,
                separatorBuilder: (_, _) => const SizedBox(height: 4),
                itemBuilder: (context, index) {
                  final experiment = _experiments[index];
                  final selected =
                      experiment.experimentId ==
                      _selectedExperiment?.experimentId;
                  return WorkspaceHoverCard(
                    child: ListTile(
                      selected: selected,
                      leading: const Icon(Icons.science_outlined),
                      title: Text(
                        experiment.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: const Text('本机实验记录'),
                      trailing: selected
                          ? const Icon(Icons.chevron_right)
                          : null,
                      onTap: () =>
                          setState(() => _selectedExperiment = experiment),
                    ),
                  );
                },
              ),
      ),
    ],
  );
}

class _ExperimentCreateRequest {
  const _ExperimentCreateRequest({
    required this.title,
    required this.startWithProtocol,
  });

  final String title;
  final bool startWithProtocol;
}

class _ExperimentCreateDialog extends StatefulWidget {
  const _ExperimentCreateDialog();

  @override
  State<_ExperimentCreateDialog> createState() =>
      _ExperimentCreateDialogState();
}

class _ExperimentCreateDialogState extends State<_ExperimentCreateDialog> {
  final _title = TextEditingController();
  bool _startWithProtocol = false;

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  void _submit() {
    if (_title.text.trim().isEmpty) return;
    Navigator.of(context).pop(
      _ExperimentCreateRequest(
        title: _title.text.trim(),
        startWithProtocol: _startWithProtocol,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('新建实验'),
    content: SizedBox(
      width: 520,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _title,
            autofocus: true,
            textInputAction: TextInputAction.done,
            decoration: const InputDecoration(
              labelText: '实验名称',
              prefixIcon: Icon(Icons.science_outlined),
            ),
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: 12),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            value: _startWithProtocol,
            onChanged: (value) =>
                setState(() => _startWithProtocol = value ?? false),
            title: const Text('创建后立即新建 Protocol 运行'),
            subtitle: const Text('下一步必须选择已批准版本；只想先建实验时保持关闭。'),
            controlAffinity: ListTileControlAffinity.leading,
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('取消'),
      ),
      FilledButton.icon(
        onPressed: _title.text.trim().isEmpty ? null : _submit,
        icon: const Icon(Icons.add),
        label: Text(_startWithProtocol ? '选择 Protocol' : '保存实验'),
      ),
    ],
  );
}

class _RunCreation {
  const _RunCreation({
    required this.title,
    this.protocol,
    this.parameters = const {},
    this.plannedStartUtc,
  });
  final String title;
  final ProtocolVersionRecord? protocol;
  final Map<String, Object?> parameters;
  final DateTime? plannedStartUtc;
}

String _runStateLabel(String state) => switch (state) {
  'planned' => '计划中',
  'active' || 'running' => '进行中',
  'completed' => '已完成',
  'failed' => '失败',
  'cancelled' => '已取消',
  _ => state,
};

WorkspaceBadgeTone _runStateTone(String state) => switch (state) {
  'completed' => WorkspaceBadgeTone.success,
  'failed' || 'cancelled' => WorkspaceBadgeTone.danger,
  'active' || 'running' => WorkspaceBadgeTone.warning,
  _ => WorkspaceBadgeTone.neutral,
};

String _stepStateLabel(String state) => switch (state) {
  'pending' => '待开始',
  'ready' => '可开始',
  'running' => '进行中',
  'completed' => '已完成',
  'skipped' => '已跳过',
  'failed' => '失败',
  'cancelled' => '已取消',
  _ => state,
};

class _RunCreationForm extends StatefulWidget {
  const _RunCreationForm({required this.defaultTitle, required this.protocol});

  final String defaultTitle;
  final ProtocolVersionRecord? protocol;

  @override
  State<_RunCreationForm> createState() => _RunCreationFormState();
}

class _RunCreationFormState extends State<_RunCreationForm> {
  late final TextEditingController _title = TextEditingController(
    text: widget.defaultTitle,
  );
  late final ProtocolVersionRecord? _protocol = widget.protocol;
  DateTime? _plannedStart;
  final Map<String, TextEditingController> _fields = {};

  @override
  void dispose() {
    _title.dispose();
    for (final controller in _fields.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _initializeProtocolFields();
  }

  void _initializeProtocolFields() {
    final variables = _protocol?.document['variables'];
    if (variables is List) {
      for (final item in variables.whereType<Map>()) {
        final field = Map<String, Object?>.from(item);
        final key = field['key'];
        if (key is String) {
          _fields[key] = TextEditingController(
            text: field['default']?.toString() ?? '',
          );
        }
      }
    }
  }

  Future<void> _pickStart() async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: _plannedStart ?? now,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 10),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_plannedStart ?? now),
    );
    if (time == null) return;
    setState(
      () => _plannedStart = DateTime(
        date.year,
        date.month,
        date.day,
        time.hour,
        time.minute,
      ).toUtc(),
    );
  }

  void _submit() {
    final parameters = <String, Object?>{};
    final variables = _protocol?.document['variables'];
    if (variables is List) {
      for (final raw in variables.whereType<Map>()) {
        final field = Map<String, Object?>.from(raw);
        final key = field['key']! as String;
        final text = _fields[key]?.text.trim() ?? '';
        if (text.isEmpty) {
          if (field['required'] == true) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text('请填写：$key')));
            return;
          }
          continue;
        }
        switch (field['kind']) {
          case 'boolean':
            if (text != 'true' && text != 'false') {
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(SnackBar(content: Text('$key 请输入 true 或 false')));
              return;
            }
            parameters[key] = text == 'true';
            break;
          case 'integer':
            if (int.tryParse(text) == null) {
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(SnackBar(content: Text('$key 必须为整数')));
              return;
            }
            parameters[key] = int.parse(text);
            break;
          default:
            parameters[key] = text;
            break;
        }
      }
    }
    Navigator.of(context).pop(
      _RunCreation(
        title: _title.text,
        protocol: _protocol,
        parameters: parameters,
        plannedStartUtc: _plannedStart,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          controller: _title,
          autofocus: true,
          decoration: const InputDecoration(labelText: '运行名称'),
        ),
        Container(
          width: double.infinity,
          margin: const EdgeInsets.only(top: 12),
          padding: const EdgeInsets.all(13),
          decoration: BoxDecoration(
            color: _protocol == null
                ? const Color(0xFFF3F5F4)
                : const Color(0xFFEAF3F1),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              Icon(
                _protocol == null
                    ? Icons.flash_on_outlined
                    : Icons.verified_outlined,
                color: _protocol == null ? workspaceMutedInk : workspaceAccent,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  _protocol == null
                      ? 'Quick Run · 不含 Protocol 步骤'
                      : '${_protocol.title} · ${_protocol.protocolId}@${_protocol.version}',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              if (_protocol != null)
                const WorkspaceStatusBadge(
                  label: '已批准快照',
                  icon: Icons.lock_outline,
                  tone: WorkspaceBadgeTone.success,
                ),
            ],
          ),
        ),
        if (_protocol != null) ...[
          const SizedBox(height: 8),
          for (final item
              in (_protocol.document['variables'] as List? ?? const [])
                  .whereType<Map>())
            TextField(
              controller: _fields[item['key']],
              decoration: InputDecoration(
                labelText:
                    '${item['key']}${item['required'] == true ? ' *' : ''}',
                helperText: item['unit'] == null
                    ? '类型：${item['kind']}'
                    : '类型：${item['kind']} · 单位 ${item['unit']}',
              ),
            ),
          const Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text('步骤 DAG 将从已审批版本冻结快照；步骤依赖和人工门由服务校验。'),
            ),
          ),
        ],
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: _pickStart,
            icon: const Icon(Icons.schedule),
            label: Text(
              _plannedStart == null
                  ? '设置计划开始时间'
                  : '计划 ${_plannedStart!.toLocal()}',
            ),
          ),
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            const SizedBox(width: 8),
            FilledButton(onPressed: _submit, child: const Text('创建运行')),
          ],
        ),
      ],
    ),
  );
}

Future<_RunCreation?> _promptRunCreation(
  BuildContext context, {
  required ExperimentRecord experiment,
  required int runNumber,
  required ProtocolVersionRecord? protocol,
}) => showDialog<_RunCreation>(
  context: context,
  builder: (context) => AlertDialog(
    title: const Text('新建运行'),
    content: SizedBox(
      width: 640,
      child: _RunCreationForm(
        defaultTitle: '${experiment.title} run $runNumber',
        protocol: protocol,
      ),
    ),
    actions: const [],
  ),
);

class ExperimentRunsPage extends StatefulWidget {
  const ExperimentRunsPage({
    required this.core,
    required this.experiment,
    required this.onOpenProtocolLibrary,
    required this.onCreateAiProtocolDraft,
    this.onBack,
    super.key,
  });

  final LabCore core;
  final ExperimentRecord experiment;
  final VoidCallback? onBack;
  final Future<void> Function() onOpenProtocolLibrary;
  final Future<void> Function() onCreateAiProtocolDraft;

  @override
  State<ExperimentRunsPage> createState() => _ExperimentRunsPageState();
}

class _ExperimentRunsPageState extends State<ExperimentRunsPage> {
  List<RunRecord> _runs = const [];
  String? _selectedRunId;
  Object? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final runs = widget.core.runs.listRuns(
        experimentId: widget.experiment.experimentId,
      );
      if (mounted) {
        setState(() {
          _runs = runs;
          if (_selectedRunId != null &&
              !runs.any((run) => run.runId == _selectedRunId)) {
            _selectedRunId = null;
          }
        });
      }
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _createProtocolRun() async {
    final protocol = await showProtocolChooserDialog(
      context: context,
      protocols: widget.core.protocols,
      onOpenProtocolLibrary: widget.onOpenProtocolLibrary,
      onDraftProtocol: widget.onCreateAiProtocolDraft,
    );
    if (protocol == null || !mounted) return;
    await _createRun(protocol);
  }

  Future<void> _createQuickRun() => _createRun(null);

  Future<void> _createRun(ProtocolVersionRecord? protocol) async {
    final run = await _promptRunCreation(
      context,
      experiment: widget.experiment,
      runNumber: _runs.length + 1,
      protocol: protocol,
    );
    if (run == null || run.title.trim().isEmpty) return;
    try {
      final created = await widget.core.runs.createRun(
        experimentId: widget.experiment.experimentId,
        title: run.title.trim(),
        protocolId: protocol?.protocolId,
        protocolVersion: protocol?.version,
        parameters: run.parameters,
        plannedStartUtc: run.plannedStartUtc,
      );
      if (run.plannedStartUtc != null && protocol != null) {
        widget.core.schedule.rebuildPlan(
          runId: created.runId,
          startAtUtc: run.plannedStartUtc!,
        );
      }
      await _reload();
      if (mounted) setState(() => _selectedRunId = created.runId);
    } on Object catch (error) {
      if (mounted) _showError(error);
    }
  }

  void _showError(Object error) => ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text('操作未完成：$error')));

  @override
  Widget build(BuildContext context) {
    final selectedRun = _runs
        .where((run) => run.runId == _selectedRunId)
        .firstOrNull;
    if (selectedRun != null) {
      return RunDetailPage(
        core: widget.core,
        run: selectedRun,
        experimentTitle: widget.experiment.title,
        assets: widget.core.assets,
        onBack: () => setState(() => _selectedRunId = null),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        WorkspacePageHeader(
          title: '实验运行',
          subtitle: '新建运行时绑定所选的已批准 Protocol 快照。',
          icon: Icons.play_circle_outline_rounded,
          breadcrumbs: [widget.experiment.title],
          actions: [
            OutlinedButton.icon(
              onPressed: widget.onCreateAiProtocolDraft,
              icon: const Icon(Icons.auto_awesome_outlined),
              label: const Text('AI 起草 Protocol'),
            ),
            FilledButton.icon(
              onPressed: _busy ? null : _createProtocolRun,
              icon: const Icon(Icons.rule_folder_outlined),
              label: const Text('选择 Protocol 新建运行'),
            ),
            OutlinedButton.icon(
              onPressed: _busy ? null : _createQuickRun,
              icon: const Icon(Icons.flash_on_outlined),
              label: const Text('Quick Run'),
            ),
          ],
        ),
        if (widget.onBack != null)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: widget.onBack,
              icon: const Icon(Icons.arrow_back),
              label: const Text('返回实验列表'),
            ),
          ),
        if (_busy) const LinearProgressIndicator(),
        if (_error != null)
          MaterialBanner(
            content: Text('无法读取运行记录：$_error'),
            actions: [TextButton(onPressed: _reload, child: const Text('重试'))],
          ),
        Expanded(
          child: _runs.isEmpty
              ? WorkspaceEmptyState(
                  icon: Icons.play_circle_outline_rounded,
                  title: '此实验还没有运行',
                  description:
                      '从已批准 Protocol 创建可复现的步骤快照，或创建不带 Protocol 步骤的 Quick Run。',
                  action: FilledButton.icon(
                    onPressed: _createProtocolRun,
                    icon: const Icon(Icons.rule_folder_outlined),
                    label: const Text('选择已批准 Protocol'),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.only(bottom: 14),
                  itemCount: _runs.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 7),
                  itemBuilder: (context, index) {
                    final run = _runs[index];
                    return WorkspaceHoverCard(
                      onTap: () => setState(() => _selectedRunId = run.runId),
                      child: ListTile(
                        leading: Icon(
                          run.protocolId == null
                              ? Icons.flash_on_outlined
                              : Icons.fact_check_outlined,
                        ),
                        title: Text(run.title),
                        subtitle: Text(
                          '${run.protocolId == null ? 'Quick Run · 无步骤模板' : 'Protocol ${run.protocolId} @ ${run.protocolVersion}'}\n'
                          '创建 ${run.createdAtUtc.toLocal()} · 计划 ${run.plannedStartUtc?.toLocal() ?? '未安排'}',
                        ),
                        isThreeLine: true,
                        trailing: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            WorkspaceStatusBadge(
                              label: _runStateLabel(run.state),
                              tone: _runStateTone(run.state),
                            ),
                            const SizedBox(height: 4),
                            const Icon(Icons.chevron_right, size: 18),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class RunDetailPage extends StatefulWidget {
  const RunDetailPage({
    required this.core,
    required this.run,
    required this.experimentTitle,
    required this.assets,
    required this.onBack,
    super.key,
  });

  final LabCore core;
  final RunRecord run;
  final String experimentTitle;
  final AssetGateway assets;
  final VoidCallback onBack;

  @override
  State<RunDetailPage> createState() => _RunDetailPageState();
}

class _RunDetailPageState extends State<RunDetailPage> {
  RunRecord? _currentRun;
  List<StepRecord> _steps = const [];
  List<ExperimentalGroupRecord> _groups = const [];
  List<SampleRecord> _samples = const [];
  Object? _error;
  bool _busy = false;
  RunRecord get _run => _currentRun ?? widget.run;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final steps = widget.core.runs.listSteps(widget.run.runId);
      final currentRun = widget.core.runs.getRun(widget.run.runId);
      final groups = widget.core.groups.listGroups(widget.run.runId);
      final samples = widget.core.samples.listSamples(runId: widget.run.runId);
      if (mounted) {
        setState(() {
          _currentRun = currentRun ?? widget.run;
          _steps = steps;
          _groups = groups;
          _samples = samples;
        });
      }
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _transitionStep(StepRecord step) async {
    try {
      if (step.state == 'running') {
        final captured = await _captureStep(step);
        if (captured == null) return;
        widget.core.runs.completeStep(step.stepId, captured: captured);
      } else {
        widget.core.runs.startStep(step.stepId);
      }
      await _reload();
    } on Object catch (error) {
      if (mounted) _showError(error);
    }
  }

  Future<Map<String, Object?>?> _captureStep(StepRecord step) async {
    if (!step.humanGate) return const <String, Object?>{};
    final controller = TextEditingController();
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('完成：${step.title}'),
        content: TextField(
          controller: controller,
          maxLines: 3,
          decoration: const InputDecoration(labelText: '记录观察或备注（可留空）'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('完成步骤'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (value == null) return null;
    return value.trim().isEmpty
        ? const <String, Object?>{}
        : <String, Object?>{'observation': value.trim()};
  }

  void _showError(Object error) => ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text('操作未完成：$error')));

  Future<void> _recordMeasurement() async {
    final analyte = TextEditingController();
    final value = TextEditingController();
    final unit = TextEditingController();
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('记录测量值'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: analyte,
              decoration: const InputDecoration(labelText: '分析物/指标'),
            ),
            TextField(
              controller: value,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
                signed: true,
              ),
              decoration: const InputDecoration(labelText: '原始值'),
            ),
            TextField(
              controller: unit,
              decoration: const InputDecoration(labelText: '单位（可选）'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('保存原始测量'),
          ),
        ],
      ),
    );
    if (accepted != true ||
        analyte.text.trim().isEmpty ||
        value.text.trim().isEmpty) {
      analyte.dispose();
      value.dispose();
      unit.dispose();
      return;
    }
    try {
      widget.core.runs.recordMeasurement(
        runId: widget.run.runId,
        analyte: analyte.text.trim(),
        valueText: value.text.trim(),
        unit: unit.text.trim().isEmpty ? null : unit.text.trim(),
        state: 'recorded',
        sourceMethod: 'manual_entry',
      );
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('原始测量值已保存。')));
      }
    } on Object catch (error) {
      if (mounted) _showError(error);
    } finally {
      analyte.dispose();
      value.dispose();
      unit.dispose();
    }
  }

  Future<void> _attachEvidence() async {
    try {
      final imported = await AssetImportPicker(widget.assets).pickAndImport(
        kind: AssetKind.raw,
        links: [
          AssetLinkRef(
            targetType: 'run',
            targetId: widget.run.runId,
            role: 'raw_evidence',
          ),
        ],
      );
      if (mounted && imported.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已导入并关联 ${imported.length} 个原始证据文件。')),
        );
      }
    } on Object catch (error) {
      if (mounted) _showError(error);
    }
  }

  Future<void> _scheduleRun() async {
    final now = DateTime.now();
    final selected = await showDatePicker(
      context: context,
      initialDate: _run.plannedStartUtc?.toLocal() ?? now,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 10),
      helpText: '选择计划开始日期',
    );
    if (selected == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(
        _run.plannedStartUtc?.toLocal() ?? now,
      ),
    );
    if (time == null) return;
    final local = DateTime(
      selected.year,
      selected.month,
      selected.day,
      time.hour,
      time.minute,
    );
    try {
      final plan = widget.core.schedule.rebuildPlan(
        runId: _run.runId,
        startAtUtc: local.toUtc(),
      );
      await _reload();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '计划已重建 · ${plan.steps.length} 步 · ${plan.warnings.length} 条提示',
            ),
          ),
        );
      }
    } on Object catch (error) {
      if (mounted) _showError(error);
    }
  }

  Future<void> _closeRun(String state) async {
    final reason = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(switch (state) {
          'completed' => '完成运行？',
          'failed' => '标记运行失败？',
          _ => '取消运行？',
        }),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('完成要求所有步骤完成或跳过；失败或取消会关闭剩余步骤并保留完整事件记录。'),
            TextField(
              controller: reason,
              minLines: 2,
              maxLines: 4,
              decoration: const InputDecoration(labelText: '原因（失败或取消必填）'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('返回'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认终止'),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      reason.dispose();
      return;
    }
    try {
      final cleanReason = reason.text.trim();
      if (state != 'completed' && cleanReason.isEmpty) {
        throw const FormatException('失败或取消运行必须填写原因。');
      }
      widget.core.runs.closeRun(
        runId: _run.runId,
        expectedRevision: _run.revision,
        state: state,
        reason: cleanReason.isEmpty ? null : cleanReason,
      );
      await _reload();
    } on Object catch (error) {
      if (mounted) _showError(error);
    } finally {
      reason.dispose();
    }
  }

  Future<void> _createGroup() async {
    final title = TextEditingController();
    final conditions = TextEditingController(text: '{}');
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('新建实验组'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: title,
              decoration: const InputDecoration(labelText: '组名'),
            ),
            TextField(
              controller: conditions,
              decoration: const InputDecoration(labelText: '处理条件 JSON'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final parsed = jsonDecode(conditions.text);
      if (parsed is! Map) throw const FormatException('条件必须为 JSON object');
      widget.core.groups.createGroup(
        runId: widget.run.runId,
        title: title.text,
        conditions: Map<String, Object?>.from(parsed),
      );
      await _reload();
    } on Object catch (error) {
      if (mounted) _showError(error);
    } finally {
      title.dispose();
      conditions.dispose();
    }
  }

  Future<void> _createSample() async {
    final name = TextEditingController();
    String? groupId;
    final selected = await showDialog<(String, String?)>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('登记样本'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: name,
                decoration: const InputDecoration(labelText: '样本名称'),
              ),
              DropdownButtonFormField<String?>(
                initialValue: null,
                decoration: const InputDecoration(labelText: '实验组（可选）'),
                items: [
                  const DropdownMenuItem<String?>(
                    value: null,
                    child: Text('未分组'),
                  ),
                  for (final group in _groups)
                    DropdownMenuItem<String?>(
                      value: group.groupId,
                      child: Text(group.title),
                    ),
                ],
                onChanged: (value) => setDialogState(() => groupId = value),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, (name.text, groupId)),
              child: const Text('登记'),
            ),
          ],
        ),
      ),
    );
    name.dispose();
    if (selected == null || selected.$1.trim().isEmpty) return;
    try {
      widget.core.samples.createSample(
        name: selected.$1.trim(),
        runId: widget.run.runId,
        groupId: selected.$2,
      );
      await _reload();
    } on Object catch (error) {
      if (mounted) _showError(error);
    }
  }

  Future<void> _recordTreatment(SampleRecord sample) async {
    final json = TextEditingController(text: '{"condition":""}');
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('记录处理 · ${sample.name}'),
        content: TextField(
          controller: json,
          minLines: 3,
          maxLines: 8,
          decoration: const InputDecoration(labelText: '条件 JSON object'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('保存处理'),
          ),
        ],
      ),
    );
    if (ok != true) {
      json.dispose();
      return;
    }
    try {
      final parsed = jsonDecode(json.text);
      if (parsed is! Map) throw const FormatException('处理条件必须为 JSON object');
      widget.core.samples.recordTreatment(
        sampleId: sample.sampleId,
        runId: widget.run.runId,
        conditions: Map<String, Object?>.from(parsed),
        appliedAtUtc: DateTime.now().toUtc(),
      );
      await _reload();
    } on Object catch (error) {
      if (mounted) _showError(error);
    } finally {
      json.dispose();
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      WorkspacePageHeader(
        title: _run.title,
        subtitle: _run.protocolId == null
            ? 'Quick Run · 原始记录与测量值'
            : 'Protocol ${_run.protocolId} @ ${_run.protocolVersion}',
        icon: Icons.play_circle_outline_rounded,
        breadcrumbs: [widget.experimentTitle, '运行详情'],
        actions: [
          OutlinedButton.icon(
            onPressed: _busy ? null : _attachEvidence,
            icon: const Icon(Icons.attach_file),
            label: const Text('关联原始文件'),
          ),
          FilledButton.icon(
            onPressed:
                const {'completed', 'failed', 'cancelled'}.contains(_run.state)
                ? null
                : _recordMeasurement,
            icon: const Icon(Icons.add_chart),
            label: const Text('记录测量'),
          ),
        ],
      ),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: widget.onBack,
          icon: const Icon(Icons.arrow_back),
          label: const Text('返回运行列表'),
        ),
      ),
      Expanded(
        child: ListView(
          padding: const EdgeInsets.only(bottom: 20),
          children: [
            Card(
              child: ListTile(
                leading: Icon(
                  _run.protocolId == null
                      ? Icons.flash_on_outlined
                      : Icons.fact_check_outlined,
                ),
                title: Text(
                  _run.protocolId == null
                      ? 'Quick Run · ${_runStateLabel(_run.state)}'
                      : 'Protocol Run · ${_runStateLabel(_run.state)}',
                ),
                subtitle: Text(
                  '创建 ${_run.createdAtUtc.toLocal()}\n计划开始 ${_run.plannedStartUtc?.toLocal() ?? '未安排'} · 实际开始 ${_run.startedAtUtc?.toLocal() ?? '尚未开始'} · 实际结束 ${_run.finishedAtUtc?.toLocal() ?? '进行中'}',
                ),
                isThreeLine: true,
                trailing: Wrap(
                  spacing: 4,
                  children: [
                    if (!const {
                      'completed',
                      'failed',
                      'cancelled',
                    }.contains(_run.state))
                      IconButton(
                        onPressed: _scheduleRun,
                        tooltip: '重建计划时间线',
                        icon: const Icon(Icons.schedule),
                      ),
                    if (!const {
                      'completed',
                      'failed',
                      'cancelled',
                    }.contains(_run.state))
                      PopupMenuButton<String>(
                        onSelected: _closeRun,
                        itemBuilder: (_) => const [
                          PopupMenuItem(
                            value: 'completed',
                            child: Text('完成运行'),
                          ),
                          PopupMenuItem(value: 'failed', child: Text('标记失败')),
                          PopupMenuItem(
                            value: 'cancelled',
                            child: Text('取消运行'),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Wrap(
                  spacing: 8,
                  children: [
                    OutlinedButton.icon(
                      onPressed:
                          const {
                            'completed',
                            'failed',
                            'cancelled',
                          }.contains(_run.state)
                          ? null
                          : _createGroup,
                      icon: const Icon(Icons.groups_outlined),
                      label: Text('实验组 (${_groups.length})'),
                    ),
                    OutlinedButton.icon(
                      onPressed:
                          const {
                            'completed',
                            'failed',
                            'cancelled',
                          }.contains(_run.state)
                          ? null
                          : _createSample,
                      icon: const Icon(Icons.science_outlined),
                      label: Text('样本 (${_samples.length})'),
                    ),
                  ],
                ),
              ),
            ),
            if (_groups.isNotEmpty || _samples.isNotEmpty) ...[
              const ListTile(title: Text('组别、样本与处理')),
              for (final group in _groups)
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.groups_outlined),
                  title: Text(group.title),
                  subtitle: Text('条件：${jsonEncode(group.conditions)}'),
                ),
              for (final sample in _samples)
                Builder(
                  builder: (context) {
                    final treatments = widget.core.samples.listTreatments(
                      sampleId: sample.sampleId,
                      runId: widget.run.runId,
                    );
                    return Card(
                      child: Column(
                        children: [
                          ListTile(
                            title: Text(sample.name),
                            subtitle: Text(
                              '样本 ${sample.sampleId} · ${treatments.length} 项处理记录',
                            ),
                            trailing: TextButton(
                              onPressed:
                                  const {
                                    'completed',
                                    'failed',
                                    'cancelled',
                                  }.contains(_run.state)
                                  ? null
                                  : () => _recordTreatment(sample),
                              child: const Text('记录处理'),
                            ),
                          ),
                          for (final treatment in treatments)
                            ListTile(
                              dense: true,
                              leading: const Icon(Icons.medication_outlined),
                              title: Text(
                                '处理时间 ${treatment.appliedAtUtc?.toLocal() ?? '未指定'}',
                              ),
                              subtitle: Text(
                                '条件：${jsonEncode(treatment.conditions)}${treatment.correctedFrom == null ? '' : ' · 更正 ${treatment.correctedFrom}'}',
                              ),
                            ),
                        ],
                      ),
                    );
                  },
                ),
            ],
            if (_busy) const LinearProgressIndicator(),
            if (_error != null)
              MaterialBanner(
                content: Text('无法读取步骤：$_error'),
                actions: [
                  TextButton(onPressed: _reload, child: const Text('重试')),
                ],
              ),
            const WorkspaceSectionHeader(
              title: '执行步骤',
              subtitle: '步骤状态、计划时间与人工记录要求。',
            ),
            if (_steps.isEmpty)
              const WorkspaceEmptyState(
                icon: Icons.rule_outlined,
                title: '此运行尚无协议步骤',
                description: 'Quick Run 可以直接记录测量值；绑定 Protocol 的新运行会在这里生成步骤。',
              )
            else
              for (final step in _steps)
                Builder(
                  builder: (context) {
                    final canStart =
                        step.state == 'pending' || step.state == 'ready';
                    final canComplete = step.state == 'running';
                    return Card(
                      child: ListTile(
                        leading: Icon(
                          step.state == 'completed'
                              ? Icons.check_circle_outline
                              : Icons.radio_button_unchecked,
                        ),
                        title: Text(step.title),
                        subtitle: Text(
                          '${_stepStateLabel(step.state)}${step.humanGate ? ' · 需要人工记录' : ''}\n'
                          '计划 ${step.plannedStartUtc?.toLocal() ?? '未安排'} → ${step.plannedEndUtc?.toLocal() ?? '未知'} · '
                          '实际 ${step.startedAtUtc?.toLocal() ?? '未开始'} → ${step.completedAtUtc?.toLocal() ?? '未完成'}'
                          '${step.dependencies.isEmpty ? '' : '\n依赖 ${step.dependencies.length} 个前序步骤'}',
                        ),
                        isThreeLine: true,
                        trailing: canStart || canComplete
                            ? TextButton(
                                onPressed: _busy
                                    ? null
                                    : () => _transitionStep(step),
                                child: Text(canComplete ? '完成' : '开始'),
                              )
                            : null,
                      ),
                    );
                  },
                ),
          ],
        ),
      ),
    ],
  );
}
