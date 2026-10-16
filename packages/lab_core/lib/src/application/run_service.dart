import 'dart:convert';

import '../domain/commands.dart';
import '../domain/errors.dart';
import '../domain/events.dart';
import '../domain/ids.dart';
import '../domain/json_value.dart';
import '../domain/protocol_document.dart';
import '../domain/records.dart';
import '../domain/vault.dart';
import '../persistence/workspace_database.dart';
import '_service_support.dart';

final class RunService {
  const RunService(this.vault);

  final VaultContext vault;
  WorkspaceDatabase get _database => vault.database;

  RunRecord createRun({
    required String experimentId,
    required String title,
    String? protocolId,
    String? protocolVersion,
    Map<String, Object?> parameters = const <String, Object?>{},
    DateTime? plannedStartUtc,
    CommandMetadata? command,
  }) {
    if ((protocolId == null) != (protocolVersion == null)) {
      throw const ValidationException(
        'PROTOCOL_VERSION_REQUIRED',
        'A Run must include both protocolId and protocolVersion or neither.',
      );
    }
    final actualCommand = serviceCommand(command: command);
    final cleanTitle = normalizedText(title, 'title');
    final frozenParameters = freezeJsonObject(parameters);
    final payload = <String, Object?>{
      'experiment_id': experimentId,
      'title': cleanTitle,
      'protocol_id': protocolId,
      'protocol_version': protocolVersion,
      'parameter_snapshot': frozenParameters,
      'planned_start_utc': plannedStartUtc?.toUtc().toIso8601String(),
    };
    return _database.transaction((tx) {
      final prior = tx.findMutationByCommandId(actualCommand.commandId);
      if (prior != null) {
        final priorIntent = Map<String, Object?>.from(prior.payload)
          ..remove('protocol_snapshot')
          ..remove('state')
          ..remove('step_instances');
        if (prior.entityType != 'run' ||
            prior.eventType != 'run.created' ||
            prior.action != MutationAction.create ||
            canonicalJson(priorIntent) != canonicalJson(payload)) {
          throw CommandAlreadyAppliedException(actualCommand.commandId);
        }
        final rows = tx.query('SELECT * FROM experiment_runs WHERE run_id=?', [
          prior.entityId,
        ]);
        if (rows.isEmpty) throw MissingEntityException('Run', prior.entityId);
        return _runFromRow(rows.single);
      }
      final experiments = tx.query(
        'SELECT 1 FROM experiments WHERE experiment_id=? AND deleted_at_utc IS NULL',
        [experimentId],
      );
      if (experiments.isEmpty)
        throw MissingEntityException('Experiment', experimentId);

      Map<String, Object?> protocolDocument = const <String, Object?>{};
      String initialState = 'draft';
      List<Map<String, Object?>> protocolSteps = const [];
      if (protocolId != null && protocolVersion != null) {
        final rows = tx.query(
          '''SELECT payload_json,status FROM protocol_versions
             WHERE protocol_id=? AND version=?''',
          [protocolId, protocolVersion],
        );
        if (rows.isEmpty)
          throw MissingEntityException(
            'ProtocolVersion',
            '$protocolId@$protocolVersion',
          );
        if (rows.single['status'] != 'approved') {
          throw const ValidationException(
            'PROTOCOL_NOT_APPROVED',
            'Only an approved ProtocolVersion can be snapshotted into a live Run.',
          );
        }
        protocolDocument = requireJsonObject(
          jsonDecode(rows.single['payload_json']! as String),
          'protocol snapshot',
        );
        _validateParameters(protocolDocument, frozenParameters);
        protocolSteps = (protocolDocument['steps'] as List)
            .map((step) => requireJsonObject(step, 'protocol step'))
            .toList(growable: false);
        initialState = 'planned';
      }
      final runId = newUuidV7(at: actualCommand.normalizedUtcTime);
      final createdAt = actualCommand.normalizedUtcTime.toIso8601String();
      tx.execute(
        '''INSERT INTO experiment_runs
           (run_id,experiment_id,protocol_id,protocol_version,title,state,revision,
            parameter_snapshot_json,created_at_utc,protocol_snapshot_json,planned_start_utc)
           VALUES(?,?,?,?,?,?,1,?,?,?,?)''',
        [
          runId,
          experimentId,
          protocolId,
          protocolVersion,
          cleanTitle,
          initialState,
          jsonEncode(frozenParameters),
          createdAt,
          jsonEncode(protocolDocument),
          plannedStartUtc?.toUtc().toIso8601String(),
        ],
      );
      final stepIdByProtocolId = <String, String>{};
      for (final step in protocolSteps) {
        stepIdByProtocolId[step['step_id']! as String] = newUuidV7(
          at: actualCommand.normalizedUtcTime,
        );
      }
      final stepInstances = protocolSteps
          .map((step) {
            final duration = requireJsonObject(
              step['duration'],
              'step duration',
            );
            final params = step['params'] == null
                ? const <String, Object?>{}
                : requireJsonObject(step['params'], 'step parameters');
            return <String, Object?>{
              'step_id': stepIdByProtocolId[step['step_id'] as String],
              'protocol_step_id': step['step_id'],
              'kind': step['kind'],
              'title': step['title'],
              'instructions': step['instructions'] ?? '',
              'parameters': params,
              'human_gate': step['human_gate'] == true,
              'expected_seconds': duration['expected_seconds'],
              'duration_origin': _durationOriginForStorage(
                duration['source'] as String,
              ),
              'duration_min_seconds': null,
              'duration_max_seconds': null,
              'resource_key': null,
              'depends_on_step_ids': (step['depends_on'] as List)
                  .cast<String>()
                  .map((id) => stepIdByProtocolId[id]!)
                  .toList(growable: false),
            };
          })
          .toList(growable: false);
      for (final step in protocolSteps) {
        final dependencies = (step['depends_on'] as List).cast<String>();
        final duration = requireJsonObject(step['duration'], 'step duration');
        final expectedSeconds = duration['expected_seconds'] as int?;
        tx.execute(
          '''INSERT INTO step_executions
             (step_id,run_id,protocol_step_id,kind,title,state,expected_seconds,revision,
              captured_json,instructions,parameters_json,human_gate,repeat_index,
              duration_origin,planned_start_utc,planned_end_utc,duration_min_seconds,
              duration_max_seconds,resource_key)
             VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)''',
          [
            stepIdByProtocolId[step['step_id'] as String],
            runId,
            step['step_id'],
            step['kind'],
            step['title'],
            dependencies.isEmpty ? 'ready' : 'pending',
            expectedSeconds,
            1,
            '{}',
            step['instructions'] ?? '',
            jsonEncode(step['params'] ?? const <String, Object?>{}),
            step['human_gate'] == true ? 1 : 0,
            0,
            _durationOriginForStorage(duration['source'] as String),
            null,
            null,
            null,
            null,
            null,
          ],
        );
      }
      for (final step in protocolSteps) {
        for (final dependency in (step['depends_on'] as List).cast<String>()) {
          tx.execute(
            'INSERT INTO step_dependencies(step_id,required_step_id) VALUES(?,?)',
            [
              stepIdByProtocolId[step['step_id'] as String],
              stepIdByProtocolId[dependency],
            ],
          );
        }
      }
      appendServiceMutation(
        tx: tx,
        command: actualCommand,
        deviceId: vault.deviceId,
        entityType: 'run',
        entityId: runId,
        eventType: 'run.created',
        action: MutationAction.create,
        payload: <String, Object?>{
          ...payload,
          'protocol_snapshot': protocolDocument,
          'state': initialState,
          'step_instances': stepInstances,
        },
        assetShaRefs: _protocolAssetHashes(protocolDocument),
      );
      return _runFromRow(
        tx.query('SELECT * FROM experiment_runs WHERE run_id=?', [
          runId,
        ]).single,
      );
    });
  }

