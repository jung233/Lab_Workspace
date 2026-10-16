import 'dart:convert';

import 'package:lab_core/src/ai/ai_provider_service.dart';
import 'package:lab_core/src/ai/models.dart';
import 'package:lab_core/src/ai/provider_adapters.dart';
import 'package:lab_core/src/domain/security.dart';
import 'package:lab_core/src/domain/ids.dart';
import 'package:lab_core/src/assets/asset_gateway.dart';
import 'package:lab_core/src/assets/asset_models.dart';

import 'image_tool_registry.dart';

enum ImageJobMode { imageDocumentation, reportExtraction, scientificQuantification, presentationEdit }
enum ImageJobState { proposed, waitingForModel, reviewRequired, approved, executed, rejected }

class ImageRoi {
  const ImageRoi({required this.x, required this.y, required this.width, required this.height});
  final int x;
  final int y;
  final int width;
  final int height;
  bool inside(int imageWidth, int imageHeight) =>
      x >= 0 && y >= 0 && width > 0 && height > 0 && x + width <= imageWidth && y + height <= imageHeight;
  Map<String, Object?> toJson() => {'x': x, 'y': y, 'width': width, 'height': height};
}

class ImageRoiApproval {
  const ImageRoiApproval({
    required this.approvalRef,
    required this.sourceAssetId,
    required this.sourceSha256,
    required this.signalRoi,
    required this.channelIndex,
    required this.channelName,
    this.pageIndex = 0,
    required this.approvedAtUtc,
    this.backgroundRoi,
    this.backgroundMethod = 'none',
    this.reviewer = 'local_user',
  });
  final ApprovalRef approvalRef;
  final AssetId sourceAssetId;
  final String sourceSha256;
  final ImageRoi signalRoi;
  final ImageRoi? backgroundRoi;
  final int channelIndex;
  final String channelName;
  final int pageIndex;
  final String backgroundMethod;
  final DateTime approvedAtUtc;
  final String reviewer;

  Map<String, Object?> toJson() => {
        'approval_ref': approvalRef.value,
        'source_asset_id': sourceAssetId,
        'source_sha256': sourceSha256,
        'signal_roi': signalRoi.toJson(),
        'background_roi': backgroundRoi?.toJson(),
        'channel_index': channelIndex,
        'channel_name': channelName,
        'page_index': pageIndex,
        'background_method': backgroundMethod,
        'approved_at_utc': approvedAtUtc.toUtc().toIso8601String(),
        'reviewer': reviewer,
        'approved': true,
      };
}

class RoiSuggestion {
  const RoiSuggestion({required this.roi, required this.label, required this.explanation, this.confidence});
  final ImageRoi roi;
  final String label;
  final String explanation;
  final double? confidence;
}

class ImageMetadata {
  const ImageMetadata({
    required this.width,
    required this.height,
    required this.mimeType,
    this.bitDepth = 8,
    this.channels = const ['luminance'],
    this.pageIndex = 0,
    this.pageCount = 1,
  });
  final int width;
  final int height;
  final String mimeType;
  final int bitDepth;
  final List<String> channels;
  final int pageIndex;
  final int pageCount;
}

class ImagePreview {
  const ImagePreview({required this.dataUri, required this.byteLength, required this.width, required this.height});
  final String dataUri;
  final int byteLength;
  final int width;
  final int height;
}

class ImagePlan {
  const ImagePlan({
    required this.jobId,
    required this.sourceAssetId,
    required this.sourceSha256,
    required this.validationLevel,
    required this.mode,
    required this.metadata,
    required this.suggestions,
    required this.state,
    this.approvedRoi,
    this.approvedBackgroundRoi,
    this.approvedChannelIndex,
    this.approvedChannelName,
    this.backgroundMethod,
    this.approvedAtUtc,
    this.approvalRef,
    this.traceId,
    this.derivedAssetId,
  });
  final String jobId;
  final AssetId sourceAssetId;
  final String sourceSha256;
  final AssetValidationLevel validationLevel;
  final ImageJobMode mode;
  final ImageMetadata metadata;
  final List<RoiSuggestion> suggestions;
  final ImageJobState state;
  final ImageRoi? approvedRoi;
  final ImageRoi? approvedBackgroundRoi;
  final int? approvedChannelIndex;
  final String? approvedChannelName;
  final String? backgroundMethod;
  final DateTime? approvedAtUtc;
  final ApprovalRef? approvalRef;
  final String? traceId;
  final AssetId? derivedAssetId;
}

