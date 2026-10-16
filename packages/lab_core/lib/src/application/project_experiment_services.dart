import '../domain/commands.dart';
import '../domain/errors.dart';
import '../domain/events.dart';
import '../domain/ids.dart';
import '../domain/records.dart';
import '../domain/vault.dart';
import '../persistence/workspace_database.dart';
import '_service_support.dart';

final class ProjectService {
  const ProjectService(this.vault);

  final VaultContext vault;
  WorkspaceDatabase get _database => vault.database;

  ProjectRecord createProject({
    required String title,
    String note = '',
    CommandMetadata? command,
  }) {
    final actualCommand = serviceCommand(command: command);
    final cleanTitle = normalizedText(title, 'title');
    final payload = <String, Object?>{'title': cleanTitle, 'note': note};
    return _database.transaction((tx) {
      final prior = replayMutation(
        tx: tx,
        command: actualCommand,
        entityType: 'project',
        eventType: 'project.created',
        action: MutationAction.create,
        payload: payload,
      );
      if (prior != null) {
        final rows = tx.query('SELECT * FROM projects WHERE project_id=?', [prior.entityId]);
        if (rows.isEmpty) throw MissingEntityException('Project', prior.entityId);
        return _projectFromRow(rows.single);
      }
      final projectId = newUuidV7(at: actualCommand.normalizedUtcTime);
      tx.execute(
        'INSERT INTO projects(project_id,title,note,revision,created_at_utc) VALUES(?,?,?,?,?)',
        [projectId, cleanTitle, note, 1, actualCommand.normalizedUtcTime.toIso8601String()],
      );
      appendServiceMutation(
        tx: tx,
        command: actualCommand,
        deviceId: vault.deviceId,
        entityType: 'project',
        entityId: projectId,
        eventType: 'project.created',
        action: MutationAction.create,
        payload: payload,
      );
      return _projectFromRow(tx.query('SELECT * FROM projects WHERE project_id=?', [projectId]).single);
    });
  }

  ProjectRecord updateProject({
    required String projectId,
    required int expectedRevision,
    required String title,
    required String note,
    CommandMetadata? command,
  }) {
    final actualCommand = serviceCommand(
      command: command ?? CommandMetadata(
        commandId: newUuidV7(),
        utcTime: DateTime.now().toUtc(),
        baseRevision: expectedRevision,
      ),
    );
    final cleanTitle = normalizedText(title, 'title');
    final payload = <String, Object?>{
      'project_id': projectId,
      'revision': expectedRevision,
      'title': cleanTitle,
      'note': note,
    };
    return _database.transaction((tx) {
      final prior = replayMutation(
        tx: tx,
        command: actualCommand,
        entityType: 'project',
        entityId: projectId,
        eventType: 'project.updated',
        action: MutationAction.patch,
        payload: payload,
      );
      if (prior != null) {
        return _projectFromRow(tx.query('SELECT * FROM projects WHERE project_id=?', [projectId]).single);
      }
      final row = _requireProject(tx, projectId);
      final revision = intFromDb(row['revision']);
      if (revision != expectedRevision) {
        throw RevisionConflictException(
          entityType: 'project',
          entityId: projectId,
          expectedRevision: expectedRevision,
          actualRevision: revision,
        );
      }
      final mutationCommand = serviceCommandAtRevision(
        actualCommand,
        entityType: 'project',
        entityId: projectId,
        revision: revision,
      );
      final changed = tx.execute(
        'UPDATE projects SET title=?,note=?,revision=revision+1 WHERE project_id=? AND revision=? AND deleted_at_utc IS NULL',
        [cleanTitle, note, projectId, expectedRevision],
      );
      if (changed != 1) throw RevisionConflictException(
        entityType: 'project', entityId: projectId,
        expectedRevision: expectedRevision, actualRevision: revision,
      );
      appendServiceMutation(
        tx: tx, command: mutationCommand, deviceId: vault.deviceId,
        entityType: 'project', entityId: projectId,
        eventType: 'project.updated', action: MutationAction.patch, payload: payload,
      );
      return _projectFromRow(tx.query('SELECT * FROM projects WHERE project_id=?', [projectId]).single);
    });
  }

  ProjectRecord? getProject(String projectId, {bool includeDeleted = false}) {
    final rows = _database.query(
      'SELECT * FROM projects WHERE project_id=?${includeDeleted ? '' : ' AND deleted_at_utc IS NULL'}',
      [projectId],
    );
    return rows.isEmpty ? null : _projectFromRow(rows.single);
  }

  List<ProjectRecord> listProjects({bool includeDeleted = false}) => _database
      .query(
        'SELECT * FROM projects${includeDeleted ? '' : ' WHERE deleted_at_utc IS NULL'} ORDER BY title COLLATE NOCASE,project_id',
      )
      .map(_projectFromRow)
      .toList(growable: false);

  ProjectRecord _projectFromRow(DbRow row) => ProjectRecord(
    projectId: row['project_id']! as String,
    title: row['title']! as String,
    note: row['note']! as String,
    revision: intFromDb(row['revision']),
    createdAtUtc: dateFromDb(row['created_at_utc']),
    deletedAtUtc: optionalDateFromDb(row['deleted_at_utc']),
  );

  DbRow _requireProject(WorkspaceTransaction tx, String id) {
    final rows = tx.query('SELECT * FROM projects WHERE project_id=? AND deleted_at_utc IS NULL', [id]);
    if (rows.isEmpty) throw MissingEntityException('Project', id);
    return rows.single;
  }
}