  List<RunRecord> listRuns({
    String? experimentId,
    String? state,
    int limit = 100,
    int offset = 0,
  }) {
    validatePagination(limit: limit, offset: offset);
    final where = <String>[];
    final bindings = <Object?>[];
    if (experimentId != null) {
      where.add('experiment_id=?');
      bindings.add(experimentId);
    }
    if (state != null) {
      where.add('state=?');
      bindings.add(state);
    }
    final clause = where.isEmpty ? '' : ' WHERE ${where.join(' AND ')}';
    bindings.add(limit);
    bindings.add(offset);
    return _database
        .query(
          'SELECT * FROM experiment_runs$clause ORDER BY created_at_utc DESC,run_id LIMIT ? OFFSET ?',
          bindings,
        )
        .map(_runFromRow)
        .toList(growable: false);
  }

  RunRecord? getRun(String runId) {
    final rows = _database.query(
      'SELECT * FROM experiment_runs WHERE run_id=?',
      [runId],
    );
    return rows.isEmpty ? null : _runFromRow(rows.single);
  }

  List<StepRecord> listSteps(String runId) {
    final rows = _database.query(
      'SELECT * FROM step_executions WHERE run_id=? ORDER BY rowid',
      [runId],
    );
    return rows
        .map(
          (row) => _stepFromRow(
            row,
            _database
                .query(
                  'SELECT required_step_id FROM step_dependencies WHERE step_id=? ORDER BY required_step_id',
                  [row['step_id']],
                )
                .map((dependency) => dependency['required_step_id']! as String)
                .toList(),
          ),
        )
        .toList(growable: false);
  }

  MeasurementRecord? getMeasurement(String measurementId) {
    final rows = _database.query(
      'SELECT * FROM measurements WHERE measurement_id=?',
      [measurementId],
    );
    return rows.isEmpty ? null : _measurementFromRow(rows.single);
  }

  List<MeasurementRecord> listMeasurements({
    String? runId,
    String? sampleId,
    bool includeSuperseded = false,
    int limit = 100,
    int offset = 0,
  }) {
    validatePagination(limit: limit, offset: offset);
    final conditions = <String>[];
    final bindings = <Object?>[];
    if (runId != null) {
      conditions.add('run_id=?');
      bindings.add(runId);
    }
    if (sampleId != null) {
      conditions.add('sample_id=?');
      bindings.add(sampleId);
    }
    if (!includeSuperseded) conditions.add("state<>'superseded'");
    final where = conditions.isEmpty
        ? ''
        : ' WHERE ${conditions.join(' AND ')}';
    bindings
      ..add(limit)
      ..add(offset);
    return _database
        .query(
          'SELECT * FROM measurements$where ORDER BY created_at_utc DESC,measurement_id LIMIT ? OFFSET ?',
          bindings,
        )
        .map(_measurementFromRow)
        .toList(growable: false);
  }

