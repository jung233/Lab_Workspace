import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:lab_core/lab_core.dart';

/// Opens one independent Protocol generation/review dialog.
///
/// The dialog returns a local, unapproved draft. The caller remains responsible
/// for saving it through ProtocolService and for the separate approval action.
Future<AiProtocolDraft?> showAiProtocolDraftDialog({
  required BuildContext context,
  required AiProtocolDraftService service,
  required ApprovalService approvals,
  required List<AiProviderProfile> providers,
  List<ProtocolVersionRecord> referenceVersions = const [],
  String? initialObjective,
  Future<void> Function()? onOpenProviderSettings,
}) => showDialog<AiProtocolDraft>(
  context: context,
  barrierDismissible: false,
  builder: (_) => AiProtocolDraftDialog(
    service: service,
    approvals: approvals,
    providers: providers,
    referenceVersions: referenceVersions,
    initialObjective: initialObjective,
    onOpenProviderSettings: onOpenProviderSettings,
  ),
);

final class AiProtocolDraftDialog extends StatefulWidget {
  const AiProtocolDraftDialog({
    required this.service,
    required this.approvals,
    required this.providers,
    this.referenceVersions = const [],
    this.initialObjective,
    this.onOpenProviderSettings,
    super.key,
  });

  final AiProtocolDraftService service;
  final ApprovalService approvals;
  final List<AiProviderProfile> providers;
  final List<ProtocolVersionRecord> referenceVersions;
  final String? initialObjective;
  final Future<void> Function()? onOpenProviderSettings;

  @override
  State<AiProtocolDraftDialog> createState() => _AiProtocolDraftDialogState();
}

final class _AiProtocolDraftDialogState extends State<AiProtocolDraftDialog> {
  late final TextEditingController _objective;
  late final TextEditingController _constraints;
  late final TextEditingController _draftJson;
  String? _providerId;
  String? _referenceKey;
  AiProtocolGenerationRequest? _preparedRequest;
  AiProtocolDraft? _draft;
  String? _localError;
  String? _validatedText;
  bool _uploadConsent = false;
  bool _preparing = false;
  bool _generating = false;
  bool _validating = false;

  bool get _busy => _preparing || _generating || _validating;

  @override
  void initState() {
    super.initState();
    _objective = TextEditingController(text: widget.initialObjective ?? '');
    _constraints = TextEditingController();
    _draftJson = TextEditingController();
    _providerId = widget.providers.firstOrNull?.providerId;
    final approvedReferences = widget.referenceVersions.where(
      (version) => version.isApproved,
    );
    _referenceKey = approvedReferences.firstOrNull == null
        ? null
        : _keyFor(approvedReferences.first);
  }

  @override
  void dispose() {
    _objective.dispose();
    _constraints.dispose();
    _draftJson.dispose();
    super.dispose();
  }

  AiProviderProfile? get _selectedProvider {
    final id = _providerId;
    if (id == null) return null;
    for (final provider in widget.providers) {
      if (provider.providerId == id) return provider;
    }
    return null;
  }

  ProtocolVersionRecord? get _selectedReference {
    final key = _referenceKey;
    if (key == null) return null;
    for (final reference in widget.referenceVersions) {
      if (reference.isApproved && _keyFor(reference) == key) return reference;
    }
    return null;
  }

  static String _keyFor(ProtocolVersionRecord version) =>
      '${version.protocolId}@${version.version}';

  void _invalidatePreparedRequest() {
    if (_busy) return;
    setState(() {
      _preparedRequest = null;
      _uploadConsent = false;
      _localError = null;
    });
  }

