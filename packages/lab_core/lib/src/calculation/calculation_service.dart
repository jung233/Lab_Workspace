import 'dart:async';
import 'dart:convert';

import '../domain/calculation_records.dart';
import '../domain/commands.dart';
import '../domain/errors.dart';
import '../domain/events.dart';
import '../domain/ids.dart';
import '../domain/json_value.dart';
import '../domain/vault.dart';
import '../persistence/workspace_database.dart';
import '../packs/calculation_pack.dart';
import '../packs/calculation_pack_registry.dart';
import '../packs/calculation_pack_validator.dart';
import 'calculation_executor.dart';
import 'decimal_support.dart';
import 'primitive_code_manifest.dart';
import 'unit_registry.dart';

enum CalculationJobState { queued, running, completed, failed, cancelled }

const _maxCalculationInputSnapshotBytes = 4 * 1024 * 1024;
const _maxCalculationSourceSnapshotBytes = 1024 * 1024;
const _maxCalculationSyncEventBytes = 30 * 1024 * 1024;

final class CalculationJobSnapshot {
  const CalculationJobSnapshot({
    required this.calculationId,
    required this.packId,
    required this.packVersion,
    required this.state,
    required this.createdAtUtc,
    this.errorCode,
  });

  final CalculationId calculationId;
  final String packId;
  final String packVersion;
  final CalculationJobState state;
  final DateTime createdAtUtc;
  final String? errorCode;
}

/// Public calculation facade used by application and Flutter clients.
/// Durable rows are created only for immutable completed/failed results.
final class CalculationService {
  CalculationService({
    required this.database,
    required this.vault,
    required this.packs,
    required this.executor,
    DateTime Function()? clock,
    String Function()? idGenerator,
  })  : _clock = clock ?? _utcNow,
        _idGenerator = idGenerator ?? newUuidV7 {
    if (!identical(database, vault.database)) {
      throw ArgumentError('CalculationService database must match VaultContext.database.');
    }
  }

  final WorkspaceDatabase database;
  final VaultContext vault;
  final CalculationPackRegistry packs;
  final CalculationExecutor executor;
  final DateTime Function() _clock;
  final String Function() _idGenerator;
  final Map<CalculationId, _ActiveCalculation> _active = {};

  Future<CalculationCapabilities> probe() => executor.probe();

  List<CalculationJobSnapshot> get activeJobs => List.unmodifiable(
        _active.values.map((job) => job.snapshot),
      );

  Future<List<CalculationRun>> listRecent({int limit = 50}) async {
    if (limit < 1 || limit > 500) throw ArgumentError.value(limit, 'limit');
    final rows = database.query(
      '''SELECT calculation_id,parent_calculation_id,run_id,sample_id,step_id,
                pack_id,pack_version,pack_sha256,status,input_json,source_assets_json,
                output_json,trace_json,trace_sha256,error_code,started_at_utc,
                completed_at_utc,revision
         FROM calculation_runs
         WHERE status IN('completed','failed')
           AND pack_sha256 IS NOT NULL AND trace_json IS NOT NULL
           AND trace_sha256 IS NOT NULL AND completed_at_utc IS NOT NULL
         ORDER BY completed_at_utc DESC,calculation_id DESC LIMIT ?''',
      [limit],
    );
    return List<CalculationRun>.unmodifiable(rows.map(_runFromRow));
  }

  /// Schedules an approved calculation and returns its immutable id promptly.
  Future<CalculationId> start({
    required String packId,
    required String packVersion,
    required Map<String, Object?> inputSnapshot,
    List<Map<String, Object?>> sourceAssets = const [],
    String? runId,
    String? sampleId,
    String? stepId,
  }) async {
    final pack = await packs.getInstalled(packId, packVersion);
    final snapshot = freezeJsonObject(inputSnapshot);
    _rejectFloatingPoint(snapshot, r'$.inputSnapshot');
    final sources = _validateSourceAssets(sourceAssets);
    _validateSnapshotSize(snapshot, sources);
    final now = _clock().toUtc();
    final calculationId = _idGenerator();
    final active = _ActiveCalculation(
      calculationId: calculationId,
      pack: pack,
      inputSnapshot: snapshot,
      sourceAssets: sources,
      runId: runId,
      sampleId: sampleId,
      stepId: stepId,
      createdAtUtc: now,
    );
    _active[calculationId] = active;
    unawaited(_executeAndPersist(active));
    return calculationId;
  }

  Future<bool> cancel(CalculationId calculationId) async {
    final active = _active[calculationId];
    if (active == null || active.isTerminal) return false;
    active.cancelRequested = true;
    final accepted = await executor.requestCancel(calculationId);
    if (!accepted && active.state != CalculationJobState.queued) {
      active.cancelRequested = false;
      return false;
    }
    return true;
  }

  Future<CalculationTrace> getTrace(CalculationId calculationId) async {
    final rows = database.query(
      'SELECT trace_json,trace_sha256 FROM calculation_runs WHERE calculation_id=?',
      [calculationId],
    );
    if (rows.isEmpty) throw MissingEntityException('CalculationRun', calculationId);
    final traceJson = rows.single['trace_json'];
    final expectedHash = rows.single['trace_sha256'];
    if (traceJson is! String || expectedHash is! String) {
      throw const ValidationException(
        'CALC_TRACE_MISSING',
        'The calculation has no saved raw CalculationTrace.',
      );
    }
    final trace = CalculationTrace.fromJson(traceJson);
    if (trace.contentSha256 != expectedHash) {
      throw const ValidationException(
        'CALC_TRACE_HASH_MISMATCH',
        'Stored CalculationTrace failed its canonical SHA-256 check.',
      );
    }
    if (trace.calculationId != calculationId) {
      throw const ValidationException(
        'CALC_TRACE_ID_MISMATCH',
        'Stored CalculationTrace identifies a different CalculationRun.',
      );
    }
    return trace;
  }