  StepRecord startStep(
    String stepId, {
    int? expectedRevision,
    CommandMetadata? command,
  }) {
    final actualCommand = serviceCommand(command: command);
    return _database.transaction((tx) {
      final row = _requireStep(tx, stepId);
      final state = row['state']! as String;
      final revision = intFromDb(row['revision']);
      final now = actualCommand.normalizedUtcTime;
      final dueAt = row['expected_seconds'] == null
          ? null
          : now.add(Duration(seconds: intFromDb(row['expected_seconds'])));
      final payload = <String, Object?>{
        'step_id': stepId,
        'started_at_utc': now.toIso8601String(),
        'due_at_utc': dueAt?.toIso8601String(),
      };
      final prior = replayMutation(
        tx: tx,
        command: actualCommand,
        entityType: 'step',
        entityId: stepId,
        eventType: 'step.started',
        action: MutationAction.patch,
        payload: payload,
      );
      if (prior != null)
        return _stepFromRow(
          _requireStep(tx, stepId),
          _dependencies(tx, stepId),
        );
      if (expectedRevision != null && expectedRevision != revision) {
        throw RevisionConflictException(
          entityType: 'step',
          entityId: stepId,
          expectedRevision: expectedRevision,
          actualRevision: revision,
        );
      }
      final mutationCommand = serviceCommandAtRevision(
        actualCommand,
        entityType: 'step',
        entityId: stepId,
        revision: revision,
      );
      if (state != 'ready' && state != 'pending') {
        throw ValidationException(
          'STEP_CANNOT_START',
          'Step $stepId in state $state cannot start.',
        );
      }
      final blockers = tx.query(
        '''SELECT d.required_step_id FROM step_dependencies d
           JOIN step_executions parent ON parent.step_id=d.required_step_id
           WHERE d.step_id=? AND parent.state NOT IN('completed','skipped')''',
        [stepId],
      );
      if (blockers.isNotEmpty) {
        throw ValidationException(
          'STEP_DEPENDENCIES_INCOMPLETE',
          'A Step can start only after all prerequisite Steps complete.',
          details: {
            'blocked_by': blockers
                .map((item) => item['required_step_id'])
                .toList(),
          },
        );
      }
      final changed = tx.execute(
        '''UPDATE step_executions SET state=?,started_at_utc=?,due_at_utc=?,
             revision=revision+1 WHERE step_id=? AND revision=?''',
        [
          row['kind'] == 'wait' ? 'waiting' : 'running',
          now.toIso8601String(),
          dueAt?.toIso8601String(),
          stepId,
          revision,
        ],
      );
      if (changed != 1)
        throw RevisionConflictException(
          entityType: 'step',
          entityId: stepId,
          expectedRevision: revision,
          actualRevision: intFromDb(_requireStep(tx, stepId)['revision']),
        );
      final runId = row['run_id']! as String;
      tx.execute(
        '''UPDATE experiment_runs SET state='running',started_at_utc=COALESCE(started_at_utc,?),
             revision=revision+1 WHERE run_id=? AND state IN('draft','planned','paused')''',
        [now.toIso8601String(), runId],
      );
      appendServiceMutation(
        tx: tx,
        command: mutationCommand,
        deviceId: vault.deviceId,
        entityType: 'step',
        entityId: stepId,
        eventType: 'step.started',
        action: MutationAction.patch,
        payload: payload,
      );
      _appendStepEvent(
        tx,
        stepId: stepId,
        command: mutationCommand,
        eventType: 'started',
        occurredAt: now,
        data: {'due_at_utc': dueAt?.toIso8601String()},
      );
      return _stepFromRow(_requireStep(tx, stepId), _dependencies(tx, stepId));
    });
  }

  RunRecord closeRun({
    required String runId,
    required int expectedRevision,
    required String state,
    String? reason,
    CommandMetadata? command,
  }) {
    if (!const {'completed', 'failed', 'cancelled'}.contains(state)) {
      throw ValidationException(
        'RUN_CLOSE_STATE_INVALID',
        'Unsupported terminal Run state: $state.',
      );
    }
    final cleanReason = state == 'completed'
        ? reason?.trim()
        : normalizedText(reason ?? '', 'reason');
    final actualCommand = serviceCommand(command: command);
    final finishedAt = actualCommand.normalizedUtcTime;
    final payload = <String, Object?>{
      'run_id': runId,
      'state': state,
      'reason': cleanReason,
      'finished_at_utc': finishedAt.toIso8601String(),
    };
    return _database.transaction((tx) {
      final rows = tx.query('SELECT * FROM experiment_runs WHERE run_id=?', [
        runId,
      ]);
      if (rows.isEmpty) throw MissingEntityException('Run', runId);
      final prior = replayMutation(
        tx: tx,
        command: actualCommand,
        entityType: 'run',
        entityId: runId,
        eventType: 'run.closed',
        action: MutationAction.patch,
        payload: payload,
      );
      if (prior != null) return _runFromRow(rows.single);
      final row = rows.single;
      final revision = intFromDb(row['revision']);
      if (revision != expectedRevision) {
        throw RevisionConflictException(
          entityType: 'run',
          entityId: runId,
          expectedRevision: expectedRevision,
          actualRevision: revision,
        );
      }
      final mutationCommand = serviceCommandAtRevision(
        actualCommand,
        entityType: 'run',
        entityId: runId,
        revision: revision,
      );
      if (const {'completed', 'failed', 'cancelled'}.contains(row['state'])) {
        throw ValidationException('RUN_TERMINAL', 'Run is already terminal.');
      }
      final unfinished = tx.query(
        "SELECT * FROM step_executions WHERE run_id=? AND state NOT IN('completed','skipped') ORDER BY rowid",
        [runId],
      );
      if (state == 'completed' && unfinished.isNotEmpty) {
        throw const ValidationException(
          'RUN_INCOMPLETE',
          'A Run can be completed only after every Step is completed or skipped.',
        );
      }
      for (final step in unfinished) {
        final stepId = step['step_id']! as String;
        if (step['state'] == 'failed') continue;
        final wasActive = const {'running', 'waiting'}.contains(step['state']);
        final stepState = wasActive && state == 'failed' ? 'failed' : 'skipped';
        tx.execute(
          '''UPDATE step_executions SET state=?,completed_at_utc=?,due_at_utc=NULL,
               revision=revision+1 WHERE step_id=?''',
          [stepState, finishedAt.toIso8601String(), stepId],
        );
        _appendStepEvent(
          tx,
          stepId: stepId,
          command: mutationCommand,
          eventType: stepState,
          occurredAt: finishedAt,
          data: {'run_outcome': state, 'reason': cleanReason},
        );
      }
      final changed = tx.execute(
        'UPDATE experiment_runs SET state=?,finished_at_utc=?,revision=revision+1 WHERE run_id=? AND revision=?',
        [state, finishedAt.toIso8601String(), runId, revision],
      );
      if (changed != 1) {
        throw RevisionConflictException(
          entityType: 'run',
          entityId: runId,
          expectedRevision: revision,
          actualRevision: intFromDb(
            tx.query('SELECT revision FROM experiment_runs WHERE run_id=?', [
              runId,
            ]).single['revision'],
          ),
        );
      }
      appendServiceMutation(
        tx: tx,
        command: mutationCommand,
        deviceId: vault.deviceId,
        entityType: 'run',
        entityId: runId,
        eventType: 'run.closed',
        action: MutationAction.patch,
        payload: payload,
      );
      return _runFromRow(
        tx.query('SELECT * FROM experiment_runs WHERE run_id=?', [
          runId,
        ]).single,
      );
    });
  }

