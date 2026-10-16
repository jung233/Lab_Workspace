import 'dart:convert';

import 'package:lab_core/src/image/image_analysis_service.dart';
import 'package:lab_core/src/assets/asset_models.dart';
import 'package:lab_core/src/persistence/workspace_database.dart';
import 'package:lab_core/src/domain/security.dart';

/// Persists review state beside the source Asset. The original Asset row and
/// blob are never updated; output identifiers refer to newly derived Assets.
final class SqliteImagePlanRepository implements ImagePlanRepository {
  SqliteImagePlanRepository(this.database);

  final WorkspaceDatabase database;

  @override
  Future<void> save(ImagePlan plan) async {
    final candidates = [
      for (final item in plan.suggestions)
        {
          ...item.roi.toJson(),
          'label': item.label,
          'explanation': item.explanation,
          'confidence': item.confidence,
        }
    ];
    final approved = plan.approvedRoi == null
        ? null
        : <String, Object?>{
            ...plan.approvedRoi!.toJson(),
            'background_roi': plan.approvedBackgroundRoi?.toJson(),
            'channel_index': plan.approvedChannelIndex,
            'channel_name': plan.approvedChannelName,
            'background_method': plan.backgroundMethod,
          };
    database.transaction((tx) {
      tx.execute(
        '''INSERT INTO analysis_runs(
             analysis_id,source_asset_id,model_job_id,roi_approval_json,status,approved_at_utc,created_at_utc,calculation_trace_id)
           VALUES(?,?,?,?,?,?,?,?)
           ON CONFLICT(analysis_id) DO UPDATE SET
             source_asset_id=excluded.source_asset_id,model_job_id=excluded.model_job_id,
             roi_approval_json=excluded.roi_approval_json,status=excluded.status,
             approved_at_utc=excluded.approved_at_utc,
             calculation_trace_id=excluded.calculation_trace_id''',
        [
          plan.jobId,
          plan.sourceAssetId,
          plan.jobId,
          approved == null ? null : jsonEncode(approved),
          plan.state.name,
          plan.approvedAtUtc?.toUtc().toIso8601String(),
          DateTime.now().toUtc().toIso8601String(),
          plan.traceId,
        ],
      );
      tx.execute(
        '''INSERT INTO image_roi_reviews(
             review_id,analysis_id,original_asset_id,source_sha256,validation_level,
             candidate_rois_json,approved_rois_json,approval_ref,approved_at_utc,
             quantification_trace_id,trace_asset_id,derived_asset_ids_json,state)
           VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)
           ON CONFLICT(review_id) DO UPDATE SET
             source_sha256=excluded.source_sha256,validation_level=excluded.validation_level,
             candidate_rois_json=excluded.candidate_rois_json,
             approved_rois_json=excluded.approved_rois_json,approval_ref=excluded.approval_ref,
             approved_at_utc=excluded.approved_at_utc,
             quantification_trace_id=excluded.quantification_trace_id,
             trace_asset_id=excluded.trace_asset_id,
             derived_asset_ids_json=excluded.derived_asset_ids_json,state=excluded.state''',
        [
          plan.jobId,
          plan.jobId,
          plan.sourceAssetId,
          plan.sourceSha256,
          plan.validationLevel.name,
          jsonEncode({
            'mode': plan.mode.name,
            'metadata': {
              'width': plan.metadata.width,
              'height': plan.metadata.height,
              'mime_type': plan.metadata.mimeType,
              'bit_depth': plan.metadata.bitDepth,
              'channels': plan.metadata.channels,
              'page_index': plan.metadata.pageIndex,
              'page_count': plan.metadata.pageCount,
            },
            'suggestions': candidates,
          }),
          approved == null ? null : jsonEncode([approved]),
          plan.approvalRef?.value,
          plan.approvedAtUtc?.toUtc().toIso8601String(),
          plan.traceId,
          plan.traceId == null ? null : plan.derivedAssetId,
          jsonEncode(plan.derivedAssetId == null ? const [] : [plan.derivedAssetId]),
          _persistedState(plan.state),
        ],
      );
      return null;
    });
  }