  /// Creates a new result row linked to the earlier calculation. History is
  /// never updated or replaced by recalculation.
  Future<CalculationId> recalculate(CalculationId calculationId) async {
    final rows = database.query(
      '''SELECT run_id,sample_id,step_id,pack_id,pack_version,input_json,source_assets_json
         FROM calculation_runs WHERE calculation_id=?''',
      [calculationId],
    );
    if (rows.isEmpty) throw MissingEntityException('CalculationRun', calculationId);
    final row = rows.single;
    final inputJson = row['input_json'];
    final sourceJson = row['source_assets_json'];
    if (inputJson is! String || sourceJson is! String) {
      throw const FormatException('Stored calculation input snapshot is malformed.');
    }
    final inputs = jsonDecode(inputJson);
    final sources = jsonDecode(sourceJson);
    if (inputs is! Map || sources is! List) {
      throw const FormatException('Stored calculation snapshot is malformed.');
    }
    return _startWithParent(
      packId: row['pack_id']! as String,
      packVersion: row['pack_version']! as String,
      inputSnapshot: requireJsonObject(inputs, 'input_json'),
      sourceAssets: _sourceAssetRows(sources),
      runId: row['run_id'] as String?,
      sampleId: row['sample_id'] as String?,
      stepId: row['step_id'] as String?,
      parentCalculationId: calculationId,
    );
  }

  Future<CalculationId> _startWithParent({
    required String packId,
    required String packVersion,
    required Map<String, Object?> inputSnapshot,
    required List<Map<String, Object?>> sourceAssets,
    String? runId,
    String? sampleId,
    String? stepId,
    required CalculationId parentCalculationId,
  }) async {
    final pack = await packs.getInstalled(packId, packVersion);
    final snapshot = freezeJsonObject(inputSnapshot);
    _rejectFloatingPoint(snapshot, r'$.inputSnapshot');
    final sources = _validateSourceAssets(sourceAssets);
    _validateSnapshotSize(snapshot, sources);
    final now = _clock().toUtc();
    final calculationId = _idGenerator();
    final active = _ActiveCalculation(
      calculationId: calculationId,
      pack: pack,
      inputSnapshot: snapshot,
      sourceAssets: sources,
      runId: runId,
      sampleId: sampleId,
      stepId: stepId,
      parentCalculationId: parentCalculationId,
      createdAtUtc: now,
    );
    _active[calculationId] = active;
    unawaited(_executeAndPersist(active));
    return calculationId;
  }

  Future<void> _executeAndPersist(_ActiveCalculation active) async {
    active.state = CalculationJobState.running;
    try {
      final request = CalculationExecutionRequest(
        calculationId: active.calculationId,
        traceId: _idGenerator(),
        pack: active.pack,
        inputSnapshot: active.inputSnapshot,
        sourceAssets: active.sourceAssets,
        approvalRef: active.pack.approvalRef ?? '',
        approvalKind: active.pack.origin == 'trusted_builtin'
            ? 'trusted_builtin'
            : 'user_approval',
        createdAtUtc: active.createdAtUtc,
        runId: active.runId,
        sampleId: active.sampleId,
        stepId: active.stepId,
        parentCalculationId: active.parentCalculationId,
      );
      final result = await executor.execute(
        request,
        isCancelled: () => active.cancelRequested,
      );
      _verifyExecutionResult(active, result);
      final completedAt = _clock().toUtc();
      final run = CalculationRun(
        calculationId: active.calculationId,
        parentCalculationId: active.parentCalculationId,
        runId: active.runId,
        sampleId: active.sampleId,
        stepId: active.stepId,
        packId: active.pack.packId,
        packVersion: active.pack.version,
        packSha256: active.pack.contentSha256,
        status: CalculationStatus.completed,
        inputSnapshot: active.inputSnapshot,
        sourceAssets: active.sourceAssets,
        output: {'outputs': result.trace.document['outputs']},
        trace: result.trace,
        createdAtUtc: active.createdAtUtc,
        completedAtUtc: completedAt,
      );
      _persistTerminal(run, pack: active.pack);
      active.state = CalculationJobState.completed;
    } on Object catch (error) {
      final errorCode = _errorCode(error);
      final completedAt = _clock().toUtc();
      final trace = _failureTrace(active, errorCode);
      final run = CalculationRun(
        calculationId: active.calculationId,
        parentCalculationId: active.parentCalculationId,
        runId: active.runId,
        sampleId: active.sampleId,
        stepId: active.stepId,
        packId: active.pack.packId,
        packVersion: active.pack.version,
        packSha256: active.pack.contentSha256,
        status: CalculationStatus.failed,
        inputSnapshot: active.inputSnapshot,
        sourceAssets: active.sourceAssets,
        trace: trace,
        errorCode: errorCode,
        createdAtUtc: active.createdAtUtc,
        completedAtUtc: completedAt,
      );
      _persistTerminal(run, pack: active.pack);
      active.errorCode = errorCode;
      active.state = errorCode == 'CALC_CANCELLED'
          ? CalculationJobState.cancelled
          : CalculationJobState.failed;
    } finally {
      active.terminalAtUtc = _clock().toUtc();
      Timer(const Duration(minutes: 10), () => _active.remove(active.calculationId));
    }
  }

