import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:lab_core/lab_core.dart';

/// Uses the platform's bundled trusted Python runtime when its capability
/// probe succeeds; otherwise the core's portable typed primitive executor is
/// selected. The channel accepts JSON-RPC envelopes only, never source code or
/// arbitrary filesystem paths.
final class PlatformCalculationExecutor implements CalculationExecutor {
  PlatformCalculationExecutor({
    required this.platform,
    MethodChannel? channel,
    DartCalculationExecutor? fallback,
  }) : _channel =
           channel ?? const MethodChannel('lab_workspace/calculation_executor'),
       _fallback = fallback ?? DartCalculationExecutor(platform: platform);

  final String platform;
  final MethodChannel _channel;
  final DartCalculationExecutor _fallback;
  CalculationCapabilities? _nativeCapabilities;
  int _rpcId = 0;

  @override
  Future<CalculationCapabilities> probe() async {
    final response = await _call('probe', const <String, Object?>{});
    if (response == null) return await _fallback.probe();
    try {
      final result = response['result'];
      if (result is! Map) return await _fallback.probe();
      final values = Map<String, Object?>.from(result);
      final capabilities = CalculationCapabilities(
        platform: values['platform'] as String? ?? platform,
        executorId: values['executor_id'] as String? ?? 'lab-workspace-python',
        available: values['available'] == true,
        bundledExecutor: values['bundled_executor'] == true,
        pythonRuntime: values['python_runtime'] as String? ?? 'unknown',
        supportedOperations:
            (values['supported_operations'] as List? ?? const [])
                .whereType<String>(),
        supportsCancellation: values['supports_cancellation'] == true,
        unsupportedReason: values['unsupported_reason'] as String?,
      );
      _nativeCapabilities = capabilities.available ? capabilities : null;
      return capabilities.available ? capabilities : await _fallback.probe();
    } on Object {
      _nativeCapabilities = null;
      return await _fallback.probe();
    }
  }

  @override
  Future<CalculationExecutionResult> execute(
    CalculationExecutionRequest request, {
    required bool Function() isCancelled,
  }) async {
    if (isCancelled()) throw const FormatException('CALC_CANCELLED');
    var capabilities = _nativeCapabilities;
    if (capabilities == null) {
      await probe();
      capabilities = _nativeCapabilities;
    }
    if (capabilities == null ||
        !_supportsPack(capabilities, request.pack.document)) {
      return _fallback.execute(request, isCancelled: isCancelled);
    }

    final response = await _call('execute', {
      'job': {
        'job_id': request.calculationId,
        'calculation_id': request.calculationId,
        'trace_id': request.traceId,
        'pack': {
          'document': request.pack.document,
          'approval': {
            'approval_ref': request.approvalRef,
            'kind': request.approvalKind,
          },
          'sha256': request.pack.contentSha256,
        },
        'inputs': request.inputSnapshot,
        'source_assets': request.sourceAssets,
        'context': {
          'run_id': request.runId,
          'sample_id': request.sampleId,
          'step_id': request.stepId,
          'parent_calculation_id': request.parentCalculationId,
        },
      },
    });
    if (isCancelled()) throw const FormatException('CALC_CANCELLED');
    final result = response?['result'];
    if (result is! Map || result['status'] == 'unsupported') {
      return _fallback.execute(request, isCancelled: isCancelled);
    }
    if (result['status'] == 'cancelled') {
      throw const FormatException('CALC_CANCELLED');
    }
    if (result['status'] != 'completed' || result['trace'] is! Map) {
      final code =
          result['error_code'] as String? ?? 'NATIVE_CALCULATION_FAILED';
      throw FormatException(
        '$code: ${result['message'] ?? 'Native calculation failed.'}',
      );
    }
    final trace = CalculationTrace(
      document: Map<String, Object?>.from(result['trace'] as Map),
    );
    final outputs = <String, Object?>{};
    final rawOutputs = trace.document['outputs'];
    if (rawOutputs is! List) {
      throw const FormatException(
        'Native CalculationTrace outputs are malformed.',
      );
    }
    for (final raw in rawOutputs) {
      if (raw is! Map || raw['key'] is! String) {
        throw const FormatException(
          'Native CalculationTrace output is malformed.',
        );
      }
      final row = Map<String, Object?>.from(raw)..remove('key');
      outputs[raw['key']! as String] = row;
    }
    return CalculationExecutionResult(outputs: outputs, trace: trace);
  }

  @override
  Future<bool> requestCancel(CalculationId calculationId) async {
    final capabilities = _nativeCapabilities;
    if (capabilities?.supportsCancellation != true) return false;
    try {
      final response = await _call('requestCancel', {'job_id': calculationId});
      final result = response?['result'];
      return result is Map && result['accepted'] == true;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  Future<Map<String, Object?>?> _call(
    String method,
    Map<String, Object?> params,
  ) async {
    final request = jsonEncode({
      'jsonrpc': '2.0',
      'id': ++_rpcId,
      'method': method,
      'params': params,
    });
    try {
      final responseJson = await _channel.invokeMethod<String>(method, {
        'requestJson': request,
      });
      if (responseJson == null) return null;
      final response = jsonDecode(responseJson);
      if (response is! Map) {
        throw const FormatException('Malformed native JSON-RPC response.');
      }
      final decoded = Map<String, Object?>.from(response);
      if (decoded['error'] != null) {
        final error = decoded['error'];
        throw FormatException('Native JSON-RPC $method failed: $error');
      }
      return decoded;
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  bool _supportsPack(
    CalculationCapabilities capabilities,
    Map<String, Object?> document,
  ) {
    final pipeline = document['pipeline'];
    if (pipeline is! List) return false;
    final supported = capabilities.supportedOperations.toSet();
    return pipeline.every((step) {
      if (step is! Map) return false;
      final operation = step['op'];
      return operation is String && supported.contains(operation);
    });
  }
}
