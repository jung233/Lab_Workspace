import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:lab_core/lab_core.dart';

import '../platform/secure_secret_store.dart';
import '../src/ai_image/python_json_rpc_process.dart';

class ProviderSettingsPage extends StatefulWidget {
  const ProviderSettingsPage({required this.core, super.key});

  final LabCore core;

  @override
  State<ProviderSettingsPage> createState() => _ProviderSettingsPageState();
}

class _ProviderSettingsPageState extends State<ProviderSettingsPage> {
  final _secretStore = FlutterSecretStore();
  List<AiProviderProfile> _profiles = const [];
  bool _loading = true;
  Object? _error;
  late final TextEditingController _pythonExecutable;
  late final TextEditingController _aiSdkScript;
  late final TextEditingController _calculationScript;
  String _workerStatus = '';

  @override
  void initState() {
    super.initState();
    final configured = _readWorkerConfig();
    _pythonExecutable = TextEditingController(text: configured['python_executable'] ?? Platform.environment['LAB_WORKSPACE_PYTHON'] ?? '');
    _aiSdkScript = TextEditingController(text: configured['ai_sdk_script'] ?? Platform.environment['LAB_WORKSPACE_AI_SDK_BRIDGE'] ?? '');
    _calculationScript = TextEditingController(text: configured['calculation_rpc_script'] ?? Platform.environment['LAB_WORKSPACE_CALCULATION_RPC'] ?? '');
    _reload();
  }

  @override
  void dispose() {
    _pythonExecutable.dispose();
    _aiSdkScript.dispose();
    _calculationScript.dispose();
    super.dispose();
  }

  Map<String, String> _readWorkerConfig() {
    final rows = widget.core.database.query('SELECT value_json FROM workspace_settings WHERE setting_key=?', ['trusted_python_workers']);
    if (rows.isEmpty || rows.single['value_json'] is! String) return const {};
    try {
      final decoded = jsonDecode(rows.single['value_json'] as String);
      if (decoded is! Map) return const {};
      return decoded.map((key, value) => MapEntry(key.toString(), value is String ? value : '')).cast<String, String>();
    } on Object {
      return const {};
    }
  }

  Future<void> _saveWorkerConfig() async {
    if (!Platform.isWindows) {
      setState(() => _workerStatus = 'Windows Python/Conda 进程配置仅在 Windows 生效；移动端必须使用签名随包交付的可信运行时。');
      return;
    }
    final python = _pythonExecutable.text.trim();
    final aiScript = _aiSdkScript.text.trim();
    final calculation = _calculationScript.text.trim();
    final pythonName = File(python).uri.pathSegments.last.toLowerCase();
    if (python.isEmpty || aiScript.isEmpty || !{'python.exe', 'python3.exe'}.contains(pythonName) ||
        File(aiScript).uri.pathSegments.last != 'ai_provider_sdk_bridge.py' ||
        (calculation.isNotEmpty && File(calculation).uri.pathSegments.last != 'calculation_rpc.py')) {
      setState(() => _workerStatus = '请填写 Python executable、ai_provider_sdk_bridge.py；Calculation RPC 只能填 calculation_rpc.py。');
      return;
    }
    if (!await File(python).exists() || !await File(aiScript).exists() ||
        (calculation.isNotEmpty && !await File(calculation).exists())) {
      setState(() => _workerStatus = '配置文件路径不存在。请使用绝对路径并确认文件受信任。');
      return;
    }
    final value = jsonEncode({
      'python_executable': python,
      'ai_sdk_script': aiScript,
      'calculation_rpc_script': calculation,
    });
    widget.core.database.execute(
      '''INSERT INTO workspace_settings(setting_key,value_json,revision,updated_at_utc)
         VALUES(?,?,1,?) ON CONFLICT(setting_key) DO UPDATE SET value_json=excluded.value_json,
         revision=workspace_settings.revision+1,updated_at_utc=excluded.updated_at_utc''',
      ['trusted_python_workers', value, DateTime.now().toUtc().toIso8601String()],
    );
    if (mounted) setState(() => _workerStatus = '本地 runner 配置已保存；路径不是凭据，不会同步或备份。');
  }

