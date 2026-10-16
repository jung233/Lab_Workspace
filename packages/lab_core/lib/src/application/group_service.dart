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

final class ExperimentalGroupService {
  const ExperimentalGroupService(this.vault);

  final VaultContext vault;
  WorkspaceDatabase get _database => vault.database;

  ExperimentalGroupRecord createGroup({
    required String runId,
    required String title,
    Map<String, Object?> conditions = const <String, Object?>{},
    CommandMetadata? command,
  }) {
    final actualCommand = serviceCommand(command: command);
    final cleanTitle = normalizedText(title, 'title');
    final frozenConditions = freezeJsonObject(conditions);
    final payload = <String, Object?>{
      'run_id': runId,
      'title': cleanTitle,
      'conditions': frozenConditions,
    };
    return _database.transaction((tx) {
      final prior = replayMutation(
        tx: tx,
        command: actualCommand,
        entityType: 'experimental_group',
        eventType: 'group.created',
        action: MutationAction.create,
        payload: payload,
      );
      if (prior != null) {
        final rows = tx.query('SELECT * FROM experimental_groups WHERE group_id=?', [prior.entityId]);
        if (rows.isEmpty) throw MissingEntityException('ExperimentalGroup', prior.entityId);
        return _fromRow(rows.single);
      }
      if (tx.query('SELECT 1 FROM experiment_runs WHERE run_id=?', [runId]).isEmpty) {
        throw MissingEntityException('Run', runId);
      }
      final groupId = newUuidV7(at: actualCommand.normalizedUtcTime);
      tx.execute(
        'INSERT INTO experimental_groups(group_id,run_id,title,conditions_json,revision) VALUES(?,?,?,?,1)',
        [groupId, runId, cleanTitle, jsonEncode(frozenConditions)],
      );
      appendServiceMutation(
        tx: tx,
        command: actualCommand,
        deviceId: vault.deviceId,
        entityType: 'experimental_group',
        entityId: groupId,
        eventType: 'group.created',
        action: MutationAction.create,
        payload: payload,
      );
      return _fromRow(tx.query('SELECT * FROM experimental_groups WHERE group_id=?', [groupId]).single);
    });
  }

  ExperimentalGroupRecord updateGroup({
    required String groupId,
    required int expectedRevision,
    required String title,
    required Map<String, Object?> conditions,
    CommandMetadata? command,
  }) {
    final actualCommand = serviceCommand(command: command);
    final cleanTitle = normalizedText(title, 'title');
    final frozenConditions = freezeJsonObject(conditions);
    final payload = <String, Object?>{
      'group_id': groupId,
      'revision': expectedRevision,
      'title': cleanTitle,
      'conditions': frozenConditions,
    };
    return _database.transaction((tx) {
      final prior = replayMutation(
        tx: tx,
        command: actualCommand,
        entityType: 'experimental_group',
        entityId: groupId,
        eventType: 'group.updated',
        action: MutationAction.patch,
        payload: payload,
      );
      if (prior != null) {
        return _fromRow(tx.query('SELECT * FROM experimental_groups WHERE group_id=?', [groupId]).single);
      }
      final rows = tx.query('SELECT revision FROM experimental_groups WHERE group_id=?', [groupId]);
      if (rows.isEmpty) throw MissingEntityException('ExperimentalGroup', groupId);
      final revision = intFromDb(rows.single['revision']);
      if (revision != expectedRevision) {
        throw RevisionConflictException(
          entityType: 'experimental_group',
          entityId: groupId,
          expectedRevision: expectedRevision,
          actualRevision: revision,
        );
      }
      final mutationCommand = serviceCommandAtRevision(
        actualCommand,
        entityType: 'experimental_group',
        entityId: groupId,
        revision: revision,
      );
      tx.execute(
        'UPDATE experimental_groups SET title=?,conditions_json=?,revision=revision+1 WHERE group_id=? AND revision=?',
        [cleanTitle, jsonEncode(frozenConditions), groupId, revision],
      );
      appendServiceMutation(
        tx: tx,
        command: mutationCommand,
        deviceId: vault.deviceId,
        entityType: 'experimental_group',
        entityId: groupId,
        eventType: 'group.updated',
        action: MutationAction.patch,
        payload: payload,
      );
      return _fromRow(tx.query('SELECT * FROM experimental_groups WHERE group_id=?', [groupId]).single);
    });
  }

  ExperimentalGroupRecord? getGroup(String groupId) {
    final rows = _database.query('SELECT * FROM experimental_groups WHERE group_id=?', [groupId]);
    return rows.isEmpty ? null : _fromRow(rows.single);
  }

  List<ExperimentalGroupRecord> listGroups(String runId) => _database.query(
    'SELECT * FROM experimental_groups WHERE run_id=? ORDER BY title COLLATE NOCASE,group_id',
    [runId],
  ).map(_fromRow).toList(growable: false);

  ExperimentalGroupRecord _fromRow(DbRow row) => ExperimentalGroupRecord(
    groupId: row['group_id']! as String,
    runId: row['run_id']! as String,
    title: row['title']! as String,
    conditions: objectFromDb(row['conditions_json']),
    revision: intFromDb(row['revision']),
  );
}
