import 'dart:convert';

import '../domain/commands.dart';
import '../domain/errors.dart';
import '../domain/events.dart';
import '../domain/ids.dart';
import '../domain/json_value.dart';
import '../domain/records.dart';
import '../domain/vault.dart';
import '../persistence/workspace_database.dart';
import 'run_service.dart';
import '_service_support.dart';

final class ScheduleService {
  const ScheduleService(this.vault);

  final VaultContext vault;
  WorkspaceDatabase get _database => vault.database;

  List<ScheduledStep> listUpcoming({DateTime? fromUtc, int limit = 100}) {
    validatePagination(limit: limit);
    final from = (fromUtc ?? DateTime.now().toUtc()).toUtc().toIso8601String();
    return _database
        .query(
          '''SELECT s.*,r.title AS run_title,
           COALESCE(s.planned_start_utc,s.due_at_utc,r.planned_start_utc) AS sort_at
         FROM step_executions s JOIN experiment_runs r ON r.run_id=s.run_id
         WHERE s.state IN('pending','ready','running','waiting','paused')
           AND (s.planned_start_utc IS NULL OR s.planned_start_utc>=?
                OR s.due_at_utc IS NULL OR s.due_at_utc>=?)
         ORDER BY (sort_at IS NULL),sort_at,r.title COLLATE NOCASE,s.step_id LIMIT ?''',
          [from, from, limit],
        )
        .map(
          (row) => ScheduledStep(
            stepId: row['step_id']! as String,
            runId: row['run_id']! as String,
            runTitle: row['run_title']! as String,
            title: row['title']! as String,
            state: row['state']! as String,
            plannedStartUtc: optionalDateFromDb(row['planned_start_utc']),
            plannedEndUtc: optionalDateFromDb(row['planned_end_utc']),
            dueAtUtc: optionalDateFromDb(row['due_at_utc']),
            expectedSeconds: row['expected_seconds'] == null
                ? null
                : intFromDb(row['expected_seconds']),
            durationOrigin: row['duration_origin'] as String? ?? 'unknown',
            humanGate: intFromDb(row['human_gate']) == 1,
          ),
        )
        .toList(growable: false);
  }