  /// Adds an executable step to a live Run without changing its ProtocolVersion
  /// snapshot. This supports ad hoc experiments while keeping the originating
  /// protocol immutable.
  StepRecord addAdHocStep({
    required String runId,
    required String kind,
    required String title,
    String instructions = '',
    int? expectedSeconds,
    int? durationMinSeconds,
    int? durationMaxSeconds,
    String durationOrigin = 'unknown',
    List<String> dependsOnStepIds = const [],
    Map<String, Object?> parameters = const <String, Object?>{},
    bool humanGate = true,
    String? resourceKey,
    DateTime? plannedStartUtc,
    CommandMetadata? command,
  }) {
    const stepKinds = {
      'action',
      'wait',
      'measure',
      'calculate',
      'image',
      'record',
      'decision',
      'repeat',
      'sample',
      'review',
    };
    if (!stepKinds.contains(kind)) {
      throw ValidationException(
        'STEP_KIND_UNSUPPORTED',
        'Unsupported ad hoc Step kind: $kind.',
      );
    }
    if (expectedSeconds != null && expectedSeconds < 0 ||
        durationMinSeconds != null && durationMinSeconds < 0 ||
        durationMaxSeconds != null && durationMaxSeconds < 0 ||
        durationMinSeconds != null &&
            durationMaxSeconds != null &&
            durationMinSeconds > durationMaxSeconds) {
      throw const ValidationException(
        'STEP_DURATION_INVALID',
        'Step duration bounds are invalid.',
      );
    }
    if (!const {
      'user',
      'sop',
      'historical',
      'ai_estimate',
      'unknown',
    }.contains(durationOrigin)) {
      throw const ValidationException(
        'STEP_DURATION_ORIGIN_INVALID',
        'Unsupported Step duration origin.',
      );
    }
    final actualCommand = serviceCommand(command: command);
    final cleanTitle = normalizedText(title, 'title');
    final frozenParameters = freezeJsonObject(parameters);
    final uniqueDependencies = dependsOnStepIds.toSet().toList()..sort();
    if (uniqueDependencies.length != dependsOnStepIds.length) {
      throw const ValidationException(
        'STEP_DEPENDENCY_DUPLICATE',
        'Ad hoc Step dependencies must be unique.',
      );
    }
    final planned = plannedStartUtc?.toUtc();
    final payload = <String, Object?>{
      'run_id': runId,
      'kind': kind,
      'title': cleanTitle,
      'instructions': instructions,
      'expected_seconds': expectedSeconds,
      'duration_min_seconds': durationMinSeconds,
      'duration_max_seconds': durationMaxSeconds,
      'duration_origin': durationOrigin,
      'depends_on_step_ids': uniqueDependencies,
      'parameters': frozenParameters,
      'human_gate': humanGate,
      'resource_key': resourceKey,
      'planned_start_utc': planned?.toIso8601String(),
    };
    return _database.transaction((tx) {
      final prior = replayMutation(
        tx: tx,
        command: actualCommand,
        entityType: 'step',
        eventType: 'step.added',
        action: MutationAction.create,
        payload: payload,
      );
      if (prior != null)
        return _stepFromRow(
          _requireStep(tx, prior.entityId),
          _dependencies(tx, prior.entityId),
        );
      final runs = tx.query(
        'SELECT state FROM experiment_runs WHERE run_id=?',
        [runId],
      );
      if (runs.isEmpty) throw MissingEntityException('Run', runId);
      if (const {
        'completed',
        'failed',
        'cancelled',
      }.contains(runs.single['state'])) {
        throw ValidationException(
          'RUN_TERMINAL',
          'A terminal Run cannot accept new Steps.',
        );
      }
      for (final dependencyId in uniqueDependencies) {
        final dependency = tx.query(
          'SELECT run_id FROM step_executions WHERE step_id=?',
          [dependencyId],
        );
        if (dependency.isEmpty)
          throw MissingEntityException('Dependency Step', dependencyId);
        if (dependency.single['run_id'] != runId) {
          throw const ValidationException(
            'STEP_DEPENDENCY_RUN_MISMATCH',
            'Step dependencies must belong to the same Run.',
          );
        }
      }
      final stepId = newUuidV7(at: actualCommand.normalizedUtcTime);
      tx.execute(
        '''INSERT INTO step_executions
           (step_id,run_id,protocol_step_id,kind,title,state,planned_start_utc,started_at_utc,
            due_at_utc,completed_at_utc,expected_seconds,revision,captured_json,instructions,
            parameters_json,human_gate,repeat_index,resource_key,duration_origin,
            duration_min_seconds,duration_max_seconds,planned_end_utc)
           VALUES(?,?,NULL,?,?,?, ?,NULL,NULL,NULL,?,1,'{}',?,?,?,?,?,?,?,?,NULL)''',
        [
          stepId,
          runId,
          kind,
          cleanTitle,
          uniqueDependencies.isEmpty ? 'ready' : 'pending',
          planned?.toIso8601String(),
          expectedSeconds,
          instructions,
          jsonEncode(frozenParameters),
          humanGate ? 1 : 0,
          0,
          resourceKey,
          durationOrigin,
          durationMinSeconds,
          durationMaxSeconds,
        ],
      );
      for (final dependencyId in uniqueDependencies) {
        tx.execute(
          'INSERT INTO step_dependencies(step_id,required_step_id) VALUES(?,?)',
          [stepId, dependencyId],
        );
      }
      tx.execute(
        "UPDATE experiment_runs SET state='planned',revision=revision+1 WHERE run_id=? AND state='draft'",
        [runId],
      );
      appendServiceMutation(
        tx: tx,
        command: actualCommand,
        deviceId: vault.deviceId,
        entityType: 'step',
        entityId: stepId,
        eventType: 'step.added',
        action: MutationAction.create,
        payload: payload,
      );
      return _stepFromRow(_requireStep(tx, stepId), _dependencies(tx, stepId));
    });
  }

  static String _durationOriginForStorage(String source) => switch (source) {
    'history' => 'historical',
    'ai_suggestion' => 'ai_estimate',
    _ => source,
  };

