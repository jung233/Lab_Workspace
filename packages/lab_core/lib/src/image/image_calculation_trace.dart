import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:lab_core/src/domain/json_value.dart';

import '../calculation/primitive_code_manifest.dart';
import 'image_analysis_service.dart';

/// Immutable, image-specific CalculationTrace v2 document. It deliberately
/// does not pretend to be a Pack CalculationRun: the approved ROI primitive
/// has its own narrow arithmetic contract and source mapping.
final class ImageCalculationTrace {
  ImageCalculationTrace._(this.document, this.contentSha256);

  final Map<String, Object?> document;
  final String contentSha256;

  static ImageCalculationTrace validateRoiTrace(
    Map<String, Object?> sourceTrace, {
    required ImageCalculationTraceBinding binding,
  }) {
    final trace = _deepObject(sourceTrace);
    if (trace['schema_version'] != '2.0' ||
        trace['pack_ref'] != 'lab-workspace.image-roi@1.0.0' ||
        trace['trace_id'] is! String ||
        trace['trace_id'] == '' ||
        trace['calculation_id'] is! String ||
        trace['calculation_id'] == '') {
      throw const ImageServiceException('IMAGE_TRACE_INVALID', 'ROI result lacks a versioned trace ID.');
    }
    final sourceAssets = trace['source_assets'];
    if (sourceAssets is! List || sourceAssets.length != 1 || sourceAssets.single is! Map) {
      throw const ImageServiceException('IMAGE_TRACE_SOURCE_INVALID', 'Image trace must bind exactly one immutable source Asset.');
    }
    final source = _objectMap(sourceAssets.single);
    if (source['asset_id'] != binding.sourceAssetId ||
        source['sha256'] != binding.sourceSha256 ||
        source['validation_level'] != binding.validationLevel) {
      throw const ImageServiceException('IMAGE_TRACE_SOURCE_MISMATCH', 'Image trace source does not match the verified Asset snapshot.');
    }
    final context = _objectMap(trace['quantification_context']);
    final expectedContext = <String, Object?>{
      'source_asset_kind': 'raw',
      'source_immutable': true,
      'generated_pixels_used': false,
      'source_sha256': binding.sourceSha256,
      'channel_index': binding.channelIndex,
      'channel_name': binding.channelName,
      'image_width': binding.width,
      'image_height': binding.height,
      'bit_depth': binding.bitDepth,
      'signal_roi': binding.signalRoi.toJson(),
      'background_roi': binding.backgroundRoi?.toJson(),
      'background_method': binding.backgroundMethod,
      'approval_ref': binding.approvalRef,
      'approved_at_utc': binding.approvedAtUtc.toUtc().toIso8601String(),
      'reviewer': binding.reviewer,
      'page_index': binding.pageIndex,
      'page_count': binding.pageCount,
    };
    // The runner owns arithmetic fields; the host supplies the source hash and
    // selected TIFF page metadata after independently binding them to approval.
    final expectedWithoutPages = Map<String, Object?>.from(expectedContext)
      ..remove('page_index')
      ..remove('page_count');
    if (_canonical(context) != _canonical(expectedWithoutPages)) {
      throw const ImageServiceException('IMAGE_TRACE_CONTEXT_MISMATCH', 'Trace page, channel, ROI, or approval context differs from the reviewed request.');
    }
    trace['quantification_context'] = {...context, 'page_index': binding.pageIndex, 'page_count': binding.pageCount};

    final approval = _objectMap(trace['approval']);
    if (approval['reference'] != binding.approvalRef || approval['kind'] != 'user_approval') {
      throw const ImageServiceException('IMAGE_TRACE_APPROVAL_MISMATCH', 'Image trace does not retain the exact user ROI approval.');
    }
    final primitiveVersions = _objectMap(_objectMap(trace['engine'])['primitive_versions']);
    final buildVersions = _objectMap(trace['primitive_build_versions']);
    final engine = _objectMap(trace['engine']);
    final primitiveHashes = _objectMap(engine['primitive_code_sha256']);
    final expectedOps = binding.backgroundMethod == 'mean_subtract'
        ? const ['image.compute_roi_pixels@1', 'image.background_correct@1']
        : const ['image.compute_roi_pixels@1'];
    if (_sameKeys(primitiveVersions, expectedOps) == false ||
        _sameKeys(buildVersions, expectedOps) == false ||
        _sameKeys(primitiveHashes, expectedOps) == false ||
        buildVersions.values.any((value) => value is! String || value.isEmpty) ||
        primitiveVersions.values.any((value) => value != '1') ||
        primitiveHashes.values.any((value) => value != imageRoiPrimitiveCodeSha256)) {
      throw const ImageServiceException('IMAGE_TRACE_PRIMITIVE_MISMATCH', 'Image trace primitive versions do not match the approved arithmetic path.');
    }
    if (engine['executor_id'] != 'trusted-original-pixel-arithmetic' ||
        engine['python_version'] is! String || (engine['python_version'] as String).isEmpty ||
        engine['platform'] is! String || (engine['platform'] as String).isEmpty) {
      throw const ImageServiceException('IMAGE_TRACE_EXECUTOR_INVALID', 'Image trace lacks trusted executor and runtime identity.');
    }
    final steps = trace['steps'];
    if (steps is! List || steps.length != expectedOps.length) {
      throw const ImageServiceException('IMAGE_TRACE_STEPS_INVALID', 'Image trace does not contain the expected primitive steps.');
    }
    for (var index = 0; index < expectedOps.length; index++) {
      if (steps[index] is! Map) {
        throw const ImageServiceException('IMAGE_TRACE_STEPS_INVALID', 'Image trace step is malformed.');
      }
      final step = _objectMap(steps[index]);
      if (step['seq'] != index + 1 || step['op'] != expectedOps[index] ||
          step['expression'] is! String || (step['expression'] as String).isEmpty ||
          step['substitution'] is! String || (step['substitution'] as String).isEmpty ||
          step['inputs'] is! Map || step['intermediates'] is! Map ||
          step['result'] is! Map || step['results'] is! List || step['warnings'] is! List) {
        throw const ImageServiceException('IMAGE_TRACE_STEPS_INVALID', 'Image trace step is missing formula, parameters, intermediates, results, or warnings.');
      }
      final expectedResultKey = index == 0 ? 'signal_integrated_density' : 'background_corrected_integrated_density';
      final stepInputs = _objectMap(step['inputs']);
      final intermediates = _objectMap(step['intermediates']);
      final result = _objectMap(step['result']);
      final results = step['results'] as List;
      if (result['key'] != expectedResultKey || result['source_ref'] != binding.sourceAssetId ||
          results.length != 1 || results.single is! Map ||
          _canonical(results.single) != _canonical(result)) {
        throw const ImageServiceException('IMAGE_TRACE_RESULT_MAPPING_INVALID', 'Image trace primitive output does not map to its immutable source.');
      }
      final expectedExpression = index == 0
          ? 'signal_sum = sum(original_pixel_values inside the approved signal ROI)'
          : 'corrected_integrated_density = signal_sum - mean(background_pixels) * signal_pixel_count';
      if (step['expression'] != expectedExpression) {
        throw const ImageServiceException('IMAGE_TRACE_FORMULA_INVALID', 'Image trace formula is not the registered ROI arithmetic formula.');
      }
      if (index == 0) {
        if (stepInputs['asset_id'] != binding.sourceAssetId ||
            stepInputs['source_sha256'] != binding.sourceSha256 ||
            stepInputs['channel_index'] != binding.channelIndex ||
            stepInputs['channel_name'] != binding.channelName ||
            stepInputs['signal_roi'] == null || _canonical(stepInputs['signal_roi']) != _canonical(binding.signalRoi.toJson()) ||
            stepInputs['pixel_count'] != binding.signalRoi.width * binding.signalRoi.height ||
            stepInputs['bit_depth'] != binding.bitDepth ||
            stepInputs['pixel_values_sha256'] != binding.signalPixelsSha256 ||
            (intermediates['signal_sum'] is! int && intermediates['signal_sum'] is! String) ||
            result['value'] != intermediates['signal_sum']?.toString()) {
          throw const ImageServiceException('IMAGE_TRACE_INPUT_INVALID', 'Signal primitive parameters or exact pixel sum do not match the reviewed source.');
        }
      } else if (stepInputs['signal_sum']?.toString() != _objectMap(_objectMap(steps.first)['result'])['value'] ||
          stepInputs['signal_pixel_count'] != binding.signalRoi.width * binding.signalRoi.height ||
          stepInputs['background_roi'] == null ||
          _canonical(stepInputs['background_roi']) != _canonical(binding.backgroundRoi?.toJson()) ||
          stepInputs['background_pixel_count'] != binding.backgroundRoi!.width * binding.backgroundRoi!.height ||
          stepInputs['background_pixel_values_sha256'] != binding.backgroundPixelsSha256 ||
          intermediates['background_sum'] is! int ||
          intermediates['background_mean'] is! String ||
          intermediates['background_total'] is! String ||
          result['value'] != intermediates['background_corrected_integrated_density']?.toString()) {
        throw const ImageServiceException('IMAGE_TRACE_INPUT_INVALID', 'Background-correction parameters or result do not match the reviewed ROI.');
      }
    }
    final outputs = trace['outputs'];
    final outputRef = r'$steps.' + '${expectedOps.length}.' +
        (binding.backgroundMethod == 'mean_subtract' ? 'background_corrected_integrated_density' : 'signal_integrated_density');
    if (outputs is! List || outputs.length != 1 || outputs.single is! Map) {
      throw const ImageServiceException('IMAGE_TRACE_OUTPUT_INVALID', 'Image trace must retain one calculated output.');
    }
    final output = _objectMap(outputs.single);
    final stepResult = _objectMap(_objectMap(steps.last)['result']);
    if (output['key'] != 'integrated_density' ||
        output['value'] != stepResult['value'] || output['unit'] != stepResult['unit'] ||
        output['source_ref'] != outputRef) {
      throw const ImageServiceException('IMAGE_TRACE_OUTPUT_MAPPING_INVALID', 'Published image value does not match its final primitive result.');
    }
    final precision = _objectMap(trace['precision']);
    if (precision['decimal_precision'] is! int ||
        precision['decimal_precision'] != 28 ||
        precision['rounding'] is! String ||
        !(precision['rounding'] as String).contains('ROUND_HALF_EVEN') ||
        precision['float_inputs_allowed'] != false) {
      throw const ImageServiceException('IMAGE_TRACE_PRECISION_INVALID', 'Trace must retain decimal precision, rounding, and integer-only input policy.');
    }
    if (trace['warnings'] is! List || trace['created_at_utc'] is! String ||
        DateTime.tryParse(trace['created_at_utc'] as String) == null ||
        trace['engine'] is! Map || trace['inputs'] is! List || trace['execution_environment'] is! Map) {
      throw const ImageServiceException('IMAGE_TRACE_INCOMPLETE', 'Image CalculationTrace is missing execution or warning details.');
    }
    final environment = _objectMap(trace['execution_environment']);
    final dependencies = _objectMap(environment['dependencies']);
    final target = dependencies['runtime_source_target'];
    if (dependencies['runtime_source_manifest_version'] != calculationSourceManifestVersion) {
      throw const ImageServiceException('IMAGE_TRACE_RUNTIME_SOURCE_MISSING', 'Image trace lacks its pinned runtime source manifest.');
    }
    if (target == 'android') {
      if (dependencies['runtime_entry_source_sha256'] != pythonMobileEntrySourceSha256 ||
          dependencies['native_runner_source_sha256'] != androidPythonRunnerSourceSha256 ||
          dependencies['runtime_preparation_source_sha256'] != androidPythonPreparationSourceSha256) {
        throw const ImageServiceException('IMAGE_TRACE_RUNTIME_SOURCE_MISMATCH', 'Android ROI runner source hashes do not match the pinned manifest.');
      }
    } else if (target == 'ios') {
      if (dependencies['runtime_entry_source_sha256'] != pythonMobileEntrySourceSha256 ||
          dependencies['native_runner_source_sha256'] != iosPythonRunnerSourceSha256 ||
          dependencies['runtime_preparation_source_sha256'] != iosPythonPreparationSourceSha256) {
        throw const ImageServiceException('IMAGE_TRACE_RUNTIME_SOURCE_MISMATCH', 'iOS ROI runner source hashes do not match the pinned manifest.');
      }
    } else if (target == 'windows') {
      if (dependencies['runtime_entry_source_sha256'] != pythonDesktopEntrySourceSha256) {
        throw const ImageServiceException('IMAGE_TRACE_RUNTIME_SOURCE_MISMATCH', 'Desktop ROI runner source hash does not match the pinned manifest.');
      }
    } else {
      throw const ImageServiceException('IMAGE_TRACE_RUNTIME_TARGET_INVALID', 'Image ROI trace runtime target is unsupported.');
    }
    if (trace['user_confirmed'] != false || trace['ai_provenance'] is! List ||
        (trace['recalculation_parent_id'] != null && trace['recalculation_parent_id'] is! String)) {
      throw const ImageServiceException('IMAGE_TRACE_PROVENANCE_INVALID', 'Image trace must preserve calculation confirmation and provenance fields.');
    }
    if (trace['errors'] != null && (trace['errors'] is! List || (trace['errors'] as List).isNotEmpty)) {
      throw const ImageServiceException('IMAGE_TRACE_ERRORS_PRESENT', 'A failed ROI trace cannot be published as a successful result.');
    }
    trace['errors'] = const <String>[];
    final canonicalBase = canonicalJson(trace);
    final digest = sha256.convert(utf8.encode(canonicalBase)).toString();
    final frozen = <String, Object?>{...trace, 'content_sha256': digest};
    return ImageCalculationTrace._(Map.unmodifiable(frozen), digest);
  }

