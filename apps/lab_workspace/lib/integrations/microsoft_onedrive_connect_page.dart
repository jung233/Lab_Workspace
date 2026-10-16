import 'package:flutter/material.dart';
import 'package:lab_core/lab_core.dart';

import 'microsoft_identity.dart';

final class MicrosoftOneDriveConnection {
  const MicrosoftOneDriveConnection({required this.credentialRef, this.driveId});
  final SecretRef credentialRef;
  final String? driveId;
}

/// Explicit, device-local OneDrive sign-in. The returned reference is opaque;
/// callers must attach it only to the matching OneDrive SyncTarget.
final class MicrosoftOneDriveConnectPage extends StatefulWidget {
  const MicrosoftOneDriveConnectPage({
    required this.core,
    required this.secretStore,
    required this.targetId,
    this.existingDriveId,
    super.key,
  });

  final LabCore core;
  final SecretStore secretStore;
  final String targetId;
  final String? existingDriveId;

  @override
  State<MicrosoftOneDriveConnectPage> createState() => _MicrosoftOneDriveConnectPageState();
}

final class _MicrosoftOneDriveConnectPageState extends State<MicrosoftOneDriveConnectPage> {
  late final SqliteMicrosoftOneDriveOAuthRepository _repository;
  late final MicrosoftOneDriveIdentitySession _identity;
  final _clientId = TextEditingController();
  final _tenantId = TextEditingController(text: 'common');
  final _driveId = TextEditingController();
  MicrosoftDeviceAuthorization? _authorization;
  String _message = '';
  bool _busy = false;
  bool _cancel = false;

  @override
  void initState() {
    super.initState();
    _repository = SqliteMicrosoftOneDriveOAuthRepository(widget.core.database);
    _identity = MicrosoftOneDriveIdentitySession(secrets: widget.secretStore, repository: _repository);
    _driveId.text = widget.existingDriveId ?? '';
    _loadProfile();
  }

  @override
  void dispose() {
    _clientId.dispose();
    _tenantId.dispose();
    _driveId.dispose();
    super.dispose();
  }

  Future<void> _loadProfile() async {
    try {
      final profile = await _repository.get(widget.targetId);
      if (!mounted || profile == null) return;
      setState(() {
        _clientId.text = profile.clientId;
        _tenantId.text = profile.tenantId;
        _driveId.text = profile.driveId ?? '';
        _message = profile.credentialRef == null
            ? '配置已保存；尚未连接 OneDrive。'
            : '已保存 OneDrive 专用凭据引用。令牌仅在此设备安全存储。';
      });
    } on Object catch (error) {
      if (mounted) setState(() => _message = _safeError(error));
    }
  }

  Future<void> _connect() async {
    if (_busy) return;
    setState(() { _busy = true; _cancel = false; _message = ''; });
    try {
      final profile = await _identity.saveConfiguration(
        targetId: widget.targetId,
        clientId: _clientId.text,
        tenantId: _tenantId.text,
        driveId: _driveId.text,
      );
      final authorization = await _identity.beginDeviceAuthorization(
        clientId: profile.clientId,
        tenantId: profile.tenantId,
      );
      if (!mounted) return;
      setState(() => _authorization = authorization);
      final proceed = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          title: const Text('连接 OneDrive'),
          content: SelectableText(
            '在浏览器打开 ${authorization.verificationUri}\n输入一次性代码：${authorization.userCode}\n\n'
            '本授权只请求 Microsoft Graph Files.ReadWrite 和 offline_access，用于此 OneDrive SyncTarget 的文件同步。'
            '它不会授权 Microsoft To Do，也不会把访问或刷新令牌写入 Vault 数据库。',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('我已完成浏览器授权')),
          ],
        ),
      );
      if (proceed != true) {
        _cancel = true;
        return;
      }
      final connected = await _identity.finishDeviceAuthorization(
        authorization: authorization,
        profile: profile,
        isCancelled: () => _cancel,
      );
      final credentialRef = connected.credentialRef;
      if (credentialRef == null) throw const MicrosoftOneDriveAuthException('ONEDRIVE_AUTH_FAILED', 'No secure credential reference was returned.');
      if (mounted) {
        Navigator.of(context).pop<MicrosoftOneDriveConnection>(MicrosoftOneDriveConnection(
          credentialRef: credentialRef,
          driveId: connected.driveId,
        ));
      }
    } on Object catch (error) {
      if (mounted) setState(() => _message = _safeError(error));
    } finally {
      if (mounted) setState(() { _busy = false; _authorization = null; });
    }
  }

  Future<void> _disconnect() async {
    try {
      await _identity.signOut(widget.targetId);
      if (mounted) setState(() => _message = 'OneDrive 此设备令牌已从安全存储移除。');
    } on Object catch (error) {
      if (mounted) setState(() => _message = _safeError(error));
    }
  }

  String _safeError(Object error) => error is MicrosoftOneDriveAuthException
      ? '${error.code}: ${error.message}'
      : 'ONEDRIVE_AUTH_FAILED: OneDrive authorization could not be completed.';

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('OneDrive 授权')),
        body: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const Text('OneDrive 使用独立的 OAuth 配置和 secure-storage 令牌。登录令牌不会同步，也不会与 To Do 账号共享。'),
            TextField(controller: _clientId, enabled: !_busy, decoration: const InputDecoration(labelText: 'Microsoft 公共客户端应用 ID')),
            TextField(controller: _tenantId, enabled: !_busy, decoration: const InputDecoration(labelText: 'Tenant ID（common 或组织租户）')),
            TextField(controller: _driveId, enabled: !_busy, decoration: const InputDecoration(labelText: 'Drive ID（可选；留空表示 /me/drive）')),
            const SizedBox(height: 12),
            if (_busy) const LinearProgressIndicator(),
            if (_authorization != null) Text('等待浏览器授权：${_authorization!.userCode}'),
            Wrap(spacing: 8, children: [
              FilledButton(onPressed: _busy ? null : _connect, child: const Text('明确授权并连接 OneDrive')),
              OutlinedButton(onPressed: _busy ? null : _disconnect, child: const Text('移除此设备授权')),
              TextButton(onPressed: _busy ? () => setState(() => _cancel = true) : null, child: const Text('取消等待')),
            ]),
            if (_message.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 12), child: SelectableText(_message)),
          ],
        ),
      );
}
