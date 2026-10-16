import 'package:path/path.dart' as p;

import '../persistence/workspace_database.dart';
import 'ids.dart';

final class VaultLayout {
  VaultLayout._(this.rootDirectory)
    : databasePath = p.join(rootDirectory, 'workspace.sqlite3'),
      assetStorePath = p.join(rootDirectory, 'store'),
      identityMarkerPath = p.join(rootDirectory, '.local-device-id');

  factory VaultLayout.forRoot(String path) {
    final trimmed = path.trim();
    if (trimmed.isEmpty)
      throw ArgumentError.value(path, 'path', 'Vault path cannot be empty.');
    return VaultLayout._(p.normalize(p.absolute(trimmed)));
  }

  final String rootDirectory;
  final String databasePath;
  final String assetStorePath;
  final String identityMarkerPath;
}

final class VaultContext {
  const VaultContext({
    required this.rootDirectory,
    required this.vaultId,
    required this.deviceId,
    required this.database,
  });

  /// Absolute path selected by the native client for this device's Vault.
  final String rootDirectory;
  final VaultId vaultId;
  final DeviceId deviceId;
  final WorkspaceDatabase database;

  int get authorityGeneration => database.authorityGeneration;
}

final class Vault {
  const Vault(this.context);

  final VaultContext context;
  VaultId get id => context.vaultId;
  DeviceId get deviceId => context.deviceId;
}
