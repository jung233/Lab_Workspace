import 'dart:convert';

import '../domain/commands.dart';
import '../domain/errors.dart';
import '../domain/events.dart';
import '../domain/ids.dart';
import '../domain/json_value.dart';
import '../domain/records.dart';
import '../domain/vault.dart';
import '../persistence/workspace_database.dart';
import '_service_support.dart';

final class SampleService {
  const SampleService(this.vault);

  final VaultContext vault;
  WorkspaceDatabase get _database => vault.database;

  SampleRecord createSample({
    required String name,
    String? parentSampleId,
    Map<String, Object?> properties = const <String, Object?>{},
    String? runId,
    String? groupId,
    CommandMetadata? command,
  }) {
    final actualCommand = serviceCommand(command: command);
    final cleanName = normalizedText(name, 'name');
    final frozenProperties = freezeJsonObject(properties);
    final payload = <String, Object?>{
      'name': cleanName,
      'parent_sample_id': parentSampleId,
      'properties': frozenProperties,
      'run_id': runId,
      'group_id': groupId,
    };
    return _database.transaction((tx) {
      final prior = replayMutation(
        tx: tx, command: actualCommand, entityType: 'sample',
        eventType: 'sample.created', action: MutationAction.create,
        payload: payload,
      );
      if (prior != null) {
        final rows = tx.query('SELECT * FROM samples WHERE sample_id=?', [prior.entityId]);
        if (rows.isEmpty) throw MissingEntityException('Sample', prior.entityId);
        return _sampleFromRow(rows.single);
      }
      if (parentSampleId != null && tx.query(
        'SELECT 1 FROM samples WHERE sample_id=? AND deleted_at_utc IS NULL', [parentSampleId],
      ).isEmpty) {
        throw MissingEntityException('Parent Sample', parentSampleId);
      }
      if (runId != null) _requireRunAndGroup(tx, runId, groupId);
      final sampleId = newUuidV7(at: actualCommand.normalizedUtcTime);
      tx.execute(
        '''INSERT INTO samples(sample_id,name,parent_sample_id,properties_json,created_at_utc,revision)
           VALUES(?,?,?,?,?,1)''',
        [sampleId, cleanName, parentSampleId, jsonEncode(frozenProperties),
         actualCommand.normalizedUtcTime.toIso8601String()],
      );
      if (parentSampleId != null) {
        tx.execute(
          '''INSERT INTO sample_edges(edge_id,parent_sample_id,child_sample_id,relationship_kind,
             created_at_utc,command_id) VALUES(?,?,?,'derived_from',?,?)''',
          [newUuidV7(at: actualCommand.normalizedUtcTime), parentSampleId, sampleId,
           actualCommand.normalizedUtcTime.toIso8601String(), actualCommand.commandId],
        );
      }
      if (runId != null) {
        tx.execute(
          'INSERT INTO run_samples(run_id,sample_id,group_id) VALUES(?,?,?)',
          [runId, sampleId, groupId],
        );
      }
      appendServiceMutation(
        tx: tx, command: actualCommand, deviceId: vault.deviceId,
        entityType: 'sample', entityId: sampleId, eventType: 'sample.created',
        action: MutationAction.create, payload: payload,
      );
      return _sampleFromRow(tx.query('SELECT * FROM samples WHERE sample_id=?', [sampleId]).single);
    });
  }