  Future<void> _prepareRequest() async {
    if (_providersUnavailable()) return;
    final provider = _selectedProvider;
    if (provider == null) return;
    if (provider.secretRef == null) {
      setState(() => _localError = '此 Provider 尚未保存安全凭据，请先在设置中配置 API key。');
      return;
    }
    final capability = provider.apiMode == AiApiMode.responses
        ? provider.capabilities.responses
        : provider.capabilities.chatCompletions;
    if (capability != CapabilityState.supported) {
      setState(
        () => _localError =
            '当前 ${provider.apiMode.name} 模式尚未通过能力探测。请先在 AI 页面使用合成数据完成探测，再重试。',
      );
      return;
    }
    setState(() {
      _preparing = true;
      _localError = null;
      _preparedRequest = null;
      _uploadConsent = false;
    });
    try {
      final request = await widget.service.prepareGeneration(
        objective: _objective.text,
        constraints: _constraints.text,
        referenceProtocol: _selectedReference,
      );
      if (!mounted) return;
      setState(() {
        _preparedRequest = request;
        _uploadConsent = false;
      });
    } on AiProtocolDraftException catch (error) {
      if (mounted) {
        setState(() => _localError = '${error.code}：${error.message}');
      }
    } on Object {
      if (mounted) setState(() => _localError = '无法准备请求。请检查本地 Pack 库后重试。');
    } finally {
      if (mounted) setState(() => _preparing = false);
    }
  }

  bool _providersUnavailable() {
    if (widget.providers.isEmpty) {
      setState(
        () => _localError = '尚未配置 AI Provider。请先添加 Provider、模型 ID 和安全存储凭据。',
      );
      return true;
    }
    return false;
  }

  Future<void> _generate() async {
    final provider = _selectedProvider;
    final request = _preparedRequest;
    if (provider == null || request == null) {
      setState(() => _localError = '请先选择 Provider 并准备本次请求。');
      return;
    }
    if (!_uploadConsent) {
      setState(() => _localError = '需要明确同意本次文本外发后才能生成。');
      return;
    }
    final now = DateTime.now().toUtc();
    final expiresAt = now.add(const Duration(minutes: 10));
    final byteCap = request.requestBytes + 512;
    const scopes = {'protocol_generation'};
    final approvalScope = <String, Object?>{
      'provider_id': provider.providerId,
      'provider_base_url': provider.baseUrl.toString(),
      'model_id': provider.modelId,
      'api_mode': provider.apiMode.name,
      'max_output_tokens': provider.maxOutputTokens,
      'purpose': 'protocol_generation',
      'data_class': 'text',
      'asset_ids': const <String>[],
      'total_bytes': byteCap,
      'approved_scopes': scopes.toList()..sort(),
      'expires_at_utc': expiresAt.toIso8601String(),
    };
    setState(() {
      _generating = true;
      _localError = null;
    });
    try {
      final approvalRef = widget.approvals.issue(
        action: 'ai.upload_consent',
        subjectType: 'ai_provider',
        subjectId: provider.providerId,
        scope: approvalScope,
        expiresAtUtc: expiresAt,
      );
      final receipt = ConsentReceipt(
        id: newUuidV7(),
        providerId: provider.providerId,
        purpose: 'protocol_generation',
        dataClass: 'text',
        assetIds: const <String>{},
        totalBytes: byteCap,
        approvedScopes: scopes,
        approvedAt: now,
        expiresAt: expiresAt,
        approvalRef: approvalRef,
      );
      await widget.service.ai.recordConsent(receipt);
      final generated = await widget.service.generateDraft(
        providerProfile: provider,
        request: request,
        consent: receipt,
      );
      if (!mounted) return;
      final text = const JsonEncoder.withIndent(
        '  ',
      ).convert(generated.toEditableJson());
      setState(() {
        _draft = generated;
        _draftJson.value = TextEditingValue(
          text: text,
          selection: TextSelection.collapsed(offset: text.length),
        );
        _validatedText = text;
        _uploadConsent = false;
      });
    } on AiProviderException catch (error) {
      if (mounted) {
        setState(() {
          _localError = '${error.code}：${error.message}';
          _uploadConsent = false;
        });
      }
    } on AiProtocolDraftException catch (error) {
      if (mounted) {
        setState(() {
          _localError = '${error.code}：${error.message}';
          _uploadConsent = false;
        });
      }
    } on Object {
      if (mounted) {
        setState(() {
          _localError = '生成失败，未创建或保存草稿。请检查网络与 Provider 配置后重新同意并重试。';
          _uploadConsent = false;
        });
      }
    } finally {
      if (mounted) setState(() => _generating = false);
    }
  }

