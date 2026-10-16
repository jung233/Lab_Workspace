import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:lab_core/lab_core.dart';

import 'microsoft_identity.dart';

final class MicrosoftTodoPage extends StatefulWidget {
  const MicrosoftTodoPage({required this.core, required this.secretStore, super.key});

  final LabCore core;
  final SecretStore secretStore;

  @override
  State<MicrosoftTodoPage> createState() => _MicrosoftTodoPageState();
}

final class _MicrosoftTodoPageState extends State<MicrosoftTodoPage> {
  late final SqliteMicrosoftTodoRepository _repository;
  late final MicrosoftIdentitySession _identity;
  late final HttpMicrosoftGraphTodoClient _graph;
  late final MicrosoftTodoSyncService _sync;
  late final MicrosoftTodoImportService _import;
  final _profileId = TextEditingController(text: 'microsoft_todo');
  final _clientId = TextEditingController();
  final _tenantId = TextEditingController(text: 'common');
  final _listId = TextEditingController();
  MicrosoftTodoProfile? _profile;
  List<MicrosoftTodoRemoteList> _lists = const [];
  MicrosoftTodoSyncPreview? _preview;
  MicrosoftTodoSyncResult? _result;
  MicrosoftTodoImportPreview? _importPreview;
  MicrosoftTodoImportResult? _importResult;
  List<MicrosoftTodoImportConflict> _importConflicts = const [];
  MicrosoftDeviceAuthorization? _authorization;
  String _status = '';
  bool _busy = false;
  bool _cancelLogin = false;
  bool _importRemoteTasks = false;

  @override
  void initState() {
    super.initState();
    _repository = SqliteMicrosoftTodoRepository(
      database: widget.core.database,
      currentDeviceId: widget.core.vault.context.deviceId,
    );
    _identity = MicrosoftIdentitySession(secrets: widget.secretStore, repository: _repository);
    _graph = HttpMicrosoftGraphTodoClient(tokenProvider: _identity);
    _sync = MicrosoftTodoSyncService(
      repository: _repository,
      graph: _graph,
      currentDeviceId: widget.core.vault.context.deviceId,
    );
    _import = MicrosoftTodoImportService(
      database: widget.core.database,
      tasks: widget.core.tasks,
      repository: _repository,
      graph: _graph,
      currentDeviceId: widget.core.vault.context.deviceId,
    );
    _reload();
  }

  @override
  void dispose() {
    for (final controller in [_profileId, _clientId, _tenantId, _listId]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _reload() async {
    try {
      final profile = await _sync.profileStatus();
      final preview = profile == null || profile.listId.isEmpty ? null : await _sync.preview();
      final conflicts = await _import.openConflicts();
      if (!mounted) return;
      setState(() {
        _profile = profile;
        _preview = preview;
        _importRemoteTasks = profile?.importRemoteTasks ?? false;
        _importConflicts = conflicts;
        if (profile != null) {
          _profileId.text = profile.profileId;
          _clientId.text = profile.clientId;
          _tenantId.text = profile.tenantId;
          _listId.text = profile.listId;
        }
      });
    } on Object catch (error) {
      if (mounted) setState(() => _status = _safeError(error));
    }
  }

  Future<bool> _saveProfile() async {
    final previous = _profile;
    try {
      final profile = MicrosoftTodoProfile(
        profileId: _profileId.text.trim(),
        clientId: _clientId.text.trim(),
        tenantId: _tenantId.text.trim(),
        listId: _listId.text.trim(),
        secretRef: previous?.secretRef,
        enabled: true,
        importRemoteTasks: _importRemoteTasks,
      );
      if (profile.profileId.isEmpty || profile.clientId.isEmpty) {
        throw const MicrosoftTodoException('TODO_PROFILE_INVALID', '本地 Connector ID 和 Microsoft app ID 都必填。');
      }
      await _repository.saveProfile(profile);
      if (mounted) setState(() => _status = '配置已保存到本地 Vault。Token 只进入设备安全存储。');
      await _reload();
      return true;
    } on Object catch (error) {
      if (mounted) setState(() => _status = _safeError(error));
      return false;
    }
  }

  Future<void> _beginSignIn() async {
    setState(() { _busy = true; _cancelLogin = false; _status = ''; });
    try {
      if (!await _saveProfile()) return;
      final profile = _profile ?? await _repository.profile();
      if (profile == null) throw const MicrosoftTodoException('TODO_PROFILE_INVALID', '请先保存 Microsoft 配置。');
      final authorization = await _identity.beginDeviceAuthorization(clientId: profile.clientId, tenantId: profile.tenantId);
      if (!mounted) return;
      setState(() => _authorization = authorization);
      final proceed = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          title: const Text('Microsoft 设备登录'),
          content: SelectableText('在浏览器打开：${authorization.verificationUri}\n\n输入一次性代码：${authorization.userCode}\n\n请求权限：Tasks.ReadWrite；用于读取和同步你选择的 To Do 列表。'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消登录')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('我已提交代码，继续')),
          ],
        ),
      );
      if (proceed != true) { _cancelLogin = true; return; }
      await _identity.finishDeviceAuthorization(
        authorization: authorization,
        clientId: profile.clientId,
        tenantId: profile.tenantId,
        profile: profile,
        isCancelled: () => _cancelLogin,
      );
      final authenticatedProfile = await _repository.profile();
      final scopeChanged = profile.accountScopeId != authenticatedProfile?.accountScopeId;
      if (mounted) {
        setState(() => _status = scopeChanged
            ? 'Microsoft 登录成功。此为新的本地授权会话；旧会话的 To Do 链接不会跨会话复用。请查看同步预览并明确确认后再重建关联。令牌仅保存在设备安全存储。'
            : 'Microsoft 登录成功；访问和刷新令牌保存在设备安全存储。');
      }
      await _loadLists();
    } on Object catch (error) {
      if (mounted) setState(() => _status = _safeError(error));
    } finally {
      if (mounted) setState(() { _busy = false; _authorization = null; });
      await _reload();
    }
  }