  void attachToRun({
    required String sampleId,
    required String runId,
    String? groupId,
    CommandMetadata? command,
  }) {
    final actualCommand = serviceCommand(command: command);
    final payload = <String, Object?>{
      'sample_id': sampleId,
      'run_id': runId,
      'group_id': groupId,
    };
    _database.transaction((tx) {
      final prior = replayMutation(
        tx: tx, command: actualCommand, entityType: 'run', entityId: runId,
        eventType: 'run.sample_attached', action: MutationAction.patch,
        payload: payload,
      );
      if (prior != null) return;
      final sample = tx.query('SELECT 1 FROM samples WHERE sample_id=? AND deleted_at_utc IS NULL', [sampleId]);
      if (sample.isEmpty) throw MissingEntityException('Sample', sampleId);
      _requireRunAndGroup(tx, runId, groupId);
      final existing = tx.query('SELECT group_id FROM run_samples WHERE run_id=? AND sample_id=?', [runId, sampleId]);
      if (existing.isNotEmpty) {
        if (existing.single['group_id'] == groupId) {
          appendServiceMutation(
            tx: tx, command: actualCommand, deviceId: vault.deviceId,
            entityType: 'run', entityId: runId, eventType: 'run.sample_attached',
            action: MutationAction.patch, payload: payload,
          );
          return;
        }
        throw ValidationException('SAMPLE_GROUP_CONFLICT', 'Sample already belongs to a different group in this Run.');
      }
      tx.execute('INSERT INTO run_samples(run_id,sample_id,group_id) VALUES(?,?,?)', [runId, sampleId, groupId]);
      appendServiceMutation(
        tx: tx, command: actualCommand, deviceId: vault.deviceId,
        entityType: 'run', entityId: runId, eventType: 'run.sample_attached',
        action: MutationAction.patch, payload: payload,
      );
    });
  }

  TreatmentRecord recordTreatment({
    required String sampleId,
    required String runId,
    required Map<String, Object?> conditions,
    DateTime? appliedAtUtc,
    String? correctedFrom,
    String? correctionReason,
    CommandMetadata? command,
  }) {
    final actualCommand = serviceCommand(command: command);
    final frozenConditions = freezeJsonObject(conditions);
    final payload = <String, Object?>{
      'sample_id': sampleId,
      'run_id': runId,
      'conditions': frozenConditions,
      'applied_at_utc': appliedAtUtc?.toUtc().toIso8601String(),
      'corrected_from': correctedFrom,
      'correction_reason': correctionReason,
    };
    return _database.transaction((tx) {
      final prior = replayMutation(
        tx: tx, command: actualCommand, entityType: 'treatment',
        eventType: correctedFrom == null ? 'treatment.recorded' : 'treatment.corrected',
        action: MutationAction.append, payload: payload,
      );
      if (prior != null) {
        final rows = tx.query('SELECT * FROM treatments WHERE treatment_id=?', [prior.entityId]);
        if (rows.isEmpty) throw MissingEntityException('Treatment', prior.entityId);
        return _treatmentFromRow(rows.single);
      }
      if (tx.query(
        'SELECT 1 FROM run_samples WHERE run_id=? AND sample_id=?', [runId, sampleId],
      ).isEmpty) {
        throw ValidationException('SAMPLE_RUN_LINK_REQUIRED', 'Attach the Sample to this Run before recording Treatment.');
      }
      String? previousId;
      if (correctedFrom != null) {
        final previous = tx.query(
          'SELECT sample_id,run_id FROM treatments WHERE treatment_id=?', [correctedFrom],
        );
        if (previous.isEmpty) throw MissingEntityException('Treatment', correctedFrom);
        if (previous.single['sample_id'] != sampleId || previous.single['run_id'] != runId) {
          throw const ValidationException(
            'TREATMENT_CORRECTION_SCOPE',
            'A treatment correction must preserve the original Sample and Run.',
          );
        }
        if (normalizedText(correctionReason ?? '', 'correctionReason').isEmpty) {
          throw const ValidationException('CORRECTION_REASON_REQUIRED', 'Treatment correction requires a reason.');
        }
        previousId = correctedFrom;
      }
      final treatmentId = newUuidV7(at: actualCommand.normalizedUtcTime);
      final recordedAt = actualCommand.normalizedUtcTime.toIso8601String();
      tx.execute(
        '''INSERT INTO treatments
           (treatment_id,sample_id,run_id,conditions_json,applied_at_utc,corrected_from,recorded_at_utc,correction_reason)
           VALUES(?,?,?,?,?,?,?,?)''',
        [treatmentId, sampleId, runId, jsonEncode(frozenConditions),
         appliedAtUtc?.toUtc().toIso8601String(), previousId, recordedAt, correctionReason],
      );
      if (previousId != null) {
        tx.execute(
          '''INSERT INTO treatment_corrections
             (correction_id,treatment_id,replacement_treatment_id,reason,created_at_utc,command_id)
             VALUES(?,?,?,?,?,?)''',
          [newUuidV7(at: actualCommand.normalizedUtcTime), previousId, treatmentId,
           correctionReason, recordedAt, actualCommand.commandId],
        );
      }
      appendServiceMutation(
        tx: tx, command: actualCommand, deviceId: vault.deviceId,
        entityType: 'treatment', entityId: treatmentId,
        eventType: correctedFrom == null ? 'treatment.recorded' : 'treatment.corrected',
        action: MutationAction.append, payload: payload,
      );
      return _treatmentFromRow(tx.query('SELECT * FROM treatments WHERE treatment_id=?', [treatmentId]).single);
    });
  }

