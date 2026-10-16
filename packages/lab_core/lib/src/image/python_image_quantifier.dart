import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:lab_core/src/assets/asset_models.dart';
import 'package:lab_core/src/domain/ids.dart';
import 'package:lab_core/src/image/image_analysis_service.dart';
import 'image_calculation_trace.dart';

final class OriginalImagePixelChannel {
  const OriginalImagePixelChannel({required this.index, required this.name, required this.values});
  final int index;
  final String name;
  final List<int> values;
}

final class OriginalImagePixelPlane {
  const OriginalImagePixelPlane({
    required this.width,
    required this.height,
    required this.bitDepth,
    required this.channels,
  });
  final int width;
  final int height;
  final int bitDepth;
  final List<OriginalImagePixelChannel> channels;
}

/// Platform-owned decoder. It reads the exact AssetOpenHandle snapshot; it may
/// decode formats but must not perform local detection, segmentation, or edit.
abstract interface class OriginalImagePixelDecoder {
  Future<OriginalImagePixelPlane> decodeOriginal(AssetOpenHandle source, {int pageIndex = 0});
}

/// Implemented by the trusted calculation runner transport. The only method
/// exposed to this adapter is its narrow, no-path `quantifyRoi` primitive.
abstract interface class CalculationRoiArithmeticBridge {
  Future<Map<String, Object?>> quantifyRoi(Map<String, Object?> params);
}

final class PythonImageQuantifier implements ImageQuantifier {
  PythonImageQuantifier({
    required OriginalImagePixelDecoder decoder,
    required CalculationRoiArithmeticBridge calculation,
    this.maxSelectedPixels = 1000000,
  })  : _decoder = decoder,
        _calculation = calculation;

  final OriginalImagePixelDecoder _decoder;
  final CalculationRoiArithmeticBridge _calculation;
  final int maxSelectedPixels;