  Future<void> _loadLists() async {
    try {
      final lists = await _graph.listLists();
      if (!mounted) return;
      setState(() {
        _lists = lists;
        if (_lists.any((item) => item.listId == _listId.text)) return;
        if (_lists.length == 1) _listId.text = _lists.single.listId;
      });
      if (lists.isEmpty && mounted) setState(() => _status = '此 Microsoft 账户没有可用的 To Do 列表。');
    } on Object catch (error) {
      if (mounted) setState(() => _status = _safeError(error));
    }
  }

  Future<void> _claimPrimary() async {
    final device = widget.core.vault.context.deviceId;
    final ref = widget.core.approvals.issue(
      action: 'todo.primary_device.takeover',
      subjectType: 'todo_integration',
      subjectId: 'microsoft_todo',
      scope: {'device_id': device},
      expiresAtUtc: DateTime.now().toUtc().add(const Duration(minutes: 5)),
    );
    try {
      await _sync.claimPrimaryDevice(ref);
      if (mounted) setState(() => _status = '此设备已被明确设为唯一同步主设备。');
      await _reload();
    } on Object catch (error) {
      if (mounted) setState(() => _status = _safeError(error));
    }
  }

  Future<void> _signOut() async {
    final profile = _profile;
    if (profile == null) return;
    try {
      await _repository.saveProfile(MicrosoftTodoProfile(
        profileId: profile.profileId,
        clientId: profile.clientId,
        tenantId: profile.tenantId,
        listId: profile.listId,
        secretRef: null,
        enabled: false,
        importRemoteTasks: profile.importRemoteTasks,
      ));
      if (profile.secretRef != null) await widget.secretStore.delete(profile.secretRef!);
      if (mounted) setState(() => _status = '本设备的访问/刷新令牌已从安全存储移除。');
      await _reload();
    } on Object catch (error) {
      if (mounted) setState(() => _status = _safeError(error));
    }
  }