  SchedulePlan rebuildPlan({
    required String runId,
    required DateTime startAtUtc,
    CommandMetadata? command,
  }) {
    final actualCommand = serviceCommand(command: command);
    final start = startAtUtc.toUtc();
    return _database.transaction((tx) {
      final prior = tx.findMutationByCommandId(actualCommand.commandId);
      if (prior != null) {
        final expectedIntent = <String, Object?>{
          'run_id': runId,
          'start_at_utc': start.toIso8601String(),
        };
        final actualIntent = <String, Object?>{
          'run_id': prior.payload['run_id'],
          'start_at_utc': prior.payload['start_at_utc'],
        };
        if (prior.entityType != 'run' ||
            prior.entityId != runId ||
            prior.eventType != 'schedule.rebuilt' ||
            prior.action != MutationAction.patch ||
            canonicalJson(expectedIntent) != canonicalJson(actualIntent)) {
          throw CommandAlreadyAppliedException(actualCommand.commandId);
        }
        final traces = tx.query(
          'SELECT * FROM schedule_traces WHERE command_id=?',
          [actualCommand.commandId],
        );
        if (traces.isEmpty)
          throw MissingEntityException(
            'ScheduleTrace',
            actualCommand.commandId,
          );
        return _planFromRow(traces.single);
      }
      final runs = tx.query(
        'SELECT planned_start_utc,state,revision FROM experiment_runs WHERE run_id=?',
        [runId],
      );
      if (runs.isEmpty) throw MissingEntityException('Run', runId);
      final run = runs.single;
      if (const {'completed', 'failed', 'cancelled'}.contains(run['state'])) {
        throw const ValidationException(
          'RUN_TERMINAL',
          'A terminal Run cannot be rescheduled.',
        );
      }
      final revision = intFromDb(run['revision']);
      final mutationCommand = serviceCommandAtRevision(
        actualCommand,
        entityType: 'run',
        entityId: runId,
        revision: revision,
      );
      final rows = tx.query(
        'SELECT * FROM step_executions WHERE run_id=? ORDER BY rowid',
        [runId],
      );
      final stepsById = <String, DbRow>{
        for (final row in rows) row['step_id']! as String: row,
      };
      final dependencyMap = <String, List<String>>{};
      for (final id in stepsById.keys) {
        dependencyMap[id] = tx
            .query(
              'SELECT required_step_id FROM step_dependencies WHERE step_id=? ORDER BY required_step_id',
              [id],
            )
            .map((row) => row['required_step_id']! as String)
            .toList(growable: false);
      }
      final orderedIds = _topologicalOrder(dependencyMap);
      final plannedStarts = <String, DateTime?>{};
      final plannedEnds = <String, DateTime?>{};
      final resourceEnds = <String, DateTime?>{};
      final unavailableResources = <String>{};
      final warnings = <String>[];
      final scheduleSteps = <Map<String, Object?>>[];
      for (final id in orderedIds) {
        final row = stepsById[id]!;
        final dependencies = dependencyMap[id]!;
        final terminal = const {
          'completed',
          'skipped',
          'failed',
          'cancelled',
        }.contains(row['state']);
        DateTime? earliest;
        if (terminal) {
          // A rebuilt plan cannot rewrite historical plan timestamps for a
          // terminal Step. Preserve them in the new trace and as downstream
          // dependency inputs.
          earliest = optionalDateFromDb(row['planned_start_utc']);
        } else if (dependencies.isEmpty) {
          earliest = start;
        } else if (dependencies.every(
          (dependency) => plannedEnds[dependency] != null,
        )) {
          earliest = dependencies
              .map((dependency) => plannedEnds[dependency]!)
              .reduce((left, right) => left.isAfter(right) ? left : right);
        } else {
          warnings.add(
            'Step $id has a prerequisite with unknown planned end time.',
          );
        }
        final resource = row['resource_key'] as String?;
        if (!terminal && resource != null && resource.isNotEmpty) {
          if (unavailableResources.contains(resource)) {
            earliest = null;
            warnings.add(
              'Resource $resource has an earlier step with unknown duration.',
            );
          } else {
            final resourceEnd = resourceEnds[resource];
            if (resourceEnd != null &&
                (earliest == null || resourceEnd.isAfter(earliest))) {
              earliest = resourceEnd;
            }
          }
        }
        final duration = row['expected_seconds'] == null
            ? null
            : intFromDb(row['expected_seconds']);
        DateTime? end;
        if (terminal) {
          end = optionalDateFromDb(row['planned_end_utc']);
        } else if (earliest != null && duration != null) {
          end = earliest.add(Duration(seconds: duration));
        } else if (duration == null) {
          warnings.add(
            'Step $id has unknown duration; no end time was inferred.',
          );
        }
        if (resource != null && resource.isNotEmpty) {
          if (end == null) {
            unavailableResources.add(resource);
          } else {
            final priorEnd = resourceEnds[resource];
            if (priorEnd == null || end.isAfter(priorEnd)) {
              resourceEnds[resource] = end;
            }
          }
        }
        plannedStarts[id] = earliest;
        plannedEnds[id] = end;
        if (!terminal) {
          tx.execute(
            '''UPDATE step_executions SET planned_start_utc=?,planned_end_utc=?
               WHERE step_id=?''',
            [earliest?.toIso8601String(), end?.toIso8601String(), id],
          );
        }
        scheduleSteps.add(<String, Object?>{
          'step_id': id,
          'protocol_step_id': row['protocol_step_id'],
          'title': row['title'],
          'dependencies': dependencies,
          'resource_key': resource,
          'expected_seconds': duration,
          'duration_origin': row['duration_origin'],
          'planned_start_utc': earliest?.toIso8601String(),
          'planned_end_utc': end?.toIso8601String(),
        });
      }
      final generationRows = tx.query(
        'SELECT COALESCE(MAX(generation),0) AS generation FROM schedule_traces WHERE run_id=?',
        [runId],
      );
      final generation = intFromDb(generationRows.single['generation']) + 1;
      final traceId = newUuidV7(at: actualCommand.normalizedUtcTime);
      final scheduleJson = <String, Object?>{
        'start_at_utc': start.toIso8601String(),
        'steps': scheduleSteps,
      };
      final input = <String, Object?>{
        'run_id': runId,
        'start_at_utc': start.toIso8601String(),
        'step_count': rows.length,
        'generation': generation,
      };
      final warningsJson = List<String>.unmodifiable(warnings.toSet());
      final traceInput = <String, Object?>{...input};
      final traceSchedule = <String, Object?>{...scheduleJson};
      final traceDocument = <String, Object?>{
        'trace_id': traceId,
        'generation': generation,
        'input': traceInput,
        'schedule': traceSchedule,
        'warnings': warningsJson,
        'created_at_utc': actualCommand.normalizedUtcTime.toIso8601String(),
      };
      tx.execute(
        '''INSERT INTO schedule_traces
           (trace_id,run_id,generation,input_json,schedule_json,warnings_json,created_at_utc,command_id)
           VALUES(?,?,?,?,?,?,?,?)''',
        [
          traceId,
          runId,
          generation,
          jsonEncode(input),
          jsonEncode(scheduleJson),
          jsonEncode(warningsJson),
          actualCommand.normalizedUtcTime.toIso8601String(),
          actualCommand.commandId,
        ],
      );
      final changed = tx.execute(
        'UPDATE experiment_runs SET planned_start_utc=?,revision=revision+1 WHERE run_id=? AND revision=?',
        [start.toIso8601String(), runId, revision],
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
      final eventPayload = <String, Object?>{
        'run_id': runId,
        'start_at_utc': start.toIso8601String(),
        'generation': generation,
        'trace_id': traceId,
        'warnings': warningsJson,
        'schedule_trace': traceDocument,
      };
      appendServiceMutation(
        tx: tx,
        command: mutationCommand,
        deviceId: vault.deviceId,
        entityType: 'run',
        entityId: runId,
        eventType: 'schedule.rebuilt',
        action: MutationAction.patch,
        payload: eventPayload,
      );
      return SchedulePlan(
        traceId: traceId,
        runId: runId,
        generation: generation,
        startAtUtc: start,
        steps: _scheduledSteps(tx, runId),
        warnings: warningsJson,
      );
    });
  }

  SchedulePlan _planFromRow(DbRow row) {
    final schedule = objectFromDb(row['schedule_json']);
    final steps = (schedule['steps'] as List)
        .map((value) {
          final step = requireJsonObject(value, 'scheduled step');
          return ScheduledStep(
            stepId: step['step_id']! as String,
            runId: row['run_id']! as String,
            runTitle: '',
            title: step['title']! as String,
            state: 'planned',
            plannedStartUtc: optionalDateFromDb(step['planned_start_utc']),
            plannedEndUtc: optionalDateFromDb(step['planned_end_utc']),
            dueAtUtc: null,
            expectedSeconds: step['expected_seconds'] == null
                ? null
                : intFromDb(step['expected_seconds']),
            durationOrigin: step['duration_origin'] as String? ?? 'unknown',
            humanGate: false,
          );
        })
        .toList(growable: false);
    final input = objectFromDb(row['input_json']);
    return SchedulePlan(
      traceId: row['trace_id']! as String,
      runId: row['run_id']! as String,
      generation: intFromDb(row['generation']),
      startAtUtc: dateFromDb(input['start_at_utc']),
      steps: steps,
      warnings: stringListFromDb(row['warnings_json']),
    );
  }

  List<ScheduledStep> _scheduledSteps(WorkspaceTransaction tx, String runId) {
    final runTitleRows = tx.query(
      'SELECT title FROM experiment_runs WHERE run_id=?',
      [runId],
    );
    final runTitle = runTitleRows.isEmpty
        ? ''
        : runTitleRows.single['title']! as String;
    return tx
        .query('SELECT * FROM step_executions WHERE run_id=? ORDER BY rowid', [
          runId,
        ])
        .map(
          (row) => ScheduledStep(
            stepId: row['step_id']! as String,
            runId: runId,
            runTitle: runTitle,
            title: row['title']! as String,
            state: row['state']! as String,
            plannedStartUtc: optionalDateFromDb(row['planned_start_utc']),
            plannedEndUtc: optionalDateFromDb(row['planned_end_utc']),
            dueAtUtc: optionalDateFromDb(row['due_at_utc']),
            expectedSeconds: row['expected_seconds'] == null
                ? null
                : intFromDb(row['expected_seconds']),
            durationOrigin: row['duration_origin'] as String? ?? 'unknown',
            humanGate: intFromDb(row['human_gate']) == 1,
          ),
        )
        .toList(growable: false);
  }

  List<String> _topologicalOrder(Map<String, List<String>> dependencies) {
    final ordered = <String>[];
    final visiting = <String>{};
    final visited = <String>{};
    void visit(String id) {
      if (visiting.contains(id)) {
        throw const ValidationException(
          'SCHEDULE_DAG_CYCLE',
          'Run Steps contain a dependency cycle.',
        );
      }
      if (visited.contains(id)) return;
      visiting.add(id);
      for (final dependency in dependencies[id] ?? const <String>[]) {
        if (!dependencies.containsKey(dependency)) {
          throw ValidationException(
            'SCHEDULE_DAG_INVALID',
            'Step $id depends on missing Step $dependency.',
          );
        }
        visit(dependency);
      }
      visiting.remove(id);
      visited.add(id);
      ordered.add(id);
    }

    for (final id in dependencies.keys) {
      visit(id);
    }
    return ordered;
  }
}

final class DashboardService {
  const DashboardService(this.vault);

