import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:lab_core/lab_core.dart';

class CalculationPage extends StatefulWidget {
  const CalculationPage({
    required this.packs,
    required this.calculations,
    required this.approvals,
    super.key,
  });

  final CalculationPackRegistry packs;
  final CalculationService calculations;
  final ApprovalService approvals;

  @override
  State<CalculationPage> createState() => _CalculationPageState();
}

class _CalculationPageState extends State<CalculationPage> {
  List<InstalledPackRecord> _packs = const [];
  List<CalculationRun> _runs = const [];
  Object? _error;
  bool _busy = false;
  Timer? _poll;
  late final Future<CalculationCapabilities> _capabilities;

  @override
  void initState() {
    super.initState();
    _capabilities = widget.calculations.probe();
    _refresh();
    _poll = Timer.periodic(const Duration(seconds: 1), (_) {
      if (widget.calculations.activeJobs.isNotEmpty) _refresh();
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final packs = await widget.packs.listInstalled();
      final runs = await widget.calculations.listRecent(limit: 50);
      if (!mounted) return;
      setState(() {
        _packs = packs;
        _runs = runs;
        _error = null;
      });
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  Future<void> _installBuiltIns() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('安装内置计算 Pack？'),
        content: const Text(
          '将安装随应用签名发布的计算 Pack。安装时会核对固定内容哈希和 Pack 声明的合成校验样例。'
          '这些样例不会接触实验数据。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('安装并核验'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => _busy = true);
    try {
      final records = await widget.packs.installTrustedBuiltIns();
      await _refresh();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已核验并安装 ${records.length} 个内置 Pack。')),
        );
      }
    } on Object catch (error) {
      if (mounted) _showError(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _start(InstalledPackRecord pack) async {
    try {
      final versioned = await widget.packs.getInstalled(
        pack.packId,
        pack.version,
      );
      if (!mounted) return;
      final values = await showDialog<Map<String, Object?>>(
        context: context,
        builder: (context) =>
            _InputSnapshotDialog(document: versioned.document),
      );
      if (values == null || !mounted) return;
      final id = await widget.calculations.start(
        packId: pack.packId,
        packVersion: pack.version,
        inputSnapshot: values,
      );
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('已排入本机计算，记录 ID：$id')));
      }
      await _refresh();
    } on Object catch (error) {
      if (mounted) _showError(error);
    }
  }

  Future<void> _importDraft() async {
    final review = await showDialog<_PackReview>(
      context: context,
      builder: (context) => _PackDraftDialog(registry: widget.packs),
    );
    if (review == null || !mounted) return;
    final document = review.document;
    final packId = document['pack_id']! as String;
    final version = document['version']! as String;
    final contentSha = review.validation.contentSha256!;
    final subjectId = '$packId@$version#$contentSha';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('审批并安装计算 Pack？'),
        content: SizedBox(
          width: 620,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('${document['title']} · $packId @ $version'),
                const SizedBox(height: 8),
                SelectableText('不可变内容 SHA-256：$contentSha'),
                const SizedBox(height: 8),
                if (review.validation.warnings.isNotEmpty)
                  Text('警告：\n${review.validation.warnings.join('\n')}'),
                const SizedBox(height: 8),
                Text('声明样例核验：${review.golden.cases.length} 项通过。'),
                const SizedBox(height: 8),
                const Text('安装后该冻结版本才可被计算服务调用。未审批草稿不会执行；审批绑定以上精确 SHA-256。'),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('明确审批并安装'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final approval = widget.approvals.issue(
        action: 'install_calculation_pack',
        subjectType: 'calculation_pack',
        subjectId: subjectId,
        scope: <String, Object?>{
          'pack_id': packId,
          'version': version,
          'content_sha256': contentSha,
        },
      );
      await widget.packs.approveAndInstall(
        document,
        approval,
        validation: review.validation,
        goldenReport: review.golden,
      );
      await _refresh();
    } on Object catch (error) {
      if (mounted) _showError(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _showTrace(CalculationRun run, {String? focusOutput}) async {
    try {
      final trace = await widget.calculations.getTrace(run.calculationId);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(
            focusOutput == null ? '原始 CalculationTrace' : '派生值 · $focusOutput',
          ),
          content: SizedBox(
            width: 760,
            child: SingleChildScrollView(
              child: SelectableText(
                '${focusOutput == null ? '' : '查看值：$focusOutput\n'}SHA-256：${trace.contentSha256}\n\n${trace.canonicalJson}',
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('关闭'),
            ),
          ],
        ),
      );
    } on Object catch (error) {
      if (mounted) _showError(error);
    }
  }

  void _showError(Object error) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('操作失败：$error')));
  }

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(24),
    children: [
      Text('声明式计算', style: Theme.of(context).textTheme.headlineMedium),
      const SizedBox(height: 8),
      const Text('计算仅接受已安装、已审批且哈希固定的 Pack。结果保存在本机，并必须可查看原始计算轨迹。'),
      if (_error != null)
        MaterialBanner(
          content: Text('读取计算状态失败：$_error'),
          actions: [TextButton(onPressed: _refresh, child: const Text('重试'))],
        ),
      const SizedBox(height: 12),
      Wrap(
        spacing: 12,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          FilledButton.icon(
            onPressed: _busy ? null : _installBuiltIns,
            icon: const Icon(Icons.verified_outlined),
            label: const Text('安装/核验内置 Pack'),
          ),
          OutlinedButton.icon(
            onPressed: _busy ? null : _importDraft,
            icon: const Icon(Icons.upload_file_outlined),
            label: const Text('导入、审查并审批 Pack'),
          ),
          OutlinedButton.icon(
            onPressed: _refresh,
            icon: const Icon(Icons.refresh),
            label: const Text('刷新'),
          ),
          FutureBuilder<CalculationCapabilities>(
            future: _capabilities,
            builder: (context, snapshot) {
              final result = snapshot.data;
              if (snapshot.hasError) return const Chip(label: Text('执行器不可用'));
              if (result == null) return const Chip(label: Text('检查执行器…'));
              return Chip(
                avatar: Icon(
                  result.available ? Icons.memory : Icons.error_outline,
                  size: 18,
                ),
                label: Text(
                  result.available
                      ? '${result.executorId} · ${result.supportedOperations.length} 种操作'
                      : result.unsupportedReason ?? '执行器不可用',
                ),
              );
            },
          ),
        ],
      ),
      const SizedBox(height: 20),
      Text('已安装 Pack', style: Theme.of(context).textTheme.titleLarge),
      if (_packs.isEmpty)
        const Card(
          child: ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('尚无已安装 Pack'),
            subtitle: Text('先安装并核验随应用发布的内置 Pack。'),
          ),
        )
      else
        for (final pack in _packs)
          Card(
            child: ListTile(
              leading: const Icon(Icons.functions),
              title: Text('${pack.packId} @ ${pack.version}'),
              subtitle: Text(
                '${pack.origin} · ${pack.trustLevel}\nSHA-256 ${pack.contentSha256}',
              ),
              isThreeLine: true,
              trailing: IconButton(
                tooltip: '填写输入并运行',
                onPressed: () => _start(pack),
                icon: const Icon(Icons.play_arrow),
              ),
            ),
          ),
      const SizedBox(height: 20),
      Text('本机计算记录', style: Theme.of(context).textTheme.titleLarge),
      if (_runs.isEmpty)
        const Card(child: ListTile(title: Text('暂无计算记录。')))
      else
        for (final run in _runs) _calculationRunCard(run),
    ],
  );

  Widget _calculationRunCard(CalculationRun run) {
    final traceOutputs = run.trace?.document['outputs'];
    final rows = traceOutputs is List
        ? traceOutputs
              .whereType<Map>()
              .map((row) => Map<String, Object?>.from(row))
              .toList(growable: false)
        : const <Map<String, Object?>>[];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListTile(
              leading: Icon(
                run.status == CalculationStatus.completed
                    ? Icons.check_circle_outline
                    : Icons.error_outline,
              ),
              title: Text(
                '${run.packId} @ ${run.packVersion} · ${run.status.name}',
              ),
              subtitle: Text(
                '${run.calculationId} · ${run.completedAtUtc?.toLocal()}\n${run.parentCalculationId == null ? '' : '重算自 ${run.parentCalculationId} · '}Pack SHA-256 ${run.packSha256}',
              ),
              isThreeLine: true,
              trailing: run.trace == null
                  ? null
                  : FilledButton.tonal(
                      onPressed: () => _showTrace(run),
                      child: const Text('展示原始计算'),
                    ),
            ),
            if (run.trace != null && rows.isNotEmpty) ...[
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: Text('每个派生值都可追溯到同一不可变 CalculationTrace：'),
              ),
              for (final row in rows)
                ListTile(
                  dense: true,
                  title: Text(
                    '${row['key'] ?? '输出'} = ${row['value'] ?? ''}${row['unit'] == null ? '' : ' ${row['unit']}'}',
                  ),
                  subtitle: Text('来源：${row['source_ref'] ?? 'trace output'}'),
                  trailing: TextButton(
                    onPressed: () =>
                        _showTrace(run, focusOutput: '${row['key']}'),
                    child: const Text('展示原始计算'),
                  ),
                ),
            ] else if (run.output != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: SelectableText('输出：${jsonEncode(run.output)}'),
              ),
          ],
        ),
      ),
    );
  }
}

