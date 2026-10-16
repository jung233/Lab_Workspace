import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:lab_core/lab_core.dart';

import '../platform/asset_import_picker.dart';

class ExperimentsPage extends StatefulWidget {
  const ExperimentsPage({required this.core, super.key});

  final LabCore core;

  @override
  State<ExperimentsPage> createState() => _ExperimentsPageState();
}

class _ExperimentsPageState extends State<ExperimentsPage> {
  List<ProjectRecord> _projects = const [];
  List<ExperimentRecord> _experiments = const [];
  String? _selectedProjectId;
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
      widget.core.projects.createProject(title: value.trim());
      await _reload();
    } on Object catch (error) {
      if (mounted) _showError(error);
    }
  }

  Future<void> _createExperiment() async {
    if (_projects.isEmpty) {
      _showError(StateError('请先创建一个项目。'));
      return;
    }
    final value = await _textPrompt(title: '新建实验', label: '实验名称');
    if (value == null || value.trim().isEmpty) return;
    try {
      widget.core.experiments.createExperiment(
        title: value.trim(),
        projectId: _selectedProjectId,
      );
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
          onSubmitted: (value) => Navigator.pop(context, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    return result;
  }

  void _showError(Object error) => ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text('操作未完成：$error')));

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.all(16),
        child: Wrap(
          spacing: 12,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text('项目与实验', style: Theme.of(context).textTheme.headlineSmall),
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
      ),
      if (_busy) const LinearProgressIndicator(),
      if (_error != null)
        MaterialBanner(
          content: Text('无法读取本地实验数据：$_error'),
          actions: [TextButton(onPressed: _reload, child: const Text('重试'))],
        ),
      Expanded(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final projectList = _projectList();
            if (constraints.maxWidth < 680) {
              return Column(
                children: [
                  SizedBox(height: 180, child: projectList),
                  const Divider(height: 1),
                  Expanded(child: _experimentList()),
                ],
              );
            }
            return Row(
              children: [
                SizedBox(width: 280, child: projectList),
                const VerticalDivider(width: 1),
                Expanded(child: _experimentList()),
              ],
            );
          },
        ),
      ),
    ],
  );

  Widget _projectList() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const ListTile(title: Text('项目')),
      Expanded(
        child: ListView(
          children: [
            ListTile(
              selected: _selectedProjectId == null,
              leading: const Icon(Icons.all_inbox_outlined),
              title: const Text('所有项目'),
              onTap: () {
                setState(() => _selectedProjectId = null);
                _reload();
              },
            ),
            for (final project in _projects)
              ListTile(
                selected: _selectedProjectId == project.projectId,
                leading: const Icon(Icons.folder_outlined),
                title: Text(
                  project.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () {
                  setState(() => _selectedProjectId = project.projectId);
                  _reload();
                },
              ),
          ],
        ),
      ),
    ],
  );

  Widget _experimentList() => _experiments.isEmpty
      ? const Center(child: Text('当前筛选条件下没有实验。'))
      : ListView.separated(
          itemCount: _experiments.length,
          separatorBuilder: (_, _) => const Divider(height: 1),
          itemBuilder: (context, index) {
            final experiment = _experiments[index];
            return ListTile(
              leading: const Icon(Icons.science_outlined),
              title: Text(experiment.title),
              subtitle: Text('本地记录 · ${experiment.experimentId}'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push<void>(
                MaterialPageRoute<void>(
                  builder: (_) => ExperimentRunsPage(
                    core: widget.core,
                    experiment: experiment,
                  ),
                ),
              ),
            );
          },
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

class _RunCreationForm extends StatefulWidget {
  const _RunCreationForm({required this.defaultTitle, required this.protocols});
  final String defaultTitle;
  final List<ProtocolVersionRecord> protocols;

  @override
  State<_RunCreationForm> createState() => _RunCreationFormState();
}

class _RunCreationFormState extends State<_RunCreationForm> {
  late final TextEditingController _title = TextEditingController(
    text: widget.defaultTitle,
  );
  ProtocolVersionRecord? _protocol;
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

  void _selectProtocol(ProtocolVersionRecord? value) {
    for (final controller in _fields.values) {
      controller.dispose();
    }
    _fields.clear();
    final variables = value?.document['variables'];
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
    setState(() => _protocol = value);
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
            parameters[key] = text;
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
        DropdownButtonFormField<ProtocolVersionRecord?>(
          initialValue: _protocol,
          decoration: const InputDecoration(
            labelText: 'Protocol 版本（可选；不选即 Quick Run）',
          ),
          items: [
            const DropdownMenuItem<ProtocolVersionRecord?>(
              value: null,
              child: Text('Quick Run · 无协议步骤'),
            ),
            for (final protocol in widget.protocols)
              DropdownMenuItem<ProtocolVersionRecord?>(
                value: protocol,
                child: Text('${protocol.title} @ ${protocol.version}'),
              ),
          ],
          onChanged: _selectProtocol,
        ),
        if (_protocol != null) ...[
          const SizedBox(height: 8),
          for (final item
              in (_protocol!.document['variables'] as List? ?? const [])
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

class ExperimentRunsPage extends StatefulWidget {
  const ExperimentRunsPage({
    required this.core,
    required this.experiment,
    super.key,
  });

  final LabCore core;
  final ExperimentRecord experiment;

  @override
  State<ExperimentRunsPage> createState() => _ExperimentRunsPageState();
}

class _ExperimentRunsPageState extends State<ExperimentRunsPage> {
  List<RunRecord> _runs = const [];
  List<ProtocolVersionRecord> _approvedProtocols = const [];
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
      final protocols = widget.core.protocols
          .listProtocols()
          .expand((item) => widget.core.protocols.listVersions(item.protocolId))
          .where((version) => version.isApproved)
          .toList(growable: false);
      if (mounted) {
        setState(() {
          _runs = runs;
          _approvedProtocols = protocols;
        });
      }
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _createRun() async {
    final run = await showDialog<_RunCreation>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('新建运行'),
        content: SizedBox(
          width: 640,
          child: _RunCreationForm(
            defaultTitle: '${widget.experiment.title} run ${_runs.length + 1}',
            protocols: _approvedProtocols,
          ),
        ),
        actions: const [],
      ),
    );
    if (run == null || run.title.trim().isEmpty) return;
    try {
      final created = widget.core.runs.createRun(
        experimentId: widget.experiment.experimentId,
        title: run.title.trim(),
        protocolId: run.protocol?.protocolId,
        protocolVersion: run.protocol?.version,
        parameters: run.parameters,
        plannedStartUtc: run.plannedStartUtc,
      );
      if (run.plannedStartUtc != null && created.protocolId != null) {
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

  void _showError(Object error) => ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text('操作未完成：$error')));

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.experiment.title)),
    floatingActionButton: FloatingActionButton.extended(
      onPressed: _busy ? null : _createRun,
      icon: const Icon(Icons.add),
      label: const Text('新建运行'),
    ),
    body: Column(
      children: [
        if (_busy) const LinearProgressIndicator(),
        if (_error != null)
          MaterialBanner(
            content: Text('无法读取运行记录：$_error'),
            actions: [TextButton(onPressed: _reload, child: const Text('重试'))],
          ),
        Expanded(
          child: _runs.isEmpty
              ? const Center(child: Text('尚无运行记录。'))
              : ListView.separated(
                  itemCount: _runs.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final run = _runs[index];
                    return ListTile(
                      leading: const Icon(Icons.play_circle_outline),
                      title: Text(run.title),
                      subtitle: Text(
                        '${run.protocolId == null ? 'Quick Run' : 'Protocol ${run.protocolId} @ ${run.protocolVersion}'} · ${run.state}\n创建 ${run.createdAtUtc.toLocal()} · 计划 ${run.plannedStartUtc?.toLocal() ?? '未安排'} · 实际开始 ${run.startedAtUtc?.toLocal() ?? '未开始'}',
                      ),
                      isThreeLine: true,
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Navigator.of(context).push<void>(
                        MaterialPageRoute<void>(
                          builder: (_) => RunDetailPage(
                            core: widget.core,
                            run: run,
                            assets: widget.core.assets,
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    ),
  );
}

class RunDetailPage extends StatefulWidget {
  const RunDetailPage({
    required this.core,
    required this.run,
    required this.assets,
    super.key,
  });

  final LabCore core;
  final RunRecord run;
  final AssetGateway assets;

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
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.run.title)),
    floatingActionButton: FloatingActionButton.extended(
      onPressed: const {'completed', 'failed', 'cancelled'}.contains(_run.state)
          ? null
          : _recordMeasurement,
      icon: const Icon(Icons.add_chart),
      label: const Text('记录测量'),
    ),
    body: Column(
      children: [
        Align(
          alignment: Alignment.centerRight,
          child: Padding(
            padding: const EdgeInsets.only(right: 16, top: 8),
            child: OutlinedButton.icon(
              onPressed: _busy ? null : _attachEvidence,
              icon: const Icon(Icons.attach_file),
              label: const Text('导入并关联原始文件'),
            ),
          ),
        ),
        Card(
          child: ListTile(
            leading: Icon(
              _run.protocolId == null
                  ? Icons.flash_on_outlined
                  : Icons.fact_check_outlined,
            ),
            title: Text(
              _run.protocolId == null
                  ? 'Quick Run · ${_run.state}'
                  : 'Protocol Run · ${_run.state}',
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
                      PopupMenuItem(value: 'completed', child: Text('完成运行')),
                      PopupMenuItem(value: 'failed', child: Text('标记失败')),
                      PopupMenuItem(value: 'cancelled', child: Text('取消运行')),
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
            actions: [TextButton(onPressed: _reload, child: const Text('重试'))],
          ),
        Expanded(
          child: _steps.isEmpty
              ? const Center(child: Text('此运行尚无协议步骤。原始测量值仍可单独登记。'))
              : ListView.builder(
                  itemCount: _steps.length,
                  itemBuilder: (context, index) {
                    final step = _steps[index];
                    final canStart =
                        step.state == 'pending' || step.state == 'ready';
                    final canComplete = step.state == 'running';
                    return ListTile(
                      leading: Icon(
                        step.state == 'completed'
                            ? Icons.check_circle_outline
                            : Icons.radio_button_unchecked,
                      ),
                      title: Text(step.title),
                      subtitle: Text(
                        '${step.state}${step.humanGate ? ' · 需要人工记录' : ''}\n'
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
                    );
                  },
                ),
        ),
      ],
    ),
  );
}