  void _verifyExecutionResult(
    _ActiveCalculation active,
    CalculationExecutionResult result,
  ) {
    final trace = result.trace;
    final document = trace.document;
    if (trace.calculationId != active.calculationId ||
        document['pack_ref'] != active.pack.ref ||
        document['pack_sha256'] != active.pack.contentSha256 ||
        canonicalJson(document['source_assets']) != canonicalJson(active.sourceAssets)) {
      throw const ValidationException(
        'CALC_EXECUTOR_TRACE_MISMATCH',
        'Executor trace does not match the approved Pack, source Assets, or calculation id.',
      );
    }
    _verifyPrimitiveCodeProvenance(document, active.pack.document);
    _verifyRuntimeSourceProvenance(document);
    final context = document['execution_context'];
    if (context is! Map ||
        context['run_id'] != active.runId ||
        context['sample_id'] != active.sampleId ||
        context['step_id'] != active.stepId ||
        document['recalculation_parent_id'] != active.parentCalculationId) {
      throw const ValidationException(
        'CALC_EXECUTOR_CONTEXT_MISMATCH',
        'Executor trace does not retain the requested run, sample, step, or recalculation context.',
      );
    }
    final approval = document['approval'];
    if (approval is! Map ||
        approval['reference'] != active.pack.approvalRef ||
        approval['kind'] != (active.pack.origin == 'trusted_builtin' ? 'trusted_builtin' : 'user_approval')) {
      throw const ValidationException(
        'CALC_EXECUTOR_APPROVAL_MISMATCH',
        'Executor trace does not retain the approved Pack reference.',
      );
    }
    final rawOutputs = document['outputs'];
    final outputRowsFromResult = <Map<String, Object?>>[];
    for (final entry in result.outputs.entries) {
      if (entry.value is! Map) {
        throw const ValidationException(
          'CALC_EXECUTOR_OUTPUT_INVALID',
          'Executor output records must be typed value objects.',
        );
      }
      outputRowsFromResult.add({
        'key': entry.key,
        ...requireJsonObject(entry.value, 'executor output'),
      });
    }
    if (rawOutputs is! List || rawOutputs.isEmpty ||
        canonicalJson(rawOutputs) != canonicalJson(outputRowsFromResult)) {
      throw const ValidationException(
        'CALC_EXECUTOR_OUTPUT_TRACE_MISMATCH',
        'Every output value must match an exact value recorded in CalculationTrace.',
      );
    }
    final outputKeys = <String>{};
    for (final rawOutput in rawOutputs) {
      if (rawOutput is! Map || rawOutput['key'] is! String ||
          !outputKeys.add(rawOutput['key'] as String)) {
        throw const ValidationException(
          'CALC_EXECUTOR_OUTPUT_TRACE_INVALID',
          'CalculationTrace output rows must have unique named values.',
        );
      }
      final sourceRef = rawOutput['source_ref'];
      if (sourceRef is! String || !_hasTraceResult(document['steps'], sourceRef)) {
        throw const ValidationException(
          'CALC_TRACE_DERIVATION_MISSING',
          'Each published output must reference a recorded primitive result.',
        );
      }
    }
    final declaredOutputs = (active.pack.document['outputs']! as List)
        .map((item) => (item as Map)['key'])
        .whereType<String>()
        .toSet();
    if (!outputKeys.containsAll(declaredOutputs) || !declaredOutputs.containsAll(outputKeys)) {
      throw const ValidationException(
        'CALC_EXECUTOR_OUTPUT_SET_MISMATCH',
        'Calculation result outputs must exactly match the approved Pack declarations.',
      );
    }
    _verifyTraceStepResults(document['steps'], active.pack.document['pipeline']);
    _verifyOutputDerivations(rawOutputs, active.pack.document['outputs'], document['steps']);
    _verifyInputTrace(document['inputs'], active);
  }