  StepRecord completeStep(
    String stepId, {
    Map<String, Object?> captured = const <String, Object?>{},
    int? expectedRevision,
    CommandMetadata? command,
  }) {
    final actualCommand = serviceCommand(command: command);
    final frozenCaptured = freezeJsonObject(captured);
    return _database.transaction((tx) {
      final row = _requireStep(tx, stepId);
      final state = row['state']! as String;
      final revision = intFromDb(row['revision']);
      final now = actualCommand.normalizedUtcTime;
      final payload = <String, Object?>{
        'step_id': stepId,
        'captured': frozenCaptured,
        'completed_at_utc': now.toIso8601String(),
      };
      final prior = replayMutation(
        tx: tx,
        command: actualCommand,
        entityType: 'step',
        entityId: stepId,
        eventType: 'step.completed',
        action: MutationAction.patch,
        payload: payload,
      );
      if (prior != null)
        return _stepFromRow(
          _requireStep(tx, stepId),
          _dependencies(tx, stepId),
        );
      if (expectedRevision != null && expectedRevision != revision) {
        throw RevisionConflictException(
          entityType: 'step',
          entityId: stepId,
          expectedRevision: expectedRevision,
          actualRevision: revision,
        );
      }
      final mutationCommand = serviceCommandAtRevision(
        actualCommand,
        entityType: 'step',
        entityId: stepId,
        revision: revision,
      );
      if (state != 'running' && state != 'waiting') {
        throw ValidationException(
          'STEP_CANNOT_COMPLETE',
          'Only a running or waiting Step can be completed.',
        );
      }
      final dueAt = optionalDateFromDb(row['due_at_utc']);
      if (state == 'waiting' && dueAt != null && now.isBefore(dueAt)) {
        throw ValidationException(
          'WAIT_STEP_NOT_ELAPSED',
          'A timed wait cannot complete before its due time.',
          details: {'due_at_utc': dueAt.toIso8601String()},
        );
      }
      _validateRequiredCaptures(tx, row, frozenCaptured);
      final changed = tx.execute(
        '''UPDATE step_executions SET state='completed',completed_at_utc=?,captured_json=?,
             due_at_utc=NULL,revision=revision+1 WHERE step_id=? AND revision=? AND state IN('running','waiting') ''',
        [now.toIso8601String(), jsonEncode(frozenCaptured), stepId, revision],
      );
      if (changed != 1)
        throw RevisionConflictException(
          entityType: 'step',
          entityId: stepId,
          expectedRevision: revision,
          actualRevision: intFromDb(_requireStep(tx, stepId)['revision']),
        );
      final runId = row['run_id']! as String;
      tx.execute(
        '''UPDATE step_executions SET state='ready',revision=revision+1
           WHERE run_id=? AND state='pending'
             AND NOT EXISTS (
               SELECT 1 FROM step_dependencies d JOIN step_executions p ON p.step_id=d.required_step_id
               WHERE d.step_id=step_executions.step_id AND p.state NOT IN('completed','skipped')
             )''',
        [runId],
      );
      final remaining = tx.query(
        "SELECT COUNT(*) AS count FROM step_executions WHERE run_id=? AND state NOT IN('completed','skipped')",
        [runId],
      );
      if (intFromDb(remaining.single['count']) == 0) {
        tx.execute(
          "UPDATE experiment_runs SET state='completed',finished_at_utc=?,revision=revision+1 WHERE run_id=?",
          [now.toIso8601String(), runId],
        );
      }
      appendServiceMutation(
        tx: tx,
        command: mutationCommand,
        deviceId: vault.deviceId,
        entityType: 'step',
        entityId: stepId,
        eventType: 'step.completed',
        action: MutationAction.patch,
        payload: payload,
      );
      _appendStepEvent(
        tx,
        stepId: stepId,
        command: mutationCommand,
        eventType: 'completed',
        occurredAt: now,
        data: {'captured': frozenCaptured},
      );
      return _stepFromRow(_requireStep(tx, stepId), _dependencies(tx, stepId));
    });
  }

  MeasurementRecord recordMeasurement({
    required String runId,
    String? stepId,
    String? sampleId,
    required String analyte,
    required String valueText,
    String? unit,
    String? rawAssetId,
    String state = 'recorded',
    String? sourceMethod,
    String? sourceRef,
    String? calculationId,
    CommandMetadata? command,
  }) {
    if (!const {'draft_ai', 'recorded', 'user_confirmed'}.contains(state)) {
      throw ValidationException(
        'MEASUREMENT_STATE_INVALID',
        'Unsupported initial Measurement state: $state.',
      );
    }
    final actualCommand = serviceCommand(command: command);
    final cleanAnalyte = normalizedText(analyte, 'analyte');
    final cleanValue = normalizedText(valueText, 'valueText');
    final payload = <String, Object?>{
      'run_id': runId,
      'step_id': stepId,
      'sample_id': sampleId,
      'analyte': cleanAnalyte,
      'value_text': cleanValue,
      'unit': unit,
      'raw_asset_id': rawAssetId,
      'state': state,
      'source_method': sourceMethod,
      'source_ref': sourceRef,
      'calculation_id': calculationId,
    };
    return _database.transaction((tx) {
      final prior = replayMutation(
        tx: tx,
        command: actualCommand,
        entityType: 'measurement',
        eventType: 'measurement.recorded',
        action: MutationAction.create,
        payload: payload,
      );
      if (prior != null) {
        final rows = tx.query(
          'SELECT * FROM measurements WHERE measurement_id=?',
          [prior.entityId],
        );
        if (rows.isEmpty)
          throw MissingEntityException('Measurement', prior.entityId);
        return _measurementFromRow(rows.single);
      }
      if (tx.query('SELECT 1 FROM experiment_runs WHERE run_id=?', [
        runId,
      ]).isEmpty) {
        throw MissingEntityException('Run', runId);
      }
      if (stepId != null &&
          tx.query(
            'SELECT 1 FROM step_executions WHERE step_id=? AND run_id=?',
            [stepId, runId],
          ).isEmpty) {
        throw ValidationException(
          'STEP_RUN_MISMATCH',
          'Measurement Step does not belong to this Run.',
        );
      }
      if (sampleId != null &&
          tx.query('SELECT 1 FROM run_samples WHERE run_id=? AND sample_id=?', [
            runId,
            sampleId,
          ]).isEmpty) {
        throw ValidationException(
          'SAMPLE_RUN_LINK_REQUIRED',
          'Attach the Sample to this Run before recording its Measurement.',
        );
      }
      var assetSha = <String>[];
      if (rawAssetId != null) {
        final assets = tx.query(
          '''SELECT a.blob_sha256 FROM assets a JOIN blob_objects b ON b.sha256=a.blob_sha256
             WHERE a.asset_id=? AND a.deleted_at_utc IS NULL AND b.state='committed' ''',
          [rawAssetId],
        );
        if (assets.isEmpty)
          throw MissingEntityException('Active Asset', rawAssetId);
        assetSha = [assets.single['blob_sha256']! as String];
      }
      if (calculationId != null) {
        requireCalculationOutputForMeasurement(
          tx: tx,
          calculationId: calculationId,
          runId: runId,
          stepId: stepId,
          sampleId: sampleId,
          analyte: cleanAnalyte,
          valueText: cleanValue,
          unit: unit,
          rawAssetId: rawAssetId,
        );
      }
      final measurementId = newUuidV7(at: actualCommand.normalizedUtcTime);
      final now = actualCommand.normalizedUtcTime.toIso8601String();
      tx.execute(
        '''INSERT INTO measurements
           (measurement_id,run_id,step_id,sample_id,analyte,value_text,unit,raw_asset_id,state,
            created_at_utc,source_method,source_ref,confirmed_at_utc,confirmed_by,revision,calculation_id)
           VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,1,?)''',
        [
          measurementId,
          runId,
          stepId,
          sampleId,
          cleanAnalyte,
          cleanValue,
          unit,
          rawAssetId,
          state,
          now,
          sourceMethod,
          sourceRef,
          state == 'user_confirmed' ? now : null,
          state == 'user_confirmed' ? actualCommand.actor : null,
          calculationId,
        ],
      );
      appendServiceMutation(
        tx: tx,
        command: actualCommand,
        deviceId: vault.deviceId,
        entityType: 'measurement',
        entityId: measurementId,
        eventType: 'measurement.recorded',
        action: MutationAction.create,
        payload: payload,
        assetShaRefs: assetSha,
      );
      return _measurementFromRow(
        tx.query('SELECT * FROM measurements WHERE measurement_id=?', [
          measurementId,
        ]).single,
      );
    });
  }