  @override
  Future<ImageQuantificationResult> compute({
    required AssetOpenHandle source,
    required AssetValidationLevel validationLevel,
    required ImageMetadata metadata,
    required ImageRoiApproval approval,
  }) async {
    final asset = source.asset;
    if (validationLevel != AssetValidationLevel.verified ||
        source.validationLevel != AssetValidationLevel.verified) {
      throw const ImageServiceException('IMAGE_FULL_SHA_REQUIRED', 'ROI arithmetic requires a fully SHA-verified source snapshot.');
    }
    if (asset.kind != AssetKind.raw || asset.assetId != approval.sourceAssetId ||
        asset.blobSha256 != approval.sourceSha256) {
      throw const ImageServiceException('IMAGE_ROI_APPROVAL_SOURCE_MISMATCH', 'ROI approval is not bound to this raw Asset version.');
    }
    final decoded = await _decoder.decodeOriginal(source, pageIndex: metadata.pageIndex);
    if (decoded.width != metadata.width || decoded.height != metadata.height ||
        decoded.bitDepth != metadata.bitDepth || decoded.width <= 0 || decoded.height <= 0 ||
        metadata.pageIndex < 0 || metadata.pageIndex >= metadata.pageCount) {
      throw const ImageServiceException('IMAGE_DECODE_METADATA_MISMATCH', 'Decoded source metadata differs from the reviewed image.');
    }
    if (approval.channelIndex < 0) {
      throw const ImageServiceException('IMAGE_CHANNEL_INVALID', 'Approved pixel channel is unavailable.');
    }
    final matchingChannels = decoded.channels.where((channel) => channel.index == approval.channelIndex).toList(growable: false);
    if (matchingChannels.length != 1) {
      throw const ImageServiceException('IMAGE_CHANNEL_INVALID', 'Approved pixel channel is unavailable.');
    }
    final channel = matchingChannels.single;
    if (channel.name != approval.channelName ||
        !metadata.channels.contains(channel.name) ||
        channel.values.length != decoded.width * decoded.height) {
      throw const ImageServiceException('IMAGE_CHANNEL_INVALID', 'Decoded pixel channel does not match the approval.');
    }
    if (!approval.signalRoi.inside(decoded.width, decoded.height) ||
        (approval.backgroundRoi != null && !approval.backgroundRoi!.inside(decoded.width, decoded.height))) {
      throw const ImageServiceException('IMAGE_ROI_OUT_OF_BOUNDS', 'Approved ROI is outside the original image bounds.');
    }
    final selectedPixelCount = approval.signalRoi.width * approval.signalRoi.height +
        (approval.backgroundRoi?.width ?? 0) * (approval.backgroundRoi?.height ?? 0);
    if (selectedPixelCount > maxSelectedPixels) {
      throw const ImageServiceException('IMAGE_ROI_TOO_LARGE', 'Approved pixel sample exceeds the calculation RPC limit.');
    }
    final signalPixels = _extract(channel.values, decoded.width, approval.signalRoi);
    final backgroundPixels = approval.backgroundRoi == null
        ? const <int>[]
        : _extract(channel.values, decoded.width, approval.backgroundRoi!);
    final params = <String, Object?>{
      'job_id': newUuidV7(),
      'calculation_id': newUuidV7(),
      'trace_id': newUuidV7(),
      'source': {
        'asset_id': asset.assetId,
        'sha256': asset.blobSha256,
        'asset_kind': 'raw',
        'immutable_original': true,
        'generated_pixels': false,
        'validation_level': validationLevel.name,
        'width': decoded.width,
        'height': decoded.height,
        'bit_depth': decoded.bitDepth,
        'channel_index': channel.index,
        'channel_name': channel.name,
        'signal_roi': approval.signalRoi.toJson(),
        'background_roi': approval.backgroundRoi?.toJson(),
      },
      'approval': {
        'approval_ref': approval.approvalRef.value,
        'approved': true,
        'source_asset_id': approval.sourceAssetId,
        'source_sha256': approval.sourceSha256,
        'signal_roi': approval.signalRoi.toJson(),
        'background_roi': approval.backgroundRoi?.toJson(),
        'channel_index': approval.channelIndex,
        'channel_name': approval.channelName,
        'approved_at_utc': approval.approvedAtUtc.toUtc().toIso8601String(),
        'reviewer': approval.reviewer,
      },
      'signal_pixels': signalPixels,
      'background_pixels': backgroundPixels,
      'background_method': approval.backgroundMethod,
      'context': const {'ai_provenance': []},
    };
    final response = await _calculation.quantifyRoi(params);
    if (response['status'] != 'completed' || response['trace'] is! Map || response['outputs'] is! List) {
      final code = response['error_code'] is String ? response['error_code'] as String : 'IMAGE_QUANTIFICATION_FAILED';
      throw ImageServiceException(code, 'Trusted ROI arithmetic did not return a completed trace.');
    }
    final rawTrace = (response['trace'] as Map).map((key, value) => MapEntry(key.toString(), value));
    final outputs = (response['outputs'] as List).whereType<Map>();
    final output = outputs.cast<Map>().firstWhere(
      (item) => item['key'] == 'integrated_density',
      orElse: () => const {},
    );
    if (output['value'] is! String || rawTrace['trace_id'] is! String) {
      throw const ImageServiceException('IMAGE_TRACE_INVALID', 'ROI result is missing a value or CalculationTrace identifier.');
    }
    final quantificationContext = rawTrace['quantification_context'];
    if (quantificationContext is! Map) {
      throw const ImageServiceException('IMAGE_TRACE_CONTEXT_MISMATCH', 'ROI trace lacks quantification context.');
    }
    rawTrace['quantification_context'] = {
      ...quantificationContext.map((key, value) => MapEntry(key.toString(), value)),
      'source_sha256': asset.blobSha256,
      'page_index': metadata.pageIndex,
      'page_count': metadata.pageCount,
    };
    final traceDocument = ImageCalculationTrace.validateRoiTrace(
      rawTrace,
      binding: ImageCalculationTraceBinding(
        sourceAssetId: asset.assetId,
        sourceSha256: asset.blobSha256,
        validationLevel: validationLevel.name,
        pageIndex: metadata.pageIndex,
        pageCount: metadata.pageCount,
        width: decoded.width,
        height: decoded.height,
        bitDepth: decoded.bitDepth,
        signalPixelsSha256: sha256.convert(utf8.encode(jsonEncode(signalPixels))).toString(),
        backgroundPixelsSha256: approval.backgroundRoi == null
            ? null
            : sha256.convert(utf8.encode(jsonEncode(backgroundPixels))).toString(),
        channelIndex: channel.index,
        channelName: channel.name,
        signalRoi: approval.signalRoi,
        backgroundRoi: approval.backgroundRoi,
        backgroundMethod: approval.backgroundMethod,
        approvalRef: approval.approvalRef.value,
        approvedAtUtc: approval.approvedAtUtc,
        reviewer: approval.reviewer,
      ),
    );
    return ImageQuantificationResult(
      value: output['value'] as String,
      unit: output['unit'] as String?,
      traceId: traceDocument.document['trace_id']! as String,
      trace: traceDocument.toJson(),
    );
  }

  static List<int> _extract(List<int> plane, int imageWidth, ImageRoi roi) {
    final values = <int>[];
    for (var y = roi.y; y < roi.y + roi.height; y++) {
      final start = y * imageWidth + roi.x;
      values.addAll(plane.getRange(start, start + roi.width));
    }
    return List<int>.unmodifiable(values);
  }
}