  Future<void> _previewSync() async {
    try {
      if (_profile?.listId.trim().isEmpty ?? true) {
        if (mounted) setState(() => _status = '请先登录，选择 Microsoft To Do 列表并保存配置。');
        return;
      }
      final preview = await _sync.preview();
      if (!mounted) return;
      setState(() => _preview = preview);
      final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('同步预览'),
          content: Text('设备是主设备：${preview.primaryDevice ? '是' : '否'}\n待创建：${preview.pendingCreate}\n待更新：${preview.pendingUpdate}\n冲突：${preview.conflicts.length}\n\n同步会将本地待办标题/状态/到期日发送给 Microsoft Graph。'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('暂不同步')),
            FilledButton(onPressed: preview.primaryDevice ? () => Navigator.pop(context, true) : null, child: const Text('确认同步')),
          ],
        ),
      );
      if (accepted == true) await _executeSync();
    } on Object catch (error) {
      if (mounted) setState(() => _status = _safeError(error));
    }
  }

  Future<void> _executeSync() async {
    setState(() { _busy = true; _status = ''; });
    try {
      final result = await _sync.sync();
      if (mounted) {
        setState(() {
          _result = result;
          _status = '同步结束：创建 ${result.created}，更新 ${result.updated}，待处理 ${result.pending}，冲突 ${result.conflicts.length}。';
        });
      }
      await _reload();
    } on Object catch (error) {
      if (mounted) setState(() => _status = _safeError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _previewRemoteImport() async {
    if (!_importRemoteTasks) {
      setState(() => _status = '先明确启用“导入远端 To Do”并保存配置。');
      return;
    }
    setState(() { _busy = true; _status = ''; });
    try {
      final preview = await _import.previewPull();
      if (!mounted) return;
      setState(() => _importPreview = preview);
      final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('预览远端任务导入'),
          content: Text('将读取选定列表的 Microsoft Graph 增量变更并写入本地 Task 事件。\n\n变更：${preview.changeCount}\n远端删除：${preview.deletionCount}\n分页：${preview.pageCount}\n已有待审冲突：${preview.pendingConflicts}\n\n游标只会在任务事件、链接和冲突快照全部提交后保存。远端删除将软删除本地任务；与本地编辑冲突时保留双方快照并等待你选择。'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('确认导入')),
          ],
        ),
      );
      if (accepted == true) await _executeRemoteImport();
    } on Object catch (error) {
      if (mounted) setState(() => _status = _safeError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _executeRemoteImport() async {
    setState(() { _busy = true; _status = ''; });
    try {
      final result = await _import.pull();
      if (!mounted) return;
      setState(() {
        _importResult = result;
        _status = '远端导入完成：新建 ${result.created}，更新 ${result.updated}，软删除 ${result.deleted}，关联 ${result.linked}，待审冲突 ${result.conflicts}。';
      });
      await _reload();
    } on Object catch (error) {
      if (mounted) setState(() => _status = _safeError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _resolveImportConflict(MicrosoftTodoImportConflict conflict, String decision) async {
    try {
      await _import.resolveConflict(conflictId: conflict.conflictId, decision: decision);
      if (mounted) {
        setState(() => _status = switch (decision) {
          'accept_remote' => '已接受远端版本并记录本地 Task 事件。',
          'keep_local' => '已保留本地版本；可在推送预览后提交到 Microsoft To Do。',
          _ => '已忽略此远端变更并保留审核记录。',
        });
      }
      await _reload();
    } on Object catch (error) {
      if (mounted) setState(() => _status = _safeError(error));
    }
  }

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(20),
    children: [
      Text('Microsoft To Do', style: Theme.of(context).textTheme.headlineSmall),
      const SizedBox(height: 8),
      const Text('通过 OAuth 设备代码授权访问个人 Microsoft To Do。登录后可浏览账户列表并选择目标列表。推送始终需要预览和确认；远端导入默认关闭，启用后可单独预览增量读取并确认。任务通过本地 TaskService 事件保存，不同步 SQLite 数据库。'),
      const Text('本地授权会话范围由 tenant、公开应用 ID、所选列表和不透明 SecretRef 派生；它不是 Microsoft 账户 ID。更换登录或列表后，旧远端链接不会自动复用，需在预览中明确确认重建。'),
      const SizedBox(height: 12),
      TextField(controller: _profileId, decoration: const InputDecoration(labelText: '本地 Connector ID')),
      TextField(controller: _clientId, decoration: const InputDecoration(labelText: 'Microsoft Entra 应用程序（客户端）ID')),
      TextField(controller: _tenantId, decoration: const InputDecoration(labelText: 'Tenant ID 或 common')),
      if (_lists.isEmpty)
        TextField(controller: _listId, decoration: const InputDecoration(labelText: 'Microsoft To Do list ID（登录后可从列表选择）'))
      else
        DropdownButtonFormField<String>(
          initialValue: _lists.any((item) => item.listId == _listId.text) ? _listId.text : null,
          decoration: const InputDecoration(labelText: 'Microsoft To Do 列表'),
          items: [for (final list in _lists) DropdownMenuItem(value: list.listId, child: Text(list.displayName))],
          onChanged: (value) { if (value != null) setState(() => _listId.text = value); },
        ),
      CheckboxListTile(
        contentPadding: EdgeInsets.zero,
        value: _importRemoteTasks,
        onChanged: _busy ? null : (value) => setState(() => _importRemoteTasks = value ?? false),
        title: const Text('启用远端 To Do 导入（默认关闭）'),
        subtitle: const Text('读取所选列表的 Graph delta。新增/变更写入本地 Task 事件，远端删除仅软删除；本地有新修改时保留两侧快照并要求审核。导入记录不会因本地 revision 增长而自动回推。'),
      ),
      const SizedBox(height: 12),
      Wrap(spacing: 8, runSpacing: 8, children: [
        OutlinedButton.icon(onPressed: _busy ? null : () async { await _saveProfile(); }, icon: const Icon(Icons.save_outlined), label: const Text('保存配置')),
        OutlinedButton.icon(onPressed: _busy || _profile?.secretRef == null ? null : _loadLists, icon: const Icon(Icons.refresh), label: const Text('刷新 To Do 列表')),
        FilledButton.icon(onPressed: _busy ? null : _beginSignIn, icon: const Icon(Icons.login), label: Text(_profile?.secretRef == null ? 'Microsoft 登录' : '重新登录 / 刷新授权')),
        OutlinedButton.icon(onPressed: _busy ? null : _claimPrimary, icon: const Icon(Icons.phonelink_lock), label: const Text('批准此设备为主设备')),
        FilledButton.tonalIcon(onPressed: _busy ? null : _previewSync, icon: const Icon(Icons.sync), label: const Text('预览并同步')),
        OutlinedButton.icon(onPressed: _busy || !_importRemoteTasks || _profile?.secretRef == null ? null : _previewRemoteImport, icon: const Icon(Icons.download_for_offline_outlined), label: const Text('预览并导入远端任务')),
        TextButton.icon(onPressed: _busy || _profile?.secretRef == null ? null : _signOut, icon: const Icon(Icons.logout), label: const Text('移除此设备的令牌')),
      ]),
      if (_busy) const Padding(padding: EdgeInsets.symmetric(vertical: 12), child: LinearProgressIndicator()),
      if (_authorization != null) SelectableText('等待授权：${_authorization!.userCode} · ${_authorization!.verificationUri}'),
      if (_preview != null) Card(child: ListTile(
        leading: Icon(_preview!.primaryDevice ? Icons.verified_user : Icons.phonelink_lock),
        title: Text(_preview!.primaryDevice ? '当前设备是唯一同步主设备' : '当前设备尚未成为主设备'),
        subtitle: Text('待创建 ${_preview!.pendingCreate} · 待更新 ${_preview!.pendingUpdate} · 冲突 ${_preview!.conflicts.length}'),
      )),
      if (_importPreview != null) Card(child: ListTile(
        leading: const Icon(Icons.download_done_outlined),
        title: const Text('最近一次远端导入预览'),
        subtitle: Text('变更 ${_importPreview!.changeCount} · 远端删除 ${_importPreview!.deletionCount} · 分页 ${_importPreview!.pageCount}'),
      )),
      if (_importResult != null) Card(child: ListTile(
        leading: const Icon(Icons.cloud_download_outlined),
        title: const Text('最近一次远端导入'),
        subtitle: Text('新建 ${_importResult!.created} · 更新 ${_importResult!.updated} · 软删除 ${_importResult!.deleted} · 冲突 ${_importResult!.conflicts}'),
      )),
      if (_importConflicts.isNotEmpty) ...[
        const SizedBox(height: 8),
        Text('待审远端冲突 (${_importConflicts.length})', style: Theme.of(context).textTheme.titleMedium),
        for (final conflict in _importConflicts)
          Builder(builder: (context) {
            final oldSession = conflict.accountScopeId != _profile?.accountScopeId;
            return Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('远端任务 ${conflict.remoteTaskId}', style: Theme.of(context).textTheme.titleSmall),
                if (oldSession) const Text('此冲突来自旧本地授权会话；为防止跨账户写入，只能忽略并归档。'),
                Text('本地：${jsonEncode(conflict.localSnapshot)}'),
                Text('远端：${jsonEncode(conflict.remoteSnapshot)}'),
                Wrap(spacing: 8, children: [
                  if (!oldSession) TextButton(onPressed: _busy ? null : () => _resolveImportConflict(conflict, 'keep_local'), child: const Text('保留本地')),
                  if (!oldSession) FilledButton.tonal(onPressed: _busy ? null : () => _resolveImportConflict(conflict, 'accept_remote'), child: const Text('接受远端')),
                  TextButton(onPressed: _busy ? null : () => _resolveImportConflict(conflict, 'ignore_remote'), child: const Text('忽略远端变更')),
                ]),
                ]),
              ),
            );
          }),
      ],
      if (_result != null && _result!.conflicts.isNotEmpty) Card(
        child: ListTile(leading: const Icon(Icons.warning_amber), title: const Text('同步冲突'), subtitle: Text(_result!.conflicts.join('\n'))),
      ),
      if (_status.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 12), child: SelectableText(_status)),
      const SizedBox(height: 12),
      const Text('OAuth 注意事项：需要在 Entra 管理中心注册允许 public client/device-code flow 的应用，并授予 Tasks.ReadWrite delegated permission。客户端不会保存 client secret。'),
    ],
  );

  static String _safeError(Object error) {
    if (error is MicrosoftTodoException) return '${error.code}: ${error.message}';
    return '操作未完成。错误详情和任何远端响应均未保存在同步日志中。';
  }
}