class ImageQuantificationResult {
  const ImageQuantificationResult({
    required this.value,
    required this.unit,
    required this.traceId,
    required this.trace,
    this.derivedAssetId,
  });
  final String value;
  final String? unit;
  final String traceId;
  final Map<String, Object?> trace;
  final AssetId? derivedAssetId;
}

abstract interface class ImagePreviewRenderer {
  Future<ImageMetadata> inspect(AssetOpenHandle source, {int pageIndex = 0});
  Future<ImagePreview> createPreview(AssetOpenHandle source, {required int maxBytes, int pageIndex = 0});
}

abstract interface class ImagePlanRepository {
  Future<void> save(ImagePlan plan);
  Future<ImagePlan?> get(String jobId);
}

abstract interface class ImageQuantifier {
  /// Must read original pixels through [source.openRead], never generated pixels.
  /// Implementations return a trace linked to the original Asset SHA and ROI.
  Future<ImageQuantificationResult> compute({
    required AssetOpenHandle source,
    required AssetValidationLevel validationLevel,
    required ImageMetadata metadata,
    required ImageRoiApproval approval,
  });
}

typedef ImageApprovalValidator = Future<void> Function(
  ApprovalRef approvalRef, {
  required String action,
  required String subjectId,
  required Map<String, Object?> scope,
});

abstract interface class ImageDerivedOutputWriter {
  /// Creates an auditable derived Asset. It must never overwrite [original].
  Future<AssetId> saveReport({
    required AssetId original,
    required String analysisId,
    required String traceId,
    required String report,
  });
}

class ImageAnalysisService {
  ImageAnalysisService({
    required AssetGateway assets,
    required AiProviderService ai,
    required ImagePreviewRenderer previewRenderer,
    required ImagePlanRepository plans,
    required ImageQuantifier quantifier,
    required ImageDerivedOutputWriter derivedOutputs,
    required ImageToolRegistry toolRegistry,
    required ImageApprovalValidator validateApproval,
    this.maxPreviewBytes = 4 * 1024 * 1024,
  })  : _assets = assets,
        _ai = ai,
        _previewRenderer = previewRenderer,
        _plans = plans,
        _quantifier = quantifier,
        _derivedOutputs = derivedOutputs,
        _toolRegistry = toolRegistry,
        _validateApproval = validateApproval;

  final AssetGateway _assets;
  final AiProviderService _ai;
  final ImagePreviewRenderer _previewRenderer;
  final ImagePlanRepository _plans;
  final ImageQuantifier _quantifier;
  final ImageDerivedOutputWriter _derivedOutputs;
  final ImageToolRegistry _toolRegistry;
  final ImageApprovalValidator _validateApproval;
  final int maxPreviewBytes;

  static List<ImageToolDescriptor> get tools => ImageToolRegistry.descriptors;