  void _verifyPrimitiveCodeProvenance(
    Map<String, Object?> trace,
    Map<String, Object?> pack,
  ) {
    final engine = trace['engine'];
    final pipeline = pack['pipeline'];
    if (engine is! Map || pipeline is! List) {
      throw const ValidationException(
        'CALC_PRIMITIVE_PROVENANCE_MISSING',
        'A new CalculationTrace must identify its executable primitive bundle.',
      );
    }
    final executorId = engine['executor_id'];
    final expectedHash = switch (executorId) {
      'lab-core-dart-2.0' => dartCalculationPrimitiveCodeSha256,
      'trusted-python-mobile-v2' || 'trusted-python-stdlib-v2' =>
        pythonCalculationPrimitiveCodeSha256,
      _ => null,
    };
    if (expectedHash == null || !RegExp(r'^[a-f0-9]{64}$').hasMatch(expectedHash)) {
      throw const ValidationException(
        'CALC_PRIMITIVE_PROVENANCE_UNSUPPORTED',
        'The executor has no pinned trusted primitive source bundle.',
      );
    }
    final usedOperations = <String>{};
    for (final raw in pipeline) {
      if (raw is! Map || raw['op'] is! String) {
        throw const ValidationException(
          'CALC_PRIMITIVE_PROVENANCE_INVALID',
          'The approved Pack has a malformed primitive declaration.',
        );
      }
      usedOperations.add(raw['op']! as String);
    }
    final rawHashes = engine['primitive_code_sha256'];
    final rawVersions = engine['primitive_versions'];
    final buildVersions = trace['primitive_build_versions'];
    if (rawHashes is! Map || rawVersions is! Map || buildVersions is! Map ||
        rawHashes.keys.toSet().length != usedOperations.length ||
        rawVersions.keys.toSet().length != usedOperations.length ||
        buildVersions.keys.toSet().length != usedOperations.length ||
        !rawHashes.keys.toSet().containsAll(usedOperations) ||
        !rawVersions.keys.toSet().containsAll(usedOperations) ||
        !buildVersions.keys.toSet().containsAll(usedOperations) ||
        rawHashes.values.any((value) => value != expectedHash) ||
        rawVersions.values.any((value) => value != '1') ||
        buildVersions.values.any((value) => value is! String || value.isEmpty)) {
      throw const ValidationException(
        'CALC_PRIMITIVE_PROVENANCE_MISMATCH',
        'CalculationTrace primitive hashes, versions, or build IDs do not match the Pack operations.',
      );
    }
  }

  void _verifyRuntimeSourceProvenance(Map<String, Object?> trace) {
    final engine = trace['engine'];
    final environment = trace['execution_environment'];
    if (engine is! Map || environment is! Map || environment['dependencies'] is! Map) {
      throw const ValidationException(
        'CALC_RUNTIME_PROVENANCE_MISSING',
        'A new CalculationTrace must retain trusted runtime source provenance.',
      );
    }
    final executorId = engine['executor_id'];
    final dependencies = environment['dependencies'] as Map;
    if (executorId == 'lab-core-dart-2.0') {
      if (dependencies['calculation_source_manifest_version'] !=
              calculationSourceManifestVersion ||
          dependencies['calculation_runtime_source_sha256'] !=
              dartCalculationRuntimeSourceSha256) {
        throw const ValidationException(
          'CALC_RUNTIME_PROVENANCE_MISMATCH',
          'Dart executor source provenance does not match its pinned runtime manifest.',
        );
      }
      return;
    }
    if (dependencies['runtime_source_manifest_version'] !=
        calculationSourceManifestVersion) {
      throw const ValidationException(
        'CALC_RUNTIME_PROVENANCE_MISSING',
        'Trusted Python trace does not identify its runtime source manifest.',
      );
    }
    final target = dependencies['runtime_source_target'];
    if (executorId == 'trusted-python-stdlib-v2') {
      if (target != 'windows' ||
          dependencies['runtime_entry_source_sha256'] !=
              pythonDesktopEntrySourceSha256) {
        throw const ValidationException(
          'CALC_RUNTIME_PROVENANCE_MISMATCH',
          'Desktop Python entry source provenance does not match its pinned manifest.',
        );
      }
      return;
    }
    if (executorId == 'trusted-python-mobile-v2') {
      final nativeHash = switch (target) {
        'android' => androidPythonRunnerSourceSha256,
        'ios' => iosPythonRunnerSourceSha256,
        _ => null,
      };
      final preparationHash = switch (target) {
        'android' => androidPythonPreparationSourceSha256,
        'ios' => iosPythonPreparationSourceSha256,
        _ => null,
      };
      if (nativeHash == null || preparationHash == null ||
          dependencies['runtime_entry_source_sha256'] !=
              pythonMobileEntrySourceSha256 ||
          dependencies['native_runner_source_sha256'] != nativeHash ||
          dependencies['runtime_preparation_source_sha256'] != preparationHash) {
        throw const ValidationException(
          'CALC_RUNTIME_PROVENANCE_MISMATCH',
          'Mobile Python runner or preparation provenance does not match its pinned manifest.',
        );
      }
      return;
    }
    throw const ValidationException(
      'CALC_RUNTIME_PROVENANCE_UNSUPPORTED',
      'The trace executor has no trusted runtime source manifest.',
    );
  }

