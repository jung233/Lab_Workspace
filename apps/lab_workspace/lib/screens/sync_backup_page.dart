import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:lab_core/lab_core.dart';

import '../widgets/workspace_ui.dart';
import 'package:path_provider/path_provider.dart';

import '../integrations/microsoft_onedrive_connect_page.dart';
import '../platform/active_vault_selection.dart';
import '../platform/secure_secret_store.dart';

class SyncBackupPage extends StatefulWidget {
  const SyncBackupPage({
    required this.core,
    required this.sync,
    required this.backups,
    required this.secretStore,
    super.key,
  });

  final LabCore core;
  final SyncService sync;
  final BackupService backups;
  final FlutterSecretStore secretStore;

  @override
  State<SyncBackupPage> createState() => _SyncBackupPageState();
}

class _SyncBackupPageState extends State<SyncBackupPage> {
  List<SyncTarget> _targets = const [];
  List<SyncHistoricalEpoch> _historicalEpochs = const [];
  List<RemoteMeasurementImportRecord> _remoteMeasurements = const [];
  List<RemoteAssetDeletionReview> _remoteAssetDeletions = const [];
  StorageUsage? _usage;
  Object? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    try {
      final targets = await widget.sync.listTargets();
      final historicalEpochs = <SyncHistoricalEpoch>[];
      for (final target in targets) {
        historicalEpochs.addAll(
          await widget.sync.listHistoricalEpochs(targetId: target.targetId),
        );
      }
      historicalEpochs.removeWhere((epoch) => !epoch.requiresReauthorization);
      final usage = await widget.core.assets.storageUsage();
      final remoteMeasurements = widget.core.remoteMeasurementReviews
          .listImports(reviewState: 'pending');
      final remoteAssetDeletions = await widget.core.assets
          .listPendingRemoteDeletions();
      if (!mounted) return;
      setState(() {
        _targets = targets;
        _historicalEpochs = List<SyncHistoricalEpoch>.unmodifiable(
          historicalEpochs,
        );
        _usage = usage;
        _remoteMeasurements = remoteMeasurements;
        _remoteAssetDeletions = remoteAssetDeletions;
        _error = null;
      });
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  Future<void> _configureS3([SyncTarget? existing]) async {
    if (existing?.provider == SyncProvider.oneDrive) {
      _showError(
        StateError(
          'OneDrive must be authorized through the Microsoft account page.',
        ),
      );
      return;
    }
    final config = await showDialog<_S3Configuration>(
      context: context,
      builder: (context) => _S3ConfigurationDialog(existing: existing),
    );
    if (config == null || !mounted) return;
    setState(() => _busy = true);
    SecretRef? credentialsRef;
    SecretRef? encryptionRef;
    var configured = false;
    try {
      final credentialBytes = Uint8List.fromList(
        utf8.encode(
          jsonEncode(<String, Object?>{
            'access_key_id': config.accessKeyId,
            'secret_access_key': config.secretAccessKey,
            if (config.sessionToken.isNotEmpty)
              'session_token': config.sessionToken,
          }),
        ),
      );
      try {
        credentialsRef = await widget.secretStore.write(credentialBytes);
      } finally {
        credentialBytes.fillRange(0, credentialBytes.length, 0);
      }
      final encryptsAnyClass =
          config.encryptMetadata ||
          config.encryptSmallFiles ||
          config.encryptLargeFiles;
      var policy = existing?.encryption ?? const RemoteEncryptionPolicy();
      if (existing == null && encryptsAnyClass) {
        final keyBytes = Uint8List.fromList(
          List<int>.generate(32, (_) => Random.secure().nextInt(256)),
        );
        try {
          encryptionRef = await widget.secretStore.write(keyBytes);
        } finally {
          keyBytes.fillRange(0, keyBytes.length, 0);
        }
        policy = RemoteEncryptionPolicy(
          mode:
              config.encryptMetadata &&
                  config.encryptSmallFiles &&
                  config.encryptLargeFiles
              ? RemoteEncryptionMode.encryptAll
              : config.encryptMetadata &&
                    !config.encryptSmallFiles &&
                    !config.encryptLargeFiles
              ? RemoteEncryptionMode.encryptMetadata
              : RemoteEncryptionMode.custom,
          encryptMetadata: config.encryptMetadata,
          encryptSmallFiles: config.encryptSmallFiles,
          encryptLargeFiles: config.encryptLargeFiles,
          keyRef: encryptionRef,
        );
      }
      await widget.sync.configureS3(
        displayName: config.displayName,
        credentialRef: credentialsRef,
        endpoint: config.endpoint,
        region: config.region,
        bucket: config.bucket,
        encryption: policy,
        backupEnabled: config.backupEnabled,
        targetId: existing?.targetId,
      );
      configured = true;
      final oldSecretRef = existing?.secretRef;
      if (oldSecretRef != null && oldSecretRef != credentialsRef) {
        final remainingTargets = await widget.sync.listTargets();
        if (remainingTargets.every(
          (target) => target.secretRef != oldSecretRef,
        )) {
          try {
            await widget.secretStore.delete(oldSecretRef);
          } on Object {
            // The new target is already committed; a stale secret is safer
            // than deleting credentials now referenced by the database.
          }
        }
      }
      await _refresh();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('S3 目标已保存；远端访问仅在你明确同步时开始。')),
        );
      }
    } on Object catch (error) {
      if (!configured) {
        if (credentialsRef != null) {
          await widget.secretStore.delete(credentialsRef);
        }
        if (encryptionRef != null) {
          await widget.secretStore.delete(encryptionRef);
        }
      }
      if (mounted) _showError(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _connectOneDrive([SyncTarget? existing]) async {
    final config = await showDialog<_OneDriveConfiguration>(
      context: context,
      builder: (context) => _OneDriveConfigurationDialog(existing: existing),
    );
    if (config == null || !mounted) return;
    final targetId = existing?.targetId ?? newUuidV7();
    final connection = await Navigator.of(context)
        .push<MicrosoftOneDriveConnection>(
          MaterialPageRoute(
            builder: (_) => MicrosoftOneDriveConnectPage(
              core: widget.core,
              secretStore: widget.secretStore,
              targetId: targetId,
              existingDriveId: existing?.driveId,
            ),
          ),
        );
    if (connection == null || !mounted) return;
    setState(() => _busy = true);
    SecretRef? encryptionRef;
    try {
      var policy = existing?.encryption ?? const RemoteEncryptionPolicy();
      final encryptsAnyClass =
          config.encryptMetadata ||
          config.encryptSmallFiles ||
          config.encryptLargeFiles;
      if (existing == null && encryptsAnyClass) {
        final keyBytes = Uint8List.fromList(
          List<int>.generate(32, (_) => Random.secure().nextInt(256)),
        );
        try {
          encryptionRef = await widget.secretStore.write(keyBytes);
        } finally {
          keyBytes.fillRange(0, keyBytes.length, 0);
        }
        policy = RemoteEncryptionPolicy(
          mode:
              config.encryptMetadata &&
                  config.encryptSmallFiles &&
                  config.encryptLargeFiles
              ? RemoteEncryptionMode.encryptAll
              : config.encryptMetadata &&
                    !config.encryptSmallFiles &&
                    !config.encryptLargeFiles
              ? RemoteEncryptionMode.encryptMetadata
              : RemoteEncryptionMode.custom,
          encryptMetadata: config.encryptMetadata,
          encryptSmallFiles: config.encryptSmallFiles,
          encryptLargeFiles: config.encryptLargeFiles,
          keyRef: encryptionRef,
        );
      }
      await widget.sync.configureOneDrive(
        displayName: config.displayName,
        credentialRef: connection.credentialRef,
        driveId: connection.driveId,
        encryption: policy,
        syncEnabled: true,
        backupEnabled: config.backupEnabled,
        targetId: targetId,
      );
      await _refresh();
      if (mounted) _showMessage('OneDrive 已连接。访问令牌由独立 Files 权限授权并保存在本机安全存储。');
    } on Object catch (error) {
      if (encryptionRef != null) await widget.secretStore.delete(encryptionRef);
      if (mounted) _showError(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reauthorizeHistoricalEpoch(SyncHistoricalEpoch epoch) async {
    final target = epoch.target;
    SecretRef? credentialRef;
    SecretRef? encryptionRef;
    var ownsCredential = false;
    var ownsEncryption = false;
    setState(() => _busy = true);
    try {
      if (target.provider == SyncProvider.oneDrive) {
        final authProfileId = '${target.targetId}-epoch-${epoch.epoch}';
        final connection = await Navigator.of(context)
            .push<MicrosoftOneDriveConnection>(
              MaterialPageRoute(
                builder: (_) => MicrosoftOneDriveConnectPage(
                  core: widget.core,
                  secretStore: widget.secretStore,
                  targetId: authProfileId,
                  existingDriveId: target.driveId,
                ),
              ),
            );
        if (connection == null || !mounted) return;
        credentialRef = connection.credentialRef;
      } else {
        final credentials = await showDialog<_S3Configuration>(
          context: context,
          builder: (context) => _S3ConfigurationDialog(existing: target),
        );
        if (credentials == null || !mounted) return;
        final credentialBytes = Uint8List.fromList(
          utf8.encode(
            jsonEncode(<String, Object?>{
              'access_key_id': credentials.accessKeyId,
              'secret_access_key': credentials.secretAccessKey,
              if (credentials.sessionToken.isNotEmpty)
                'session_token': credentials.sessionToken,
            }),
          ),
        );
        try {
          credentialRef = await widget.secretStore.write(credentialBytes);
          ownsCredential = true;
        } finally {
          credentialBytes.fillRange(0, credentialBytes.length, 0);
        }
      }

      if (epoch.requiresEncryptionKey) {
        final oldKeyId = epoch.historicalKeyId;
        if (oldKeyId == null) {
          throw StateError('历史加密策略未提供 key ID。');
        }
        final oldKey = await widget.secretStore.read(SecretRef(oldKeyId));
        if (oldKey == null || oldKey.length != 32) {
          oldKey?.fillRange(0, oldKey.length, 0);
          throw StateError('缺少此历史 epoch 的 32 字节恢复密钥。请先导入对应 Vault 的恢复密钥，再重新授权。');
        }
        try {
          encryptionRef = await widget.secretStore.write(oldKey);
          ownsEncryption = true;
        } finally {
          oldKey.fillRange(0, oldKey.length, 0);
        }
      }

      final scope = await widget.sync.historicalEpochAuthorizationScope(
        targetId: target.targetId,
        epoch: epoch.epoch,
        credentialRef: credentialRef,
        encryptionSecretRef: encryptionRef,
      );
      if (!mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('仅在本机重新授权历史 epoch？'),
          content: SelectableText(
            '目标：${target.displayName}\nProvider：${target.provider.name}\n'
            'Epoch：${epoch.epoch}\nEndpoint 指纹：${scope['endpoint_fingerprint']}\n'
            '历史 key ID：${scope['key_id'] ?? '无（明文策略）'}\n'
            '新 key 指纹：${scope['key_fingerprint'] ?? '无'}\n\n'
            '这会把新凭据和（如需）历史恢复密钥引用绑定到当前设备授权代次。旧凭据 SecretRef 不会直接授权使用；'
            '历史密钥字节会在本机从已导入恢复密钥读取，并重新保存为新的 SecretRef。'
            '凭据/密钥明文只保存在系统安全存储。此操作只恢复本机对该历史目标的访问，不会立即同步或上传。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('批准本机历史授权'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
      final approval = widget.core.approvals.issue(
        action: 'sync.epoch.reauthorize',
        subjectType: 'remote_target_epoch',
        subjectId: '${target.targetId}@${epoch.epoch}',
        scope: scope,
      );
      await widget.sync.reauthorizeHistoricalEpoch(
        targetId: target.targetId,
        epoch: epoch.epoch,
        credentialRef: credentialRef,
        encryptionSecretRef: encryptionRef,
        approvalRef: approval,
      );
      ownsCredential = false;
      ownsEncryption = false;
      await _refresh();
      if (mounted) {
        _showMessage('历史 epoch ${epoch.epoch} 已仅在本设备重新授权。远端同步仍需单独预览并确认。');
      }
    } on Object catch (error) {
      if (mounted) _showError(error);
    } finally {
      if (ownsCredential && credentialRef != null) {
        await widget.secretStore.delete(credentialRef);
      }
      if (ownsEncryption && encryptionRef != null) {
        await widget.secretStore.delete(encryptionRef);
      }
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _sync(SyncTarget target) async {
    setState(() => _busy = true);
    try {
      final preview = await widget.sync.preview(targetId: target.targetId);
      if (!mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('同步本机数据？'),
          content: SizedBox(
            width: 560,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('目标：${target.displayName} (${target.provider.name})'),
                  Text(
                    '待上传事件：${preview.pendingEvents}；Blob：${preview.pendingBlobs}',
                  ),
                  Text('估计上传：${_formatBytes(preview.bytesToUpload)}'),
                  Text('估计下载：${_formatBytes(preview.bytesToDownload)}'),
                  Text('当前未解决冲突：${preview.openConflicts}'),
                  Text(
                    '客户端加密：${target.encryption.mode == RemoteEncryptionMode.none ? '关闭（远端内容为明文）' : '开启（${target.encryption.mode.name}）'}',
                  ),
                  if (preview.warnings.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text('提示：\n${preview.warnings.join('\n')}'),
                  ],
                  const SizedBox(height: 8),
                  const Text(
                    '同步会上传不可变事件与资产 Blob，并将远端事件放入本机待审阅收件箱；'
                    '不会同步 SQLite 文件，也不会静默覆盖本机记录。',
                  ),
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
              onPressed: preview.canRun
                  ? () => Navigator.pop(context, true)
                  : null,
              child: const Text('确认并同步'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
      final result = await widget.sync.syncNow(targetId: target.targetId);
      await _refresh();
      if (mounted) {
        _showMessage(
          '同步状态：${result.state} · 上传事件 ${result.eventsUploaded} · 下载事件 ${result.eventsReceived} · '
          '冲突 ${result.conflictsPreserved} · ${_formatBytes(result.bytesTransferred)}'
          '${result.warnings.isEmpty ? '' : '\n${result.warnings.join('\n')}'}',
        );
      }
    } on Object catch (error) {
      if (mounted) _showError(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reviewRemoteMeasurement(
    RemoteMeasurementImportRecord record,
  ) async {
    setState(() => _busy = true);
    try {
      final reviews = widget.core.remoteMeasurementReviews;
      final trace = reviews.getTrace(record.sourceEventId);
      if (!mounted) return;
      final payload = record.payload;
      final decision = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('审阅远端科学测量'),
          content: SizedBox(
            width: 720,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Analyte：${payload['analyte'] ?? '未知'}'),
                  Text(
                    '原始值：${payload['value_text'] ?? '未知'} ${payload['unit'] ?? ''}',
                  ),
                  Text(
                    '事件：${record.sourceEventId} · ${record.sourceEventType}',
                  ),
                  Text('来源设备：${record.sourceDeviceId}'),
                  Text('远端 CalculationRun：${record.calculationId}'),
                  SelectableText(
                    'CalculationTrace SHA-256：${record.calculationTraceSha256}',
                  ),
                  if (record.assetShaRefs.isNotEmpty)
                    SelectableText(
                      '引用原始资产 SHA：${record.assetShaRefs.join(', ')}',
                    ),
                  const SizedBox(height: 12),
                  const Text('原始计算 Trace（只读；导入后仍作为外部计算引用保留）：'),
                  const SizedBox(height: 6),
                  SelectableText(trace.canonicalJson),
                  const SizedBox(height: 12),
                  const Text(
                    '导入会创建本机已确认 Measurement，并保留远端 CalculationRun、output key、Trace SHA 与来源事件。它不会伪装成本机执行。',
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, 'cancel'),
              child: const Text('稍后'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, 'reject'),
              child: const Text('拒绝并记录原因'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, 'import'),
              child: const Text('审阅 Trace 并导入'),
            ),
          ],
        ),
      );
      if (decision == null || decision == 'cancel' || !mounted) return;
      if (decision == 'reject') {
        final reason = await _requestReviewReason();
        if (reason == null || !mounted) return;
        reviews.reject(sourceEventId: record.sourceEventId, reason: reason);
      } else {
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('批准导入这条远端测量？'),
            content: Text(
              '将精确导入 ${payload['analyte'] ?? '未知'} = '
              '${payload['value_text'] ?? '未知'} ${payload['unit'] ?? ''}。'
              '此设备会为来源事件 ${record.sourceEventId} 签发一次性审批。',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('批准并导入'),
              ),
            ],
          ),
        );
        if (confirmed != true || !mounted) return;
        final approval = widget.core.approvals.issue(
          action: 'measurement.external_import',
          subjectType: 'remote_measurement',
          subjectId: record.sourceEventId,
          scope: <String, Object?>{
            'source_event_id': record.sourceEventId,
            'calculation_id': record.calculationId,
            'calculation_trace_sha256': record.calculationTraceSha256,
          },
        );
        reviews.importMeasurement(
          sourceEventId: record.sourceEventId,
          approvalRef: approval,
        );
      }
      await _refresh();
      if (mounted) {
        _showMessage(
          decision == 'import' ? '远端测量已导入并保留外部 Trace。' : '拒绝决定已保存到本地审核记录。',
        );
      }
    } on Object catch (error) {
      if (mounted) _showError(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reviewRemoteAssetDeletion(
    RemoteAssetDeletionReview review,
  ) async {
    setState(() => _busy = true);
    try {
      final auditOnly = review.requestedScope == 'purge';
      if (auditOnly) {
        final accepted = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('审阅远端永久删除请求'),
            content: SelectableText(
              '资产：${review.assetId}\nBlob SHA-256：${review.blobSha256}\n'
              '来源设备：${review.sourceDeviceId} · 目标：${review.targetId}\n'
              '来源事件：${review.sourceEventId} · 删除记录：${review.sourceDeletionId}\n'
              '源设备审批引用（仅来源凭据，不是本机授权）：${review.sourceApprovalRef}\n'
              '原因：${review.reason}\n\n'
              '远端请求为永久删除。本机只记录审阅结果，不会永久删除本机 Asset 或 CAS Blob。',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('稍后'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('记录为审计项（不删除）'),
              ),
            ],
          ),
        );
        if (accepted != true || !mounted) return;
        await widget.core.assets.dismissRemoteDeletionReview(
          review.sourceEventId,
          note: '远端 purge 仅作审计；本机 Asset 与 CAS 保持不变。',
        );
      } else {
        final impact = await widget.core.assets.previewRemoteDeletion(
          review.sourceEventId,
        );
        if (!mounted) return;
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('本机审阅远端移入废纸篓请求'),
            content: SizedBox(
              width: 600,
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('资产：${review.assetId}'),
                    SelectableText('Blob SHA-256：${review.blobSha256}'),
                    Text(
                      '来源设备：${review.sourceDeviceId} · 目标：${review.targetId}',
                    ),
                    Text(
                      '来源事件：${review.sourceEventId} · 删除记录：${review.sourceDeletionId}',
                    ),
                    SelectableText(
                      '源设备审批引用（仅来源凭据，不是本机授权）：${review.sourceApprovalRef}',
                    ),
                    Text('原因：${review.reason}'),
                    const Divider(),
                    Text('本机影响预览：逻辑大小 ${_formatBytes(impact.logicalBytes)}'),
                    Text(
                      '仍有 ${impact.activeLinks.length} 个活动引用；'
                      '${impact.otherActiveAssetsSharingBlob.length} 个活动资产共享同一 Blob。',
                    ),
                    Text(
                      '保留备份 ${impact.retainedBackupCount}；活动读取 ${impact.activeLeaseCount}；'
                      '估计可回收 ${_formatBytes(impact.reclaimablePhysicalBytes)}。',
                    ),
                    if (impact.activeLinks.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      const Text('本机活动引用：'),
                      for (final link in impact.activeLinks.take(8))
                        Text(
                          '• ${link.targetType}:${link.targetId} / ${link.role}',
                        ),
                    ],
                    const SizedBox(height: 10),
                    const Text(
                      '确认后将签发新的本机 asset.trash 审批并通过 AssetGateway 执行。'
                      '源设备 approval_ref 只保留为 provenance，不能授权本机操作。',
                    ),
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
                child: const Text('签发本机审批并移入废纸篓'),
              ),
            ],
          ),
        );
        if (confirmed != true || !mounted) return;
        final approval = widget.core.approvals.issue(
          action: 'asset.trash',
          subjectType: 'asset',
          subjectId: review.assetId,
          scope: <String, Object?>{
            'blob_sha256': review.blobSha256,
            'purge': false,
            'impact_reviewed': true,
          },
        );
        await widget.core.assets.acceptRemoteDeletion(
          review.sourceEventId,
          approvalRef: approval.value,
        );
      }
      await _refresh();
      if (mounted) {
        _showMessage(
          auditOnly
              ? '远端 purge 请求已记录为审计项；本机内容未删除。'
              : '已依据本机影响预览和本机审批处理远端软删除请求。',
        );
      }
    } on Object catch (error) {
      if (mounted) _showError(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String?> _requestReviewReason() => showDialog<String>(
    context: context,
    builder: (context) {
      final controller = TextEditingController();
      return AlertDialog(
        title: const Text('记录拒绝原因'),
        content: TextField(
          controller: controller,
          minLines: 2,
          maxLines: 4,
          decoration: const InputDecoration(labelText: '原因'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('保存拒绝决定'),
          ),
        ],
      );
    },
  );

  Future<int> _estimateSnapshotBytes() async {
    final dbPath = <String>[
      widget.core.vault.context.rootDirectory,
      'workspace.sqlite3',
    ].join(Platform.pathSeparator);
    final db = File(dbPath);
    final dbBytes = await db.exists() ? await db.length() : 0;
    return dbBytes + (_usage?.uniqueBlobBytes ?? 0);
  }

  Future<void> _createBackup({SyncTarget? remoteTarget}) async {
    setState(() => _busy = true);
    try {
      final estimate = await _estimateSnapshotBytes();
      if (!mounted) return;
      final keyRef = remoteTarget?.encryption.keyRef;
      final encryptDatabase =
          keyRef != null &&
          remoteTarget!.encryption.encryptsObject(metadata: true, byteSize: 0);
      final encryptAssets =
          keyRef != null &&
          (remoteTarget!.encryption.encryptsObject(
                metadata: false,
                byteSize: 1,
              ) ||
              remoteTarget.encryption.encryptsObject(
                metadata: false,
                byteSize: remoteTarget.encryption.largeFileThresholdBytes,
              ));
      final encrypted = encryptDatabase || encryptAssets;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(remoteTarget == null ? '创建本机快照？' : '创建并上传备份？'),
          content: Text(
            remoteTarget == null
                ? '将使用 SQLite Online Backup API 生成独立快照。预计数据量 ${_formatBytes(estimate)}。'
                      '本地快照不加密，因此可独立恢复；请使用设备磁盘加密并妥善保护备份目录。'
                : '目标：${remoteTarget.displayName}\n预计数据量 ${_formatBytes(estimate)}。'
                      '数据库 ${encryptDatabase ? '加密' : '明文'}；资产 ${encryptAssets ? '加密' : '明文'}。'
                      '${encrypted ? '\n恢复密钥只在此设备安全存储；丢失密钥后无法恢复。请先导出并异地保管恢复密钥。' : ''}'
                      '\n将创建包含独立数据库快照和已引用 Blob 的完整备份。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('确认创建'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
      final result = await widget.backups.snapshot(
        targetId: remoteTarget?.targetId,
        encryptionPolicy: BackupEncryptionPolicy(
          databaseKey: encryptDatabase ? keyRef : null,
          assetKey: encryptAssets ? keyRef : null,
        ),
      );
      if (mounted) {
        _showMessage(
          '快照 ${result.state} · ${result.backupId}\n${result.snapshotDirectory}'
          '${result.warnings.isEmpty ? '' : '\n${result.warnings.join('\n')}'}',
        );
      }
    } on Object catch (error) {
      if (mounted) _showError(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restoreBackup() async {
    final path = await FilePicker.getDirectoryPath(
      dialogTitle: '选择包含 manifest.json 的备份快照目录',
    );
    if (path == null || !mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('校验并恢复到新 Vault？'),
        content: const Text(
          '恢复将验证 manifest、所有对象的存储与明文 SHA-256、数据库完整性和 Vault 标识；'
          '不会覆盖当前 Vault。恢复结果会写入单独目录，完成后需在应用重新启动时选择该 Vault。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('验证并恢复'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final support = await getApplicationSupportDirectory();
      final destination = <String>[
        support.path,
        'LabWorkspace',
        'RestoredVaults',
        'restore-${DateTime.now().toUtc().microsecondsSinceEpoch}',
      ].join(Platform.pathSeparator);
      final result = await widget.backups.restore(
        snapshotDirectory: path,
        destinationDirectory: destination,
      );
      if (!mounted) return;
      final activate = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('恢复完成'),
          content: Text(
            '已验证 ${result.verifiedObjects} 个对象。Vault ${result.vaultId}\n'
            '恢复根目录：${result.destinationDirectory}\n\n'
            '恢复已建立新的本机设备身份与授权代次。旧设备凭据、审批和授权不会在此安装上继续生效；重新连接云服务并重新授予所需同意。\n\n'
            '${result.warnings.isEmpty ? '源 Vault 审计记录已写入。' : '恢复数据已验证并发布，可正常打开；但源 Vault 审计记录未能写入：\n${result.warnings.join('\n')}'}\n\n'
            '是否将此 Vault 设为下次启动时打开？当前应用仍保持在原 Vault。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('稍后选择'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('设为下次启动 Vault'),
            ),
          ],
        ),
      );
      if (activate == true) {
        final restoredCore = await LabCore.openExisting(
          directoryPath: result.destinationDirectory,
        );
        try {
          if (restoredCore.vault.id != result.vaultId) {
            throw StateError('恢复目录中的 Vault 身份与恢复结果不一致；未更改下次启动选择。');
          }
          final support = await getApplicationSupportDirectory();
          await ActiveVaultSelection.atSupportDirectory(support).write(
            ActiveVaultRecord(
              rootDirectory: restoredCore.vault.context.rootDirectory,
              vaultId: restoredCore.vault.id,
              deviceId: restoredCore.vault.deviceId,
            ),
          );
        } finally {
          await restoredCore.close();
        }
        if (mounted) {
          _showMessage(
            '已验证并选择 Vault ${result.vaultId} 作为下次启动 Vault。重启后会再次验证；本次运行仍使用当前 Vault。'
            '${result.warnings.isEmpty ? '' : '\n恢复内容已发布，但源 Vault 审计记录警告：${result.warnings.join('; ')}'}',
          );
        }
      } else if (mounted) {
        _showMessage('已恢复 Vault ${result.vaultId}，当前打开的 Vault 未切换。');
      }
    } on Object catch (error) {
      if (mounted) _showError(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _exportRecoveryKeys() async {
    setState(() => _busy = true);
    Uint8List? fileBytes;
    try {
      final targets = await widget.sync.listTargets();
      final keys = <String, String>{};
      for (final target in targets) {
        final ref = target.encryption.keyRef;
        if (ref == null) continue;
        final bytes = await widget.secretStore.read(ref);
        if (bytes == null || bytes.length != 32) {
          throw StateError('加密目标 ${target.displayName} 的 32 字节恢复密钥不可用。');
        }
        try {
          keys[ref.value] = base64UrlEncode(bytes);
        } finally {
          bytes.fillRange(0, bytes.length, 0);
        }
      }
      if (keys.isEmpty) throw StateError('当前没有已配置的客户端加密恢复密钥。');
      if (!mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('导出明文恢复密钥？'),
          content: const Text(
            '导出的 JSON 文件可解密所有使用这些密钥的远端数据。任何拿到该文件的人都能读取数据。'
            '请保存到安全的离线位置，不要上传到同一远端备份。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('导出密钥'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
      fileBytes = Uint8List.fromList(
        utf8.encode(
          const JsonEncoder.withIndent('  ').convert(<String, Object?>{
            'schema_version': '1.0',
            'vault_id': widget.core.vault.context.vaultId,
            'keys': keys.entries
                .map(
                  (entry) => <String, String>{
                    'secret_ref': entry.key,
                    'key_base64url': entry.value,
                  },
                )
                .toList(growable: false),
          }),
        ),
      );
      final uri = await FilePicker.saveFile(
        fileName: 'lab_workspace_recovery_keys.json',
        bytes: fileBytes,
        mimeType: 'application/json',
      );
      if (mounted && uri != null) {
        _showMessage('恢复密钥文件已保存到所选位置。请离线安全保管。');
      }
    } on Object catch (error) {
      if (mounted) _showError(error);
    } finally {
      fileBytes?.fillRange(0, fileBytes.length, 0);
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _importRecoveryKeys() async {
    final selected = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: const ['json'],
    );
    if (selected == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final sourceBytes = await selected.readAsBytes();
      final sensitiveKeyBytes = <Uint8List>[];
      try {
        final decoded = jsonDecode(utf8.decode(sourceBytes));
        if (decoded is! Map<String, Object?> ||
            decoded['schema_version'] != '1.0' ||
            decoded['keys'] is! List) {
          throw const FormatException('恢复密钥文件格式不受支持。');
        }
        final records = decoded['keys'] as List;
        final keys = <(SecretRef, Uint8List)>[];
        for (final record in records) {
          if (record is! Map<String, Object?> ||
              record['secret_ref'] is! String ||
              record['key_base64url'] is! String) {
            throw const FormatException('恢复密钥项无效。');
          }
          final secret = Uint8List.fromList(
            base64Url.decode(
              base64Url.normalize(record['key_base64url']! as String),
            ),
          );
          if (secret.length != 32) {
            secret.fillRange(0, secret.length, 0);
            throw const FormatException('恢复密钥必须为 32 字节。');
          }
          keys.add((SecretRef(record['secret_ref']! as String), secret));
          sensitiveKeyBytes.add(secret);
        }
        if (keys.isEmpty) throw const FormatException('恢复文件中没有密钥。');
        if (!mounted) return;
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('导入恢复密钥？'),
            content: Text(
              '将把 ${keys.length} 个密钥写入本机安全存储，保留原 SecretRef 以供旧备份解密。'
              '同名 SecretRef 会被覆盖。文件声明的 Vault：${decoded['vault_id'] ?? '未知'}。',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('明确导入'),
              ),
            ],
          ),
        );
        if (confirmed == true) {
          for (final entry in keys) {
            await widget.secretStore.importWithRef(entry.$1, entry.$2);
          }
          if (mounted) _showMessage('已导入 ${keys.length} 个恢复密钥。');
        }
        for (final entry in keys) {
          entry.$2.fillRange(0, entry.$2.length, 0);
        }
      } finally {
        sourceBytes.fillRange(0, sourceBytes.length, 0);
        for (final secret in sensitiveKeyBytes) {
          secret.fillRange(0, secret.length, 0);
        }
      }
    } on Object catch (error) {
      if (mounted) _showError(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _selectExistingVault() async {
    final root = await FilePicker.getDirectoryPath(
      dialogTitle: '选择已有 Lab Workspace Vault 根目录',
    );
    if (root == null || !mounted) return;
    setState(() => _busy = true);
    LabCore? candidate;
    try {
      candidate = await LabCore.openExisting(directoryPath: root);
      if (!mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('下次启动时打开这个 Vault？'),
          content: SelectableText(
            'Vault ID：${candidate!.vault.id}\n'
            '设备 ID：${candidate.vault.deviceId}\n'
            '目录：${candidate.vault.context.rootDirectory}\n\n'
            '目录和数据库已通过现有 Vault 检查。确认后会保存在本机 active_vault.json；当前会话仍留在当前 Vault。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('选择此 Vault'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
      final support = await getApplicationSupportDirectory();
      await ActiveVaultSelection.atSupportDirectory(support).write(
        ActiveVaultRecord(
          rootDirectory: candidate.vault.context.rootDirectory,
          vaultId: candidate.vault.id,
          deviceId: candidate.vault.deviceId,
        ),
      );
      if (mounted) {
        _showMessage('已选择 Vault ${candidate.vault.id}。重新启动应用后打开；当前会话没有切换。');
      }
    } on Object catch (error) {
      if (mounted) _showError(error);
    } finally {
      if (candidate != null) await candidate.close();
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  void _showError(Object error) => _showMessage('操作失败：$error');

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.fromLTRB(28, 22, 28, 34),
    children: [
      WorkspacePageHeader(
        title: '同步与备份',
        subtitle:
            '每台设备维护自己的 SQLite Vault。同步交换不可变事件和 Blob；备份使用 SQLite Online Backup 快照。',
        icon: Icons.cloud_sync_outlined,
        actions: [
          FilledButton.icon(
            onPressed: _busy ? null : () => _createBackup(),
            icon: const Icon(Icons.save_outlined),
            label: const Text('本机明文快照'),
          ),
          IconButton(
            tooltip: '刷新远端目标和空间用量',
            onPressed: _refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      if (_error != null)
        MaterialBanner(
          content: Text('读取远端配置失败：$_error'),
          actions: [TextButton(onPressed: _refresh, child: const Text('重试'))],
        ),
      const SizedBox(height: 12),
      Wrap(
        spacing: 12,
        runSpacing: 8,
        children: [
          FilledButton.icon(
            onPressed: _busy ? null : () => _connectOneDrive(),
            icon: const Icon(Icons.cloud_outlined),
            label: const Text('连接 OneDrive'),
          ),
          FilledButton.icon(
            onPressed: _busy ? null : () => _configureS3(),
            icon: const Icon(Icons.cloud_outlined),
            label: const Text('配置 S3 兼容目标'),
          ),
          OutlinedButton.icon(
            onPressed: _busy ? null : _restoreBackup,
            icon: const Icon(Icons.restore),
            label: const Text('校验并恢复快照'),
          ),
          OutlinedButton.icon(
            onPressed: _busy ? null : _selectExistingVault,
            icon: const Icon(Icons.folder_open),
            label: const Text('选择已有 Vault'),
          ),
          OutlinedButton.icon(
            onPressed: _busy ? null : _exportRecoveryKeys,
            icon: const Icon(Icons.key_outlined),
            label: const Text('导出恢复密钥'),
          ),
          OutlinedButton.icon(
            onPressed: _busy ? null : _importRecoveryKeys,
            icon: const Icon(Icons.key),
            label: const Text('导入恢复密钥'),
          ),
        ],
      ),
      if (_busy) const LinearProgressIndicator(),
      if (_usage != null)
        Card(
          child: ListTile(
            leading: const Icon(Icons.storage_outlined),
            title: const Text('本机 AssetStore 空间'),
            subtitle: Text(
              '逻辑资产 ${_formatBytes(_usage!.logicalBytes)} · '
              '唯一 Blob ${_formatBytes(_usage!.uniqueBlobBytes)}',
            ),
          ),
        ),
      const SizedBox(height: 16),
      WorkspaceSectionHeader(
        title: '远端测量待审核',
        subtitle: '查看原始 Trace 并逐条批准后才会进入本机记录。',
      ),
      const Text('同步收到的计算型测量保持隔离，需逐条查看原始 Trace 并明确批准后才能进入本机记录。'),
      if (_remoteMeasurements.isEmpty)
        const Card(
          child: ListTile(
            leading: Icon(Icons.fact_check_outlined),
            title: Text('没有待审核的远端计算测量'),
          ),
        )
      else
        for (final record in _remoteMeasurements)
          Card(
            child: ListTile(
              leading: const Icon(Icons.science_outlined),
              title: Text(
                '${record.payload['analyte'] ?? '未知'} = '
                '${record.payload['value_text'] ?? '未知'} ${record.payload['unit'] ?? ''}',
              ),
              subtitle: Text(
                '来源 ${record.sourceDeviceId} · ${record.sourceEventType} · '
                '远端 Calculation ${record.calculationId} · Trace ${record.calculationTraceSha256}',
              ),
              isThreeLine: true,
              trailing: IconButton(
                tooltip: '查看 Trace 并审核',
                onPressed: _busy
                    ? null
                    : () => _reviewRemoteMeasurement(record),
                icon: const Icon(Icons.rate_review_outlined),
              ),
            ),
          ),
      const SizedBox(height: 16),
      WorkspaceSectionHeader(
        title: '远端资产删除待审',
        subtitle: '软删除前先核对本机引用与共享 Blob 影响。',
      ),
      const Text(
        '远端 tombstone 不会直接复用源设备审批。软删除需先查看本机引用/共享 Blob 影响，再签发本机审批；远端 purge 只记审计，不删除本机内容。',
      ),
      if (_remoteAssetDeletions.isEmpty)
        const Card(
          child: ListTile(
            leading: Icon(Icons.delete_sweep_outlined),
            title: Text('没有待审核的远端资产删除请求'),
          ),
        )
      else
        for (final review in _remoteAssetDeletions)
          Card(
            child: ListTile(
              leading: Icon(
                review.requestedScope == 'purge'
                    ? Icons.delete_forever_outlined
                    : Icons.delete_outline,
              ),
              title: Text(
                '${review.requestedScope == 'purge' ? '远端永久删除（仅审计）' : '远端软删除请求'} · ${review.assetId}',
              ),
              subtitle: Text(
                '来源设备 ${review.sourceDeviceId} · 目标 ${review.targetId} · '
                'SHA-256 ${review.blobSha256}\n来源事件 ${review.sourceEventId} · '
                '请求 ${review.requestedAtUtc.toUtc().toIso8601String()}\n'
                '源审批 ${review.sourceApprovalRef}（仅 provenance） · ${review.reason}',
              ),
              isThreeLine: true,
              trailing: IconButton(
                tooltip: review.requestedScope == 'purge'
                    ? '记录审计项，不删除本机内容'
                    : '查看本机影响并审批软删除',
                onPressed: _busy
                    ? null
                    : () => _reviewRemoteAssetDeletion(review),
                icon: const Icon(Icons.rate_review_outlined),
              ),
            ),
          ),
      const SizedBox(height: 16),
      const WorkspaceSectionHeader(title: '历史同步策略授权'),
      const Text(
        '恢复 Vault 后，旧 epoch 的云端凭据不会自动使用。逐项重新输入 OneDrive Files 或 S3 凭据；加密 epoch 还需先导入对应历史恢复密钥。审批只授权本机读取该 epoch，不会启动同步。',
      ),
      if (_historicalEpochs.isEmpty)
        const Card(
          child: ListTile(
            leading: Icon(Icons.verified_user_outlined),
            title: Text('没有需要重新授权的历史 epoch'),
          ),
        )
      else
        for (final epoch in _historicalEpochs)
          Card(
            child: ListTile(
              leading: const Icon(Icons.lock_reset_outlined),
              title: Text(
                '${epoch.target.displayName} · ${epoch.provider.name} · epoch ${epoch.epoch}',
              ),
              subtitle: Text(
                '旧设备授权代次 ${epoch.recordedAuthorityGeneration} · 当前 ${epoch.currentAuthorityGeneration}\n'
                'Endpoint 指纹 ${epoch.endpointFingerprint} · '
                '历史 key ${epoch.historicalKeyId ?? '无'}'
                '${epoch.requiresEncryptionKey ? '（需要旧恢复密钥）' : ''}',
              ),
              isThreeLine: true,
              trailing: FilledButton.tonalIcon(
                onPressed: _busy
                    ? null
                    : () => _reauthorizeHistoricalEpoch(epoch),
                icon: const Icon(Icons.key),
                label: const Text('重新授权'),
              ),
            ),
          ),
      const SizedBox(height: 16),
      Text('远端目标', style: Theme.of(context).textTheme.titleLarge),
      if (_targets.isEmpty)
        const Card(
          child: ListTile(
            leading: Icon(Icons.cloud_off_outlined),
            title: Text('没有已配置的远端目标'),
            subtitle: Text('同步不会自动开始；配置目标后，每次同步仍需显示预览并确认。'),
          ),
        )
      else
        for (final target in _targets)
          Card(
            child: ListTile(
              leading: Icon(
                target.state == SyncTargetState.ready
                    ? Icons.cloud_done_outlined
                    : Icons.cloud_off_outlined,
              ),
              title: Text(target.displayName),
              subtitle: Text(
                '${target.provider.name} · ${target.state.name} · '
                '同步 ${target.syncEnabled ? '开启' : '关闭'} · '
                '备份 ${target.backupEnabled ? '开启' : '关闭'} · '
                '客户端加密 ${target.encryption.mode.name}'
                '${target.lastError == null ? '' : '\n${target.lastError}'}',
              ),
              isThreeLine: true,
              trailing: Wrap(
                spacing: 4,
                children: [
                  IconButton(
                    tooltip: '查看同步预览并确认同步',
                    onPressed: _busy ? null : () => _sync(target),
                    icon: const Icon(Icons.sync),
                  ),
                  IconButton(
                    tooltip: target.backupEnabled
                        ? '创建加密策略沿用目标密钥的远端快照'
                        : '该目标未启用备份',
                    onPressed: _busy || !target.backupEnabled
                        ? null
                        : () => _createBackup(remoteTarget: target),
                    icon: const Icon(Icons.cloud_upload_outlined),
                  ),
                  IconButton(
                    tooltip: '编辑 S3 凭据和加密策略',
                    onPressed: _busy || target.provider != SyncProvider.s3
                        ? null
                        : () => _configureS3(target),
                    icon: const Icon(Icons.edit_outlined),
                  ),
                  IconButton(
                    tooltip: '单独授权并配置 OneDrive Files',
                    onPressed: _busy || target.provider != SyncProvider.oneDrive
                        ? null
                        : () => _connectOneDrive(target),
                    icon: const Icon(Icons.manage_accounts_outlined),
                  ),
                ],
              ),
            ),
          ),
    ],
  );
}

class _OneDriveConfiguration {
  const _OneDriveConfiguration({
    required this.displayName,
    required this.encryptMetadata,
    required this.encryptSmallFiles,
    required this.encryptLargeFiles,
    required this.backupEnabled,
  });

  final String displayName;
  final bool encryptMetadata;
  final bool encryptSmallFiles;
  final bool encryptLargeFiles;
  final bool backupEnabled;
}

class _OneDriveConfigurationDialog extends StatefulWidget {
  const _OneDriveConfigurationDialog({this.existing});

  final SyncTarget? existing;

  @override
  State<_OneDriveConfigurationDialog> createState() =>
      _OneDriveConfigurationDialogState();
}

class _OneDriveConfigurationDialogState
    extends State<_OneDriveConfigurationDialog> {
  late final TextEditingController _displayName;
  late bool _encryptMetadata;
  late bool _encryptSmallFiles;
  late bool _encryptLargeFiles;
  late bool _backupEnabled;

  @override
  void initState() {
    super.initState();
    final target = widget.existing;
    _displayName = TextEditingController(
      text: target?.displayName ?? 'OneDrive',
    );
    _encryptMetadata = target?.encryption.encryptMetadata ?? true;
    _encryptSmallFiles = target?.encryption.encryptSmallFiles ?? true;
    _encryptLargeFiles = target?.encryption.encryptLargeFiles ?? true;
    _backupEnabled = target?.backupEnabled ?? false;
  }

  @override
  void dispose() {
    _displayName.dispose();
    super.dispose();
  }

  void _save() {
    if (_displayName.text.trim().isEmpty) return;
    Navigator.pop(
      context,
      _OneDriveConfiguration(
        displayName: _displayName.text.trim(),
        encryptMetadata: _encryptMetadata,
        encryptSmallFiles: _encryptSmallFiles,
        encryptLargeFiles: _encryptLargeFiles,
        backupEnabled: _backupEnabled,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.existing == null ? '连接 OneDrive' : '重新授权 OneDrive'),
    content: SizedBox(
      width: 520,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _displayName,
              decoration: const InputDecoration(labelText: '目标名称'),
            ),
            if (widget.existing == null) ...[
              CheckboxListTile(
                value: _encryptMetadata,
                onChanged: (value) =>
                    setState(() => _encryptMetadata = value ?? false),
                contentPadding: EdgeInsets.zero,
                title: const Text('加密数据库与元数据'),
              ),
              CheckboxListTile(
                value: _encryptSmallFiles,
                onChanged: (value) =>
                    setState(() => _encryptSmallFiles = value ?? false),
                contentPadding: EdgeInsets.zero,
                title: const Text('加密小型资产'),
              ),
              CheckboxListTile(
                value: _encryptLargeFiles,
                onChanged: (value) =>
                    setState(() => _encryptLargeFiles = value ?? false),
                contentPadding: EdgeInsets.zero,
                title: const Text('加密大型资产'),
              ),
              const Text(
                'OneDrive 只使用 Files.ReadWrite + offline_access 独立授权；To Do 登录不会共享。',
              ),
            ] else
              const Text('重新授权保留目标现有的加密类别与恢复密钥。'),
            CheckboxListTile(
              value: _backupEnabled,
              onChanged: (value) =>
                  setState(() => _backupEnabled = value ?? false),
              contentPadding: EdgeInsets.zero,
              title: const Text('允许显式创建远端完整备份'),
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
      FilledButton(onPressed: _save, child: const Text('继续授权')),
    ],
  );
}

class _S3Configuration {
  const _S3Configuration({
    required this.displayName,
    required this.endpoint,
    required this.region,
    required this.bucket,
    required this.accessKeyId,
    required this.secretAccessKey,
    required this.sessionToken,
    required this.encryptMetadata,
    required this.encryptSmallFiles,
    required this.encryptLargeFiles,
    required this.backupEnabled,
  });

  final String displayName;
  final String endpoint;
  final String region;
  final String bucket;
  final String accessKeyId;
  final String secretAccessKey;
  final String sessionToken;
  final bool encryptMetadata;
  final bool encryptSmallFiles;
  final bool encryptLargeFiles;
  final bool backupEnabled;
}

class _S3ConfigurationDialog extends StatefulWidget {
  const _S3ConfigurationDialog({this.existing});

  final SyncTarget? existing;

  @override
  State<_S3ConfigurationDialog> createState() => _S3ConfigurationDialogState();
}

class _S3ConfigurationDialogState extends State<_S3ConfigurationDialog> {
  late final TextEditingController _displayName;
  late final TextEditingController _endpoint;
  late final TextEditingController _region;
  late final TextEditingController _bucket;
  final _accessKeyId = TextEditingController();
  final _secretAccessKey = TextEditingController();
  final _sessionToken = TextEditingController();
  bool _encryptMetadata = true;
  bool _encryptSmallFiles = true;
  bool _encryptLargeFiles = true;
  bool _backupEnabled = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final target = widget.existing;
    _displayName = TextEditingController(
      text: target?.displayName ?? 'S3 backup',
    );
    _endpoint = TextEditingController(
      text: target?.endpoint ?? 'https://s3.amazonaws.com',
    );
    _region = TextEditingController(text: target?.region ?? 'us-east-1');
    _bucket = TextEditingController(text: target?.bucket ?? '');
    _encryptMetadata = target?.encryption.encryptMetadata ?? true;
    _encryptSmallFiles = target?.encryption.encryptSmallFiles ?? true;
    _encryptLargeFiles = target?.encryption.encryptLargeFiles ?? true;
    _backupEnabled = target?.backupEnabled ?? false;
  }

  @override
  void dispose() {
    for (final controller in [
      _displayName,
      _endpoint,
      _region,
      _bucket,
      _accessKeyId,
      _secretAccessKey,
      _sessionToken,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  void _save() {
    final endpoint = Uri.tryParse(_endpoint.text.trim());
    if (endpoint == null ||
        endpoint.scheme != 'https' ||
        endpoint.host.isEmpty) {
      setState(() => _error = 'S3 endpoint 必须是有效 HTTPS URL。');
      return;
    }
    if (_displayName.text.trim().isEmpty ||
        _region.text.trim().isEmpty ||
        _bucket.text.trim().isEmpty ||
        _accessKeyId.text.trim().isEmpty ||
        _secretAccessKey.text.isEmpty) {
      setState(() => _error = '目标名称、region、bucket 和访问凭据必须填写。');
      return;
    }
    Navigator.pop(
      context,
      _S3Configuration(
        displayName: _displayName.text.trim(),
        endpoint: endpoint.toString(),
        region: _region.text.trim(),
        bucket: _bucket.text.trim(),
        accessKeyId: _accessKeyId.text.trim(),
        secretAccessKey: _secretAccessKey.text,
        sessionToken: _sessionToken.text,
        encryptMetadata: _encryptMetadata,
        encryptSmallFiles: _encryptSmallFiles,
        encryptLargeFiles: _encryptLargeFiles,
        backupEnabled: _backupEnabled,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.existing == null ? '配置 S3 兼容目标' : '更新 S3 目标'),
    content: SizedBox(
      width: 540,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final item in <(TextEditingController, String, TextInputType)>[
              (_displayName, '目标名称', TextInputType.text),
              (_endpoint, 'HTTPS Endpoint', TextInputType.url),
              (_region, 'Region', TextInputType.text),
              (_bucket, 'Bucket', TextInputType.text),
              (_accessKeyId, 'Access key ID', TextInputType.text),
            ])
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: TextField(
                  controller: item.$1,
                  keyboardType: item.$3,
                  decoration: InputDecoration(labelText: item.$2),
                ),
              ),
            TextField(
              controller: _secretAccessKey,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Secret access key'),
            ),
            TextField(
              controller: _sessionToken,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Session token（可选）'),
            ),
            CheckboxListTile(
              value: _encryptMetadata,
              onChanged: widget.existing == null
                  ? (value) => setState(() => _encryptMetadata = value ?? false)
                  : null,
              contentPadding: EdgeInsets.zero,
              title: const Text('加密数据库与元数据'),
            ),
            CheckboxListTile(
              value: _encryptSmallFiles,
              onChanged: widget.existing == null
                  ? (value) =>
                        setState(() => _encryptSmallFiles = value ?? false)
                  : null,
              contentPadding: EdgeInsets.zero,
              title: const Text('加密小型资产'),
            ),
            CheckboxListTile(
              value: _encryptLargeFiles,
              onChanged: widget.existing == null
                  ? (value) =>
                        setState(() => _encryptLargeFiles = value ?? false)
                  : null,
              contentPadding: EdgeInsets.zero,
              title: Text(
                '加密大型资产（阈值 ${_formatBytes(widget.existing?.encryption.largeFileThresholdBytes ?? 64 * 1024 * 1024)}）',
              ),
            ),
            if (widget.existing == null &&
                (_encryptMetadata || _encryptSmallFiles || _encryptLargeFiles))
              const Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: EdgeInsets.only(bottom: 8),
                  child: Text('加密数据类别使用独立 AES-GCM 恢复密钥，生成后只保存在本机安全存储。'),
                ),
              ),
            if (widget.existing != null)
              const Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: EdgeInsets.only(bottom: 8),
                  child: Text('编辑时保留现有分类策略与恢复密钥，以确保旧远端对象仍可恢复。'),
                ),
              ),
            CheckboxListTile(
              value: _backupEnabled,
              onChanged: (value) =>
                  setState(() => _backupEnabled = value ?? false),
              contentPadding: EdgeInsets.zero,
              title: const Text('允许显式创建远端完整备份'),
              subtitle: const Text('远端备份只会在你查看估算并再次确认后上传。'),
            ),
            const SizedBox(height: 8),
            const Text(
              '访问凭据与加密密钥只存入操作系统安全存储。未加密目标会向提供商上传明文事件和文件；'
              '加密后请另行导出恢复密钥，否则丢失本机安全存储将无法解密。',
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
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
      FilledButton(onPressed: _save, child: const Text('保存远端目标')),
    ],
  );
}

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KiB', 'MiB', 'GiB', 'TiB'];
  var value = bytes.toDouble();
  var unit = -1;
  do {
    value /= 1024;
    unit++;
  } while (value >= 1024 && unit < units.length - 1);
  return '${value.toStringAsFixed(1)} ${units[unit]}';
}
