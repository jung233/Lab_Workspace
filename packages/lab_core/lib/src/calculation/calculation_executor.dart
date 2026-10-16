import '../domain/ids.dart';
import '../domain/json_value.dart';
import 'calculation_engine.dart';
import 'primitive_registry.dart';
import '../packs/calculation_pack.dart';

export 'calculation_engine.dart' show CalculationExecutionResult;

final class CalculationCapabilities {
  CalculationCapabilities({
    required this.platform,
    required this.executorId,
    required this.available,
    required this.bundledExecutor,
    required this.pythonRuntime,
    required Iterable<String> supportedOperations,
    required this.supportsCancellation,
    this.unsupportedReason,
  }) : supportedOperations = List<String>.unmodifiable(supportedOperations);

  final String platform;
  final String executorId;
  final bool available;
  final bool bundledExecutor;
  final String pythonRuntime;
  final List<String> supportedOperations;
  final bool supportsCancellation;
  final String? unsupportedReason;

  Map<String, Object?> toJson() => {
        'platform': platform,
        'executor_id': executorId,
        'available': available,
        'bundled_executor': bundledExecutor,
        'python_runtime': pythonRuntime,
        'supported_operations': supportedOperations,
        'supports_cancellation': supportsCancellation,
        'unsupported_reason': unsupportedReason,
      };
}

final class CalculationExecutionRequest {
  CalculationExecutionRequest({
    required this.calculationId,
    required this.traceId,
    required this.pack,
    required Map<String, Object?> inputSnapshot,
    List<Map<String, Object?>> sourceAssets = const [],
    required this.approvalRef,
    required this.approvalKind,
    required this.createdAtUtc,
    this.runId,
    this.sampleId,
    this.stepId,
    this.parentCalculationId,
  })  : inputSnapshot = freezeJsonObject(inputSnapshot),
        sourceAssets = List.unmodifiable(sourceAssets.map(freezeJsonObject));

  final CalculationId calculationId;
  final CalculationTraceId traceId;
  final VersionedCalculationPack pack;
  final Map<String, Object?> inputSnapshot;
  final List<Map<String, Object?>> sourceAssets;
  final String approvalRef;
  final String approvalKind;
  final DateTime createdAtUtc;
  final RunId? runId;
  final SampleId? sampleId;
  final StepId? stepId;
  final CalculationId? parentCalculationId;
}

abstract interface class CalculationExecutor {
  Future<CalculationCapabilities> probe();

  Future<CalculationExecutionResult> execute(
    CalculationExecutionRequest request, {
    required bool Function() isCancelled,
  });

  Future<bool> requestCancel(CalculationId calculationId);
}

/// Pure Dart fallback for the shared approved primitive set. Native clients may
/// inject a trusted Python executor through the same typed boundary.
final class DartCalculationExecutor implements CalculationExecutor {
  const DartCalculationExecutor({this.platform = 'dart'});

  final String platform;
  static const String executorId = 'lab-core-dart-2.0';
  static const _engine = CalculationEngine();

  @override
  Future<CalculationCapabilities> probe() async => CalculationCapabilities(
        platform: platform,
        executorId: executorId,
        available: true,
        bundledExecutor: true,
        pythonRuntime: 'not_used',
        supportedOperations: PrimitiveRegistry.definitions.keys,
        supportsCancellation: false,
      );

  @override
  Future<CalculationExecutionResult> execute(
    CalculationExecutionRequest request, {
    required bool Function() isCancelled,
  }) async {
    final approvalKind = request.pack.origin == 'trusted_builtin'
        ? 'trusted_builtin'
        : 'user_approval';
    final approvalRef = request.pack.approvalRef;
    if (approvalRef == null || approvalRef.isEmpty) {
      throw const FormatException('CALC_PACK_APPROVAL_MISSING: installed Pack has no approval.');
    }
    return _engine.execute(
      pack: request.pack.document,
      inputSnapshot: request.inputSnapshot,
      calculationId: request.calculationId,
      traceId: request.traceId,
      packSha256: request.pack.contentSha256,
      sourceAssets: request.sourceAssets,
      approvalReference: approvalRef,
      approvalKind: approvalKind,
      executorId: executorId,
      platform: platform,
      createdAtUtc: request.createdAtUtc,
      runId: request.runId,
      sampleId: request.sampleId,
      stepId: request.stepId,
      parentCalculationId: request.parentCalculationId,
      cancelled: isCancelled,
    );
  }

  @override
  Future<bool> requestCancel(CalculationId calculationId) async => false;
}\n