  Future<ImagePlan> plan({
    required AssetId sourceAssetId,
    required String providerId,
    required ConsentReceipt consent,
    required String purpose,
    int pageIndex = 0,
    ImageJobMode mode = ImageJobMode.scientificQuantification,
  }) async {
    if (mode != ImageJobMode.scientificQuantification) {
      throw const ImageServiceException('IMAGE_MODE_UNSUPPORTED', 'This plan endpoint supports scientific ROI review only.');
    }
      final suggestionDescriptor = _toolRegistry.descriptor('suggest_rois');
    final handle = await _assets.openVerified(sourceAssetId);
    try {
      final asset = handle.asset;
      if (mode == ImageJobMode.scientificQuantification &&
          (asset.kind != AssetKind.raw || asset.metadata['illustrative'] == true)) {
        throw const ImageServiceException('IMAGE_ORIGINAL_REQUIRED', 'Quantification requires a non-illustrative raw original Asset.');
      }
      final metadata = await _previewRenderer.inspect(handle, pageIndex: pageIndex);
      final preview = await _previewRenderer.createPreview(handle, maxBytes: maxPreviewBytes, pageIndex: pageIndex);
      if (preview.byteLength <= 0 || preview.byteLength > maxPreviewBytes ||
          preview.width <= 0 || preview.height <= 0 || !preview.dataUri.startsWith('data:image/')) {
        throw const ImageServiceException('IMAGE_PREVIEW_INVALID', 'Preview is invalid or exceeds the upload limit.');
      }
      final jobId = newUuidV7();
      final suggestedArguments = <Map<String, Object?>>[];
      final suggestionTool = AiToolDefinition(
        name: 'suggest_rois',
        description: 'Propose signal ROI rectangles on the supplied full-frame preview and explain each choice. Never return measurements.',
        parametersSchema: const {
          'type': 'object',
          'properties': {
            'rois': {
              'type': 'array',
              'minItems': 1,
              'maxItems': 16,
              'items': {
                'type': 'object',
                'properties': {
                  'x': {'type': 'integer', 'minimum': 0},
                  'y': {'type': 'integer', 'minimum': 0},
                  'width': {'type': 'integer', 'minimum': 1},
                  'height': {'type': 'integer', 'minimum': 1},
                  'label': {'type': 'string', 'maxLength': 80},
                  'explanation': {'type': 'string', 'minLength': 1, 'maxLength': 1000},
                  'confidence': {'type': 'number', 'minimum': 0, 'maximum': 1},
                },
                'required': ['x', 'y', 'width', 'height', 'label', 'explanation', 'confidence'],
                'additionalProperties': false,
              },
            },
          },
          'required': ['rois'],
          'additionalProperties': false,
        },
        scope: 'image.${suggestionDescriptor.id}',
        requiresApproval: suggestionDescriptor.requiresUserApproval,
        execute: (arguments, {approvalRef}) async {
          suggestedArguments.add(Map.unmodifiable(arguments));
          return {'candidate_count': (arguments['rois'] as List?)?.length ?? 0};
        },
      );
      await _ai.completeVisionWithTools(
        providerId: providerId,
        content: AiContent.assets(
          'Select an image tool and explain proposed signal ROI coordinates. Coordinates must use the full-frame '
          '${preview.width}x${preview.height} preview coordinate system; original is ${metadata.width}x${metadata.height}. '
          'Do not report measurements or numeric results.',
          {sourceAssetId},
          dataClass: 'scientific_image_preview',
          imageDataUri: preview.dataUri,
          uploadBytes: preview.byteLength,
        ),
        consent: consent,
        purpose: purpose,
        tools: [suggestionTool],
      );
      if (suggestedArguments.length != 1) {
        throw const ImageServiceException('IMAGE_TOOL_NOT_SELECTED', 'Model must select and explain exactly one ROI suggestion tool call.');
      }
      final suggestions = _parseSuggestions(suggestedArguments.single, preview, metadata);
      final plan = ImagePlan(
        jobId: jobId,
        sourceAssetId: sourceAssetId,
        sourceSha256: asset.blobSha256,
        validationLevel: handle.validationLevel,
        mode: mode,
        metadata: metadata,
        suggestions: suggestions,
        state: ImageJobState.reviewRequired,
      );
      await _plans.save(plan);
      return plan;
    } on AiProviderException catch (error) {
      if (error.code == 'AI_VISION_UNSUPPORTED' || error.code == 'AI_TOOLS_UNSUPPORTED') {
        final waiting = ImagePlan(
          jobId: newUuidV7(),
          sourceAssetId: sourceAssetId,
          sourceSha256: handle.asset.blobSha256,
          validationLevel: handle.validationLevel,
          mode: mode,
          metadata: await _previewRenderer.inspect(handle, pageIndex: pageIndex),
          suggestions: const [],
          state: ImageJobState.waitingForModel,
        );
        await _plans.save(waiting);
        return waiting;
      }
      rethrow;
    } finally {
      await handle.close();
    }
  }