  void _verifyTraceStepResults(Object? rawSteps, Object? rawPipeline) {
    if (rawSteps is! List || rawPipeline is! List ||
        rawSteps.length != rawPipeline.length) {
      throw const ValidationException(
        'CALC_TRACE_STEPS_MISMATCH',
        'CalculationTrace must contain one ordered row for each approved Pack operation.',
      );
    }
    for (var index = 0; index < rawPipeline.length; index++) {
      final pipelineStep = rawPipeline[index];
      final traceStep = rawSteps[index];
      if (pipelineStep is! Map || traceStep is! Map) {
        throw const ValidationException(
          'CALC_TRACE_STEPS_INVALID',
          'CalculationTrace step rows must be objects.',
        );
      }
      final operation = pipelineStep['op'];
      final stepId = pipelineStep['step_id'];
      if (operation is! String || stepId is! String ||
          traceStep['seq'] != index + 1 || traceStep['op'] != operation) {
        throw const ValidationException(
          'CALC_TRACE_OPERATION_MISMATCH',
          'CalculationTrace operations must match the approved Pack pipeline in order.',
        );
      }
      final result = traceStep['result'];
      final results = traceStep['results'];
      var expectedKeys = CalculationPackValidator.outputKeysFor(operation);
      if (operation == 'wb.normalize_ratio@1') {
        final inputs = pipelineStep['inputs'];
        expectedKeys = inputs is Map && inputs.containsKey('calibrator_ratio')
            ? const {'ratio', 'relative_ratio'}
            : const {'value'};
      }
      if (result is! Map || result['key'] != stepId ||
          results is! List || results.length != expectedKeys.length) {
        throw const ValidationException(
          'CALC_TRACE_PRIMITIVE_RESULTS_MISSING',
          'Every primitive must retain its named result and all derived output values.',
        );
      }
      final seen = <String>{};
      for (final rawResult in results) {
        if (rawResult is! Map || rawResult['key'] is! String) {
          throw const ValidationException(
            'CALC_TRACE_PRIMITIVE_RESULT_INVALID',
            'Primitive result rows must have a string key.',
          );
        }
        final key = rawResult['key'] as String;
        if (!expectedKeys.contains(key) || !seen.add(key) ||
            rawResult['source_ref'] != r'$steps.' + stepId + '.' + key) {
          throw const ValidationException(
            'CALC_TRACE_PRIMITIVE_RESULT_INVALID',
            'Primitive result keys and source references must match the registered output allowlist.',
          );
        }
      }
      if (!seen.containsAll(expectedKeys)) {
        throw const ValidationException(
          'CALC_TRACE_PRIMITIVE_RESULTS_MISSING',
          'A primitive result is missing a registered derived value.',
        );
      }
    }
  }

  void _verifyOutputDerivations(
    List rawOutputs,
    Object? rawDefinitions,
    Object? rawSteps,
  ) {
    if (rawDefinitions is! List || rawSteps is! List ||
        rawOutputs.length != rawDefinitions.length) {
      throw const ValidationException(
        'CALC_TRACE_OUTPUT_DERIVATION_MISSING',
        'Every declared Pack output must retain its source primitive result.',
      );
    }
    final primitiveResults = <String, Map<String, Object?>>{};
    for (final rawStep in rawSteps) {
      if (rawStep is! Map || rawStep['results'] is! List) continue;
      for (final rawResult in rawStep['results'] as List) {
        if (rawResult is! Map || rawResult['source_ref'] is! String) continue;
        primitiveResults[rawResult['source_ref'] as String] =
            requireJsonObject(rawResult, 'primitive trace result');
      }
    }
    for (var index = 0; index < rawDefinitions.length; index++) {
      final rawDefinition = rawDefinitions[index];
      final rawOutput = rawOutputs[index];
      if (rawDefinition is! Map || rawOutput is! Map ||
          rawDefinition['key'] is! String || rawDefinition['from_ref'] is! String) {
        throw const ValidationException(
          'CALC_TRACE_OUTPUT_DERIVATION_INVALID',
          'Pack output and CalculationTrace rows must be typed objects.',
        );
      }
      final definition = requireJsonObject(rawDefinition, 'Pack output');
      final output = requireJsonObject(rawOutput, 'CalculationTrace output');
      final sourceRef = definition['from_ref'] as String;
      final source = primitiveResults[sourceRef];
      if (source == null || output['key'] != definition['key'] ||
          output['source_ref'] != sourceRef) {
        throw const ValidationException(
          'CALC_TRACE_DERIVATION_MISSING',
          'Published values must point to the matching recorded primitive result.',
        );
      }
      final requestedUnit = definition['unit'];
      final sourceUnit = source['unit'];
      Object? expectedValue = source['value'];
      Object? expectedUnit = sourceUnit;
      if (requestedUnit is String) {
        if (sourceUnit is! String) {
          throw const ValidationException(
            'CALC_TRACE_OUTPUT_UNIT_MISMATCH',
            'A unit-bearing Pack output must derive from a unit-bearing primitive result.',
          );
        }
        try {
          final factor = UnitRegistry.conversionFactor(sourceUnit, requestedUnit);
          final convertedValue = multiplyCalculationDecimals(
            parseCalculationDecimal(source['value']),
            factor,
          );
          expectedValue = calculationDecimalText(convertedValue);
          expectedUnit = UnitRegistry.parse(requestedUnit).symbol;
        } on Object {
          throw const ValidationException(
            'CALC_TRACE_OUTPUT_UNIT_MISMATCH',
            'Pack output unit is incompatible with the source primitive result unit.',
          );
        }
      }
      if (canonicalJson(output['value']) != canonicalJson(expectedValue) ||
          canonicalJson(output['unit']) != canonicalJson(expectedUnit)) {
        throw const ValidationException(
          'CALC_TRACE_OUTPUT_VALUE_MISMATCH',
          'Published output values and units must match their exact trace derivation.',
        );
      }
    }
  }