  MeasurementRecord confirmMeasurement({
    required String measurementId,
    int? expectedRevision,
    CommandMetadata? command,
  }) {
    final actualCommand = serviceCommand(command: command);
    return _database.transaction((tx) {
      final rows = tx.query(
        'SELECT * FROM measurements WHERE measurement_id=?',
        [measurementId],
      );
      if (rows.isEmpty)
        throw MissingEntityException('Measurement', measurementId);
      final row = rows.single;
      final revision = intFromDb(row['revision']);
      final oldState = row['state']! as String;
      final now = actualCommand.normalizedUtcTime;
      final payload = <String, Object?>{
        'measurement_id': measurementId,
        'to_state': 'user_confirmed',
        'confirmed_at_utc': now.toIso8601String(),
      };
      final prior = replayMutation(
        tx: tx,
        command: actualCommand,
        entityType: 'measurement',
        entityId: measurementId,
        eventType: 'measurement.confirmed',
        action: MutationAction.patch,
        payload: payload,
      );
      if (prior != null)
        return _measurementFromRow(
          tx.query('SELECT * FROM measurements WHERE measurement_id=?', [
            measurementId,
          ]).single,
        );
      if (expectedRevision != null && expectedRevision != revision) {
        throw RevisionConflictException(
          entityType: 'measurement',
          entityId: measurementId,
          expectedRevision: expectedRevision,
          actualRevision: revision,
        );
      }
      final mutationCommand = serviceCommandAtRevision(
        actualCommand,
        entityType: 'measurement',
        entityId: measurementId,
        revision: revision,
      );
      if (oldState != 'recorded' && oldState != 'draft_ai') {
        throw ValidationException(
          'MEASUREMENT_CANNOT_CONFIRM',
          'Measurement in state $oldState cannot be confirmed.',
        );
      }
      tx.execute(
        '''UPDATE measurements SET state='user_confirmed',confirmed_at_utc=?,confirmed_by=?,
             revision=revision+1 WHERE measurement_id=? AND revision=?''',
        [now.toIso8601String(), actualCommand.actor, measurementId, revision],
      );
      appendServiceMutation(
        tx: tx,
        command: mutationCommand,
        deviceId: vault.deviceId,
        entityType: 'measurement',
        entityId: measurementId,
        eventType: 'measurement.confirmed',
        action: MutationAction.patch,
        payload: payload,
        assetShaRefs: row['raw_asset_id'] == null
            ? const []
            : [
                tx.query('SELECT blob_sha256 FROM assets WHERE asset_id=?', [
                      row['raw_asset_id'],
                    ]).single['blob_sha256']!
                    as String,
              ],
      );
      return _measurementFromRow(
        tx.query('SELECT * FROM measurements WHERE measurement_id=?', [
          measurementId,
        ]).single,
      );
    });
  }