  final VaultContext vault;

  DashboardSnapshot load({DateTime? nowUtc}) {
    final database = vault.database;
    final projects = intFromDb(
      database
          .query(
            'SELECT COUNT(*) AS count FROM projects WHERE deleted_at_utc IS NULL',
          )
          .single['count'],
    );
    final experiments = intFromDb(
      database
          .query(
            'SELECT COUNT(*) AS count FROM experiments WHERE deleted_at_utc IS NULL',
          )
          .single['count'],
    );
    final activeRuns = intFromDb(
      database
          .query(
            "SELECT COUNT(*) AS count FROM experiment_runs WHERE state IN('planned','running','paused')",
          )
          .single['count'],
    );
    final tasks = intFromDb(
      database
          .query(
            "SELECT COUNT(*) AS count FROM local_tasks WHERE state NOT IN('completed','cancelled','done')",
          )
          .single['count'],
    );
    final runService = RunService(vault);
    final scheduleService = ScheduleService(vault);
    return DashboardSnapshot(
      activeProjectCount: projects,
      activeExperimentCount: experiments,
      activeRunCount: activeRuns,
      openTaskCount: tasks,
      recentRuns: runService.listRuns(limit: 10),
      upcomingSteps: scheduleService.listUpcoming(fromUtc: nowUtc, limit: 20),
      generatedAtUtc: (nowUtc ?? DateTime.now()).toUtc(),
    );
  }
}