  static void verifyPersisted(Object? value) {
    final document = _objectMap(value);
    final savedHash = document['content_sha256'];
    if (savedHash is! String || !RegExp(r'^[a-f0-9]{64}$').hasMatch(savedHash)) {
      throw const ImageServiceException('IMAGE_TRACE_HASH_MISSING', 'Saved image trace has no canonical content SHA-256.');
    }
    final content = Map<String, Object?>.from(document)..remove('content_sha256');
    final actualHash = sha256.convert(utf8.encode(canonicalJson(content))).toString();
    if (actualHash != savedHash) {
      throw const ImageServiceException('IMAGE_TRACE_HASH_MISMATCH', 'Saved image trace failed its canonical SHA-256 check.');
    }
  }

  Map<String, Object?> toJson() => document;
}

final class ImageCalculationTraceBinding {
  const ImageCalculationTraceBinding({
    required this.sourceAssetId,
    required this.sourceSha256,
    required this.validationLevel,
    required this.pageIndex,
    required this.pageCount,
    required this.width,
    required this.height,
    required this.bitDepth,
    required this.signalPixelsSha256,
    required this.backgroundPixelsSha256,
    required this.channelIndex,
    required this.channelName,
    required this.signalRoi,
    required this.backgroundRoi,
    required this.backgroundMethod,
    required this.approvalRef,
    required this.approvedAtUtc,
    required this.reviewer,
  });

  final String sourceAssetId;
  final String sourceSha256;
  final String validationLevel;
  final int pageIndex;
  final int pageCount;
  final int width;
  final int height;
  final int bitDepth;
  final String signalPixelsSha256;
  final String? backgroundPixelsSha256;
  final int channelIndex;
  final String channelName;
  final ImageRoi signalRoi;
  final ImageRoi? backgroundRoi;
  final String backgroundMethod;
  final String approvalRef;
  final DateTime approvedAtUtc;
  final String reviewer;
}

Map<String, Object?> _deepObject(Map<String, Object?> value) =>
    Map<String, Object?>.from(jsonDecode(jsonEncode(value)) as Map);

Map<String, Object?> _objectMap(Object? value) {
  if (value is! Map) {
    throw const ImageServiceException('IMAGE_TRACE_INVALID', 'Image CalculationTrace field must be an object.');
  }
  return value.map((key, entry) => MapEntry(key.toString(), entry));
}

String _canonical(Object? value) => canonicalJson(value);

bool _sameKeys(Map<String, Object?> values, List<String> expected) =>
    values.length == expected.length && values.keys.toSet().containsAll(expected);