  MeasurementRecord correctMeasurement({
    required String measurementId,
    required int expectedRevision,
    required String correctionReason,
    String? analyte,
    String? valueText,
    String? unit,
    String? rawAssetId,
    String? calculationId,
    bool clearUnit = false,
    bool clearRawAsset = false,
    bool clearCalculation = false,
    CommandMetadata? command,
  }) {
    final reason = normalizedText(correctionReason, 'correctionReason');
    final actualCommand = serviceCommand(command: command);
    return _database.transaction((tx) {
      final rows = tx.query(
        'SELECT * FROM measurements WHERE measurement_id=?',
        [measurementId],
      );
      if (rows.isEmpty)
        throw MissingEntityException('Measurement', measurementId);
      final original = rows.single;
      final revision = intFromDb(original['revision']);
      final newAnalyte = normalizedText(
        analyte ?? original['analyte']! as String,
        'analyte',
      );
      final newValue = normalizedText(
        valueText ?? original['value_text']! as String,
        'valueText',
      );
      if (clearCalculation && calculationId != null) {
        throw const ValidationException(
          'CORRECTION_CALCULATION_INPUT',
          'A corrected Measurement cannot both clear and set its CalculationRun link.',
        );
      }
      final newUnit = clearUnit ? null : unit ?? original['unit'] as String?;
      final newAsset = clearRawAsset
          ? null
          : rawAssetId ?? original['raw_asset_id'] as String?;
      final preservesCalculationOutput =
          newAnalyte == original['analyte'] &&
          newValue == original['value_text'] &&
          newUnit == original['unit'] &&
          newAsset == original['raw_asset_id'];
      final newCalculation = clearCalculation
          ? null
          : calculationId ??
                (preservesCalculationOutput
                    ? original['calculation_id'] as String?
                    : null);
      final createdAt = actualCommand.normalizedUtcTime.toIso8601String();
      final intent = <String, Object?>{
        'supersedes_measurement_id': measurementId,
        'run_id': original['run_id'],
        'step_id': original['step_id'],
        'sample_id': original['sample_id'],
        'analyte': newAnalyte,
        'value_text': newValue,
        'unit': newUnit,
        'raw_asset_id': newAsset,
        'calculation_id': newCalculation,
        'correction_reason': reason,
        'created_at_utc': createdAt,
      };
      final prior = tx.findMutationByCommandId(actualCommand.commandId);
      if (prior != null) {
        final priorIntent = Map<String, Object?>.from(prior.payload)
          ..remove('replacement_measurement_id');
        if (prior.entityType != 'measurement' ||
            prior.entityId != measurementId ||
            prior.eventType != 'measurement.corrected' ||
            prior.action != MutationAction.append ||
            canonicalJson(priorIntent) != canonicalJson(intent)) {
          throw CommandAlreadyAppliedException(actualCommand.commandId);
        }
        return _measurementFromRow(
          tx.query('SELECT * FROM measurements WHERE measurement_id=?', [
            prior.payload['replacement_measurement_id'],
          ]).single,
        );
      }
      if (revision != expectedRevision) {
        throw RevisionConflictException(
          entityType: 'measurement',
          entityId: measurementId,
          expectedRevision: expectedRevision,
          actualRevision: revision,
        );
      }
      if (original['superseded_by'] != null ||
          original['state'] == 'superseded') {
        throw ValidationException(
          'MEASUREMENT_ALREADY_CORRECTED',
          'A superseded Measurement cannot be corrected again.',
        );
      }
      final replacementId = newUuidV7(at: actualCommand.normalizedUtcTime);
      final payload = <String, Object?>{
        ...intent,
        'replacement_measurement_id': replacementId,
      };
      final mutationCommand = serviceCommandAtRevision(
        actualCommand,
        entityType: 'measurement',
        entityId: measurementId,
        revision: revision,
      );
      if (newCalculation != null) {
        requireCalculationOutputForMeasurement(
          tx: tx,
          calculationId: newCalculation,
          runId: original['run_id']! as String,
          stepId: original['step_id'] as String?,
          sampleId: original['sample_id'] as String?,
          analyte: newAnalyte,
          valueText: newValue,
          unit: newUnit,
          rawAssetId: newAsset,
        );
      }
      final shaRefs = <String>{};
      for (final assetId in <String?>[
        original['raw_asset_id'] as String?,
        newAsset,
      ]) {
        if (assetId == null) continue;
        final assets = tx.query(
          '''SELECT a.blob_sha256 FROM assets a JOIN blob_objects b ON b.sha256=a.blob_sha256
             WHERE a.asset_id=? AND a.deleted_at_utc IS NULL AND b.state='committed' ''',
          [assetId],
        );
        if (assets.isEmpty)
          throw MissingEntityException('Active Asset', assetId);
        shaRefs.add(assets.single['blob_sha256']! as String);
      }
      tx.execute(
        '''INSERT INTO measurements
           (measurement_id,run_id,step_id,sample_id,analyte,value_text,unit,raw_asset_id,state,
            superseded_by,created_at_utc,source_method,source_ref,confirmed_at_utc,confirmed_by,revision,calculation_id)
           VALUES(?,?,?,?,?,?,?,?,'recorded',NULL,?,'manual_correction',?,NULL,NULL,1,?)''',
        [
          replacementId,
          original['run_id'],
          original['step_id'],
          original['sample_id'],
          newAnalyte,
          newValue,
          newUnit,
          newAsset,
          createdAt,
          reason,
          newCalculation,
        ],
      );
      final changed = tx.execute(
        '''UPDATE measurements SET state='superseded',superseded_by=?,revision=revision+1
           WHERE measurement_id=? AND revision=? AND superseded_by IS NULL''',
        [replacementId, measurementId, revision],
      );
      if (changed != 1) {
        throw RevisionConflictException(
          entityType: 'measurement',
          entityId: measurementId,
          expectedRevision: revision,
          actualRevision: intFromDb(
            tx.query(
              'SELECT revision FROM measurements WHERE measurement_id=?',
              [measurementId],
            ).single['revision'],
          ),
        );
      }
      tx.execute(
        '''INSERT INTO measurement_corrections
           (correction_id,measurement_id,replacement_measurement_id,reason,created_at_utc,command_id)
           VALUES(?,?,?,?,?,?)''',
        [
          newUuidV7(at: actualCommand.normalizedUtcTime),
          measurementId,
          replacementId,
          reason,
          createdAt,
          actualCommand.commandId,
        ],
      );
      appendServiceMutation(
        tx: tx,
        command: mutationCommand,
        deviceId: vault.deviceId,
        entityType: 'measurement',
        entityId: measurementId,
        eventType: 'measurement.corrected',
        action: MutationAction.append,
        payload: payload,
        assetShaRefs: shaRefs.toList(growable: false)..sort(),
      );
      return _measurementFromRow(
        tx.query('SELECT * FROM measurements WHERE measurement_id=?', [
          replacementId,
        ]).single,
      );
    });
  }

  DbRow _requireStep(WorkspaceTransaction tx, String stepId) {
    final rows = tx.query('SELECT * FROM step_executions WHERE step_id=?', [
      stepId,
    ]);
    if (rows.isEmpty) throw MissingEntityException('Step', stepId);
    return rows.single;
  }