class _InputSnapshotDialog extends StatefulWidget {
  const _InputSnapshotDialog({required this.document});

  final Map<String, Object?> document;

  @override
  State<_InputSnapshotDialog> createState() => _InputSnapshotDialogState();
}

class _InputSnapshotDialogState extends State<_InputSnapshotDialog> {
  late final List<Map<String, Object?>> _fields;
  late final List<TextEditingController> _controllers;
  String? _error;

  @override
  void initState() {
    super.initState();
    final rawFields = widget.document['inputs'];
    _fields = rawFields is List
        ? rawFields
              .whereType<Map>()
              .map((field) => Map<String, Object?>.from(field))
              .toList()
        : const [];
    _controllers = _fields.map((field) {
      return TextEditingController(
        text: field['kind'] == 'table'
            ? '[\n  {"concentration":"0","absorbance":"0"}\n]'
            : '',
      );
    }).toList();
  }

  @override
  void dispose() {
    for (final controller in _controllers) {
      controller.dispose();
    }
    super.dispose();
  }

  void _submit() {
    final values = <String, Object?>{};
    try {
      for (var i = 0; i < _fields.length; i++) {
        final field = _fields[i];
        final key = field['key']! as String;
        final kind = field['kind'];
        final text = _controllers[i].text.trim();
        if (text.isEmpty && field['required'] == true) {
          throw FormatException('请填写必填项：$key');
        }
        if (text.isEmpty) continue;
        if (kind == 'table') {
          values[key] = jsonDecode(text);
        } else if (kind == 'asset_ref' || kind == 'sample_ref') {
          values[key] = text;
        } else if (kind == 'boolean') {
          if (text != 'true' && text != 'false') {
            throw FormatException('$key 必须填写 true 或 false。');
          }
          values[key] = text == 'true';
        } else {
          // Keep decimal values as exact text; the deterministic decimal engine
          // parses these without a binary floating-point conversion.
          values[key] = text;
        }
      }
      Navigator.pop(context, values);
    } on Object catch (error) {
      setState(() => _error = error.toString());
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('输入快照 · ${widget.document['title'] ?? 'Calculation Pack'}'),
    content: SizedBox(
      width: 620,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < _fields.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: TextField(
                  controller: _controllers[i],
                  minLines: _fields[i]['kind'] == 'table' ? 4 : 1,
                  maxLines: _fields[i]['kind'] == 'table' ? 8 : 1,
                  decoration: InputDecoration(
                    labelText:
                        '${_fields[i]['key']}${_fields[i]['required'] == true ? ' *' : ''}',
                    helperText: _fields[i]['kind'] == 'table'
                        ? 'JSON 数组，例如 [{"concentration":"0","absorbance":"0.04"}]'
                        : (_fields[i]['unit'] == null
                              ? null
                              : '单位：${_fields[i]['unit']}'),
                    border: const OutlineInputBorder(),
                  ),
                ),
              ),
            if (_error != null)
              Align(
                alignment: Alignment.centerLeft,
                child: Text(_error!, style: const TextStyle(color: Colors.red)),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(onPressed: _submit, child: const Text('开始本机计算')),
    ],
  );
}

class _PackReview {
  const _PackReview({
    required this.document,
    required this.validation,
    required this.golden,
  });