final class ExperimentService {
  const ExperimentService(this.vault);

  final VaultContext vault;
  WorkspaceDatabase get _database => vault.database;

  ExperimentRecord createExperiment({
    required String title,
    String? projectId,
    String note = '',
    CommandMetadata? command,
  }) {
    final actualCommand = serviceCommand(command: command);
    final cleanTitle = normalizedText(title, 'title');
    final payload = <String, Object?>{
      'project_id': projectId,
      'title': cleanTitle,
      'note': note,
    };
    return _database.transaction((tx) {
      final prior = replayMutation(
        tx: tx,
        command: actualCommand,
        entityType: 'experiment',
        eventType: 'experiment.created',
        action: MutationAction.create,
        payload: payload,
      );
      if (prior != null) {
        final rows = tx.query('SELECT * FROM experiments WHERE experiment_id=?', [prior.entityId]);
        if (rows.isEmpty) throw MissingEntityException('Experiment', prior.entityId);
        return _experimentFromRow(rows.single);
      }
      if (projectId != null) {
        final project = tx.query('SELECT 1 FROM projects WHERE project_id=? AND deleted_at_utc IS NULL', [projectId]);
        if (project.isEmpty) throw MissingEntityException('Project', projectId);
      }
      final experimentId = newUuidV7(at: actualCommand.normalizedUtcTime);
      tx.execute(
        'INSERT INTO experiments(experiment_id,project_id,title,note,revision,created_at_utc) VALUES(?,?,?,?,?,?)',
        [experimentId, projectId, cleanTitle, note, 1, actualCommand.normalizedUtcTime.toIso8601String()],
      );
      appendServiceMutation(
        tx: tx,
        command: actualCommand,
        deviceId: vault.deviceId,
        entityType: 'experiment',
        entityId: experimentId,
        eventType: 'experiment.created',
        action: MutationAction.create,
        payload: payload,
      );
      return _experimentFromRow(tx.query('SELECT * FROM experiments WHERE experiment_id=?', [experimentId]).single);
    });
  }

  ExperimentRecord updateExperiment({
    required String experimentId,
    required int expectedRevision,
    required String title,
    required String note,
    CommandMetadata? command,
  }) {
    final actualCommand = serviceCommand(command: command);
    final cleanTitle = normalizedText(title, 'title');
    final payload = <String, Object?>{
      'experiment_id': experimentId,
      'revision': expectedRevision,
      'title': cleanTitle,
      'note': note,
    };
    return _database.transaction((tx) {
      final prior = replayMutation(
        tx: tx, command: actualCommand, entityType: 'experiment',
        entityId: experimentId, eventType: 'experiment.updated',
        action: MutationAction.patch, payload: payload,
      );
      if (prior != null) {
        return _experimentFromRow(tx.query('SELECT * FROM experiments WHERE experiment_id=?', [experimentId]).single);
      }
      final rows = tx.query('SELECT * FROM experiments WHERE experiment_id=? AND deleted_at_utc IS NULL', [experimentId]);
      if (rows.isEmpty) throw MissingEntityException('Experiment', experimentId);
      final current = intFromDb(rows.single['revision']);
      if (current != expectedRevision) {
        throw RevisionConflictException(
          entityType: 'experiment', entityId: experimentId,
          expectedRevision: expectedRevision, actualRevision: current,
        );
      }
      final mutationCommand = serviceCommandAtRevision(
        actualCommand,
        entityType: 'experiment',
        entityId: experimentId,
        revision: current,
      );
      tx.execute(
        'UPDATE experiments SET title=?,note=?,revision=revision+1 WHERE experiment_id=? AND revision=? AND deleted_at_utc IS NULL',
        [cleanTitle, note, experimentId, expectedRevision],
      );
      appendServiceMutation(
        tx: tx, command: mutationCommand, deviceId: vault.deviceId,
        entityType: 'experiment', entityId: experimentId,
        eventType: 'experiment.updated', action: MutationAction.patch, payload: payload,
      );
      return _experimentFromRow(tx.query('SELECT * FROM experiments WHERE experiment_id=?', [experimentId]).single);
    });
  }

  ExperimentRecord? getExperiment(String experimentId, {bool includeDeleted = false}) {
    final rows = _database.query(
      'SELECT * FROM experiments WHERE experiment_id=?${includeDeleted ? '' : ' AND deleted_at_utc IS NULL'}',
      [experimentId],
    );
    return rows.isEmpty ? null : _experimentFromRow(rows.single);
  }

  List<ExperimentRecord> listExperiments({
    String? projectId,
    bool includeDeleted = false,
  }) {
    final where = <String>[];
    final bindings = <Object?>[];
    if (!includeDeleted) where.add('deleted_at_utc IS NULL');
    if (projectId != null) {
      where.add('project_id=?');
      bindings.add(projectId);
    }
    final clause = where.isEmpty ? '' : ' WHERE ${where.join(' AND ')}';
    return _database
        .query('SELECT * FROM experiments$clause ORDER BY title COLLATE NOCASE,experiment_id', bindings)
        .map(_experimentFromRow)
        .toList(growable: false);
  }

  ExperimentRecord _experimentFromRow(DbRow row) => ExperimentRecord(
    experimentId: row['experiment_id']! as String,
    projectId: row['project_id'] as String?,
    title: row['title']! as String,
    note: row['note']! as String,
    revision: intFromDb(row['revision']),
    createdAtUtc: dateFromDb(row['created_at_utc']),
    deletedAtUtc: optionalDateFromDb(row['deleted_at_utc']),
  );
}
