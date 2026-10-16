import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lab_core/lab_core.dart';

/// Opens the small Protocol picker used when creating a new Experiment Run.
///
/// The returned version is an immutable approved record. Callers should bind it
/// through `RunService.createRun`; applying a Protocol to an existing Run would
/// rewrite its execution history, so the chooser only returns a new selection.
Future<ProtocolVersionRecord?> showProtocolChooserDialog({
  required BuildContext context,
  required ProtocolService protocols,
  required Future<void> Function() onOpenProtocolLibrary,
  Future<void> Function()? onDraftProtocol,
}) => showDialog<ProtocolVersionRecord>(
  context: context,
  builder: (_) => _ProtocolChooserDialog(
    protocols: protocols,
    onOpenProtocolLibrary: onOpenProtocolLibrary,
    onDraftProtocol: onDraftProtocol,
  ),
);

class _ProtocolChooserDialog extends StatefulWidget {
  const _ProtocolChooserDialog({
    required this.protocols,
    required this.onOpenProtocolLibrary,
    required this.onDraftProtocol,
  });

  final ProtocolService protocols;
  final Future<void> Function() onOpenProtocolLibrary;
  final Future<void> Function()? onDraftProtocol;

  @override
  State<_ProtocolChooserDialog> createState() => _ProtocolChooserDialogState();
}

class _ProtocolChooserDialogState extends State<_ProtocolChooserDialog> {
  List<ProtocolVersionRecord> _versions = const [];
  Object? _error;

  @override
  void initState() {
    super.initState();
    _readVersions();
  }

  void _readVersions() {
    try {
      final versions = <ProtocolVersionRecord>[];
      for (final protocol in widget.protocols.listProtocols()) {
        versions.addAll(widget.protocols.listVersions(protocol.protocolId));
      }
      versions.sort((left, right) {
        final titleOrder = left.title.toLowerCase().compareTo(
          right.title.toLowerCase(),
        );
        if (titleOrder != 0) return titleOrder;
        final createdOrder = right.createdAtUtc.compareTo(left.createdAtUtc);
        return createdOrder != 0
            ? createdOrder
            : right.version.compareTo(left.version);
      });
      _versions = List.unmodifiable(versions);
      _error = null;
    } on Object catch (error) {
      _versions = const [];
      _error = error;
    }
  }

  void _retry() => setState(_readVersions);

  void _select(ProtocolVersionRecord version) {
    if (!version.isApproved) return;
    Navigator.of(context).pop(version);
  }

  void _openProtocolLibrary() {
    final openProtocolLibrary = widget.onOpenProtocolLibrary;
    Navigator.of(context).pop();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(openProtocolLibrary());
    });
  }

  void _draftProtocol() {
    final callback = widget.onDraftProtocol;
    if (callback == null) return;
    Navigator.of(context).pop();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(callback());
    });
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 720,
          maxHeight: size.height * 0.82,
        ),
        child: SizedBox(
          width: size.width,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 20, 12, 16),
                child: Row(
                  children: [
                    const Icon(Icons.rule_folder_outlined),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '从 Protocol 库选择',
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '批准版本会以快照绑定到新运行，步骤随后进入实验执行。',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: '关闭',
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              if (_error != null)
                Expanded(
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.error_outline),
                          const SizedBox(height: 8),
                          Text('无法读取 Protocol 库：$_error'),
                          const SizedBox(height: 12),
                          OutlinedButton.icon(
                            onPressed: _retry,
                            icon: const Icon(Icons.refresh),
                            label: const Text('重试'),
                          ),
                        ],
                      ),
                    ),
                  ),
                )
              else if (_versions.isEmpty)
                Expanded(child: _emptyState())
              else ...[
                if (!_versions.any((version) => version.isApproved))
                  MaterialBanner(
                    content: const Text('当前库中没有已批准版本。草稿需先在 Protocol 库完成审核。'),
                    leading: const Icon(Icons.info_outline),
                    actions: [
                      TextButton(
                        onPressed: _openProtocolLibrary,
                        child: const Text('打开 Protocol 库'),
                      ),
                    ],
                  ),
                Expanded(
                  child: ListView.separated(
                    padding: const EdgeInsets.all(16),
                    itemCount: _versions.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, index) =>
                        _versionTile(context, _versions[index]),
                  ),
                ),
              ],
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: Row(
                  children: [
                    TextButton.icon(
                      onPressed: _openProtocolLibrary,
                      icon: const Icon(Icons.library_books_outlined),
                      label: const Text('Protocol 库'),
                    ),
                    if (widget.onDraftProtocol != null)
                      TextButton.icon(
                        onPressed: _draftProtocol,
                        icon: const Icon(Icons.auto_awesome_outlined),
                        label: const Text('AI 起草 Protocol'),
                      ),
                    const Spacer(),
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('取消'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _emptyState() => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.rule_folder_outlined, size: 40),
          const SizedBox(height: 12),
          Text(
            'Protocol 库还是空的',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          const Text(
            '导入或创建 Protocol，并完成审核后，就可以在这里将批准版本应用到实验运行。',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: _openProtocolLibrary,
                icon: const Icon(Icons.library_books_outlined),
                label: const Text('打开 Protocol 库'),
              ),
              if (widget.onDraftProtocol != null)
                OutlinedButton.icon(
                  onPressed: _draftProtocol,
                  icon: const Icon(Icons.auto_awesome_outlined),
                  label: const Text('AI 起草 Protocol'),
                ),
            ],
          ),
        ],
      ),
    ),
  );

  Widget _versionTile(BuildContext context, ProtocolVersionRecord version) {
    final approved = version.isApproved;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        enabled: approved,
        onTap: approved ? () => _select(version) : null,
        leading: Icon(
          approved ? Icons.verified_outlined : Icons.description_outlined,
        ),
        title: Row(
          children: [
            Expanded(
              child: Text(
                version.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            _approvalChip(context, version),
          ],
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
            '版本 ${version.version} · ${_stepSummary(version)}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        trailing: FilledButton.tonal(
          onPressed: approved ? () => _select(version) : null,
          child: Text(approved ? '应用' : '不可应用'),
        ),
      ),
    );
  }

  Widget _approvalChip(BuildContext context, ProtocolVersionRecord version) {
    final approved = version.isApproved;
    final label = switch (version.status) {
      'approved' when approved => '已批准',
      'approved' => '批准记录不完整',
      'draft' => '草稿',
      'archived' => '已归档',
      _ => '状态 ${version.status}',
    };
    return Chip(
      visualDensity: VisualDensity.compact,
      label: Text(label),
      avatar: Icon(
        approved ? Icons.check_circle_outline : Icons.lock_outline,
        size: 16,
      ),
    );
  }

  String _stepSummary(ProtocolVersionRecord version) {
    final rawSteps = version.document['steps'];
    if (rawSteps is! List || rawSteps.isEmpty) return '暂无步骤摘要';
    final titles = rawSteps
        .map((value) => value is Map ? value['title'] : null)
        .whereType<String>()
        .where((title) => title.trim().isNotEmpty)
        .take(2)
        .toList(growable: false);
    final suffix = rawSteps.length > titles.length ? ' …' : '';
    final names = titles.isEmpty ? '步骤名称缺失' : titles.join(' · ') + suffix;
    return '${rawSteps.length} 步 · $names';
  }
}
