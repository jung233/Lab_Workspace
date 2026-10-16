import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lab_core/lab_core.dart';

import '../../platform/asset_import_picker.dart';
import 'http_ai_sdk_bridge.dart';
import 'png_derived_image_tools.dart';
import 'png_image_platform.dart';
import 'python_json_rpc_process.dart';
import 'http_community_pack_transport.dart';
import 'roi_review_dialog.dart';
import '../../widgets/workspace_ui.dart';

/// User-facing AI and scientific image workflow. Upload approval is created
/// only after the page presents the provider, purpose, data class and byte cap.
final class AiImagePage extends StatefulWidget {
  const AiImagePage({
    required this.core,
    required this.assets,
    required this.secretStore,
    required this.packRegistry,
    super.key,
  });

  final LabCore core;
  final AssetGateway assets;
  final SecretStore secretStore;
  final CalculationPackRegistry packRegistry;

  @override
  State<AiImagePage> createState() => _AiImagePageState();
}

final class _AiImagePageState extends State<AiImagePage> {
  late final SqliteAiProviderProfileRepository _profiles;
  late final SqliteConsentReceiptRepository _consents;
  late final SqliteToolApprovalValidator _toolApprovals;
  late final AiSdkBridge _bridge;
  HttpAiSdkBridge? _httpBridge;
  late final AiProviderService _ai;
  late final ScientificImagePlatform _png;
  late final ImageAnalysisService _images;
  late final PackDraftService _packDrafts;
  late final ImageToolRegistry _imageTools;
  late final PngDerivedImageTools _derivedImages;
  late final SkillRegistryService _skillService;
  late final SqliteSkillRegistryRepository _skillRepository;
  late final SqliteCommunityPackPublisherTrustStore _communityTrust;
  late final HttpCommunityPackCatalogTransport _communityTransport;
  late final CommunityPackCatalogService _communityCatalog;
  List<AiProviderProfile> _providerList = const [];
  List<CommunityPackPublisherKey> _communityPublishers = const [];
  List<VerifiedCommunityPack> _communityPacks = const [];
  String? _providerId;
  AssetRecord? _asset;
  ImagePlan? _plan;
  GeneratedCalculationPackDraft? _draft;
  PackDraftValidation? _draftValidation;
  final _packPrompt = TextEditingController();
  final _skillId = TextEditingController(text: 'lab-workflow');
  final _skillVersion = TextEditingController(text: '1.0.0');
  final _skillText = TextEditingController();
  final _communityCatalogUrl = TextEditingController();
  final _communityPublisherId = TextEditingController();
  final _communityPublicKey = TextEditingController();
  List<SkillDocument> _skills = const [];
  String? _selectedSkill;
  String _message = '';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _profiles = SqliteAiProviderProfileRepository(widget.core.database);
    _consents = SqliteConsentReceiptRepository(widget.core.database);
    _toolApprovals = SqliteToolApprovalValidator(widget.core.database);
    final workerConfig = _readTrustedWorkerConfig(widget.core.database);
    final python =
        workerConfig['python_executable'] ??
        Platform.environment['LAB_WORKSPACE_PYTHON'];
    final aiBridgePath =
        workerConfig['ai_sdk_script'] ??
        Platform.environment['LAB_WORKSPACE_AI_SDK_BRIDGE'];
    if (python != null && aiBridgePath != null && Platform.isWindows) {
      _bridge = OpenAiPythonSdkBridge(
        PythonJsonRpcProcess(
          pythonExecutable: python,
          scriptPath: aiBridgePath,
        ),
      );
    } else {
      _httpBridge = HttpAiSdkBridge();
      _bridge = _httpBridge!;
    }
    _ai = AiProviderService(
      profiles: _profiles,
      consents: _consents,
      bridge: _bridge,
      secretStore: widget.secretStore,
      requestToolApproval: _requestToolApproval,
      validateToolApproval: _toolApprovals.call,
      audit: (event, _) async {
        // Audit metadata is deliberately reduced to the event name; provider
        // payloads, text, secrets and image bytes are never persisted here.
        widget.core.database.execute(
          'INSERT INTO outbox(outbox_id,event_type,payload_json,idempotency_key,next_attempt_at_utc,state,attempts,last_error) VALUES(?,?,?,?,?,\'pending\',0,NULL)',
          [
            newUuidV7(),
            'audit.$event',
            '{}',
            newUuidV7(),
            DateTime.now().toUtc().toIso8601String(),
          ],
        );
      },
    );
    _png = ScientificImagePlatform();
    _derivedImages = PngDerivedImageTools(
      assets: widget.assets,
      renderer: _png,
      database: widget.core.database,
    );
    _imageTools = ImageToolRegistry(
      handlers: {
        'crop_derived': _executeDerivedTool,
        'render_overlay': _executeDerivedTool,
        'export_image_report': _executeDerivedTool,
      },
    );
    final runner =
        workerConfig['calculation_rpc_script'] ??
        Platform.environment['LAB_WORKSPACE_CALCULATION_RPC'];
    final CalculationRoiArithmeticBridge calculationBridge;
    if (Platform.isWindows && python != null && runner != null) {
      calculationBridge = _ProcessRoiBridge(
        PythonJsonRpcProcess(pythonExecutable: python, scriptPath: runner),
      );
    } else if (Platform.isAndroid || Platform.isIOS) {
      calculationBridge = const _MobileRoiBridge();
    } else {
      calculationBridge = const _UnavailableRoiBridge();
    }
    _images = ImageAnalysisService(
      assets: widget.assets,
      ai: _ai,
      previewRenderer: _png,
      plans: SqliteImagePlanRepository(widget.core.database),
      quantifier: PythonImageQuantifier(
        decoder: _png,
        calculation: calculationBridge,
      ),
      derivedOutputs: AssetImageDerivedOutputWriter(widget.assets),
      toolRegistry: _imageTools,
      validateApproval: _validateImageApproval,
    );
    _packDrafts = PackDraftService(
      ai: _ai,
      drafts: SqlitePackDraftRepository(widget.core.database),
      calculationRegistry: CalculationPackReviewAdapter(widget.packRegistry),
    );
    _skillRepository = SqliteSkillRegistryRepository(widget.core.database);
    _communityTrust = SqliteCommunityPackPublisherTrustStore(
      widget.core.database,
    );
    _communityTransport = HttpCommunityPackCatalogTransport();
    _communityCatalog = CommunityPackCatalogService(
      transport: _communityTransport,
      trustStore: _communityTrust,
      registry: widget.packRegistry,
    );
    _skillService = SkillRegistryService(
      repository: _skillRepository,
      validator: _AppSkillInstructionValidator(),
      hasher: const Sha256ContentHasher(),
    );
    _loadProviders();
    _loadSkills();
    _loadCommunityPublishers();
  }

  @override
  void dispose() {
    _httpBridge?.close();
    _packPrompt.dispose();
    _skillId.dispose();
    _skillVersion.dispose();
    _skillText.dispose();
    _communityCatalogUrl.dispose();
    _communityPublisherId.dispose();
    _communityPublicKey.dispose();
    _communityTransport.close();
    super.dispose();
  }

  Future<void> _loadProviders() async {
    try {
      final providers = await _profiles.list();
      if (!mounted) return;
      setState(() {
        _providerList = providers;
        _providerId ??= providers.firstOrNull?.providerId;
      });
    } on Object catch (error) {
      if (mounted) setState(() => _message = '读取 Provider 失败：$error');
    }
  }

  Future<void> _loadSkills() async {
    try {
      final skills = await _skillRepository.list();
      if (mounted) setState(() => _skills = skills);
    } on Object catch (error) {
      if (mounted) {
        setState(() => _message = '读取 Skill 失败：${_safeMessage(error)}');
      }
    }
  }

  Future<void> _loadCommunityPublishers() async {
    try {
      final keys = await _communityTrust.list();
      if (mounted) setState(() => _communityPublishers = keys);
    } on Object catch (error) {
      if (mounted) {
        setState(() => _message = '读取社区发布者信任记录失败：${_safeMessage(error)}');
      }
    }
  }

  Future<void> _pinCommunityPublisher() async {
    final publisher = _communityPublisherId.text.trim();
    final keyBytes = base64.decode(
      base64.normalize(_communityPublicKey.text.trim()),
    );
    if (keyBytes.length != 32) {
      if (mounted) setState(() => _message = 'Ed25519 公钥必须是 32 字节 Base64。');
      return;
    }
    final fingerprint = CommunityPackPublisherKey(
      publisherId: publisher,
      publicKeyBytes: keyBytes,
      trustedAtUtc: DateTime.now().toUtc(),
    ).fingerprint;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('信任社区 Pack 发布者？'),
        content: SelectableText(
          '发布者：$publisher\nEd25519 公钥 SHA-256：$fingerprint\n\n请通过该发布者独立的官方渠道核对完整指纹。信任该 key 只代表验证来源签名，不代表自动批准或安装 Pack。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('已独立核对并信任'),
          ),
        ],
      ),
    );
    if (accepted != true) return;
    await _run(() async {
      await _communityTrust.pin(
        publisherId: publisher,
        publicKeyBase64: base64Encode(keyBytes),
      );
      await _loadCommunityPublishers();
      if (mounted) setState(() => _message = '已固定发布者公钥指纹 $fingerprint。');
    });
  }

  Future<void> _fetchCommunityCatalog() async {
    final uri = Uri.tryParse(_communityCatalogUrl.text.trim());
    if (uri == null) {
      setState(() => _message = '社区目录 URL 无效。');
      return;
    }
    await _run(() async {
      final packs = await _communityCatalog.fetch(uri);
      if (mounted) setState(() => _communityPacks = packs);
      if (mounted) {
        setState(
          () => _message =
              '签名目录验证完成：${packs.length} 个 Pack 通过来源签名、schema/能力校验和 golden fixtures。',
        );
      }
    });
  }

  Future<void> _installCommunityPack(VerifiedCommunityPack pack) async {
    final document = pack.document;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('审核社区 Calculation Pack'),
        content: SingleChildScrollView(
          child: SelectableText(
            'Pack：${document['pack_id']}@${document['version']}\n发布者：${pack.publisherId}\nKey SHA-256：${pack.keyFingerprint}\n内容 SHA-256：${pack.contentSha256}\n来源：${pack.documentUri}\n\n说明：${pack.description}\n权限摘要：${pack.permissionSummary.isEmpty ? '无外部权限；仅使用已批准的核心 primitives' : pack.permissionSummary.join(', ')}\n操作：${pack.validation.unsupportedOperations.isEmpty ? '无不支持操作' : pack.validation.unsupportedOperations.join(', ')}\nGolden cases：${pack.golden.cases.length} 全部通过\n\n安装仍会以用户批准的不可变本地 Pack 记录，并再次运行验证和 golden cases。',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('拒绝'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('批准并安装'),
          ),
        ],
      ),
    );
    if (accepted != true) return;
    final approval = widget.core.approvals.issue(
      action: 'install_calculation_pack',
      subjectType: 'calculation_pack',
      subjectId:
          '${document['pack_id']}@${document['version']}#${pack.contentSha256}',
      scope: {
        'pack_id': document['pack_id'],
        'version': document['version'],
        'content_sha256': pack.contentSha256,
      },
      expiresAtUtc: DateTime.now().toUtc().add(const Duration(minutes: 10)),
    );
    await _run(() async {
      final installed = await _communityCatalog.install(pack, approval);
      if (mounted) {
        setState(
          () => _message =
              '已安装社区 Pack ${installed.ref} · SHA-256 ${installed.contentSha256} · 来源签名与本地审批均已记录。',
        );
      }
    });
  }

  Future<void> _importSkill() async {
    try {
      await _skillService.importInstructions(
        skillId: _skillId.text.trim(),
        version: _skillVersion.text.trim(),
        instructions: _skillText.text,
      );
      if (mounted) {
        setState(
          () => _message = 'Skill 指令已校验并保存为 versioned instruction-only 记录。',
        );
      }
      await _loadSkills();
    } on Object catch (error) {
      if (mounted) setState(() => _message = _safeMessage(error));
    }
  }

  Future<void> _enableSkill(SkillDocument skill) async {
    try {
      final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('启用指令型 Skill'),
          content: SelectableText(
            '${skill.skillId}@${skill.version}\nSHA-256 ${skill.contentSha256}\n\nSkill 仅作为模型指令文本，不能授权工具或执行文件。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('启用此版本'),
            ),
          ],
        ),
      );
      if (accepted != true) return;
      await _skillService.enable(skill.skillId, skill.version);
      if (mounted) {
        setState(() => _message = '已启用 ${skill.skillId}@${skill.version}。');
      }
      await _loadSkills();
    } on Object catch (error) {
      if (mounted) setState(() => _message = _safeMessage(error));
    }
  }

  Future<T?> _run<T>(Future<T> Function() action) async {
    if (_busy) return null;
    setState(() {
      _busy = true;
      _message = '';
    });
    try {
      final result = await action();
      return result;
    } on Object catch (error) {
      if (mounted) setState(() => _message = _safeMessage(error));
      return null;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _probe() async {
    final provider = _providerId;
    if (provider == null) return;
    await _run(() async {
      final consent = await _consent(
        providerId: provider,
        purpose: 'provider_capability_probe',
        dataClass: 'synthetic',
        assetIds: const {},
        bytes: 8192,
        scopes: const {'capability_probe'},
        details: '仅发送合成探测文本与 1 像素图像；供应商可能按请求计费。',
      );
      final capabilities = await _ai.probe(provider, consent: consent);
      if (mounted) {
        setState(
          () => _message = '能力探测完成：${jsonEncode(capabilities.toJson())}',
        );
      }
    });
    await _loadProviders();
  }

  Future<void> _completeText() async {
    final provider = _providerId;
    if (provider == null) return;
    final promptController = TextEditingController();
    final prompt = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('发送文本请求'),
        content: TextField(
          controller: promptController,
          minLines: 3,
          maxLines: 8,
          decoration: const InputDecoration(labelText: '发送给模型的内容'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, promptController.text),
            child: const Text('继续'),
          ),
        ],
      ),
    );
    promptController.dispose();
    if (prompt == null || prompt.trim().isEmpty) return;
    await _run(() async {
      final bytes = utf8.encode(prompt).length + 512;
      final consent = await _consent(
        providerId: provider,
        purpose: 'text_assistance',
        dataClass: 'text',
        assetIds: const {},
        bytes: bytes,
        scopes: const {'text'},
        details: '将发送你输入的文本，估算上限 $bytes 字节。',
      );
      final response = await _ai.completeText(
        providerId: provider,
        prompt: prompt,
        consent: consent,
      );
      if (mounted) setState(() => _message = response);
    });
  }

  Future<void> _importAsset() async {
    final imported = await AssetImportPicker(
      widget.assets,
    ).pickAndImport(allowMultiple: false, kind: AssetKind.raw);
    if (imported.isNotEmpty && mounted) {
      setState(() {
        _asset = imported.single.asset;
        _plan = null;
        _message =
            '原始资产已导入：${_asset!.displayName} · SHA-256 ${_asset!.blobSha256}';
      });
    }
  }

  Future<void> _generatePackDraft() async {
    final provider = _providerId;
    final request = _packPrompt.text.trim();
    if (provider == null || request.isEmpty) return;
    await _run(() async {
      final skillInstructions = await _packSkillInstructions();
      final bytes =
          utf8.encode(request).length +
          utf8.encode(skillInstructions).length +
          16 * 1024;
      final consent = await _consent(
        providerId: provider,
        purpose: 'calculation_pack_generation',
        dataClass: 'text',
        assetIds: const {},
        bytes: bytes,
        scopes: const {'pack_generation'},
        details:
            '将发送协议描述${_selectedSkill == null ? '' : '和启用的 Skill 指令（$_selectedSkill）'}，用于生成未批准的 Calculation Pack 草案。草案不能直接运行。',
      );
      final draft = await _packDrafts.generateDraft(
        providerId: provider,
        request: request,
        consent: consent,
        skillInstructions: skillInstructions,
      );
      final validation = await _packDrafts.validate(draft.draftId);
      if (mounted) {
        setState(() {
          _draft = draft;
          _draftValidation = validation;
        });
      }
    });
  }

  Future<String> _packSkillInstructions() async {
    const base =
        'Use only the versioned declarative Calculation Pack schema and listed primitive operations. Do not write code. Preserve missing parameters in requires_user_input and unknown operations in unsupported_operations.';
    final selected = _selectedSkill;
    if (selected == null) return base;
    for (final skill in _skills) {
      final key = '${skill.skillId}@${skill.version}';
      if (key == selected && skill.state == SkillState.enabled) {
        return '$base\n\nEnabled instruction-only Skill (${skill.skillId}@${skill.version}):\n${await _skillService.getInstructions(skill.skillId, skill.version)}';
      }
    }
    return base;
  }

  Future<void> _approvePackDraft() async {
    final draft = _draft;
    final validation = _draftValidation;
    if (draft == null ||
        validation == null ||
        !validation.valid ||
        validation.contentSha256 == null) {
      return;
    }
    final id = draft.document['pack_id'];
    final version = draft.document['version'];
    if (id is! String || version is! String) return;
    final subject = '$id@$version#${validation.contentSha256}';
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('审批并安装不可变 Pack 版本'),
        content: SelectableText(
          'Pack：$subject\n\n这是由模型生成的声明式草案。将先执行 schema / primitive 检查和 golden cases，再由 registry 冻结并安装此 SHA。安装后版本不可变。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('审批并安装'),
          ),
        ],
      ),
    );
    if (accepted != true) return;
    final approval = widget.core.approvals.issue(
      action: 'install_calculation_pack',
      subjectType: 'calculation_pack',
      subjectId: subject,
      scope: {
        'content_sha256': validation.contentSha256,
        'pack_id': id,
        'version': version,
      },
      expiresAtUtc: DateTime.now().toUtc().add(const Duration(minutes: 10)),
    );
    await _run(() async {
      final installed = await _packDrafts.approveAndInstall(
        draft.draftId,
        approval,
      );
      if (mounted) {
        setState(
          () => _message =
              '已安装 ${installed.packId}@${installed.version} · SHA-256 ${installed.contentSha256}',
        );
      }
    });
  }

  Future<ImageToolResult> _executeDerivedTool(ImageToolRequest request) async {
    final approval = request.approvalRef;
    final roi = request.roi;
    if (approval == null || roi == null) {
      throw const ImageServiceException(
        'IMAGE_TOOL_APPROVAL_REQUIRED',
        'A user-approved ROI is required for derived image output.',
      );
    }
    final operation = request.toolId;
    final assetId = operation == 'export_image_report'
        ? await _derivedImages.exportRoiReport(
            sourceAssetId: request.assetId,
            sourceSha256: request.sourceSha256,
            roi: roi,
            approvalRef: approval,
            metadata: _plan!.metadata,
            pageIndex: _plan!.metadata.pageIndex,
          )
        : await _derivedImages.transform(
            sourceAssetId: request.assetId,
            sourceSha256: request.sourceSha256,
            roi: roi,
            operation: operation,
            approvalRef: approval,
            pageIndex: _plan!.metadata.pageIndex,
          );
    return ImageToolResult({
      'asset_id': assetId,
      'derived_operation': operation,
    });
  }

  Future<void> _createDerivedImage(String operation) async {
    final plan = _plan;
    final roi = plan?.approvedRoi;
    if (plan == null || roi == null || plan.state == ImageJobState.rejected) {
      return;
    }
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('批准生成衍生图像/报告'),
        content: Text(
          '操作：$operation\n原图 Asset：${plan.sourceAssetId}\n原图 SHA-256：${plan.sourceSha256}\nROI：${jsonEncode(roi.toJson())}\n\n结果会作为新的 derived/report Asset 保存。编辑像素不会进入定量。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('批准此操作'),
          ),
        ],
      ),
    );
    if (accepted != true) return;
    final scope = <String, Object?>{
      'operation': operation,
      'source_asset_id': plan.sourceAssetId,
      'source_sha256': plan.sourceSha256,
      'roi': roi.toJson(),
      'page_index': plan.metadata.pageIndex,
      'generated_pixels_used_for_quantitation': false,
    };
    final approval = widget.core.approvals.issue(
      action: 'image.derived.create',
      subjectType: 'image_derived',
      subjectId: '${plan.sourceAssetId}@${plan.sourceSha256}',
      scope: scope,
      expiresAtUtc: DateTime.now().toUtc().add(const Duration(minutes: 5)),
    );
    await _run(() async {
      final result = await _imageTools.execute(
        ImageToolRequest(
          toolId: operation,
          assetId: plan.sourceAssetId,
          sourceSha256: plan.sourceSha256,
          mode: plan.mode,
          arguments: roi.toJson(),
          approvalRef: approval,
          roi: roi,
        ),
      );
      if (mounted) {
        setState(
          () => _message = '已生成独立衍生 Asset：${(result.value as Map)['asset_id']}',
        );
      }
    });
  }

  Future<void> _showImageTrace() async {
    final derived = _plan?.derivedAssetId;
    if (derived == null) return;
    String report;
    final handle = await widget.assets.openVerified(derived);
    try {
      final chunks = <int>[];
      await for (final chunk in handle.openRead()) {
        if (chunks.length + chunk.length > 4 * 1024 * 1024) {
          throw const ImageServiceException(
            'IMAGE_TRACE_TOO_LARGE',
            'The saved calculation report exceeds the display limit.',
          );
        }
        chunks.addAll(chunk);
      }
      report = utf8.decode(chunks);
      final decoded = jsonDecode(report);
      if (decoded is! Map || decoded['trace'] is! Map) {
        throw const ImageServiceException(
          'IMAGE_TRACE_INVALID',
          'Saved image result does not contain a CalculationTrace.',
        );
      }
      final trace = (decoded['trace'] as Map).map(
        (key, value) => MapEntry(key.toString(), value),
      );
      ImageCalculationTrace.verifyPersisted(trace);
      if (trace['trace_id'] != _plan?.traceId ||
          decoded['source_sha256'] != _plan?.sourceSha256 ||
          decoded['generated_pixels_used_for_quantitation'] != false) {
        throw const ImageServiceException(
          'IMAGE_TRACE_SOURCE_MISMATCH',
          'Saved trace no longer matches the reviewed original Asset.',
        );
      }
      report = const JsonEncoder.withIndent('  ').convert(decoded);
    } finally {
      await handle.close();
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('展示原始计算'),
        content: SizedBox(
          width: 720,
          child: SingleChildScrollView(child: SelectableText(report)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Future<void> _planImage() async {
    final provider = _providerId;
    final asset = _asset;
    if (provider == null || asset == null) return;
    await _run(() async {
      final original = await widget.assets.openVerified(asset.assetId);
      late final ImageMetadata firstPage;
      try {
        firstPage = await _png.inspect(original);
      } finally {
        await original.close();
      }
      var pageIndex = 0;
      if (firstPage.pageCount > 1) {
        if (!mounted) return;
        final selected = await showDialog<int>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('选择原图页面'),
            content: DropdownButtonFormField<int>(
              initialValue: 0,
              items: [
                for (var page = 0; page < firstPage.pageCount; page++)
                  DropdownMenuItem(value: page, child: Text('页面 ${page + 1}')),
              ],
              onChanged: (value) => Navigator.pop(context, value),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消'),
              ),
            ],
          ),
        );
        if (selected == null) return;
        pageIndex = selected;
      }
      final verifiedOriginal = await widget.assets.openVerified(asset.assetId);
      try {
        await _png.inspect(verifiedOriginal, pageIndex: pageIndex);
        // Decode exact unsigned integer samples before asking for cloud consent.
        await _png.decodeOriginal(verifiedOriginal, pageIndex: pageIndex);
      } finally {
        await verifiedOriginal.close();
      }
      final consent = await _consent(
        providerId: provider,
        purpose: 'scientific_image_roi',
        dataClass: 'scientific_image_preview',
        assetIds: {asset.assetId},
        bytes: 6 * 1024 * 1024,
        scopes: const {'vision', 'tool_use'},
        details:
            '向 $provider 上传原图第 ${pageIndex + 1} 页的最大 4 MiB 缩略预览，用于解释 ROI 候选；不上传原始文件。可定量格式仅限无调色板、无 alpha 的无符号 8/16-bit 灰度或 RGB PNG/TIFF；其他精度和通道布局会在上传前拒绝。供应商可能计费。',
      );
      final plan = await _images.plan(
        sourceAssetId: asset.assetId,
        providerId: provider,
        consent: consent,
        purpose: 'scientific_image_roi',
        pageIndex: pageIndex,
      );
      if (mounted) setState(() => _plan = plan);
    });
  }

  Future<void> _reviewAndExecute() async {
    final plan = _plan;
    if (plan == null || plan.suggestions.isEmpty) return;
    final handle = await widget.assets.openVerified(plan.sourceAssetId);
    Uint8List previewBytes;
    try {
      final preview = await _png.createPreview(
        handle,
        maxBytes: 4 * 1024 * 1024,
        pageIndex: plan.metadata.pageIndex,
      );
      final separator = preview.dataUri.indexOf(',');
      if (separator < 0 ||
          !preview.dataUri.startsWith('data:image/png;base64,')) {
        throw const ImageServiceException(
          'IMAGE_PREVIEW_INVALID',
          'Reviewed source preview is not a PNG image.',
        );
      }
      previewBytes = base64Decode(preview.dataUri.substring(separator + 1));
    } finally {
      await handle.close();
    }
    if (!mounted) return;
    final decision = await showRoiReviewDialog(
      context: context,
      plan: plan,
      originalPreviewPng: previewBytes,
    );
    if (decision == null || !mounted) return;
    final roi = decision.signalRoi;
    final channelIndex = decision.channelIndex;
    final channelName = plan.metadata.channels[channelIndex];
    final now = DateTime.now().toUtc();
    final scope = <String, Object?>{
      'source_asset_id': plan.sourceAssetId,
      'source_sha256': plan.sourceSha256,
      'signal_roi': roi.toJson(),
      'background_roi': decision.backgroundRoi?.toJson(),
      'channel_index': channelIndex,
      'channel_name': channelName,
      'page_index': plan.metadata.pageIndex,
      'background_method': decision.backgroundMethod,
      'reviewer': 'local_user',
    };
    final approval = widget.core.approvals.issue(
      action: 'image.roi.approve',
      subjectType: 'image_roi_review',
      subjectId: plan.jobId,
      scope: scope,
      expiresAtUtc: now.add(const Duration(hours: 1)),
    );
    await _run(() async {
      await _images.approveRoi(
        jobId: plan.jobId,
        signalRoi: roi,
        channelIndex: channelIndex,
        channelName: channelName,
        pageIndex: plan.metadata.pageIndex,
        approvalRef: approval,
        backgroundRoi: decision.backgroundRoi,
        backgroundMethod: decision.backgroundMethod,
      );
      await _images.executeQuantification(plan.jobId);
      final completed = await SqliteImagePlanRepository(
        widget.core.database,
      ).get(plan.jobId);
      if (mounted) setState(() => _plan = completed);
    });
  }

  Future<ConsentReceipt> _consent({
    required String providerId,
    required String purpose,
    required String dataClass,
    required Set<String> assetIds,
    required int bytes,
    required Set<String> scopes,
    required String details,
  }) async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('允许此请求发送到云端？'),
        content: Text(
          'Provider：$providerId\n用途：$purpose\n数据类别：$dataClass\n资产 ID：${assetIds.join(', ')}\n估算请求上限：$bytes 字节\n授权能力：${scopes.join(', ')}\n\n$details',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('拒绝'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('明确同意并继续'),
          ),
        ],
      ),
    );
    if (accepted != true) {
      throw const AiProviderException(
        'AI_UPLOAD_CONSENT_REQUIRED',
        '用户未同意此数据外发请求。',
      );
    }
    final approvedAt = DateTime.now().toUtc();
    final expiresAt = approvedAt.add(const Duration(minutes: 10));
    final approvalScope = <String, Object?>{
      'provider_id': providerId,
      'purpose': purpose,
      'data_class': dataClass,
      'asset_ids': assetIds.toList()..sort(),
      'total_bytes': bytes,
      'approved_scopes': scopes.toList()..sort(),
      'expires_at_utc': expiresAt.toIso8601String(),
    };
    final approvalRef = widget.core.approvals.issue(
      action: 'ai.upload_consent',
      subjectType: 'ai_provider',
      subjectId: providerId,
      scope: approvalScope,
      expiresAtUtc: expiresAt,
    );
    final receipt = ConsentReceipt(
      id: newUuidV7(),
      providerId: providerId,
      purpose: purpose,
      dataClass: dataClass,
      assetIds: assetIds,
      totalBytes: bytes,
      approvedScopes: scopes,
      approvedAt: approvedAt,
      expiresAt: expiresAt,
      approvalRef: approvalRef,
    );
    await _ai.recordConsent(receipt);
    return receipt;
  }

  Future<ToolApproval> _requestToolApproval(ToolApprovalRequest request) async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('模型请求运行本地工具'),
        content: SelectableText(
          '工具：${request.call.name}\n参数：${jsonEncode(request.call.arguments)}\n资产：${request.assetIds.join(', ')}\n权限：${request.scope}\n\n${request.reason}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('拒绝'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('批准此参数调用'),
          ),
        ],
      ),
    );
    if (accepted != true) {
      return const ToolApproval(approved: false, approvalRef: null);
    }
    final scope = <String, Object?>{
      'tool_name': request.call.name,
      'parameters': request.call.arguments,
      'asset_ids': request.assetIds.toList()..sort(),
      'scope': request.scope,
    };
    final ref = widget.core.approvals.issue(
      action: 'ai.tool.execute',
      subjectType: 'ai_tool',
      subjectId: request.call.name,
      scope: scope,
      expiresAtUtc: DateTime.now().toUtc().add(const Duration(minutes: 5)),
    );
    return ToolApproval(approved: true, approvalRef: ref);
  }

  Future<void> _validateImageApproval(
    ApprovalRef ref, {
    required String action,
    required String subjectId,
    required Map<String, Object?> scope,
  }) async {
    widget.core.database.transaction((tx) {
      tx.requireApproval(
        approvalRef: ref,
        action: action,
        subjectType: 'image_roi_review',
        subjectId: subjectId,
        atUtc: DateTime.now().toUtc(),
        requiredScope: scope,
      );
      return null;
    });
    final row = widget.core.database.query(
      'SELECT scope_json FROM approval_receipts WHERE approval_ref=?',
      [ref.value],
    );
    if (row.isEmpty ||
        _canonical(jsonDecode(row.single['scope_json'] as String)) !=
            _canonical(scope)) {
      throw const ImageServiceException(
        'APPROVAL_SCOPE_MISMATCH',
        'ROI approval does not match the reviewed source and coordinates.',
      );
    }
  }

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.fromLTRB(28, 22, 28, 34),
    children: [
      WorkspacePageHeader(
        title: '图像与 AI',
        subtitle: 'AI 只提出文本建议；上传需明确同意，ROI 需人工核对，定量结果保留原始 CalculationTrace。',
        icon: Icons.image_search_outlined,
        actions: [
          OutlinedButton.icon(
            onPressed: _busy ? null : _importAsset,
            icon: const Icon(Icons.add_photo_alternate_outlined),
            label: const Text('导入原始图像'),
          ),
          if (_plan?.state == ImageJobState.executed)
            OutlinedButton.icon(
              onPressed: _busy ? null : _showImageTrace,
              icon: const Icon(Icons.receipt_long_outlined),
              label: const Text('展示原始计算'),
            ),
        ],
      ),
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Row(
          children: [
            Expanded(
              child: DropdownButtonFormField<String>(
                initialValue: _providerId,
                decoration: const InputDecoration(labelText: 'AI Provider'),
                items: [
                  for (final profile in _providerList)
                    DropdownMenuItem(
                      value: profile.providerId,
                      child: Text('${profile.name} · ${profile.modelId}'),
                    ),
                ],
                onChanged: _busy
                    ? null
                    : (value) => setState(() => _providerId = value),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              onPressed: _busy ? null : _loadProviders,
              icon: const Icon(Icons.refresh),
              tooltip: '刷新 Provider',
            ),
            FilledButton.tonal(
              onPressed: _busy || _providerId == null ? null : _probe,
              child: const Text('明确同意并探测'),
            ),
          ],
        ),
      ),
      if (_busy) const LinearProgressIndicator(),
      if (_providerList.isEmpty)
        const Padding(
          padding: EdgeInsets.all(16),
          child: Text('先在设置中保存 Provider、模型 ID 和安全存储凭据。'),
        ),
      if (_providerList.isNotEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Wrap(
            spacing: 8,
            children: [
              FilledButton.icon(
                onPressed: _busy ? null : _completeText,
                icon: const Icon(Icons.chat),
                label: const Text('发送文本请求'),
              ),
              FilledButton.tonalIcon(
                onPressed: _busy || _asset == null ? null : _planImage,
                icon: const Icon(Icons.visibility_outlined),
                label: const Text('同意后让模型规划 ROI'),
              ),
            ],
          ),
        ),
      if (_providerList.isNotEmpty)
        Card(
          margin: const EdgeInsets.all(12),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Calculation Pack 草案',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const Text('模型只能生成 draft；验证、golden cases 和单独用户审批完成前不会安装。'),
                TextField(
                  controller: _packPrompt,
                  minLines: 2,
                  maxLines: 5,
                  decoration: const InputDecoration(labelText: '描述需要的计算协议'),
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton.tonal(
                    onPressed: _busy ? null : _generatePackDraft,
                    child: const Text('明确同意后生成草案'),
                  ),
                ),
                if (_draft != null)
                  SelectableText(
                    'Draft ${_draft!.draftId}\n${const JsonEncoder.withIndent('  ').convert(_draft!.toJson())}',
                  ),
                if (_draftValidation != null)
                  Text(
                    '验证：${_draftValidation!.valid ? '通过' : '未通过'} · SHA ${_draftValidation!.contentSha256 ?? 'N/A'}\n${[..._draftValidation!.errors, ..._draftValidation!.warnings, ..._draftValidation!.unsupportedOperations.map((value) => '不支持：$value'), ..._draftValidation!.requiresUserInput.map((value) => '需要输入：$value')].join('\n')}',
                  ),
                if (_draftValidation?.valid == true)
                  Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton(
                      onPressed: _busy ? null : _approvePackDraft,
                      child: const Text('审阅并审批安装'),
                    ),
                  ),
              ],
            ),
          ),
        ),
      Card(
        margin: const EdgeInsets.all(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '签名社区 Pack 目录',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const Text(
                '仅接受 HTTPS 上的 JSON declarative Pack；发布者 key 必须先通过独立渠道核对完整指纹。签名验证、schema/primitive allowlist、golden fixtures 和单独用户批准全部通过后才会安装；不运行目录脚本或插件代码。',
              ),
              TextField(
                controller: _communityCatalogUrl,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  labelText: 'HTTPS signed catalog URL',
                ),
              ),
              TextField(
                controller: _communityPublisherId,
                decoration: const InputDecoration(labelText: '发布者 ID'),
              ),
              TextField(
                controller: _communityPublicKey,
                minLines: 1,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: 'Ed25519 public key（32-byte Base64）',
                ),
              ),
              Wrap(
                spacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _pinCommunityPublisher,
                    icon: const Icon(Icons.verified_user_outlined),
                    label: const Text('核对指纹并固定发布者'),
                  ),
                  FilledButton.tonalIcon(
                    onPressed: _busy ? null : _fetchCommunityCatalog,
                    icon: const Icon(Icons.download_outlined),
                    label: const Text('获取并验证目录'),
                  ),
                  IconButton(
                    onPressed: _busy ? null : _loadCommunityPublishers,
                    icon: const Icon(Icons.refresh),
                    tooltip: '刷新信任记录',
                  ),
                ],
              ),
              for (final publisher in _communityPublishers)
                ListTile(
                  dense: true,
                  title: Text(
                    '${publisher.publisherId} · ${publisher.enabled ? '已信任' : '已禁用'}',
                  ),
                  subtitle: SelectableText(
                    'Ed25519 SHA-256 ${publisher.fingerprint} · 固定于 ${publisher.trustedAtUtc.toIso8601String()}',
                  ),
                  trailing: Switch(
                    value: publisher.enabled,
                    onChanged: _busy
                        ? null
                        : (enabled) async {
                            await _communityTrust.setEnabled(
                              publisher.publisherId,
                              enabled,
                            );
                            await _loadCommunityPublishers();
                          },
                  ),
                ),
              for (final pack in _communityPacks)
                ListTile(
                  leading: const Icon(Icons.inventory_2_outlined),
                  title: Text(
                    '${pack.document['pack_id']}@${pack.document['version']}',
                  ),
                  subtitle: Text(
                    '${pack.publisherId} · ${pack.contentSha256} · ${pack.description}\n权限：${pack.permissionSummary.isEmpty ? '无额外权限' : pack.permissionSummary.join(', ')}',
                  ),
                  isThreeLine: true,
                  trailing: FilledButton(
                    onPressed: _busy ? null : () => _installCommunityPack(pack),
                    child: const Text('审核安装'),
                  ),
                ),
            ],
          ),
        ),
      ),
      Card(
        margin: const EdgeInsets.all(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Versioned Skills',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const Text('仅导入文本指令；能力声明不会授予本地权限，也不会执行包内脚本。'),
              TextField(
                controller: _skillId,
                decoration: const InputDecoration(labelText: 'Skill ID'),
              ),
              TextField(
                controller: _skillVersion,
                decoration: const InputDecoration(labelText: '版本（SemVer）'),
              ),
              TextField(
                controller: _skillText,
                minLines: 2,
                maxLines: 5,
                decoration: const InputDecoration(
                  labelText: 'Skill instruction text',
                ),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: OutlinedButton(
                  onPressed: _busy ? null : _importSkill,
                  child: const Text('校验并保存 Skill'),
                ),
              ),
              for (final skill in _skills)
                ListTile(
                  dense: true,
                  title: Text(
                    '${skill.skillId}@${skill.version} · ${skill.state.name}',
                  ),
                  subtitle: Text(
                    'SHA-256 ${skill.contentSha256} · instruction_only',
                  ),
                  trailing: skill.state == SkillState.enabled
                      ? const Icon(Icons.check_circle_outline)
                      : IconButton(
                          onPressed: () => _enableSkill(skill),
                          icon: const Icon(Icons.check),
                          tooltip: '启用',
                        ),
                  onTap: skill.state == SkillState.enabled
                      ? () => setState(
                          () => _selectedSkill =
                              '${skill.skillId}@${skill.version}',
                        )
                      : null,
                ),
            ],
          ),
        ),
      ),
      if (_asset != null)
        ListTile(
          leading: const Icon(Icons.image_outlined),
          title: Text(_asset!.displayName),
          subtitle: SelectableText(
            'Asset ${_asset!.assetId} · SHA-256 ${_asset!.blobSha256}',
          ),
        ),
      if (_plan != null)
        Card(
          margin: const EdgeInsets.all(12),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '图像计划：${_plan!.state.name} · ${_plan!.metadata.width}×${_plan!.metadata.height} · ${_plan!.validationLevel.name}',
                ),
                for (final item in _plan!.suggestions)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      '${item.label}: ${item.explanation} · 候选 ROI ${item.roi.toJson()} · 置信度 ${item.confidence}',
                    ),
                  ),
                if (_plan!.suggestions.isNotEmpty)
                  Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton(
                      onPressed: _busy ? null : _reviewAndExecute,
                      child: const Text('人工核对 ROI 并定量'),
                    ),
                  ),
                if (_plan!.state == ImageJobState.waitingForModel)
                  const Text('该 Provider 尚未验证 vision/tools 能力；请先进行明确同意的能力探测。'),
                if (_plan!.approvedRoi != null)
                  Wrap(
                    spacing: 8,
                    children: [
                      OutlinedButton(
                        onPressed: _busy
                            ? null
                            : () => _createDerivedImage('crop_derived'),
                        child: const Text('批准并保存 ROI 裁剪图'),
                      ),
                      OutlinedButton(
                        onPressed: _busy
                            ? null
                            : () => _createDerivedImage('render_overlay'),
                        child: const Text('批准并保存 ROI 标注图'),
                      ),
                      OutlinedButton(
                        onPressed: _busy
                            ? null
                            : () => _createDerivedImage('export_image_report'),
                        child: const Text('批准并导出 ROI 报告'),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ),
      if (_plan?.state == ImageJobState.executed)
        Card(
          margin: const EdgeInsets.all(12),
          child: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.functions),
                title: const Text('ROI 定量已完成'),
                subtitle: SelectableText(
                  'CalculationTrace ${_plan!.traceId} · 衍生报告 Asset ${_plan!.derivedAssetId ?? '未生成'}。',
                ),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: _showImageTrace,
                  icon: const Icon(Icons.receipt_long),
                  label: const Text('展示原始计算'),
                ),
              ),
            ],
          ),
        ),
      if (_message.isNotEmpty)
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: SelectableText(_message),
          ),
        ),
    ],
  );

  static String _safeMessage(Object error) {
    if (error is AiProviderException || error is ImageServiceException) {
      return '$error';
    }
    return '操作未完成。请检查本地服务配置；敏感请求和响应未写入日志。';
  }

  static String _canonical(Object? value) {
    if (value is Map) {
      final keys = value.keys.map((key) => key.toString()).toList()..sort();
      return '{${keys.map((key) => '${jsonEncode(key)}:${_canonical(value[key])}').join(',')}}';
    }
    if (value is List) return '[${value.map(_canonical).join(',')}]';
    return jsonEncode(value);
  }
}