  void _verifyInputTrace(Object? rawInputs, _ActiveCalculation active) {
    if (rawInputs is! List) {
      throw const ValidationException(
        'CALC_TRACE_INPUTS_MISSING',
        'CalculationTrace must retain each supplied input snapshot value.',
      );
    }
    final definitions = active.pack.document['inputs'];
    if (definitions is! List) {
      throw const ValidationException(
        'CALC_PACK_INPUTS_INVALID',
        'Installed Pack input schema is malformed.',
      );
    }
    final expected = <Map<String, Object?>>[];
    final sourceIds = active.sourceAssets
        .map((asset) => asset['asset_id'])
        .whereType<String>()
        .toSet();
    for (final rawDefinition in definitions) {
      if (rawDefinition is! Map) continue;
      final definition = requireJsonObject(rawDefinition, 'Pack input');
      final key = definition['key'];
      if (key is! String || !active.inputSnapshot.containsKey(key)) continue;
      final value = active.inputSnapshot[key];
      final kind = definition['kind'];
      final rawUnit = definition['unit'];
      final unit = kind == 'decimal'
          ? UnitRegistry.parse(rawUnit as String?).symbol
          : null;
      final tracedValue = switch (kind) {
        'decimal' => value is String
            ? value
            : calculationDecimalText(
                parseCalculationDecimal(value, field: key),
              ),
        'boolean' => value == true ? 'true' : 'false',
        'table' => canonicalJson(value),
        _ => value,
      };
      expected.add({
        'key': key,
        'value': tracedValue,
        'unit': unit,
        'source_ref': value is String && sourceIds.contains(value) ? value : null,
      });
    }
    if (canonicalJson(rawInputs) != canonicalJson(expected)) {
      throw const ValidationException(
        'CALC_TRACE_INPUT_SNAPSHOT_MISMATCH',
        'CalculationTrace inputs must exactly retain the submitted immutable snapshot.',
      );
    }
  }

  bool _hasTraceResult(Object? rawSteps, String sourceRef) {
    if (rawSteps is! List || !sourceRef.startsWith(r'$steps.')) return false;
    final parts = sourceRef.substring(1).split('.');
    if (parts.length != 3) return false;
    for (final rawStep in rawSteps) {
      if (rawStep is! Map || rawStep['op'] is! String) continue;
      final resultRows = rawStep['results'];
      if (resultRows is List && resultRows.any((result) =>
          result is Map && result['key'] == parts[2] &&
          result['source_ref'] == sourceRef)) {
        return true;
      }
    }
    return false;
  }

  CalculationTrace _failureTrace(
    _ActiveCalculation active,
    String errorCode,
  ) {
    final inputRows = <Map<String, Object?>>[];
    final rawDefinitions = active.pack.document['inputs'];
    final definitions = <String, Map<String, Object?>>{};
    if (rawDefinitions is List) {
      for (final rawDefinition in rawDefinitions) {
        if (rawDefinition is! Map) continue;
        final definition = requireJsonObject(rawDefinition, 'Pack input');
        final key = definition['key'];
        if (key is String) definitions[key] = definition;
      }
    }
    final sourceIds = active.sourceAssets
        .map((asset) => asset['asset_id'])
        .whereType<String>()
        .toSet();
    for (final entry in active.inputSnapshot.entries) {
      final definition = definitions[entry.key];
      final unit = definition?['kind'] == 'decimal'
          ? UnitRegistry.parse(definition?['unit'] as String?).symbol
          : null;
      inputRows.add({
        'key': entry.key,
        'value': _traceInput(entry.value),
        'unit': unit,
        'source_ref': entry.value is String && sourceIds.contains(entry.value)
            ? entry.value
            : null,
      });
    }
    return CalculationTrace(document: {
      'schema_version': '2.0',
      'trace_id': _idGenerator(),
      'calculation_id': active.calculationId,
      'pack_ref': active.pack.ref,
      'engine': {
        'executor_id': 'lab-core-failed-execution',
        'python_version': 'not_applicable',
        'primitive_versions': const <String, String>{},
        'primitive_code_sha256': const <String, String>{},
        'platform': 'shared-core',
      },
      'inputs': inputRows,
      'steps': [
        {
          'seq': 1,
          'op': 'calculation.execution_failed@1',
          'expression': 'No scientific result was published because execution failed.',
          'substitution': errorCode,
          'inputs': const <String, Object?>{},
          'intermediates': const <String, Object?>{},
          'result': {'key': 'error_code', 'value': errorCode, 'unit': null, 'source_ref': null},
          'results': const <Object?>[],
          'warnings': const <String>[],
        },
      ],
      'outputs': const <Object?>[],
      'source_assets': active.sourceAssets,
      'warnings': ['Calculation failed before publishing scientific outputs ($errorCode).'],
      'user_confirmed': false,
      'created_at_utc': active.createdAtUtc.toUtc().toIso8601String(),
      'pack_sha256': active.pack.contentSha256,
      'primitive_build_versions': const <String, String>{},
      'execution_context': {
        'run_id': active.runId,
        'sample_id': active.sampleId,
        'step_id': active.stepId,
      },
      'approval': {
        'reference': active.pack.approvalRef ?? 'missing',
        'kind': active.pack.origin == 'trusted_builtin' ? 'trusted_builtin' : 'user_approval',
      },
      'ai_provenance': const <Object?>[],
      'recalculation_parent_id': active.parentCalculationId,
      'precision': {
        'decimal_precision': calculationDecimalPrecision,
        'rounding': calculationRoundingPolicy,
        'float_inputs_allowed': false,
      },
      'execution_environment': {
        'runtime': 'calculation-service',
        'platform': 'shared-core',
        'dependencies': {
          'calculation_source_manifest_version': calculationSourceManifestVersion,
          'calculation_runtime_source_sha256': dartCalculationRuntimeSourceSha256,
          'scientific_primitive_executed': 'false',
        },
      },
    });
  }

