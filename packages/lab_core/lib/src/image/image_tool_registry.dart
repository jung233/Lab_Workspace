import 'package:lab_core/src/domain/security.dart';
import 'package:lab_core/src/assets/asset_models.dart';

import 'image_analysis_service.dart';

class ImageToolDescriptor {
  const ImageToolDescriptor({required this.id, required this.requiresUserApproval, required this.quantitative});
  final String id;
  final bool requiresUserApproval;
  final bool quantitative;
}

class ImageToolRequest {
  const ImageToolRequest({
    required this.toolId,
    required this.assetId,
    required this.sourceSha256,
    required this.mode,
    required this.arguments,
    this.approvalRef,
    this.roi,
    this.generatedPixels = false,
  });
  final String toolId;
  final AssetId assetId;
  final String sourceSha256;
  final ImageJobMode mode;
  final Map<String, Object?> arguments;
  final ApprovalRef? approvalRef;
  final ImageRoi? roi;
  final bool generatedPixels;
}

class ImageToolResult {
  const ImageToolResult(this.value);
  final Object? value;
}

typedef ImageToolHandler = Future<ImageToolResult> Function(ImageToolRequest request);

class ImageToolRegistry {
  ImageToolRegistry({Map<String, ImageToolHandler> handlers = const {}})
      : _handlers = Map.unmodifiable(handlers);

  static const descriptors = <ImageToolDescriptor>[
    ImageToolDescriptor(id: 'inspect_metadata', requiresUserApproval: false, quantitative: false),
    ImageToolDescriptor(id: 'create_model_preview', requiresUserApproval: false, quantitative: false),
    // A model proposal is not a local operation. It remains untrusted until a
    // separate user review approves exact geometry, channel, and source SHA.
    ImageToolDescriptor(id: 'suggest_rois', requiresUserApproval: false, quantitative: false),
    ImageToolDescriptor(id: 'render_overlay', requiresUserApproval: true, quantitative: false),
    ImageToolDescriptor(id: 'crop_derived', requiresUserApproval: true, quantitative: false),
    ImageToolDescriptor(id: 'compute_roi_pixels', requiresUserApproval: true, quantitative: true),
    ImageToolDescriptor(id: 'save_derived_asset', requiresUserApproval: true, quantitative: false),
    ImageToolDescriptor(id: 'export_image_report', requiresUserApproval: true, quantitative: false),
  ];

  final Map<String, ImageToolHandler> _handlers;

  ImageToolDescriptor descriptor(String id) => descriptors.firstWhere(
        (item) => item.id == id,
        orElse: () => throw ImageToolRegistryException('IMAGE_TOOL_UNSUPPORTED', 'Tool $id is not registered.'),
      );

  ImageToolDescriptor validateRequest(ImageToolRequest request) {
    final definition = descriptor(request.toolId);
    if (definition.requiresUserApproval && request.approvalRef == null) {
      throw const ImageToolRegistryException('IMAGE_TOOL_APPROVAL_REQUIRED', 'This image operation requires user approval.');
    }
    if (definition.quantitative && request.mode != ImageJobMode.scientificQuantification) {
      throw const ImageToolRegistryException('IMAGE_QUANTIFICATION_MODE_INVALID', 'Pixel arithmetic is limited to scientific quantification mode.');
    }
    if (definition.quantitative && (request.generatedPixels || request.roi == null)) {
      throw const ImageToolRegistryException('IMAGE_GENERATED_QUANTITATION_FORBIDDEN', 'Quantitation requires a reviewed ROI on original pixels.');
    }
    return definition;
  }

  Future<ImageToolResult> execute(ImageToolRequest request) async {
    validateRequest(request);
    final handler = _handlers[request.toolId];
    if (handler == null) {
      throw ImageToolRegistryException('IMAGE_TOOL_UNAVAILABLE', 'Registered tool ${request.toolId} has no approved implementation.');
    }
    return handler(request);
  }
}

class ImageToolRegistryException implements Exception {
  const ImageToolRegistryException(this.code, this.message);
  final String code;
  final String message;
  @override
  String toString() => '$code: $message';
}
