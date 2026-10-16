import 'dart:io';

import 'package:lab_core/lab_core.dart';
import 'package:path_provider/path_provider.dart';

import 'calculation_pack_signatures.dart';
import '../integrations/microsoft_identity.dart';
import 'local_reminder_notifications.dart';
import 'platform_calculation_executor.dart';
import 'secure_secret_store.dart';

/// Owns the device-local service instances for one open Vault.
///
/// Providers that need platform credentials or an optional transport are added
/// here only when their durable adapters are available; pages never substitute
/// in-memory fake repositories.
final class WorkspaceServices {
  WorkspaceServices(this.core)
    : assets = core.assets,
      secretStore = FlutterSecretStore() {
    tasks = core.tasks;
    reminders = core.reminders;
    localNotifications = LocalReminderNotifications(reminders: reminders);
    packRegistry = CalculationPackRegistry(
      database: core.database,
      vault: core.vault.context,
      signatures: SecureCalculationPackSignatures(
        secrets: secretStore,
        settings: core.settings,
      ),
    );
    final protocolExecutionValidator = ProtocolExecutionValidator(
      calculationBinder: WorkflowCalculationPackBinder(packRegistry),
    );
    core.protocols.configureExecutionValidator(protocolExecutionValidator);
    core.runs.configureExecutionValidator(protocolExecutionValidator);
    calculations = CalculationService(
      database: core.database,
      vault: core.vault.context,
      packs: packRegistry,
      executor: PlatformCalculationExecutor(platform: _platformName),
    );
    sync = SyncService(
      vault: core.vault.context,
      assets: assets,
      secrets: secretStore,
      oneDriveTokenProvider: MicrosoftOneDriveIdentitySession(
        secrets: secretStore,
        repository: SqliteMicrosoftOneDriveOAuthRepository(core.database),
      ),
    );
    backups = BackupService(
      vault: core.vault.context,
      assets: assets,
      secrets: secretStore,
      remoteTransfer: sync,
    );
  }

  final LabCore core;
  final AssetGateway assets;
  final FlutterSecretStore secretStore;
  late final TaskService tasks;
  late final ReminderService reminders;
  late final LocalReminderNotifications localNotifications;
  late final CalculationPackRegistry packRegistry;
  late final CalculationService calculations;
  late final ProjectStorageService projectStorage;
  late final SyncService sync;
  late final BackupService backups;
  bool _initialized = false;

  Future<void> initialize() async {
    if (_initialized) return;
    final documents = await getApplicationDocumentsDirectory();
    projectStorage = ProjectStorageService(
      vault: core.vault.context,
      assets: assets,
      documentsDirectory: documents.path,
    );
    assets.addPostImportMaterializer(projectStorage.materializeImportedAsset);
    await assets.initialize();
    await localNotifications.initialize();
    _initialized = true;
  }

  static String get _platformName {
    if (Platform.isWindows) return 'windows';
    if (Platform.isAndroid) return 'android';
    if (Platform.isIOS) return 'ios';
    return 'unsupported';
  }
}
