import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:lab_core/lab_core.dart';

import '../platform/workspace_ai_provider.dart';
import '../widgets/ai_protocol_draft_dialog.dart';
import '../widgets/workspace_ui.dart';

/// Local versioned-protocol authoring and review. A version is immutable after
/// approval; live Runs may select approved versions only.
class ProtocolsPage extends StatefulWidget {
  const ProtocolsPage({
    required this.core,
    required this.packRegistry,
    required this.aiProvider,
    required this.onOpenProviderSettings,
    super.key,
  });

  final LabCore core;
  final CalculationPackRegistry packRegistry;
  final WorkspaceAiProvider aiProvider;
  final Future<void> Function() onOpenProviderSettings;

  @override
  State<ProtocolsPage> createState() => _ProtocolsPageState();
}

class _ProtocolsPageState extends State<ProtocolsPage> {
  List<ProtocolVersionRecord> _versions = const [];
  Object? _error;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void didUpdateWidget(covariant ProtocolsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _reload();
    });
  }

  Future<void> _reload() async {
    try {
      final protocols = widget.core.protocols.listProtocols(
        includeArchived: true,
      );
      final versions = protocols
          .expand(
            (protocol) =>
                widget.core.protocols.listVersions(protocol.protocolId),
          )
          .toList(growable: false);
      if (mounted) {
        setState(() {
          _versions = versions;
          _error = null;
        });
      }
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  Future<void> _newDraft() async {
    final editor = TextEditingController(
      text: const JsonEncoder.withIndent('  ').convert(_template()),
    );
    final raw = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('新建 Protocol v2 草稿'),
        content: SizedBox(
          width: 760,
          child: TextField(
            controller: editor,
            minLines: 18,
            maxLines: 28,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              labelText: 'Protocol JSON',
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, editor.text),
            child: const Text('校验并保存草稿'),
          ),
        ],
      ),
    );
    editor.dispose();
    if (raw == null) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        throw const FormatException('Protocol 必须是 JSON object。');
      }
      final document = Map<String, Object?>.from(decoded)
        ..['schema_version'] = '2.0'
        ..['status'] = 'draft'
        ..['review'] = <String, Object?>{
          'approved_by_user': false,
          'warnings': <String>[],
        };
      final report = ProtocolDocument.validate(document);
      if (!report.isValid) throw FormatException(report.errors.join('\n'));
      final saved = widget.core.protocols.saveDraft(document: document);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('草稿已保存：${saved.protocolId} @ ${saved.version}'),
          ),
        );
      }
      await _reload();
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Protocol 未保存：$error')));
      }
    }
  }

  Future<void> _createAiDraft() async {
    try {
      final providers = await widget.aiProvider.profiles.list();
      if (!mounted) return;
      final referenceVersions = widget.core.protocols
          .listProtocols(includeArchived: true)
          .expand(
            (protocol) =>
                widget.core.protocols.listVersions(protocol.protocolId),
          )
          .toList(growable: false);
      final draft = await showAiProtocolDraftDialog(
        context: context,
        service: AiProtocolDraftService(
          ai: widget.aiProvider.ai,
          calculationBinder: WorkflowCalculationPackBinder(widget.packRegistry),
        ),
        approvals: widget.core.approvals,
        providers: providers,
        referenceVersions: referenceVersions,
        onOpenProviderSettings: widget.onOpenProviderSettings,
      );
      if (draft == null) return;
      if (!draft.isValid || draft.unsupportedOperations.isNotEmpty) {
        _showMessage('草稿包含阻断错误，未保存。');
        return;
      }
      final saved = widget.core.protocols.saveDraft(
        document: draft.document,
        provenance: <String, Object?>{
          ...draft.provenance,
          'requires_user_input': draft.requiresUserInput,
        },
      );
      if (draft.requiresUserInput.isNotEmpty) {
        _showMessage(
          '草稿已保存为待审阅版本：${saved.protocolId} @ ${saved.version}。仍需补齐：${draft.requiresUserInput.join('、')}',
        );
      } else {
        _showMessage(
          'AI 草稿已保存待审阅：${saved.protocolId} @ ${saved.version}。尚未批准，不能用于运行。',
        );
      }
      await _reload();
    } on Object catch (error) {
      if (mounted) _showMessage('AI 草稿未保存：$error');
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _approve(ProtocolVersionRecord version) async {
    if (version.status != 'draft' || version.isApproved) {
      _showMessage('只有待审阅草稿可以批准。');
      return;
    }
    final unresolvedMarkers = _unresolvedInputMarkers(version.document);
    Map<String, Object?> provenance;
    try {
      provenance = _provenanceFor(version);
    } on Object catch (error) {
      _showMessage('无法读取 Protocol 起草来源，已阻止批准：$error');
      return;
    }
    final persistedInputs = _stringList(provenance['requires_user_input']);
    if (unresolvedMarkers.isNotEmpty || persistedInputs.isNotEmpty) {
      final unresolved = <String>{
        ...unresolvedMarkers,
        ...persistedInputs,
      }.toList(growable: false);
      _showMessage('Protocol 仍有未补充的输入，不能批准：${unresolved.join('；')}');
      return;
    }
    final review = ProtocolDocument.validate(version.document);
    if (!review.isValid) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('校验失败：${review.errors.join('; ')}')),
      );
      return;
    }
    final semantic = ProtocolSemanticValidator.validate(version.document);
    if (semantic.errors.isNotEmpty ||
        semantic.unsupportedOperations.isNotEmpty) {
      _showMessage(
        'Protocol 语义校验失败：${<String>{...semantic.errors, ...semantic.unsupportedOperations}.join('；')}',
      );
      return;
    }
    final calculationBindings = await WorkflowCalculationPackBinder(
      widget.packRegistry,
    ).validate(version.document);
    if (calculationBindings.errors.isNotEmpty ||
        calculationBindings.requiresUserInput.isNotEmpty) {
      final issues = [
        ...calculationBindings.errors,
        ...calculationBindings.requiresUserInput.map((value) => '待补充：$value'),
      ];
      _showMessage('Protocol 不能批准：${issues.join('；')}');
      return;
    }
    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('审批并冻结 Protocol 版本？'),
        content: SizedBox(
          width: 600,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '${version.title} · ${version.protocolId} @ ${version.version}',
                ),
                SelectableText('SHA-256: ${version.payloadSha256}'),
                const SizedBox(height: 8),
                Text(
                  '步骤 DAG：${(version.document['steps'] as List).length} 个步骤',
                ),
                if (review.warnings.isNotEmpty)
                  Text('提示：\n${review.warnings.join('\n')}'),
                const Text('审批后该版本不可修改。新流程必须保存为新版本；运行只会快照已审批版本。'),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('返回审阅'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('审批并冻结'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    try {
      final approval = widget.core.approvals.issue(
        action: 'protocol.approve',
        subjectType: 'protocol_version',
        subjectId: '${version.protocolId}@${version.version}',
        scope: <String, Object?>{
          'payload_sha256': version.payloadSha256,
          'reviewed': true,
        },
      );
      await widget.core.protocols.approveVersion(
        protocolId: version.protocolId,
        version: version.version,
        approvalRef: approval,
      );
      await _reload();
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('审批失败：$error')));
      }
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(28, 22, 28, 24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        WorkspacePageHeader(
          title: 'Protocol 库',
          subtitle: '版本化流程草稿、校验与人工审批；批准版本不可变。',
          icon: Icons.account_tree_outlined,
          actions: [
            OutlinedButton.icon(
              onPressed: _createAiDraft,
              icon: const Icon(Icons.auto_awesome_outlined),
              label: const Text('AI 起草 Protocol'),
            ),
            FilledButton.icon(
              onPressed: _newDraft,
              icon: const Icon(Icons.add),
              label: const Text('手工新建草稿'),
            ),
            IconButton(
              onPressed: _reload,
              tooltip: '刷新',
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        if (_error != null)
          MaterialBanner(
            content: Text('无法读取 Protocol 列表：$_error'),
            actions: [TextButton(onPressed: _reload, child: const Text('重试'))],
          ),
        Expanded(
          child: _versions.isEmpty
              ? WorkspaceEmptyState(
                  icon: Icons.rule_folder_outlined,
                  title: 'Protocol 库还是空的',
                  description:
                      '从人工编辑或 AI 草稿开始。所有 Protocol 仍需本地校验和单独人工审批后，才能用于新运行。',
                  action: Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FilledButton.icon(
                        onPressed: _createAiDraft,
                        icon: const Icon(Icons.auto_awesome_outlined),
                        label: const Text('AI 起草 Protocol'),
                      ),
                      OutlinedButton.icon(
                        onPressed: _newDraft,
                        icon: const Icon(Icons.edit_outlined),
                        label: const Text('手工新建'),
                      ),
                    ],
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.only(bottom: 14),
                  itemCount: _versions.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 7),
                  itemBuilder: (context, index) {
                    final version = _versions[index];
                    final steps =
                        version.document['steps'] as List? ?? const [];
                    final titles = steps
                        .map((step) => step is Map ? step['title'] : null)
                        .whereType<String>()
                        .take(2)
                        .join(' · ');
                    final approved = version.isApproved;
                    return WorkspaceHoverCard(
                      onTap: () => _showVersion(version),
                      child: ListTile(
                        leading: Icon(
                          approved
                              ? Icons.verified_outlined
                              : Icons.description_outlined,
                        ),
                        title: Text(
                          '${version.title} · ${version.version}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          '${steps.length} 步${titles.isEmpty ? '' : ' · $titles'}\n'
                          '${version.protocolId} · 创建 ${version.createdAtUtc.toLocal()}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        isThreeLine: false,
                        trailing: Wrap(
                          crossAxisAlignment: WrapCrossAlignment.center,
                          spacing: 8,
                          children: [
                            WorkspaceStatusBadge(
                              label: approved
                                  ? '已批准'
                                  : _statusLabel(version.status),
                              icon: approved
                                  ? Icons.lock_outline
                                  : Icons.edit_outlined,
                              tone: approved
                                  ? WorkspaceBadgeTone.success
                                  : WorkspaceBadgeTone.warning,
                            ),
                            if (!approved && version.status == 'draft') ...[
                              IconButton(
                                tooltip: '补充并重校验',
                                onPressed: () => _editDraft(version),
                                icon: const Icon(Icons.edit_note_outlined),
                              ),
                              FilledButton.tonal(
                                onPressed: () => _approve(version),
                                child: const Text('审阅并批准'),
                              ),
                            ],
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    ),
  );

  Future<void> _showVersion(ProtocolVersionRecord version) => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('${version.title} · ${version.version}'),
      content: SizedBox(
        width: 760,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  WorkspaceStatusBadge(
                    label: version.isApproved
                        ? '已批准 · 冻结版本'
                        : _statusLabel(version.status),
                    tone: version.isApproved
                        ? WorkspaceBadgeTone.success
                        : WorkspaceBadgeTone.warning,
                  ),
                  Chip(
                    label: Text('${version.protocolId} @ ${version.version}'),
                  ),
                  Chip(
                    label: Text(
                      '${(version.document['steps'] as List? ?? const []).length} 个步骤',
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              SelectableText(
                'SHA-256：${version.payloadSha256}\n创建：${version.createdAtUtc.toLocal()}'
                '${version.approvedAtUtc == null ? '' : '\n批准：${version.approvedAtUtc!.toLocal()}'}',
              ),
              const SizedBox(height: 12),
              SelectableText(
                const JsonEncoder.withIndent('  ').convert(version.document),
              ),
            ],
          ),
        ),
      ),
      actions: [
        if (!version.isApproved && version.status == 'draft')
          TextButton.icon(
            onPressed: () {
              Navigator.of(context).pop();
              _editDraft(version);
            },
            icon: const Icon(Icons.edit_note_outlined),
            label: const Text('补充并重校验'),
          ),
        if (!version.isApproved && version.status == 'draft')
          FilledButton.tonal(
            onPressed: () {
              Navigator.of(context).pop();
              _approve(version);
            },
            child: const Text('审阅并批准'),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    ),
  );

  Future<void> _editDraft(ProtocolVersionRecord version) async {
    if (version.isApproved || version.status != 'draft') return;
    late final Map<String, Object?> originalProvenance;
    try {
      originalProvenance = _provenanceFor(version);
    } on Object catch (error) {
      _showMessage('无法读取 Protocol 起草来源，已阻止编辑：$error');
      return;
    }
    final initialMarkers = <String>{
      ..._unresolvedInputMarkers(version.document),
      ..._stringList(originalProvenance['requires_user_input']),
    }.toList(growable: false);
    final editor = TextEditingController(
      text: const JsonEncoder.withIndent('  ').convert(version.document),
    );
    var confirmedMarkers = false;
    final result = await showDialog<Map<String, Object?>>(
      context: context,
      builder: (context) {
        final size = MediaQuery.sizeOf(context);
        final dialogWidth = size.width < 968
            ? (size.width - 48).clamp(280.0, 920.0).toDouble()
            : 920.0;
        final dialogHeight = size.height < 840
            ? (size.height - 180).clamp(240.0, 660.0).toDouble()
            : 660.0;
        return StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            title: Text('补充草稿 · ${version.title}'),
            content: SizedBox(
              width: dialogWidth,
              height: dialogHeight,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (initialMarkers.isNotEmpty) ...[
                    Text(
                      'AI 标记了以下待补充内容。请在 Protocol 文档中逐项补齐，移除对应“需要用户补充：”提示后，再执行本地校验。',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 8),
                    for (final marker in initialMarkers)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: SelectableText('• $marker'),
                      ),
                    CheckboxListTile(
                      value: confirmedMarkers,
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      onChanged: (value) => setDialogState(
                        () => confirmedMarkers = value ?? false,
                      ),
                      title: const Text('我已逐项补齐上述内容，并检查了对应步骤。'),
                    ),
                    const SizedBox(height: 8),
                  ],
                  Expanded(
                    child: TextField(
                      controller: editor,
                      minLines: 12,
                      maxLines: null,
                      keyboardType: TextInputType.multiline,
                      autocorrect: false,
                      enableSuggestions: false,
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        labelText: 'Protocol JSON',
                        alignLabelWithHint: true,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消'),
              ),
              FilledButton.icon(
                onPressed: initialMarkers.isNotEmpty && !confirmedMarkers
                    ? null
                    : () => Navigator.pop(context, <String, Object?>{
                        'json': editor.text,
                        'confirmed': confirmedMarkers,
                      }),
                icon: const Icon(Icons.fact_check_outlined),
                label: const Text('本地校验并保存'),
              ),
            ],
          ),
        );
      },
    );
    editor.dispose();
    if (result == null) return;

    try {
      final decoded = jsonDecode(result['json']! as String);
      if (decoded is! Map) {
        throw const FormatException('Protocol 必须是 JSON object。');
      }
      final document = Map<String, Object?>.from(decoded)
        ..['schema_version'] = '2.0'
        ..['protocol_id'] = version.protocolId
        ..['version'] = version.version
        ..['status'] = 'draft';
      final reviewValue = document['review'];
      if (reviewValue is! Map) {
        throw const FormatException('review 必须是 object。');
      }
      final review = Map<String, Object?>.from(reviewValue)
        ..['approved_by_user'] = false;
      final warnings = review['warnings'];
      if (warnings is! List || warnings.any((value) => value is! String)) {
        throw const FormatException('review.warnings 必须是字符串数组。');
      }
      final remainingMarkers = warnings
          .cast<String>()
          .where((warning) => warning.startsWith('需要用户补充：'))
          .toList(growable: false);
      if (initialMarkers.isNotEmpty && result['confirmed'] != true) {
        throw const FormatException('请确认已逐项补齐待补充内容。');
      }
      if (remainingMarkers.isNotEmpty) {
        throw FormatException('请先补齐并移除待补充标记：${remainingMarkers.join('；')}');
      }
      document['review'] = review;

      final structural = ProtocolDocument.validate(document);
      if (!structural.isValid) {
        throw FormatException(structural.errors.join('\n'));
      }
      final semantic = ProtocolSemanticValidator.validate(document);
      if (semantic.errors.isNotEmpty ||
          semantic.unsupportedOperations.isNotEmpty) {
        throw FormatException(
          <String>{
            ...semantic.errors,
            ...semantic.unsupportedOperations,
          }.join('\n'),
        );
      }
      final calculationBindings = await WorkflowCalculationPackBinder(
        widget.packRegistry,
      ).validate(document);
      if (calculationBindings.errors.isNotEmpty ||
          calculationBindings.requiresUserInput.isNotEmpty) {
        throw FormatException(
          <String>[
            ...calculationBindings.errors,
            ...calculationBindings.requiresUserInput.map(
              (value) => '待补充：$value',
            ),
          ].join('\n'),
        );
      }

      final provenance = _provenanceFor(version)
        ..['requires_user_input'] = const <String>[];
      final saved = widget.core.protocols.saveDraft(
        document: document,
        provenance: provenance,
      );
      _showMessage(
        '草稿已补充并通过本地校验：${saved.protocolId} @ ${saved.version}。仍需单独审阅批准。',
      );
      await _reload();
    } on Object catch (error) {
      _showMessage('草稿未保存：$error');
    }
  }

  Map<String, Object?> _provenanceFor(ProtocolVersionRecord version) {
    final rows = widget.core.database.query(
      'SELECT provenance_json FROM protocol_versions WHERE protocol_id=? AND version=?',
      [version.protocolId, version.version],
    );
    if (rows.isEmpty) {
      throw StateError('找不到 Protocol 起草来源记录。');
    }
    final decoded = jsonDecode(rows.single['provenance_json']! as String);
    if (decoded is! Map) {
      throw const FormatException('Protocol provenance 必须是 JSON object。');
    }
    final provenance = Map<String, Object?>.from(decoded);
    if (provenance['method'] == 'ai_protocol_generation' &&
        !provenance.containsKey('requires_user_input')) {
      throw const FormatException('AI Protocol 来源缺少 requires_user_input 校验记录。');
    }
    _stringList(provenance['requires_user_input']);
    return provenance;
  }

  List<String> _unresolvedInputMarkers(Map<String, Object?> document) {
    final review = document['review'];
    if (review is! Map) return const [];
    final warnings = review['warnings'];
    if (warnings is! List) return const [];
    return warnings
        .whereType<String>()
        .where((warning) => warning.startsWith('需要用户补充：'))
        .map((warning) => warning.substring('需要用户补充：'.length).trim())
        .where((warning) => warning.isNotEmpty)
        .toList(growable: false);
  }

  List<String> _stringList(Object? value) {
    if (value == null) return const [];
    if (value is! List || value.any((item) => item is! String)) {
      throw const FormatException('requires_user_input 必须是字符串数组。');
    }
    return value
        .cast<String>()
        .where((item) => item.trim().isNotEmpty)
        .toList();
  }

  String _statusLabel(String status) => switch (status) {
    'draft' => '待审阅草稿',
    'archived' => '已归档',
    _ => status,
  };

  Map<String, Object?> _template() => <String, Object?>{
    'schema_version': '2.0',
    'protocol_id': 'protocol.example',
    'version': '1.0.0',
    'title': '新 Protocol',
    'status': 'draft',
    'sources': <Object?>[],
    'variables': <Object?>[],
    'steps': <Object?>[
      <String, Object?>{
        'step_id': 'step_1',
        'kind': 'action',
        'title': '操作步骤',
        'instructions': '描述可复现操作。',
        'depends_on': <String>[],
        'duration': <String, Object?>{
          'expected_seconds': null,
          'source': 'user',
        },
        'human_gate': true,
        'captures': <Object?>[],
      },
    ],
    'review': <String, Object?>{
      'approved_by_user': false,
      'warnings': <String>[],
    },
  };
}