  void _persistTerminal(
    CalculationRun run, {
    required VersionedCalculationPack pack,
  }) {
    final trace = run.trace;
    if (trace == null) {
      throw const ValidationException(
        'CALC_TRACE_MISSING',
        'Every terminal calculation must retain its raw CalculationTrace.',
      );
    }
    final traceJson = trace.canonicalJson;
    final outputJson = run.output == null ? null : canonicalJson(run.output);
    final inputJson = canonicalJson(run.inputSnapshot);
    final sourcesJson = canonicalJson(run.sourceAssets);
    final status = run.status.wireValue;
    if (pack.packId != run.packId || pack.version != run.packVersion ||
        pack.contentSha256 != run.packSha256) {
      throw const ValidationException(
        'CALC_PACK_SNAPSHOT_MISMATCH',
        'CalculationRun Pack identity does not match the execution snapshot.',
      );
    }
    final packEnvelope = <String, Object?>{
      'pack_id': pack.packId,
      'version': pack.version,
      'content_sha256': pack.contentSha256,
      'document': pack.document,
      'origin': pack.origin,
      'trust_level': pack.trustLevel,
      'source_approval_ref': pack.approvalRef,
      'signature': pack.signature,
      if (pack.sourceProvenance != null)
        'source_provenance': pack.sourceProvenance!.toJson(),
      'approved_at_utc': pack.approvedAtUtc?.toUtc().toIso8601String(),
    };
    final mutationPayload = <String, Object?>{
      'record_kind': 'calculation_run_v2',
      'event_type': status == 'completed' ? 'calculation.completed' : 'calculation.failed',
      'calculation': {
        'calculation_id': run.calculationId,
        'parent_calculation_id': run.parentCalculationId,
        'run_id': run.runId,
        'sample_id': run.sampleId,
        'step_id': run.stepId,
        'pack_id': run.packId,
        'pack_version': run.packVersion,
        'pack_sha256': run.packSha256,
        'status': status,
        'input_snapshot': run.inputSnapshot,
        'source_assets': run.sourceAssets,
        'output': run.output,
        'trace': trace.document,
        'trace_sha256': trace.contentSha256,
        'error_code': run.errorCode,
        'created_at_utc': run.createdAtUtc.toUtc().toIso8601String(),
        'completed_at_utc': run.completedAtUtc!.toUtc().toIso8601String(),
        'revision': run.revision,
      },
      'pack_envelope': packEnvelope,
    };
    final mutationPayloadJson = canonicalJson(mutationPayload);
    if (utf8.encode(mutationPayloadJson).length > _maxCalculationSyncEventBytes) {
      throw const ValidationException(
        'CALC_SYNC_SNAPSHOT_TOO_LARGE',
        'Calculation trace exceeds the supported immutable sync-event size.',
      );
    }
    database.transaction((tx) {
      tx.execute(
        '''INSERT INTO calculation_runs
           (calculation_id,parent_calculation_id,run_id,sample_id,step_id,pack_id,
            pack_version,pack_sha256,input_json,source_assets_json,status,trace_json,
            trace_sha256,output_json,result_json,error_code,started_at_utc,
            finished_at_utc,completed_at_utc,revision)
           VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)''',
        [
          run.calculationId,
          run.parentCalculationId,
          run.runId,
          run.sampleId,
          run.stepId,
          run.packId,
          run.packVersion,
          run.packSha256,
          inputJson,
          sourcesJson,
          status,
          traceJson,
          trace.contentSha256,
          outputJson,
          outputJson,
          run.errorCode,
          run.createdAtUtc.toUtc().toIso8601String(),
          run.completedAtUtc!.toUtc().toIso8601String(),
          run.completedAtUtc!.toUtc().toIso8601String(),
          run.revision,
        ],
      );
      final command = CommandMetadata(
        commandId: _idGenerator(),
        utcTime: run.completedAtUtc!,
      );
      tx.appendMutation(MutationEventDraft(
        command: command,
        deviceId: vault.deviceId,
        entityType: 'calculation',
        entityId: run.calculationId,
        eventType: status == 'completed' ? 'calculation.completed' : 'calculation.failed',
        action: MutationAction.create,
        payloadJson: mutationPayloadJson,
        assetShaRefs: run.sourceAssets.map((asset) => asset['sha256']! as String).toList(),
      ));
    });
  }

  CalculationRun _runFromRow(DbRow row) {
    final traceJson = row['trace_json'];
    final traceHash = row['trace_sha256'];
    final trace = traceJson is String ? CalculationTrace.fromJson(traceJson) : null;
    if (trace != null && (traceHash is! String || trace.contentSha256 != traceHash)) {
      throw const ValidationException(
        'CALC_TRACE_HASH_MISMATCH',
        'A stored calculation trace does not match its SHA-256.',
      );
    }
    if (trace != null && trace.calculationId != row['calculation_id']) {
      throw const ValidationException(
        'CALC_TRACE_ID_MISMATCH',
        'A stored CalculationTrace identifies a different CalculationRun.',
      );
    }
    final sourcesJson = row['source_assets_json'] as String;
    final sourcesDecoded = jsonDecode(sourcesJson);
    final outputJson = row['output_json'];
    final outputDecoded = outputJson is String ? jsonDecode(outputJson) : null;
    final sourceAssets = _sourceAssetRows(sourcesDecoded);
    final output = outputDecoded is Map ? requireJsonObject(outputDecoded, 'output_json') : null;
    return CalculationRun(
      calculationId: row['calculation_id']! as String,
      parentCalculationId: row['parent_calculation_id'] as String?,
      runId: row['run_id'] as String?,
      sampleId: row['sample_id'] as String?,
      stepId: row['step_id'] as String?,
      packId: row['pack_id']! as String,
      packVersion: row['pack_version']! as String,
      packSha256: row['pack_sha256']! as String,
      status: CalculationStatus.values.byName(row['status']! as String),
      inputSnapshot: requireJsonObject(jsonDecode(row['input_json']! as String), 'input_json'),
      sourceAssets: sourceAssets,
      output: output,
      trace: trace,
      errorCode: row['error_code'] as String?,
      createdAtUtc: DateTime.parse(row['started_at_utc']! as String).toUtc(),
      completedAtUtc: DateTime.parse(row['completed_at_utc']! as String).toUtc(),
      revision: _int(row['revision']),
    );
  }