  final Map<String, Object?> document;
  final PackValidationReport validation;
  final PackGoldenTestReport golden;
}

class _PackDraftDialog extends StatefulWidget {
  const _PackDraftDialog({required this.registry});

  final CalculationPackRegistry registry;

  @override
  State<_PackDraftDialog> createState() => _PackDraftDialogState();
}

class _PackDraftDialogState extends State<_PackDraftDialog> {
  final _controller = TextEditingController();
  Map<String, Object?>? _document;
  PackValidationReport? _validation;
  PackGoldenTestReport? _golden;
  Object? _error;
  bool _checking = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _validateAndCheckFixtures() async {
    setState(() {
      _checking = true;
      _error = null;
      _validation = null;
      _golden = null;
    });
    try {
      final decoded = jsonDecode(_controller.text);
      if (decoded is! Map<String, Object?>) {
        throw const FormatException('Pack 文档必须是 JSON object。');
      }
      if (decoded['status'] != 'draft') {
        throw const FormatException('导入内容必须是 status=draft；不能导入伪装为已批准的 Pack。');
      }
      final validation = widget.registry.validate(decoded);
      final golden = validation.valid
          ? widget.registry.testPack(decoded)
          : null;
      setState(() {
        _document = decoded;
        _validation = validation;
        _golden = golden;
      });
    } on Object catch (error) {
      setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final validation = _validation;
    final golden = _golden;
    return AlertDialog(
      title: const Text('导入 Calculation Pack 草稿'),
      content: SizedBox(
        width: 760,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '仅接受符合声明式 Pack schema 的 JSON。未经验证、未通过声明样例、'
                '或包含不支持运算的草稿不会安装或执行。',
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _controller,
                minLines: 12,
                maxLines: 22,
                decoration: const InputDecoration(
                  labelText: 'Draft JSON',
                  border: OutlineInputBorder(),
                ),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    '校验失败：$_error',
                    style: const TextStyle(color: Colors.red),
                  ),
                ),
              if (validation != null) ...[
                const SizedBox(height: 12),
                Text('结构与运算校验：${validation.valid ? '通过' : '失败'}'),
                if (validation.contentSha256 != null)
                  SelectableText('SHA-256：${validation.contentSha256}'),
                if (validation.errors.isNotEmpty)
                  Text('错误：\n${validation.errors.join('\n')}'),
                if (validation.unsupportedOperations.isNotEmpty)
                  Text('不支持的运算：${validation.unsupportedOperations.join(', ')}'),
                if (validation.warnings.isNotEmpty)
                  Text('警告：\n${validation.warnings.join('\n')}'),
                if (golden != null)
                  Text(
                    '声明样例：${golden.passed ? '通过' : '失败'}'
                    '${golden.errors.isEmpty ? '' : '\n${golden.errors.join('\n')}'}',
                  ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        OutlinedButton(
          onPressed: _checking ? null : _validateAndCheckFixtures,
          child: Text(_checking ? '校验中…' : '校验并运行声明样例'),
        ),
        FilledButton(
          onPressed: validation?.valid == true && golden?.passed == true
              ? () => Navigator.pop(
                  context,
                  _PackReview(
                    document: _document!,
                    validation: validation!,
                    golden: golden!,
                  ),
                )
              : null,
          child: const Text('继续审批'),
        ),
      ],
    );
  }
}