  Future<void> _probePythonWorker() async {
    if (!Platform.isWindows) {
      setState(() => _workerStatus = '此平台不支持任意 Python 进程；移动端 trusted runtime 由原生签名构建提供。');
      return;
    }
    try {
      final result = await PythonJsonRpcProcess(
        pythonExecutable: _pythonExecutable.text.trim(),
        scriptPath: _aiSdkScript.text.trim(),
      ).call('ai.self_test', const {}, timeoutSeconds: 15);
      if (mounted) {
        setState(() => _workerStatus = result['ok'] == true
            ? '本地 OpenAI SDK worker 可用（${result['version']}）。此检查不发起网络请求。'
            : 'Python worker 启动成功，但未安装 openai SDK（${result['code'] ?? 'unknown'}）。');
      }
    } on Object catch (error) {
      if (mounted) setState(() => _workerStatus = error is AiProviderException ? '${error.code}: ${error.message}' : '本地 worker 不可用；请核对 Python 与脚本路径。');
    }
  }

  SqliteAiProviderProfileRepository get _profilesStore =>
      SqliteAiProviderProfileRepository(widget.core.database);

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final profiles = await _profilesStore.list();
      if (mounted) setState(() => _profiles = profiles);
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _editProfile([AiProviderProfile? current]) async {
    final id = TextEditingController(text: current?.providerId ?? 'default');
    final name = TextEditingController(text: current?.name ?? 'OpenAI');
    final baseUrl = TextEditingController(
      text: current?.baseUrl.toString() ?? 'https://api.openai.com/v1',
    );
    final model = TextEditingController(text: current?.modelId ?? '');
    final secret = TextEditingController();
    var apiMode = current?.apiMode ?? AiApiMode.responses;
    var clearSecret = false;
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, dialogSetState) => AlertDialog(
          title: Text(current == null ? '添加 AI Provider' : '编辑 AI Provider'),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: id,
                    enabled: current == null,
                    decoration: const InputDecoration(labelText: 'Provider ID'),
                  ),
                  TextField(
                    controller: name,
                    decoration: const InputDecoration(labelText: '显示名称'),
                  ),
                  TextField(
                    controller: baseUrl,
                    keyboardType: TextInputType.url,
                    decoration: const InputDecoration(
                      labelText: 'HTTPS API base URL',
                    ),
                  ),
                  TextField(
                    controller: model,
                    decoration: const InputDecoration(labelText: '模型 ID'),
                  ),
                  const SizedBox(height: 8),
                  SegmentedButton<AiApiMode>(
                    segments: const [
                      ButtonSegment(
                        value: AiApiMode.responses,
                        label: Text('Responses'),
                      ),
                      ButtonSegment(
                        value: AiApiMode.chatCompletions,
                        label: Text('Chat Completions'),
                      ),
                    ],
                    selected: {apiMode},
                    onSelectionChanged: (selection) =>
                        dialogSetState(() => apiMode = selection.single),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: secret,
                    obscureText: true,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: InputDecoration(
                      labelText: current?.secretRef == null
                          ? 'API key'
                          : '替换 API key（留空保留当前值）',
                      helperText:
                          '凭据只进入设备 Keychain/Keystore/安全存储，不进入 SQLite 或备份。',
                    ),
                  ),
                  if (current?.secretRef != null)
                    CheckboxListTile(
                      value: clearSecret,
                      onChanged: (value) =>
                          dialogSetState(() => clearSecret = value ?? false),
                      title: const Text('移除已保存的凭据'),
                      contentPadding: EdgeInsets.zero,
                    ),
                  const SizedBox(height: 8),
                  const Text(
                    '保存后能力仍标记为“未验证”。每次探测或模型请求都要单独审阅并同意上传范围。'
                    '配置了受信任的 Windows Python SDK bridge 时优先使用 OpenAI SDK；其他原生平台使用 HTTPS wire adapter。',
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
              child: const Text('保存配置'),
            ),
          ],
        ),
      ),
    );
    if (saved != true) {
      for (final controller in [id, name, baseUrl, model, secret]) {
        controller.dispose();
      }
      return;
    }
    SecretRef? secretRef = current?.secretRef;
    SecretRef? newlyWrittenSecret;
    var profileSaved = false;
    try {
      final endpoint = Uri.tryParse(baseUrl.text.trim());
      if (endpoint == null ||
          !endpoint.isAbsolute ||
          endpoint.host.isEmpty ||
          (endpoint.scheme != 'https' &&
              endpoint.host != 'localhost' &&
              endpoint.host != '127.0.0.1')) {
        throw const FormatException(
          '远程 Provider 必须使用 HTTPS；本地调试仅允许 localhost。',
        );
      }
      if (id.text.trim().isEmpty ||
          name.text.trim().isEmpty ||
          model.text.trim().isEmpty) {
        throw const FormatException('Provider ID、名称和模型 ID 都必填。');
      }
      if (secret.text.isNotEmpty) {
        final secretBytes = Uint8List.fromList(utf8.encode(secret.text));
        try {
          newlyWrittenSecret = await _secretStore.write(secretBytes);
          secretRef = newlyWrittenSecret;
        } finally {
          secretBytes.fillRange(0, secretBytes.length, 0);
        }
      } else if (clearSecret) {
        secretRef = null;
      }
      await _profilesStore.save(
        AiProviderProfile(
          providerId: id.text.trim(),
          name: name.text.trim(),
          baseUrl: endpoint,
          modelId: model.text.trim(),
          apiMode: apiMode,
          secretRef: secretRef,
          capabilities: current?.capabilities ?? const AiCapabilities(),
          timeoutSeconds: current?.timeoutSeconds ?? 60,
          maxToolRounds: current?.maxToolRounds ?? 8,
          maxOutputTokens: current?.maxOutputTokens ?? 4096,
          dataPolicy:
              current?.dataPolicy ??
              const <String, Object?>{'uploads_enabled': false},
        ),
      );
      profileSaved = true;
      if (clearSecret && current?.secretRef != null) {
        await _secretStore.delete(current!.secretRef!);
      }
      if (mounted) await _reload();
    } on Object catch (error) {
      if (!profileSaved && newlyWrittenSecret != null) {
        await _secretStore.delete(newlyWrittenSecret);
      }
      if (mounted) setState(() => _error = error);
    } finally {
      secret.clear();
      for (final controller in [id, name, baseUrl, model, secret]) {
        controller.dispose();
      }
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Row(
          children: [
            Expanded(
              child: Text(
                'AI Provider',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
            ),
            IconButton(
              onPressed: _loading ? null : _reload,
              tooltip: '刷新',
              icon: const Icon(Icons.refresh),
            ),
            FilledButton.icon(
              onPressed: () => _editProfile(),
              icon: const Icon(Icons.add),
              label: const Text('添加 Provider'),
            ),
          ],
        ),
      ),
      const MaterialBanner(
        leading: Icon(Icons.lock_outline),
        content: Text(
          'Provider 配置保存在本地。Responses/Chat 请求可经 HTTPS wire adapter 发送；Windows 也可配置官方 OpenAI Python SDK bridge。每次模型上传和能力探测仍需单独 consent。',
        ),
        actions: [SizedBox.shrink()],
      ),
      Card(
        margin: const EdgeInsets.all(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Windows trusted Python / Conda', style: Theme.of(context).textTheme.titleMedium),
            const Text('填写并保存绝对路径；SDK worker 用 ai.self_test 本地探测，不发网络请求。图片/科学计算 RPC 使用独立脚本。实际 provider 探测在 Lab Workspace AI 页面完成并会要求上传 consent。'),
            TextField(controller: _pythonExecutable, decoration: const InputDecoration(labelText: 'python.exe / Conda python.exe 绝对路径')),
            TextField(controller: _aiSdkScript, decoration: const InputDecoration(labelText: 'ai_provider_sdk_bridge.py 绝对路径')),
            TextField(controller: _calculationScript, decoration: const InputDecoration(labelText: 'calculation_rpc.py 绝对路径（可选）')),
            Wrap(spacing: 8, children: [
              FilledButton.tonal(onPressed: _saveWorkerConfig, child: const Text('保存 Runner 配置')),
              OutlinedButton(onPressed: _probePythonWorker, child: const Text('本地探测 OpenAI SDK')),
            ]),
            if (_workerStatus.isNotEmpty) SelectableText(_workerStatus),
            if (!Platform.isWindows) const Text('当前为非 Windows 平台。任意 Python 运行时配置已禁用；Android/iOS 需使用随应用签名交付的受信运行时。'),
          ]),
        ),
      ),
      if (_loading) const LinearProgressIndicator(),
      if (_error != null)
        MaterialBanner(
          content: Text('Provider 配置失败：$_error'),
          actions: [TextButton(onPressed: _reload, child: const Text('重试'))],
        ),
      Expanded(
        child: _profiles.isEmpty
            ? const Center(child: Text('尚未配置 Provider。'))
            : ListView.builder(
                itemCount: _profiles.length,
                itemBuilder: (context, index) {
                  final profile = _profiles[index];
                  return ListTile(
                    leading: const Icon(Icons.cloud_outlined),
                    title: Text(profile.name),
                    subtitle: Text(
                      '${profile.modelId} · ${profile.apiMode.name} · 能力未验证 · ${profile.secretRef == null ? '未保存凭据' : '凭据已安全保存'}',
                    ),
                    trailing: IconButton(
                      icon: const Icon(Icons.edit_outlined),
                      tooltip: '编辑',
                      onPressed: () => _editProfile(profile),
                    ),
                  );
                },
              ),
      ),
    ],
  );
}