  List<Map<String, Object?>> _validateSourceAssets(List<Map<String, Object?>> assets) {
    final result = <Map<String, Object?>>[];
    final seenIds = <String>{};
    final shaPattern = RegExp(r'^[a-f0-9]{64}$');
    for (final asset in assets) {
      const fields = {'asset_id', 'sha256', 'validation_level'};
      if (asset.keys.toSet().difference(fields).isNotEmpty ||
          asset['asset_id'] is! String ||
          asset['sha256'] is! String ||
          asset['validation_level'] is! String ||
          !shaPattern.hasMatch(asset['sha256'] as String) ||
          !{'verified', 'quick_checked', 'unknown'}.contains(asset['validation_level'])) {
        throw const FormatException('Each source Asset needs id, SHA-256, and truthful validation level.');
      }
      final id = asset['asset_id'] as String;
      if (id.isEmpty || !seenIds.add(id)) {
        throw const FormatException('Source Asset ids must be unique.');
      }
      result.add(Map<String, Object?>.unmodifiable(asset));
    }
    return List<Map<String, Object?>>.unmodifiable(result);
  }

  void _validateSnapshotSize(
    Map<String, Object?> inputSnapshot,
    List<Map<String, Object?>> sourceAssets,
  ) {
    if (utf8.encode(canonicalJson(inputSnapshot)).length >
        _maxCalculationInputSnapshotBytes) {
      throw const ValidationException(
        'CALC_INPUT_SNAPSHOT_TOO_LARGE',
        'Calculation input snapshots are limited to 4 MiB for immutable sync.',
      );
    }
    if (utf8.encode(canonicalJson(sourceAssets)).length >
        _maxCalculationSourceSnapshotBytes) {
      throw const ValidationException(
        'CALC_SOURCE_SNAPSHOT_TOO_LARGE',
        'Calculation source Asset metadata exceeds the supported sync size.',
      );
    }
  }

  List<Map<String, Object?>> _sourceAssetRows(Object? value) {
    if (value is! List) throw const FormatException('source_assets_json must be a list.');
    return value.map((item) => freezeJsonObject(requireJsonObject(item, 'source asset'))).toList();
  }

  Object? _traceInput(Object? value) {
    if (value is bool) return value ? 'true' : 'false';
    if (value is double) throw const FormatException('Float inputs are unsupported.');
    if (value is Map || value is List) return canonicalJson(value);
    if (value == null || value is String || value is int) return value;
    throw FormatException('Unsupported input snapshot type ${value.runtimeType}.');
  }

  void _rejectFloatingPoint(Object? value, String path) {
    if (value is double) throw FormatException('Float inputs are unsupported at $path.');
    if (value is List) {
      for (var index = 0; index < value.length; index++) {
        _rejectFloatingPoint(value[index], '$path[$index]');
      }
    } else if (value is Map) {
      for (final entry in value.entries) {
        _rejectFloatingPoint(entry.value, '$path.${entry.key}');
      }
    }
  }

  String _errorCode(Object error) {
    if (error is LabWorkspaceException) return error.code;
    final message = error.toString();
    final match = RegExp(r'\b(CALC_[A-Z0-9_]+)').firstMatch(message);
    return match?.group(1) ?? 'CALC_EXECUTION_FAILED';
  }

  int _int(Object? value) => switch (value) {
        int number => number,
        BigInt number => number.toInt(),
        _ => throw const FormatException('Expected an integer CalculationRun field.'),
      };
}

final class _ActiveCalculation {
  _ActiveCalculation({
    required this.calculationId,
    required this.pack,
    required this.inputSnapshot,
    required this.sourceAssets,
    required this.createdAtUtc,
    this.runId,
    this.sampleId,
    this.stepId,
    this.parentCalculationId,
  });

  final CalculationId calculationId;
  final VersionedCalculationPack pack;
  final Map<String, Object?> inputSnapshot;
  final List<Map<String, Object?>> sourceAssets;
  final String? runId;
  final String? sampleId;
  final String? stepId;
  final CalculationId? parentCalculationId;
  final DateTime createdAtUtc;
  CalculationJobState state = CalculationJobState.queued;
  bool cancelRequested = false;
  String? errorCode;
  DateTime? terminalAtUtc;

  bool get isTerminal => state == CalculationJobState.completed ||
      state == CalculationJobState.failed || state == CalculationJobState.cancelled;

  CalculationJobSnapshot get snapshot => CalculationJobSnapshot(
        calculationId: calculationId,
        packId: pack.packId,
        packVersion: pack.version,
        state: state,
        createdAtUtc: createdAtUtc,
        errorCode: errorCode,
      );
}

DateTime _utcNow() => DateTime.now().toUtc();