final class _ProcessRoiBridge implements CalculationRoiArithmeticBridge {
  const _ProcessRoiBridge(this.process);
  final PythonJsonRpcProcess process;

  @override
  Future<Map<String, Object?>> quantifyRoi(Map<String, Object?> params) async {
    final result = await process.call(
      'quantifyRoi',
      params,
      timeoutSeconds: 120,
    );
    final nested = result['result'];
    if (nested is Map) {
      return nested.map((key, value) => MapEntry(key.toString(), value));
    }
    return result;
  }
}

final class _UnavailableRoiBridge implements CalculationRoiArithmeticBridge {
  const _UnavailableRoiBridge();
  @override
  Future<Map<String, Object?>> quantifyRoi(
    Map<String, Object?> params,
  ) => Future.error(
    const ImageServiceException(
      'IMAGE_CALCULATION_RUNTIME_UNAVAILABLE',
      '配置 LAB_WORKSPACE_PYTHON 和 LAB_WORKSPACE_CALCULATION_RPC 后，才可调用受控 ROI 计算 runner。',
    ),
  );
}

final class _MobileRoiBridge implements CalculationRoiArithmeticBridge {
  const _MobileRoiBridge();
  static const _channel = MethodChannel('lab_workspace/calculation_executor');

  @override
  Future<Map<String, Object?>> quantifyRoi(Map<String, Object?> params) async {
    final request = jsonEncode({
      'jsonrpc': '2.0',
      'id': 'lab-image-roi-1',
      'method': 'quantifyRoi',
      'params': params,
    });
    String? response;
    try {
      response = await _channel.invokeMethod<String>('quantifyRoi', {
        'requestJson': request,
      });
    } on MissingPluginException {
      throw const ImageServiceException(
        'IMAGE_CALCULATION_RUNTIME_UNAVAILABLE',
        'The trusted mobile calculation runtime is not installed.',
      );
    } on PlatformException {
      throw const ImageServiceException(
        'IMAGE_CALCULATION_RUNTIME_FAILED',
        'The trusted mobile calculation runtime failed.',
      );
    }
    if (response == null) {
      throw const ImageServiceException(
        'IMAGE_CALCULATION_RUNTIME_UNAVAILABLE',
        'The trusted mobile calculation runtime is unavailable.',
      );
    }
    final decoded = jsonDecode(response);
    if (decoded is Map &&
        decoded['id'] == 'lab-image-roi-1' &&
        decoded['error'] is Map) {
      final error = decoded['error'] as Map;
      final code = error['code'] is String
          ? error['code'] as String
          : 'IMAGE_CALCULATION_FAILED';
      throw ImageServiceException(
        code,
        'The mobile calculation runtime rejected this approved ROI request.',
      );
    }
    if (decoded is! Map ||
        decoded['id'] != 'lab-image-roi-1' ||
        decoded['result'] is! Map) {
      throw const ImageServiceException(
        'IMAGE_CALCULATION_RESPONSE_INVALID',
        'The mobile calculation runtime returned an invalid JSON-RPC response.',
      );
    }
    return (decoded['result'] as Map).map(
      (key, value) => MapEntry(key.toString(), value),
    );
  }
}

final class _AppSkillInstructionValidator implements SkillInstructionValidator {
  @override
  Future<void> validate(String instructions) async {
    if (instructions.trim().isEmpty || instructions.contains('\u0000')) {
      throw const SkillRegistryException(
        'SKILL_INSTRUCTIONS_INVALID',
        'Skill instruction text must be non-empty plain text.',
      );
    }
  }
}

Map<String, String> _readTrustedWorkerConfig(WorkspaceDatabase database) {
  final rows = database.query(
    'SELECT value_json FROM workspace_settings WHERE setting_key=?',
    ['trusted_python_workers'],
  );
  if (rows.isEmpty || rows.single['value_json'] is! String) return const {};
  try {
    final value = jsonDecode(rows.single['value_json'] as String);
    if (value is! Map) return const {};
    return value
        .map(
          (key, item) => MapEntry(key.toString(), item is String ? item : ''),
        )
        .cast<String, String>();
  } on Object {
    return const {};
  }
}
