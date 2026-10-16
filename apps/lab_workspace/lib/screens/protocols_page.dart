import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:lab_core/lab_core.dart';

/// Local versioned-protocol authoring and review. A version is immutable after
/// approval; live Runs may select approved versions only.
class ProtocolsPage extends StatefulWidget {
  const ProtocolsPage({required this.core, super.key});

  final LabCore core;

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

  Future<void> _approve(ProtocolVersionRecord version) async {
    final review = ProtocolDocument.validate(version.document);
    if (!review.isValid) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('校验失败：${review.errors.join('; ')}')),
      );
      return;
    }
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
    if (confirmed != true) return;
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
      widget.core.protocols.approveVersion(
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
  Widget build(BuildContext context) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.all(16),
        child: Wrap(
          spacing: 12,
          children: [
            Text('Protocols', style: Theme.of(context).textTheme.headlineSmall),
            FilledButton.icon(
              onPressed: _newDraft,
              icon: const Icon(Icons.add),
              label: const Text('新建版本草稿'),
            ),
            IconButton(
              onPressed: _reload,
              tooltip: '刷新',
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
      ),
      if (_error != null)
        MaterialBanner(
          content: Text('无法读取 Protocol 列表：$_error'),
          actions: [TextButton(onPressed: _reload, child: const Text('重试'))],
        ),
      Expanded(
        child: _versions.isEmpty
            ? const Center(child: Text('尚无 Protocol 版本。创建草稿后，可校验 DAG 并单独审批。'))
            : ListView.builder(
                itemCount: _versions.length,
                itemBuilder: (context, index) {
                  final version = _versions[index];
                  final steps = version.document['steps'] as List? ?? const [];
                  return Card(
                    child: ListTile(
                      leading: Icon(
                        version.isApproved
                            ? Icons.verified_outlined
                            : Icons.edit_note,
                      ),
                      title: Text(
                        '${version.title} · ${version.protocolId} @ ${version.version}',
                      ),
                      subtitle: Text(
                        '${version.status} · ${steps.length} DAG 步骤 · SHA-256 ${version.payloadSha256}\n创建 ${version.createdAtUtc.toLocal()}${version.approvedAtUtc == null ? '' : ' · 审批 ${version.approvedAtUtc!.toLocal()}'}',
                      ),
                      isThreeLine: true,
                      trailing: version.isApproved
                          ? const Chip(label: Text('已冻结'))
                          : FilledButton.tonal(
                              onPressed: () => _approve(version),
                              child: const Text('审阅并审批'),
                            ),
                      onTap: () => showDialog<void>(
                        context: context,
                        builder: (context) => AlertDialog(
                          title: Text('${version.title} · ${version.version}'),
                          content: SizedBox(
                            width: 700,
                            child: SingleChildScrollView(
                              child: SelectableText(
                                const JsonEncoder.withIndent(
                                  '  ',
                                ).convert(version.document),
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
                      ),
                    ),
                  );
                },
              ),
      ),
    ],
  );

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
