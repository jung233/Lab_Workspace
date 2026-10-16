import 'dart:io';

import '../assets/asset_gateway.dart';
import '../domain/errors.dart';
import '../domain/ids.dart';
import '../domain/vault.dart';
import '../persistence/migrations.dart';
import '../persistence/workspace_database.dart';
import 'approval_settings_services.dart';
import 'group_service.dart';
import 'project_experiment_services.dart';
import 'protocol_service.dart';
import 'run_service.dart';
import 'remote_measurement_review_service.dart';
import 'sample_service.dart';
import 'schedule_dashboard_services.dart';
import 'task_reminder_service.dart';

/// Device-local service composition for the shared Lab Workspace core.
///
/// Each native install opens a SQLite file under its own Vault directory.
/// Remote sync exchanges immutable events and blobs; this facade never syncs a
/// live database file.
final class LabCore {
  LabCore._({
    required this.vault,
    required this.database,
    required this.assets,
    required this.projects,
    required this.experiments,
    required this.protocols,
    required this.runs,
    required this.remoteMeasurementReviews,
    required this.samples,
    required this.schedule,
    required this.dashboard,
    required this.approvals,
    required this.settings,
    required this.groups,
    required this.tasks,
    required this.reminders,
  });

  final Vault vault;
  VaultContext get context => vault.context;
  final WorkspaceDatabase database;
  final AssetGateway assets;
  final ProjectService projects;
  final ExperimentService experiments;
  final ProtocolService protocols;
  final RunService runs;
  final RemoteMeasurementReviewService remoteMeasurementReviews;
  final SampleService samples;
  final ScheduleService schedule;
  final DashboardService dashboard;
  final ApprovalService approvals;
  final SettingsService settings;
  final ExperimentalGroupService groups;
  final TaskService tasks;
  final ReminderService reminders;
  bool _closed = false;

  static Future<LabCore> initialize({required String directoryPath}) async {
    final layout = VaultLayout.forRoot(directoryPath);
    if (await File(layout.databasePath).exists()) {
      return openExisting(directoryPath: layout.rootDirectory);
    }
    await Directory(layout.rootDirectory).create(recursive: true);
    final database = await WorkspaceDatabase.open(
      filePath: layout.databasePath,
    );
    return _initializeOpenDatabase(layout, database);
  }

  /// Opens a selected existing Vault. Invalid or missing paths are rejected
  /// before SQLite is opened writable, so this method never creates a database.
  static Future<LabCore> openExisting({required String directoryPath}) async {
    final layout = VaultLayout.forRoot(directoryPath);
    if (!await Directory(layout.rootDirectory).exists()) {
      throw FileSystemException(
        'Vault directory does not exist.',
        layout.rootDirectory,
      );
    }
    if (!await File(layout.identityMarkerPath).exists()) {
      throw const ValidationException(
        'VAULT_IDENTITY_HANDOFF_REQUIRED',
        'The existing Vault has no local identity marker. Restore it through the staged Vault handoff before activation.',
      );
    }
    final database = await WorkspaceDatabase.openExisting(
      filePath: layout.databasePath,
    );
    return _initializeOpenDatabase(layout, database);
  }

  static Future<LabCore> _initializeOpenDatabase(
    VaultLayout layout,
    WorkspaceDatabase database,
  ) async {
    final root = layout.rootDirectory;
    try {
      final identity = await _loadOrCreateIdentity(root);
      final vaultRows = database.query(
        'SELECT vault_id FROM vaults ORDER BY created_at_utc LIMIT 1',
      );
      final vaultId = vaultRows.isEmpty
          ? newUuidV7()
          : vaultRows.single['vault_id']! as String;
      database.transaction((tx) {
        final currentVault = tx.query(
          'SELECT vault_id FROM vaults WHERE vault_id=?',
          [vaultId],
        );
        if (currentVault.isEmpty) {
          tx.execute(
            '''INSERT INTO vaults(vault_id,created_at_utc,schema_version,integrity_threshold_bytes)
               VALUES(?,?,?,?)''',
            [
              vaultId,
              DateTime.now().toUtc().toIso8601String(),
              currentSchemaVersion,
              2147483648,
            ],
          );
        } else {
          tx.execute('UPDATE vaults SET schema_version=? WHERE vault_id=?', [
            currentSchemaVersion,
            vaultId,
          ]);
        }
        final deviceRows = tx.query(
          'SELECT vault_id FROM devices WHERE device_id=?',
          [identity],
        );
        if (deviceRows.isNotEmpty && deviceRows.single['vault_id'] != vaultId) {
          throw StateError(
            'The local device identity is already registered to another Vault.',
          );
        }
        if (deviceRows.isEmpty) {
          tx.execute(
            'INSERT INTO devices(device_id,vault_id,display_name,seq,lamport) VALUES(?,?,?,0,0)',
            [identity, vaultId, 'This device'],
          );
        }
      });
      database.ensureLocalInstallationIdentity(
        deviceId: identity,
        atUtc: DateTime.now().toUtc(),
      );
      final context = VaultContext(
        rootDirectory: root,
        vaultId: vaultId,
        deviceId: identity,
        database: database,
      );
      final assets = AssetGateway(vault: context);
      await assets.initialize();
      return LabCore._(
        vault: Vault(context),
        database: database,
        assets: assets,
        projects: ProjectService(context),
        experiments: ExperimentService(context),
        protocols: ProtocolService(context),
        runs: RunService(context),
        remoteMeasurementReviews: RemoteMeasurementReviewService(context),
        samples: SampleService(context),
        schedule: ScheduleService(context),
        dashboard: DashboardService(context),
        approvals: ApprovalService(context),
        settings: SettingsService(context),
        groups: ExperimentalGroupService(context),
        tasks: TaskService(context),
        reminders: ReminderService(context),
      );
    } on Object {
      await database.close();
      rethrow;
    }
  }

  Future<void> close() async {
    if (_closed) return;
    await database.close();
    _closed = true;
  }

  static Future<String> _loadOrCreateIdentity(String root) async {
    final identityFile = File(VaultLayout.forRoot(root).identityMarkerPath);
    if (await identityFile.exists()) {
      final value = (await identityFile.readAsString()).trim();
      if (_validUuid(value)) return value;
      throw const FormatException('Local device identity file is malformed.');
    }
    // A markerless database never proves that this machine owns a historical
    // device identity. Generate a fresh identity and retain old device rows.
    final candidate = newUuidV7();
    final staging = File(identityFile.path + '.partial-' + newUuidV7());
    await staging.writeAsString(candidate, flush: true);
    try {
      await staging.rename(identityFile.path);
      return candidate;
    } on FileSystemException {
      if (await identityFile.exists()) {
        await staging.delete().catchError((_) => staging);
        final value = (await identityFile.readAsString()).trim();
        if (_validUuid(value)) return value;
      }
      rethrow;
    }
  }

  static bool _validUuid(String value) => RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-8][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
  ).hasMatch(value);
}