  Future<ImagePlan> approveRoi({
    required String jobId,
    required ImageRoi signalRoi,
    required int channelIndex,
    required String channelName,
    int pageIndex = 0,
    required ApprovalRef approvalRef,
    ImageRoi? backgroundRoi,
    String backgroundMethod = 'none',
  }) async {
    final old = await _requirePlan(jobId);
    if (old.state != ImageJobState.reviewRequired ||
        pageIndex != old.metadata.pageIndex ||
        !signalRoi.inside(old.metadata.width, old.metadata.height) ||
        (backgroundRoi != null && !backgroundRoi.inside(old.metadata.width, old.metadata.height)) ||
        channelIndex < 0 || channelIndex >= old.metadata.channels.length ||
        old.metadata.channels[channelIndex] != channelName ||
        !{'none', 'mean_subtract'}.contains(backgroundMethod) ||
        (backgroundMethod == 'mean_subtract' && backgroundRoi == null)) {
      throw const ImageServiceException('IMAGE_ROI_REVIEW_REQUIRED', 'ROI is invalid or the plan is not awaiting review.');
    }
    final now = DateTime.now().toUtc();
    final approval = ImageRoiApproval(
      approvalRef: approvalRef,
      sourceAssetId: old.sourceAssetId,
      sourceSha256: old.sourceSha256,
      signalRoi: signalRoi,
      backgroundRoi: backgroundRoi,
      channelIndex: channelIndex,
      channelName: channelName,
      pageIndex: pageIndex,
      backgroundMethod: backgroundMethod,
      approvedAtUtc: now,
    );
    await _validateApproval(
      approvalRef,
      action: 'image.roi.approve',
      subjectId: jobId,
      scope: approval.toJson()..remove('approval_ref')..remove('approved')..remove('approved_at_utc'),
    );
    final approved = ImagePlan(
      jobId: old.jobId,
      sourceAssetId: old.sourceAssetId,
      sourceSha256: old.sourceSha256,
      validationLevel: old.validationLevel,
      mode: old.mode,
      metadata: old.metadata,
      suggestions: old.suggestions,
      state: ImageJobState.approved,
      approvedRoi: signalRoi,
      approvedBackgroundRoi: backgroundRoi,
      approvedChannelIndex: channelIndex,
      approvedChannelName: channelName,
      backgroundMethod: backgroundMethod,
      approvedAtUtc: now,
      approvalRef: approvalRef,
    );
    await _plans.save(approved);
    return approved;
  }