  @override
  Future<ImagePlan?> get(String jobId) async {
    final rows = database.query(
      '''SELECT r.*,a.status AS analysis_status
         FROM image_roi_reviews r JOIN analysis_runs a ON a.analysis_id=r.analysis_id
         WHERE r.review_id=?''',
      [jobId],
    );
    if (rows.isEmpty) return null;
    final row = rows.single;
    final candidatesDocument = jsonDecode(row['candidate_rois_json'] as String);
    final candidateMap = candidatesDocument is Map ? candidatesDocument : const {};
    final candidates = candidateMap['suggestions'] is List
        ? candidateMap['suggestions'] as List
        : candidatesDocument as List;
    final metadataMap = candidateMap['metadata'] is Map ? candidateMap['metadata'] as Map : const {};
    final modeName = candidateMap['mode'] as String? ?? ImageJobMode.scientificQuantification.name;
    final approvedJson = row['approved_rois_json'] as String?;
    final approvedList = approvedJson == null ? const [] : jsonDecode(approvedJson) as List;
    final analysisStatus = row['analysis_status'] as String;
    final state = _state(analysisStatus, row['state'] as String);
    final traceAssetId = row['trace_asset_id'] as String?;
    final derived = traceAssetId ?? (((jsonDecode(row['derived_asset_ids_json'] as String) as List?) ?? const [])
        .whereType<String>()
        .firstOrNull);
    return ImagePlan(
      jobId: jobId,
      sourceAssetId: row['original_asset_id'] as String,
      sourceSha256: row['source_sha256'] as String,
      validationLevel: AssetValidationLevel.values.byName(row['validation_level'] as String),
      mode: ImageJobMode.values.byName(modeName),
      metadata: ImageMetadata(
        width: metadataMap['width'] is int ? metadataMap['width'] as int : 0,
        height: metadataMap['height'] is int ? metadataMap['height'] as int : 0,
        mimeType: metadataMap['mime_type'] is String ? metadataMap['mime_type'] as String : 'application/octet-stream',
        bitDepth: metadataMap['bit_depth'] is int ? metadataMap['bit_depth'] as int : 8,
        channels: (metadataMap['channels'] as List?)?.whereType<String>().toList(growable: false) ?? const ['luminance'],
        pageIndex: metadataMap['page_index'] is int ? metadataMap['page_index'] as int : 0,
        pageCount: metadataMap['page_count'] is int ? metadataMap['page_count'] as int : 1,
      ),
      suggestions: [for (final item in candidates) if (item is Map) _suggestion(item)],
      state: state,
      approvedRoi: approvedList.isEmpty ? null : _roi(approvedList.first as Map),
      approvedBackgroundRoi: approvedList.isNotEmpty && (approvedList.first as Map)['background_roi'] is Map
          ? _roi((approvedList.first as Map)['background_roi'] as Map)
          : null,
      approvedChannelIndex: approvedList.isNotEmpty && (approvedList.first as Map)['channel_index'] is int
          ? (approvedList.first as Map)['channel_index'] as int
          : null,
      approvedChannelName: approvedList.isNotEmpty && (approvedList.first as Map)['channel_name'] is String
          ? (approvedList.first as Map)['channel_name'] as String
          : null,
      backgroundMethod: approvedList.isNotEmpty && (approvedList.first as Map)['background_method'] is String
          ? (approvedList.first as Map)['background_method'] as String
          : null,
      approvalRef: row['approval_ref'] is String ? ApprovalRef(row['approval_ref'] as String) : null,
      approvedAtUtc: row['approved_at_utc'] is String
          ? DateTime.parse(row['approved_at_utc'] as String).toUtc()
          : null,
      traceId: row['quantification_trace_id'] as String?,
      derivedAssetId: derived,
    );
  }

  static RoiSuggestion _suggestion(Map item) => RoiSuggestion(
        roi: _roi(item),
        label: item['label'] is String ? item['label'] as String : 'ROI',
        explanation: item['explanation'] is String ? item['explanation'] as String : '',
        confidence: item['confidence'] is num ? (item['confidence'] as num).toDouble() : null,
      );

  static ImageRoi _roi(Map item) => ImageRoi(
        x: item['x'] as int,
        y: item['y'] as int,
        width: item['width'] as int,
        height: item['height'] as int,
      );

  static String _persistedState(ImageJobState state) => switch (state) {
        ImageJobState.waitingForModel => 'proposed',
        ImageJobState.reviewRequired => 'proposed',
        ImageJobState.rejected => 'rejected',
        _ => state.name,
      };

  static ImageJobState _state(String analysis, String review) => switch (analysis) {
        'waitingForModel' => ImageJobState.waitingForModel,
        'approved' => ImageJobState.approved,
        'executed' => ImageJobState.executed,
        'rejected' => ImageJobState.rejected,
        _ => switch (review) {
            'approved' => ImageJobState.approved,
            'executed' => ImageJobState.executed,
            'rejected' => ImageJobState.rejected,
            _ => ImageJobState.reviewRequired,
          },
      };
}

/// Verifies the durable approval reference and exact reviewed geometry scope.
final class SqliteImageApprovalValidator {
  const SqliteImageApprovalValidator(this.database);
  final WorkspaceDatabase database;

  Future<void> call(
    ApprovalRef approvalRef, {
    required String action,
    required String subjectId,
    required Map<String, Object?> scope,
  }) async {
    final rows = database.query(
      '''SELECT action,subject_type,subject_id,scope_json,expires_at_utc,revoked_at_utc,
                issuer_device_id,authority_generation
         FROM approval_receipts WHERE approval_ref=?''',
      [approvalRef.value],
    );
    if (rows.isEmpty) throw const ImageServiceException('APPROVAL_REQUIRED', 'A stored ROI approval is required.');
    final row = rows.single;
    final expires = row['expires_at_utc'] is String ? DateTime.tryParse(row['expires_at_utc'] as String) : null;
    if (row['action'] != action || row['subject_type'] != 'image_roi_review' || row['subject_id'] != subjectId ||
        row['revoked_at_utc'] != null ||
        row['issuer_device_id'] != database.activeDeviceId ||
        row['authority_generation'] != database.authorityGeneration ||
        (row['expires_at_utc'] != null && expires == null) ||
        (expires != null && !DateTime.now().toUtc().isBefore(expires.toUtc()))) {
      throw const ImageServiceException('APPROVAL_SCOPE_MISMATCH', 'Stored approval does not cover this ROI review.');
    }
    final storedScope = jsonDecode(row['scope_json'] as String);
    if (storedScope is! Map || _canonical(storedScope) != _canonical(scope)) {
      throw const ImageServiceException('APPROVAL_SCOPE_MISMATCH', 'Stored approval geometry differs from the requested ROI.');
    }
  }
}

String _canonical(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((key) => key.toString()).toList()..sort();
    return '{${keys.map((key) => '${jsonEncode(key)}:${_canonical(value[key])}').join(',')}}';
  }
  if (value is List) return '[${value.map(_canonical).join(',')}]';
  return jsonEncode(value);
}

extension _FirstOrNull<E> on Iterable<E> {
  E? get firstOrNull => isEmpty ? null : first;
}