  List<String> _dependencies(WorkspaceTransaction tx, String stepId) => tx
      .query(
        'SELECT required_step_id FROM step_dependencies WHERE step_id=? ORDER BY required_step_id',
        [stepId],
      )
      .map((row) => row['required_step_id']! as String)
      .toList(growable: false);

  void _validateRequiredCaptures(
    WorkspaceTransaction tx,
    DbRow row,
    Map<String, Object?> captured,
  ) {
    final runRows = tx.query(
      'SELECT protocol_snapshot_json FROM experiment_runs WHERE run_id=?',
      [row['run_id']],
    );
    if (runRows.isEmpty || row['protocol_step_id'] == null) return;
    final snapshot = objectFromDb(runRows.single['protocol_snapshot_json']);
    final steps = snapshot['steps'];
    if (steps is! List) return;
    for (final value in steps) {
      final step = requireJsonObject(value, 'protocol step');
      if (step['step_id'] != row['protocol_step_id']) continue;
      final captures = step['captures'];
      if (captures is! List) return;
      for (final captureValue in captures) {
        final capture = requireJsonObject(captureValue, 'capture definition');
        if (capture['required'] == true &&
            (capture['key'] is! String ||
                !captured.containsKey(capture['key']))) {
          throw ValidationException(
            'REQUIRED_CAPTURE_MISSING',
            'Step completion needs every required captured value.',
            details: {'capture_key': capture['key']},
          );
        }
      }
      return;
    }
  }

  void _appendStepEvent(
    WorkspaceTransaction tx, {
    required String stepId,
    required CommandMetadata command,
    required String eventType,
    required DateTime occurredAt,
    required Map<String, Object?> data,
  }) {
    tx.execute(
      '''INSERT INTO step_events
         (event_id,step_id,event_type,event_data_json,occurred_at_utc,recorded_at_utc,command_id)
         VALUES(?,?,?,?,?,?,?)''',
      [
        newUuidV7(at: occurredAt),
        stepId,
        eventType,
        jsonEncode(data),
        occurredAt.toIso8601String(),
        DateTime.now().toUtc().toIso8601String(),
        command.commandId,
      ],
    );
  }

  void _validateParameters(
    Map<String, Object?> protocol,
    Map<String, Object?> values,
  ) => ProtocolDocument.requireValidParameterSnapshot(protocol, values);

  List<String> _protocolAssetHashes(Map<String, Object?> document) {
    final sources = document['sources'];
    if (sources is! List) return const [];
    return sources
        .map(
          (value) =>
              requireJsonObject(value, 'protocol source')['sha256']! as String,
        )
        .toList(growable: false);
  }

  RunRecord _runFromRow(DbRow row) => RunRecord(
    runId: row['run_id']! as String,
    experimentId: row['experiment_id'] as String?,
    protocolId: row['protocol_id'] as String?,
    protocolVersion: row['protocol_version'] as String?,
    title: row['title']! as String,
    state: row['state']! as String,
    revision: intFromDb(row['revision']),
    parameterSnapshot: objectFromDb(row['parameter_snapshot_json']),
    protocolSnapshot: objectFromDb(row['protocol_snapshot_json']),
    createdAtUtc: dateFromDb(row['created_at_utc']),
    plannedStartUtc: optionalDateFromDb(row['planned_start_utc']),
    startedAtUtc: optionalDateFromDb(row['started_at_utc']),
    finishedAtUtc: optionalDateFromDb(row['finished_at_utc']),
  );

  StepRecord _stepFromRow(DbRow row, List<String> dependencies) => StepRecord(
    stepId: row['step_id']! as String,
    runId: row['run_id']! as String,
    protocolStepId: row['protocol_step_id'] as String?,
    kind: row['kind']! as String,
    title: row['title']! as String,
    state: row['state']! as String,
    plannedStartUtc: optionalDateFromDb(row['planned_start_utc']),
    plannedEndUtc: optionalDateFromDb(row['planned_end_utc']),
    startedAtUtc: optionalDateFromDb(row['started_at_utc']),
    dueAtUtc: optionalDateFromDb(row['due_at_utc']),
    completedAtUtc: optionalDateFromDb(row['completed_at_utc']),
    expectedSeconds: row['expected_seconds'] == null
        ? null
        : intFromDb(row['expected_seconds']),
    durationMinSeconds: row['duration_min_seconds'] == null
        ? null
        : intFromDb(row['duration_min_seconds']),
    durationMaxSeconds: row['duration_max_seconds'] == null
        ? null
        : intFromDb(row['duration_max_seconds']),
    durationOrigin: row['duration_origin'] as String? ?? 'unknown',
    revision: intFromDb(row['revision']),
    captured: objectFromDb(row['captured_json']),
    parameters: objectFromDb(row['parameters_json']),
    humanGate: intFromDb(row['human_gate']) == 1,
    repeatIndex: intFromDb(row['repeat_index']),
    resourceKey: row['resource_key'] as String?,
    instructions: row['instructions'] as String? ?? '',
    dependencies: dependencies,
  );

  MeasurementRecord _measurementFromRow(DbRow row) => MeasurementRecord(
    measurementId: row['measurement_id']! as String,
    runId: row['run_id']! as String,
    stepId: row['step_id'] as String?,
    sampleId: row['sample_id'] as String?,
    analyte: row['analyte']! as String,
    valueText: row['value_text']! as String,
    unit: row['unit'] as String?,
    rawAssetId: row['raw_asset_id'] as String?,
    state: row['state']! as String,
    supersededBy: row['superseded_by'] as String?,
    sourceMethod: row['source_method'] as String?,
    sourceRef: row['source_ref'] as String?,
    calculationId: row['calculation_id'] as String?,
    remoteCalculationId: row['remote_calculation_id'] as String?,
    remoteCalculationOutputKey: row['remote_calculation_output_key'] as String?,
    remoteSourceEventId: row['remote_source_event_id'] as String?,
    remoteMeasurementId: row['remote_measurement_id'] as String?,
    createdAtUtc: dateFromDb(row['created_at_utc']),
    confirmedAtUtc: optionalDateFromDb(row['confirmed_at_utc']),
    revision: intFromDb(row['revision']),
  );
}
