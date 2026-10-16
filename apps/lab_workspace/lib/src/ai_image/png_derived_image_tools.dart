import 'dart:convert';
import 'package:lab_core/lab_core.dart';

import 'png_image_platform.dart';

/// Approved, immutable-original image transformations. Outputs are always new
/// derived Assets; this class has no quantitative decoder entry point.
final class PngDerivedImageTools {
  const PngDerivedImageTools({required this.assets, required this.renderer, required this.database});

  final AssetGateway assets;
  final ScientificImagePlatform renderer;
  final WorkspaceDatabase database;

  Future<AssetId> transform({
    required AssetId sourceAssetId,
    required String sourceSha256,
    required ImageRoi roi,
    required String operation,
    required ApprovalRef approvalRef,
    int pageIndex = 0,
  }) async {
    if (operation != 'crop_derived' && operation != 'render_overlay') {
      throw const ImageServiceException('IMAGE_TOOL_UNSUPPORTED', 'Only reviewed crop and ROI overlay outputs are supported.');
    }
    final scope = _approvalScope(operation, sourceAssetId, sourceSha256, roi, pageIndex);
    _requireApproval(
      approvalRef,
      action: 'image.derived.create',
      subjectType: 'image_derived',
      subjectId: '$sourceAssetId@$sourceSha256',
      scope: scope,
    );
    final source = await assets.openVerified(sourceAssetId);
    try {
      if (source.asset.kind != AssetKind.raw || source.asset.blobSha256 != sourceSha256) {
        throw const ImageServiceException('ASSET_SHA_MISMATCH', 'The reviewed image no longer matches the original Asset.');
      }
      final bytes = await renderer.renderDerivedRoi(source, roi: roi, overlay: operation == 'render_overlay', pageIndex: pageIndex);
      final imported = await assets.importFile(
        AssetImportSource(
          displayName: '$operation-${sourceAssetId.substring(0, sourceAssetId.length.clamp(0, 8).toInt())}.png',
          mediaType: 'image/png',
          content: Stream<List<int>>.value(bytes),
          sizeHint: bytes.length,
        ),
        kind: AssetKind.derived,
        parentAssetId: sourceAssetId,
        metadata: {
          'derived_operation': operation,
          'source_sha256': sourceSha256,
          'roi': roi.toJson(),
          'page_index': pageIndex,
          'generated_pixels_used_for_quantitation': false,
          'approval_ref': approvalRef.value,
        },
      );
      bytes.fillRange(0, bytes.length, 0);
      return imported.asset.assetId;
    } finally {
      await source.close();
    }
  }

  Future<AssetId> exportRoiReport({
    required AssetId sourceAssetId,
    required String sourceSha256,
    required ImageRoi roi,
    required ApprovalRef approvalRef,
    required ImageMetadata metadata,
    int pageIndex = 0,
  }) async {
    const operation = 'export_image_report';
    _requireApproval(
      approvalRef,
      action: 'image.derived.create',
      subjectType: 'image_derived',
      subjectId: '$sourceAssetId@$sourceSha256',
      scope: _approvalScope(operation, sourceAssetId, sourceSha256, roi, pageIndex),
    );
    final source = await assets.openVerified(sourceAssetId);
    try {
      if (source.asset.kind != AssetKind.raw || source.asset.blobSha256 != sourceSha256) {
        throw const ImageServiceException('ASSET_SHA_MISMATCH', 'The reviewed image no longer matches the original Asset.');
      }
    } finally {
      await source.close();
    }
    final report = utf8.encode(jsonEncode({
      'source_asset_id': sourceAssetId,
      'source_sha256': sourceSha256,
      'operation': operation,
      'metadata': {'width': metadata.width, 'height': metadata.height, 'bit_depth': metadata.bitDepth, 'channels': metadata.channels, 'page_index': pageIndex},
      'roi': roi.toJson(),
      'generated_pixels_used_for_quantitation': false,
      'approval_ref': approvalRef.value,
    }));
    final imported = await assets.importFile(
      AssetImportSource(
        displayName: 'image-review-${sourceAssetId.substring(0, sourceAssetId.length.clamp(0, 8).toInt())}.json',
        mediaType: 'application/json',
        content: Stream<List<int>>.value(report),
        sizeHint: report.length,
      ),
      kind: AssetKind.report,
      parentAssetId: sourceAssetId,
      metadata: {'derived_operation': operation, 'generated_pixels_used_for_quantitation': false},
    );
    report.fillRange(0, report.length, 0);
    return imported.asset.assetId;
  }

  void _requireApproval(
    ApprovalRef ref, {
    required String action,
    required String subjectType,
    required String subjectId,
    required Map<String, Object?> scope,
  }) {
    database.transaction((tx) {
      tx.requireApproval(
        approvalRef: ref,
        action: action,
        subjectType: subjectType,
        subjectId: subjectId,
        atUtc: DateTime.now().toUtc(),
        requiredScope: scope,
      );
      return null;
    });
    final rows = database.query('SELECT scope_json FROM approval_receipts WHERE approval_ref=?', [ref.value]);
    if (rows.isEmpty || _canonical(jsonDecode(rows.single['scope_json'] as String)) != _canonical(scope)) {
      throw const ImageServiceException('APPROVAL_SCOPE_MISMATCH', 'Approval does not match the exact derived-image operation.');
    }
  }

  static Map<String, Object?> _approvalScope(String operation, AssetId id, String sha, ImageRoi roi, int pageIndex) => {
    'operation': operation,
    'source_asset_id': id,
    'source_sha256': sha,
    'roi': roi.toJson(),
    'page_index': pageIndex,
    'generated_pixels_used_for_quantitation': false,
  };

  static String _canonical(Object? value) {
    if (value is Map) {
      final keys = value.keys.map((key) => key.toString()).toList()..sort();
      return '{${keys.map((key) => '${jsonEncode(key)}:${_canonical(value[key])}').join(',')}}';
    }
    if (value is List) return '[${value.map(_canonical).join(',')}]';
    return jsonEncode(value);
  }
}
