import 'package:flutter/material.dart';
import 'package:lab_core/lab_core.dart';

import '../platform/asset_import_picker.dart';
import '../platform/system_file_actions.dart';

class AssetExplorerScreen extends StatefulWidget {
  const AssetExplorerScreen({
    required this.assets,
    required this.approvals,
    super.key,
  });

  final AssetGateway assets;
  final ApprovalService approvals;

  @override
  State<AssetExplorerScreen> createState() => _ExplorerPageState();
}

class _ExplorerPageState extends State<AssetExplorerScreen> {
  final _searchController = TextEditingController();
  final _systemFiles = SystemFileActions();
  VirtualFolderKind _folder = VirtualFolderKind.all;
  ExplorerPage? _page;
  StorageUsage? _usage;
  Object? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final results = await Future.wait<Object>([
        widget.assets.list(
          ExplorerQuery(
            folder: _folder,
            searchText: _searchController.text,
            pageSize: 100,
          ),
        ),
        widget.assets.storageUsage(),
      ]);
      if (!mounted) return;
      setState(() {
        _page = results[0] as ExplorerPage;
        _usage = results[1] as StorageUsage;
      });
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _import() async {
    setState(() => _busy = true);
    try {
      final imported = await AssetImportPicker(widget.assets).pickAndImport();
      if (!mounted) return;
      if (imported.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('已导入 ${imported.length} 个文件；每个文件都登记了 SHA-256。'),
          ),
        );
      }
      await _refresh();
    } on Object catch (error) {
      if (mounted) _showError(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _open(AssetRecord asset) async {
    try {
      final handle = await widget.assets.open(asset.assetId);
      final validation = handle.validationDescription;
      await _systemFiles.open(handle);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(validation)));
      }
    } on Object catch (error) {
      if (mounted) _showError(error);
    }
  }

  Future<void> _verify(AssetRecord asset) async {
    setState(() => _busy = true);
    try {
      final result = await widget.assets.fullVerify(asset.assetId);
      if (!mounted) return;
      final passed = result.isCryptographicallyVerified;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            passed
                ? '完整 SHA-256 校验通过。'
                : '校验结果：${result.status.name}。${result.message ?? ''}',
          ),
        ),
      );
      await _refresh();
    } on Object catch (error) {
      if (mounted) _showError(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete(ExplorerAsset item) async {
    final asset = item.asset;
    try {
      final impact = await widget.assets.previewDelete(asset.assetId);
      if (!mounted) return;
      final purge = asset.isDeleted;
      if (purge && !impact.purgeEligibleNow) {
        await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('暂不能永久删除'),
            content: _impactDescription(impact, purging: true),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('关闭'),
              ),
            ],
          ),
        );
        return;
      }
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(purge ? '永久删除文件？' : '移到废纸篓？'),
          content: _impactDescription(impact, purging: purge),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(purge ? '永久删除' : '移到废纸篓'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
      final approval = widget.approvals.issue(
        action: purge ? 'asset.purge' : 'asset.trash',
        subjectType: 'asset',
        subjectId: asset.assetId,
        scope: <String, Object?>{
          'blob_sha256': asset.blobSha256,
          'purge': purge,
          'impact_reviewed': true,
        },
      );
      if (purge) {
        await widget.assets.purge(
          AssetPurgeRequest(
            assetId: asset.assetId,
            approvalRef: approval.value,
            reason: 'User confirmed Explorer impact preview.',
          ),
        );
      } else {
        await widget.assets.trash(
          AssetTrashRequest(
            assetId: asset.assetId,
            approvalRef: approval.value,
            reason: 'User confirmed Explorer impact preview.',
          ),
        );
      }
      await _refresh();
    } on Object catch (error) {
      if (mounted) _showError(error);
    }
  }

  Future<void> _restore(AssetRecord asset) async {
    try {
      await widget.assets.restore(asset.assetId);
      await _refresh();
    } on Object catch (error) {
      if (mounted) _showError(error);
    }
  }

  Future<void> _collectGarbage() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('回收符合条件的废弃 Blob？'),
        content: const Text(
          '只回收已过保留期、无活动 Asset 引用、无同步/备份保留且无读取租约的内容寻址 Blob。此操作不能撤销。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('扫描并回收'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => _busy = true);
    try {
      final released = await widget.assets.collectGarbage();
      await _refresh();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('GC 已完成，可确认回收 ${_formatBytes(released)}。')),
        );
      }
    } on Object catch (error) {
      if (mounted) _showError(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _impactDescription(
    DeletionImpact impact, {
    required bool purging,
  }) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text('逻辑文件大小：${_formatBytes(impact.logicalBytes)}'),
      Text('预计可回收空间：${_formatBytes(impact.reclaimablePhysicalBytes)}'),
      Text('仍被 ${impact.activeLinks.length} 个实验/记录引用'),
      Text('其他活动资产共享同一 Blob：${impact.otherActiveAssetsSharingBlob.length}'),
      Text(
        '保留备份：${impact.retainedBackupCount}；活动读取：${impact.activeLeaseCount}',
      ),
      Text('待确认同步删除标记：${impact.pendingSyncTombstones ? '有' : '无'}'),
      if (impact.activeLinks.isNotEmpty) ...[
        const SizedBox(height: 8),
        const Text('关联引用：'),
        for (final link in impact.activeLinks.take(8))
          Text('• ${link.targetType}:${link.targetId} / ${link.role}'),
      ],
      if (purging && !impact.purgeEligibleNow)
        const Padding(
          padding: EdgeInsets.only(top: 10),
          child: Text(
            '依赖、保留期、共享 Blob 或活动读取仍阻止回收。',
            style: TextStyle(color: Colors.red),
          ),
        ),
    ],
  );

  void _showError(Object error) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('操作未完成：$error')));
  }

  @override
  Widget build(BuildContext context) {
    final items = _page?.items ?? const <ExplorerAsset>[];
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: 250,
                child: TextField(
                  controller: _searchController,
                  decoration: const InputDecoration(
                    labelText: '搜索文件',
                    prefixIcon: Icon(Icons.search),
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _refresh(),
                ),
              ),
              DropdownButton<VirtualFolderKind>(
                value: _folder,
                items: VirtualFolderKind.values
                    .where((folder) => folder != VirtualFolderKind.custom)
                    .map(
                      (folder) => DropdownMenuItem(
                        value: folder,
                        child: Text(_folderName(folder)),
                      ),
                    )
                    .toList(growable: false),
                onChanged: _busy
                    ? null
                    : (folder) {
                        if (folder != null) {
                          setState(() => _folder = folder);
                          _refresh();
                        }
                      },
              ),
              FilledButton.icon(
                onPressed: _busy ? null : _import,
                icon: const Icon(Icons.add),
                label: const Text('导入文件'),
              ),
              OutlinedButton.icon(
                onPressed: _busy ? null : _collectGarbage,
                icon: const Icon(Icons.delete_sweep_outlined),
                label: const Text('运行安全 GC'),
              ),
              IconButton(
                onPressed: _busy ? null : _refresh,
                tooltip: '刷新',
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
        ),
        if (_usage case final usage?)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '资产 ${usage.assetCount} · Blob ${usage.blobCount} · 唯一文件 ${_formatBytes(usage.uniqueBlobBytes)} · 废纸篓 ${_formatBytes(usage.trashBytes)}',
              ),
            ),
          ),
        if (_error != null)
          MaterialBanner(
            content: Text('无法加载文件：$_error'),
            actions: [TextButton(onPressed: _refresh, child: const Text('重试'))],
          ),
        if (_busy) const LinearProgressIndicator(),
        Expanded(
          child: items.isEmpty
              ? Center(child: Text(_busy ? '正在读取本地文件库…' : '此文件夹中没有资产。'))
              : ListView.separated(
                  itemCount: items.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) => _assetTile(items[index]),
                ),
        ),
      ],
    );
  }

  Widget _assetTile(ExplorerAsset item) {
    final asset = item.asset;
    final integrity = switch (asset.integrityStatus) {
      AssetIntegrityStatus.verified => 'SHA-256 已验证',
      AssetIntegrityStatus.quickChecked => '仅元数据快检（非 SHA-256）',
      AssetIntegrityStatus.overdue => '完整性检查已过期',
      AssetIntegrityStatus.mismatch => '完整性不匹配',
      AssetIntegrityStatus.missing => '本地文件缺失',
      AssetIntegrityStatus.pending => '等待检查',
    };
    return ListTile(
      leading: Icon(
        asset.isDeleted
            ? Icons.delete_outline
            : Icons.insert_drive_file_outlined,
      ),
      title: Text(
        asset.displayName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        '${_formatBytes(asset.byteSize)} · $integrity · ${item.activeLinkCount} 个引用'
        '${item.referenceLabels.isEmpty ? '' : '\n引用于：${item.referenceLabels.take(4).join('、')}'}'
        '${item.remoteReplicaStates.isEmpty ? '' : '\n远端副本：${item.remoteReplicaStates.entries.map((entry) => '${entry.key}=${entry.value}').join(' · ')}'}',
      ),
      isThreeLine:
          item.referenceLabels.isNotEmpty ||
          item.remoteReplicaStates.isNotEmpty,
      onTap: asset.isDeleted ? null : () => _open(asset),
      trailing: PopupMenuButton<String>(
        tooltip: '文件操作',
        onSelected: (value) {
          switch (value) {
            case 'open':
              _open(asset);
              break;
            case 'verify':
              _verify(asset);
              break;
            case 'delete':
              _delete(item);
              break;
            case 'restore':
              _restore(asset);
              break;
          }
        },
        itemBuilder: (_) => [
          if (!asset.isDeleted)
            const PopupMenuItem(value: 'open', child: Text('用系统应用打开')),
          if (!asset.isDeleted)
            const PopupMenuItem(value: 'verify', child: Text('完整 SHA-256 校验')),
          if (asset.isDeleted)
            const PopupMenuItem(value: 'restore', child: Text('恢复')),
          PopupMenuItem(
            value: 'delete',
            child: Text(asset.isDeleted ? '永久删除…' : '移到废纸篓…'),
          ),
        ],
      ),
    );
  }

  String _folderName(VirtualFolderKind folder) => switch (folder) {
    VirtualFolderKind.all => '全部文件',
    VirtualFolderKind.raw => '原始数据',
    VirtualFolderKind.derived => '派生文件',
    VirtualFolderKind.reports => '报告',
    VirtualFolderKind.orphans => '未关联',
    VirtualFolderKind.recent => '最近',
    VirtualFolderKind.localOnly => '仅本地',
    VirtualFolderKind.remoteOnly => '仅远程',
    VirtualFolderKind.integrityWarnings => '完整性警告',
    VirtualFolderKind.trash => '废纸篓',
    VirtualFolderKind.custom => '自定义文件夹',
  };

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    final kb = bytes / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';
    final mb = kb / 1024;
    if (mb < 1024) return '${mb.toStringAsFixed(1)} MB';
    return '${(mb / 1024).toStringAsFixed(2)} GB';
  }
}