  Future<ImagePlan> executeQuantification(String jobId) async {
    final plan = await _requirePlan(jobId);
    if (plan.state != ImageJobState.approved || plan.approvedRoi == null || plan.approvalRef == null ||
        plan.mode != ImageJobMode.scientificQuantification) {
      throw const ImageServiceException('IMAGE_ROI_REVIEW_REQUIRED', 'A user-approved ROI is required before quantification.');
    }
    final approval = ImageRoiApproval(
      approvalRef: plan.approvalRef!,
      sourceAssetId: plan.sourceAssetId,
      sourceSha256: plan.sourceSha256,
      signalRoi: plan.approvedRoi!,
      backgroundRoi: plan.approvedBackgroundRoi,
      channelIndex: plan.approvedChannelIndex!,
      channelName: plan.approvedChannelName!,
      pageIndex: plan.metadata.pageIndex,
      backgroundMethod: plan.backgroundMethod ?? 'none',
      approvedAtUtc: plan.approvedAtUtc ?? DateTime.now().toUtc(),
    );
    await _validateApproval(
      plan.approvalRef!,
      action: 'image.roi.approve',
      subjectId: jobId,
      scope: approval.toJson()..remove('approval_ref')..remove('approved')..remove('approved_at_utc'),
    );
    _toolRegistry.validateRequest(ImageToolRequest(
      toolId: 'compute_roi_pixels',
      assetId: plan.sourceAssetId,
      sourceSha256: plan.sourceSha256,
      mode: plan.mode,
      arguments: plan.approvedRoi!.toJson(),
      approvalRef: plan.approvalRef,
      roi: plan.approvedRoi,
    ));
    final handle = await _assets.openVerified(plan.sourceAssetId);
    try {
      if (handle.asset.blobSha256 != plan.sourceSha256) {
        throw const ImageServiceException('ASSET_SHA_MISMATCH', 'Source image changed after ROI review.');
      }
      if (handle.validationLevel != AssetValidationLevel.verified) {
        throw const ImageServiceException('IMAGE_FULL_SHA_REQUIRED', 'Quantification requires full SHA-256 verification of the opened snapshot.');
      }
      if (handle.asset.kind != AssetKind.raw || handle.asset.metadata['illustrative'] == true) {
        throw const ImageServiceException('IMAGE_ORIGINAL_REQUIRED', 'Quantification requires the unchanged raw original Asset.');
      }
      final result = await _quantifier.compute(
        source: handle,
        validationLevel: handle.validationLevel,
        metadata: plan.metadata,
        approval: approval,
      );
      final report = jsonEncode({
        'source_asset_id': plan.sourceAssetId,
        'source_sha256': plan.sourceSha256,
        'validation_level': handle.validationLevel.name,
        'roi': plan.approvedRoi!.toJson(),
        'background_roi': plan.approvedBackgroundRoi?.toJson(),
        'background_method': plan.backgroundMethod ?? 'none',
        'page_index': plan.metadata.pageIndex,
        'channel_index': plan.approvedChannelIndex,
        'channel_name': plan.approvedChannelName,
        'approval_ref': plan.approvalRef!.value,
        'approved_at_utc': plan.approvedAtUtc?.toUtc().toIso8601String(),
        'value': result.value,
        'unit': result.unit,
        'trace_id': result.traceId,
        'trace': result.trace,
        'generated_pixels_used_for_quantitation': false,
      });
      final derivedId = await _derivedOutputs.saveReport(
        original: plan.sourceAssetId,
        analysisId: plan.jobId,
        traceId: result.traceId,
        report: report,
      );
      final completed = ImagePlan(
        jobId: plan.jobId,
        sourceAssetId: plan.sourceAssetId,
        sourceSha256: plan.sourceSha256,
        validationLevel: handle.validationLevel,
        mode: plan.mode,
        metadata: plan.metadata,
        suggestions: plan.suggestions,
        state: ImageJobState.executed,
        approvedRoi: plan.approvedRoi,
        approvedBackgroundRoi: plan.approvedBackgroundRoi,
        approvedChannelIndex: plan.approvedChannelIndex,
        approvedChannelName: plan.approvedChannelName,
        backgroundMethod: plan.backgroundMethod,
        approvedAtUtc: plan.approvedAtUtc,
        approvalRef: plan.approvalRef,
        traceId: result.traceId,
        derivedAssetId: derivedId,
      );
      await _plans.save(completed);
      return completed;
    } finally {
      await handle.close();
    }
  }

  Future<ImagePlan> _requirePlan(String id) async =>
      await _plans.get(id) ?? (throw ImageServiceException('IMAGE_PLAN_NOT_FOUND', 'Image plan $id was not found.'));

  static List<RoiSuggestion> _parseSuggestions(Map<String, Object?> decoded, ImagePreview preview, ImageMetadata metadata) {
    try {
      if (decoded['rois'] is! List) throw const FormatException();
      final results = <RoiSuggestion>[];
      for (final item in decoded['rois'] as List) {
        if (item is! Map) continue;
        final roi = ImageRoi(
          x: item['x'] as int,
          y: item['y'] as int,
          width: item['width'] as int,
          height: item['height'] as int,
        );
        if (!roi.inside(preview.width, preview.height)) continue;
        final mapped = ImageRoi(
          x: (roi.x * metadata.width / preview.width).round(),
          y: (roi.y * metadata.height / preview.height).round(),
          width: (roi.width * metadata.width / preview.width).round().clamp(1, metadata.width).toInt(),
          height: (roi.height * metadata.height / preview.height).round().clamp(1, metadata.height).toInt(),
        );
        if (!mapped.inside(metadata.width, metadata.height)) continue;
        final confidence = item['confidence'];
        results.add(RoiSuggestion(
          roi: mapped,
          label: item['label'] is String ? item['label'] as String : 'ROI',
          explanation: item['explanation'] is String ? item['explanation'] as String : '',
          confidence: confidence is num ? confidence.toDouble() : null,
        ));
      }
      return results;
    } on Object {
      throw const ImageServiceException('IMAGE_PLAN_INVALID', 'Model did not return a valid ROI plan.');
    }
  }
}

class ImageServiceException implements Exception {
  const ImageServiceException(this.code, this.message);
  final String code;
  final String message;
  @override
  String toString() => '$code: $message';
}
