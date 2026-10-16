import 'dart:convert';
import 'dart:io';

/// Keeps only the locally selected Vault location and identity in app support.
/// Credentials, database contents and AssetStore objects stay in the Vault or
/// platform secure storage and are never copied into this pointer file.
final class ActiveVaultSelection {
  ActiveVaultSelection._(this._file);

  final File _file;

  static ActiveVaultSelection atSupportDirectory(Directory supportDirectory) =>
      ActiveVaultSelection._(
        File(<String>[
          supportDirectory.path,
          'LabWorkspace',
          'active_vault.json',
        ].join(Platform.pathSeparator)),
      );

  Future<ActiveVaultRecord?> read() async {
    if (!await _file.exists()) return null;
    final decoded = jsonDecode(await _file.readAsString());
    if (decoded is! Map<String, Object?> || decoded['schema_version'] != 1) {
      throw const FormatException('Active Vault selection file is invalid.');
    }
    final root = decoded['root_directory'];
    final vaultId = decoded['vault_id'];
    final deviceId = decoded['device_id'];
    if (root is! String || root.trim().isEmpty ||
        vaultId is! String || vaultId.trim().isEmpty ||
        (deviceId != null && deviceId is! String)) {
      throw const FormatException('Active Vault selection is incomplete.');
    }
    return ActiveVaultRecord(
      rootDirectory: File(root).absolute.path,
      vaultId: vaultId,
      deviceId: deviceId as String?,
    );
  }

  Future<void> write(ActiveVaultRecord selection) async {
    final root = File(selection.rootDirectory).absolute.path;
    if (root.trim().isEmpty || selection.vaultId.trim().isEmpty) {
      throw ArgumentError('An active Vault requires a root path and Vault ID.');
    }
    await _file.parent.create(recursive: true);
    final temporary = File('${_file.path}.partial-${DateTime.now().microsecondsSinceEpoch}');
    final bytes = utf8.encode(
      const JsonEncoder.withIndent('  ').convert(<String, Object?>{
        'schema_version': 1,
        'root_directory': root,
        'vault_id': selection.vaultId,
        if (selection.deviceId != null) 'device_id': selection.deviceId,
      }),
    );
    await temporary.writeAsBytes(bytes, flush: true);
    if (await _file.exists()) await _file.delete();
    await temporary.rename(_file.path);
  }
}

final class ActiveVaultRecord {
  const ActiveVaultRecord({
    required this.rootDirectory,
    required this.vaultId,
    this.deviceId,
  });

  final String rootDirectory;
  final String vaultId;
  final String? deviceId;
}