  SampleRecord? getSample(String sampleId, {bool includeDeleted = false}) {
    final rows = _database.query(
      'SELECT * FROM samples WHERE sample_id=?${includeDeleted ? '' : ' AND deleted_at_utc IS NULL'}',
      [sampleId],
    );
    return rows.isEmpty ? null : _sampleFromRow(rows.single);
  }

  List<SampleRecord> listSamples({String? runId, bool includeDeleted = false}) {
    final from = runId == null
        ? 'SELECT s.* FROM samples s'
        : 'SELECT s.* FROM samples s JOIN run_samples rs ON rs.sample_id=s.sample_id';
    final where = <String>[];
    final bindings = <Object?>[];
    if (!includeDeleted) where.add('s.deleted_at_utc IS NULL');
    if (runId != null) {
      where.add('rs.run_id=?');
      bindings.add(runId);
    }
    final clause = where.isEmpty ? '' : ' WHERE ${where.join(' AND ')}';
    return _database.query('$from$clause ORDER BY s.name COLLATE NOCASE,s.sample_id', bindings)
        .map(_sampleFromRow).toList(growable: false);
  }

  List<TreatmentRecord> listTreatments({required String sampleId, String? runId}) {
    final bindings = <Object?>[sampleId];
    var sql = 'SELECT * FROM treatments WHERE sample_id=?';
    if (runId != null) {
      sql += ' AND run_id=?';
      bindings.add(runId);
    }
    sql += ' ORDER BY recorded_at_utc,treatment_id';
    return _database.query(sql, bindings).map(_treatmentFromRow).toList(growable: false);
  }

  void _requireRunAndGroup(WorkspaceTransaction tx, String runId, String? groupId) {
    if (tx.query('SELECT 1 FROM experiment_runs WHERE run_id=?', [runId]).isEmpty) {
      throw MissingEntityException('Run', runId);
    }
    if (groupId != null && tx.query(
      'SELECT 1 FROM experimental_groups WHERE group_id=? AND run_id=?', [groupId, runId],
    ).isEmpty) {
      throw ValidationException('GROUP_RUN_MISMATCH', 'ExperimentalGroup does not belong to this Run.');
    }
  }

  SampleRecord _sampleFromRow(DbRow row) => SampleRecord(
    sampleId: row['sample_id']! as String,
    name: row['name']! as String,
    parentSampleId: row['parent_sample_id'] as String?,
    properties: objectFromDb(row['properties_json']),
    revision: intFromDb(row['revision']),
    createdAtUtc: dateFromDb(row['created_at_utc']),
    deletedAtUtc: optionalDateFromDb(row['deleted_at_utc']),
  );

  TreatmentRecord _treatmentFromRow(DbRow row) => TreatmentRecord(
    treatmentId: row['treatment_id']! as String,
    sampleId: row['sample_id']! as String,
    runId: row['run_id']! as String,
    conditions: objectFromDb(row['conditions_json']),
    appliedAtUtc: optionalDateFromDb(row['applied_at_utc']),
    correctedFrom: row['corrected_from'] as String?,
    recordedAtUtc: dateFromDb(row['recorded_at_utc']),
  );
}