  Future<void> _validateEdits() async {
    final prior = _draft;
    if (prior == null) return;
    setState(() {
      _validating = true;
      _localError = null;
    });
    try {
      final updated = await widget.service.validateEditedJson(
        rawJson: _draftJson.text,
        priorDraft: prior,
      );
      if (!mounted) return;
      final text = _draftJson.text;
      setState(() {
        _draft = updated;
        _validatedText = text;
      });
    } on AiProtocolDraftException catch (error) {
      if (mounted) {
        setState(() => _localError = '${error.code}：${error.message}');
      }
    } on Object {
      if (mounted) {
        setState(() => _localError = '无法校验手工编辑内容。请检查 JSON 和 Pack 库后重试。');
      }
    } finally {
      if (mounted) setState(() => _validating = false);
    }
  }

  void _cancel() {
    Navigator.of(context).pop();
  }

  void _openProviderSettings() {
    Navigator.of(context).pop();
    final callback = widget.onOpenProviderSettings;
    if (callback == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(callback());
    });
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final provider = _selectedProvider;
    final reference = _selectedReference;
    final prepared = _preparedRequest;
    final draft = _draft;
    final dirty = _draftJson.text != _validatedText;
    return Dialog(
      insetPadding: const EdgeInsets.all(20),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 1120,
          maxHeight: size.height * 0.92,
        ),
        child: SizedBox(
          width: size.width,
          child: Column(
            children: [
              _header(context),
              const Divider(height: 1),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _providerPicker(context, provider),
                      const SizedBox(height: 14),
                      TextField(
                        controller: _objective,
                        enabled: !_busy,
                        minLines: 2,
                        maxLines: 5,
                        onChanged: (_) => _invalidatePreparedRequest(),
                        decoration: const InputDecoration(
                          labelText: '实验目的',
                          hintText: '描述实验问题、主要终点和预期流程。',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _constraints,
                        enabled: !_busy,
                        minLines: 2,
                        maxLines: 5,
                        onChanged: (_) => _invalidatePreparedRequest(),
                        decoration: const InputDecoration(
                          labelText: '约束与已知条件（可选）',
                          hintText: '例如设备、样本、试剂、已有参数；未知条件会保留为待补充项。',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 12),
                      _referencePicker(reference),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              widget.service.calculationBinder == null
                                  ? '当前未连接 Calculation Pack 校验器；生成器会拒绝 calculate 步骤。'
                                  : '仅允许引用本机已批准安装的 Calculation Pack，并在本地校验绑定。',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ),
                          const SizedBox(width: 12),
                          FilledButton.tonalIcon(
                            onPressed: _busy || provider == null
                                ? null
                                : _prepareRequest,
                            icon: _preparing
                                ? const SizedBox.square(
                                    dimension: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.fact_check_outlined),
                            label: Text(_preparing ? '准备中…' : '准备本次请求'),
                          ),
                        ],
                      ),
                      if (widget.providers.isEmpty)
                        _providerEmptyState(context),
                      if (_localError != null) ...[
                        const SizedBox(height: 12),
                        _messageBanner(context, _localError!, isError: true),
                      ],
                      if (prepared != null && provider != null) ...[
                        const SizedBox(height: 16),
                        _consentPanel(context, provider, prepared, reference),
                      ],
                      if (_generating) ...[
                        const SizedBox(height: 12),
                        const LinearProgressIndicator(),
                        const SizedBox(height: 6),
                        Text(
                          '请求已发出。取消会丢弃本地结果；供应商可能仍在处理已发送的文本。',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                      if (draft != null) ...[
                        const SizedBox(height: 22),
                        _draftReview(context, draft, dirty),
                      ],
                    ],
                  ),
                ),
              ),
              const Divider(height: 1),
              _actions(context, draft, dirty),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 16, 12, 16),
    child: Row(
      children: [
        const Icon(Icons.auto_awesome_outlined),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'AI 起草 Protocol',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 4),
              Text(
                '输出仅为本机可编辑草稿；人工审阅和批准由 Protocol 库单独完成。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
        IconButton(
          tooltip: _generating ? '取消并丢弃草稿' : '关闭',
          onPressed: _cancel,
          icon: const Icon(Icons.close),
        ),
      ],
    ),
  );

  Widget _providerPicker(BuildContext context, AiProviderProfile? provider) =>
      Row(
        children: [
          Expanded(
            child: DropdownButtonFormField<String>(
              initialValue: _providerId,
              decoration: const InputDecoration(
                labelText: 'AI Provider',
                border: OutlineInputBorder(),
              ),
              items: [
                for (final profile in widget.providers)
                  DropdownMenuItem(
                    value: profile.providerId,
                    child: Text('${profile.name} · ${profile.modelId}'),
                  ),
              ],
              onChanged: _busy
                  ? null
                  : (value) {
                      setState(() {
                        _providerId = value;
                        _preparedRequest = null;
                        _uploadConsent = false;
                        _localError = null;
                      });
                    },
            ),
          ),
          const SizedBox(width: 12),
          if (provider != null)
            Chip(
              avatar: Icon(
                provider.apiMode == AiApiMode.responses
                    ? Icons.api_outlined
                    : Icons.chat_bubble_outline,
                size: 16,
              ),
              label: Text(provider.apiMode.name),
            ),
        ],
      );

  Widget _referencePicker(ProtocolVersionRecord? selected) =>
      DropdownButtonFormField<String?>(
        initialValue: _referenceKey,
        decoration: const InputDecoration(
          labelText: '已有批准 Protocol 参考（可选）',
          helperText: '选择后会把该版本的完整 Protocol JSON 随本次请求发送给 Provider。',
          border: OutlineInputBorder(),
        ),
        items: [
          const DropdownMenuItem<String?>(value: null, child: Text('不使用参考')),
          for (final version in widget.referenceVersions.where(
            (value) => value.isApproved,
          ))
            DropdownMenuItem<String?>(
              value: _keyFor(version),
              child: Text(
                '${version.title} · ${version.protocolId}@${version.version}',
              ),
            ),
        ],
        onChanged: _busy
            ? null
            : (value) {
                setState(() {
                  _referenceKey = value;
                  _preparedRequest = null;
                  _uploadConsent = false;
                  _localError = null;
                });
              },
      );

  Widget _providerEmptyState(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 12),
    child: Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            const Icon(Icons.cloud_off_outlined),
            const SizedBox(width: 12),
            const Expanded(
              child: Text(
                '没有可用 Provider。添加 HTTPS Provider、模型 ID 和安全存储凭据后，返回此对话框。',
              ),
            ),
            if (widget.onOpenProviderSettings != null)
              TextButton.icon(
                onPressed: _busy ? null : _openProviderSettings,
                icon: const Icon(Icons.settings_outlined),
                label: const Text('Provider 设置'),
              ),
          ],
        ),
      ),
    ),
  );

  Widget _consentPanel(
    BuildContext context,
    AiProviderProfile provider,
    AiProtocolGenerationRequest request,
    ProtocolVersionRecord? reference,
  ) {
    final byteCap = request.requestBytes + 512;
    return Card(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('本次云请求与上传同意', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            SelectableText(
              'Provider：${provider.name} (${provider.providerId})\n'
              '服务地址：${provider.baseUrl}\n'
              '模型：${provider.modelId}\n'
              'API：${provider.apiMode.name}\n'
              '用途：生成未批准的 Protocol 草稿\n'
              '发送内容：Protocol 生成 system instructions、实验目的、约束${reference == null ? '' : '、已选参考 ${reference.protocolId}@${reference.version} 的完整 Protocol JSON'}\n'
              '数据类别：文本\n'
              '请求大小上限：$byteCap 字节\n'
              '输出 token 上限：${provider.maxOutputTokens}\n'
              '预算：请求内容最多 64 KiB；输出受上述 token 上限约束。实际费用由 Provider 计价，本应用不估价。\n'
              'Calculation Pack 引用：${request.installedPackRefs.isEmpty ? '无' : request.installedPackRefs.join(', ')}\n'
              '敏感信息：请勿在目的或约束中输入未授权的患者身份信息、密钥或其他敏感数据。',
            ),
            CheckboxListTile(
              value: _uploadConsent,
              onChanged: _busy
                  ? null
                  : (value) => setState(() {
                      _uploadConsent = value ?? false;
                      _localError = null;
                    }),
              contentPadding: EdgeInsets.zero,
              title: const Text('我明确同意本次将上列文本发送给此 Provider。'),
              subtitle: const Text('该同意只适用于这一条请求；修改输入、切换 Provider 或重试后需要重新同意。'),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                onPressed: _busy || !_uploadConsent ? null : _generate,
                icon: _generating
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.auto_awesome),
                label: Text(_generating ? '正在生成…' : '明确同意并生成'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _draftReview(BuildContext context, AiProtocolDraft draft, bool dirty) {
    final colorScheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '草稿预览与编辑',
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            if (dirty)
              FilledButton.tonalIcon(
                onPressed: _busy ? null : _validateEdits,
                icon: _validating
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.rule_outlined),
                label: Text(_validating ? '校验中…' : '校验手工编辑'),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            Chip(label: Text('${draft.title} · ${draft.version}')),
            Chip(
              avatar: Icon(
                draft.isValid
                    ? Icons.check_circle_outline
                    : Icons.error_outline,
                size: 16,
              ),
              label: Text(draft.isValid ? '可保存为未审核草稿' : '存在阻断错误'),
            ),
            if (draft.document['steps'] is List)
              Chip(
                label: Text('${(draft.document['steps'] as List).length} 个步骤'),
              ),
          ],
        ),
        if (dirty)
          _messageBanner(context, 'JSON 已修改，请先运行本地校验。', isError: false),
        if (draft.errors.isNotEmpty) ...[
          const SizedBox(height: 8),
          _issuePanel(
            context,
            '需要修正',
            draft.errors,
            colorScheme.errorContainer,
          ),
        ],
        if (draft.unsupportedOperations.isNotEmpty) ...[
          const SizedBox(height: 8),
          _issuePanel(
            context,
            '不支持的操作（必须移除或替换）',
            draft.unsupportedOperations,
            colorScheme.errorContainer,
          ),
        ],
        if (draft.requiresUserInput.isNotEmpty) ...[
          const SizedBox(height: 8),
          _issuePanel(
            context,
            '待补充的用户输入',
            draft.requiresUserInput,
            colorScheme.tertiaryContainer,
          ),
        ],
        if (draft.warnings.isNotEmpty) ...[
          const SizedBox(height: 8),
          _issuePanel(
            context,
            '提示',
            draft.warnings,
            colorScheme.surfaceContainerHighest,
          ),
        ],
        const SizedBox(height: 10),
        TextField(
          controller: _draftJson,
          enabled: !_busy,
          minLines: 14,
          maxLines: 28,
          keyboardType: TextInputType.multiline,
          autocorrect: false,
          enableSuggestions: false,
          onChanged: (_) => setState(() {}),
          decoration: const InputDecoration(
            labelText: 'Protocol JSON envelope（可编辑）',
            helperText:
                '修正 document、unsupported_operations 或 requires_user_input 后，先校验再返回 Protocol 库。',
            border: OutlineInputBorder(),
            alignLabelWithHint: true,
          ),
        ),
      ],
    );
  }

  Widget _issuePanel(
    BuildContext context,
    String title,
    List<String> items,
    Color color,
  ) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(12),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 4),
        for (final item in items) SelectableText('• $item'),
      ],
    ),
  );

  Widget _messageBanner(
    BuildContext context,
    String message, {
    required bool isError,
  }) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: isError
          ? Theme.of(context).colorScheme.errorContainer
          : Theme.of(context).colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(12),
    ),
    child: Text(message),
  );

  Widget _actions(BuildContext context, AiProtocolDraft? draft, bool dirty) =>
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Row(
          children: [
            if (draft?.isValid == true && !dirty)
              Expanded(
                child: Text(
                  '返回 Protocol 库保存草稿后，仍需重新审阅并单独批准。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              )
            else
              const Spacer(),
            TextButton(
              onPressed: _cancel,
              child: Text(_generating ? '取消并丢弃' : '取消'),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: _busy || draft == null || !draft.isValid || dirty
                  ? null
                  : () => Navigator.of(context).pop(draft),
              child: const Text('返回并保存草稿'),
            ),
          ],
        ),
      );
}
