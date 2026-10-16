import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:lab_core/lab_core.dart';

/// Small, single-level storage dialog intended for the selected project panel.
/// Existing project screens can open it without taking ownership of its layout.
final class ProjectStorageSettingsDialog {
  const ProjectStorageSettingsDialog._();

  static Future<ProjectStorageBuildReport?> show({
    required BuildContext context,
    required ProjectStorageService service,
    required String projectId,
  }) => showDialog<ProjectStorageBuildReport>(
    context: context,
    builder: (_) =>
        _ProjectStorageSettingsDialog(service: service, projectId: projectId),
  );
}

class _ProjectStorageSettingsDialog extends StatefulWidget {
  const _ProjectStorageSettingsDialog({
    required this.service,
    required this.projectId,
  });

  final ProjectStorageService service;
  final String projectId;

  @override
  State<_ProjectStorageSettingsDialog> createState() =>
      _ProjectStorageSettingsDialogState();
}

class _ProjectStorageSettingsDialogState
    extends State<_ProjectStorageSettingsDialog> {
  ProjectStorageState? _state;
  ProjectStorageBuildReport? _lastReport;
  Object? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    try {
      final state = await widget.service.describe(widget.projectId);
      if (!mounted) return;
      setState(() {
        _state = state;
        _error = null;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _error = error);
    }
  }

  Future<void> _chooseParentFolder() async {
    if (!Platform.isWindows) return;
    try {
      final parent = await FilePicker.getDirectoryPath(
        dialogTitle: '选择项目目录的上级文件夹',
      );
      if (parent == null || !mounted) return;
      setState(() => _busy = true);
      final state = await widget.service.setCustomParentDirectory(
        widget.projectId,
        parent,
      );
      if (!mounted) return;
      setState(() {
        _state = state;
        _lastReport = null;
        _error = null;
      });
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _useDefault() async {
    setState(() => _busy = true);
    try {
      final state = await widget.service.useDefaultDirectory(widget.projectId);
      if (!mounted) return;
      setState(() {
        _state = state;
        _lastReport = null;
        _error = null;
      });
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _generate() async {
    final state = _state;
    if (state == null) return;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('生成或更新项目目录？'),
        content: Text(
          '将在以下位置创建受管 Asset 的独立可浏览副本，并记录 SHA-256：\n\n'
          '${state.location.rootDirectory}\n\n'
          '已存在且被外部修改的文件会保留并列入报告。此操作不会删除旧项目目录。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('生成目录'),
          ),
        ],
      ),
    );
    if (accepted != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final report = await widget.service.generateDirectory(widget.projectId);
      final state = await widget.service.describe(widget.projectId);
      if (!mounted) return;
      setState(() {
        _lastReport = report;
        _state = state;
        _error = null;
      });
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openInExplorer() async {
    final state = _state;
    if (!Platform.isWindows ||
        state == null ||
        !state.location.directoryExists) {
      return;
    }
    try {
      await Process.start('explorer.exe', <String>[
        state.location.rootDirectory,
      ], mode: ProcessStartMode.detached);
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  void _close() => Navigator.of(context).pop(_lastReport);

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.sizeOf(context);
    return Dialog(
      insetPadding: const EdgeInsets.all(20),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 680,
          maxHeight: media.height * 0.86,
        ),
        child: SizedBox(
          width: media.width,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(22, 16, 10, 14),
                child: Row(
                  children: [
                    const Icon(Icons.folder_copy_outlined),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '项目目录',
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                          Text(
                            '查看物理文件、切换位置或生成可浏览副本',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: '关闭',
                      onPressed: _close,
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: _busy
                    ? const Center(child: CircularProgressIndicator())
                    : _content(),
              ),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.all(14),
                child: Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if (Platform.isWindows)
                      OutlinedButton.icon(
                        onPressed: _busy ? null : _chooseParentFolder,
                        icon: const Icon(Icons.drive_file_move_outline),
                        label: const Text('选择位置'),
                      ),
                    TextButton.icon(
                      onPressed: _busy ? null : _useDefault,
                      icon: const Icon(Icons.restore),
                      label: const Text('恢复默认'),
                    ),
                    if (Platform.isWindows)
                      OutlinedButton.icon(
                        onPressed: _state?.location.directoryExists == true
                            ? _openInExplorer
                            : null,
                        icon: const Icon(Icons.folder_open_outlined),
                        label: const Text('在资源管理器打开'),
                      ),
                    FilledButton.icon(
                      onPressed: _state == null || _busy ? null : _generate,
                      icon: const Icon(Icons.sync),
                      label: const Text('生成／更新目录'),
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

  Widget _content() {
    final state = _state;
    if (_error != null && state == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline),
              const SizedBox(height: 8),
              Text('无法读取项目目录：$_error', textAlign: TextAlign.center),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _refresh,
                icon: const Icon(Icons.refresh),
                label: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }
    if (state == null) return const Center(child: CircularProgressIndicator());
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        if (_error != null) ...[
          _notice(
            context,
            icon: Icons.warning_amber_outlined,
            text: '操作未完成：$_error',
            isError: true,
          ),
          const SizedBox(height: 12),
        ],
        SelectableText(
          state.location.rootDirectory,
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(fontFamily: 'monospace'),
        ),
        const SizedBox(height: 8),
        Text(
          state.location.isDefault ? '本机默认位置' : '自定义位置',
          style: Theme.of(context).textTheme.labelMedium,
        ),
        const SizedBox(height: 16),
        _notice(
          context,
          icon: Icons.info_outline,
          text: Platform.isWindows
              ? '项目目录包含“原始文件、实验记录、分析结果、导出”分类。文件从 Vault CAS 按 SHA-256 校验后复制；若检测到硬链接或未受管的同名文件，会保留并报告，不会把它认作独立副本。解除关联的旧文件也会保留，并标明已不属于当前项目。'
              : '移动端当前只使用应用私有 Documents 路径，不支持选择或打开任意外部目录；生成的副本不保证显示在系统“文件”应用中。',
        ),
        const SizedBox(height: 8),
        _notice(
          context,
          icon: Icons.backup_outlined,
          text:
              '项目路径属于本机配置。远程 Vault 备份同步的是数据库快照与 CAS Blob；此处浏览副本需在本机备份，或从 Vault 原件重新生成。',
        ),
        const SizedBox(height: 18),
        _summaryCard(state),
        if (_lastReport case final report?) ...[
          const SizedBox(height: 14),
          _reportCard(report),
        ],
      ],
    );
  }

  Widget _summaryCard(ProjectStorageState state) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('目录状态', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            Wrap(
              spacing: 18,
              runSpacing: 8,
              children: [
                _metric('已关联原件', state.linkedAssetCount),
                _metric('已生成副本', state.copiedFileCount),
                _metric('已解除关联但保留', state.unlinkedRetainedFileCount),
                _metric('外部改动', state.externalChangedFileCount),
                _metric('缺失／失败', state.missingOrFailedFileCount),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              _manifestStatusText(state.location.manifestStatus),
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (state.location.lastGeneratedAtUtc != null) ...[
              const SizedBox(height: 4),
              Text(
                '最近更新：${state.location.lastGeneratedAtUtc!.toLocal()}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _reportCard(ProjectStorageBuildReport report) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('更新报告', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              '新增副本 ${report.copiedAssetCount} · 已存在 ${report.alreadyPresentAssetCount} · '
              '外部改动 ${report.externalChangedAssetCount} · 缺失 ${report.missingAssetCount} · '
              '失败 ${report.failedAssetCount}',
            ),
            if (report.manifestConflict)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('项目清单存在冲突，未覆盖外部内容。'),
              ),
            if (report.issues.isNotEmpty) ...[
              const SizedBox(height: 10),
              ...report.issues
                  .take(20)
                  .map(
                    (issue) => Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Text('${issue.displayName}：${issue.message}'),
                    ),
                  ),
              if (report.issues.length > 20)
                Text('另有 ${report.issues.length - 20} 项，请查看项目清单或重新生成。'),
            ],
          ],
        ),
      ),
    );
  }

  Widget _metric(String label, int value) => Text('$label：$value');

  Widget _notice(
    BuildContext context, {
    required IconData icon,
    required String text,
    bool isError = false,
  }) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: isError
          ? Theme.of(context).colorScheme.errorContainer
          : Theme.of(context).colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(10),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18),
        const SizedBox(width: 8),
        Expanded(child: Text(text)),
      ],
    ),
  );

  String _manifestStatusText(ProjectStorageManifestStatus status) =>
      switch (status) {
        ProjectStorageManifestStatus.ready => '项目清单已校验；外部改动会保留并报告。',
        ProjectStorageManifestStatus.missing => '项目清单缺失，可从 Vault 原件重新生成。',
        ProjectStorageManifestStatus.externallyChanged =>
          '项目清单已被外部修改；重新生成前请先选择其他位置或人工处理冲突。',
        ProjectStorageManifestStatus.blocked => '目录安全检查未通过；请改选位置。',
        ProjectStorageManifestStatus.notGenerated => '尚未生成物理项目目录。',
      };
}
