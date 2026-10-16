import '../domain/security.dart';

enum BackupDataCategory { database, asset }

final class BackupPackVersion {
  const BackupPackVersion({required this.packId, required this.version});

  final String packId;
  final String version;

  Map<String, Object?> toJson() => {'pack_id': packId, 'version': version};

  factory BackupPackVersion.fromJson(Map<String, Object?> json) => BackupPackVersion(
        packId: json['pack_id'] as String,
        version: json['version'] as String,
      );
}

/// Client-selected encryption by backup data class. A missing key means the
/// category remains plaintext, preserving independent plaintext recovery.
final class BackupEncryptionPolicy {
  const BackupEncryptionPolicy({this.databaseKey, this.assetKey});

  final SecretRef? databaseKey;
  final SecretRef? assetKey;

  SecretRef? keyFor(BackupDataCategory category) => switch (category) {
        BackupDataCategory.database => databaseKey,
        BackupDataCategory.asset => assetKey,
      };

  Map<String, Object?> toJson() => {
        'database': _classJson(databaseKey),
        'asset': _classJson(assetKey),
        'format': 'LWAE/1',
      };

  static Map<String, Object?> _classJson(SecretRef? key) => {
        'mode': key == null ? 'none' : 'aes_gcm_chunked_v1',
        'key_id': key?.value,
      };
}

final class BackupObjectEntry {
  const BackupObjectEntry({
    required this.objectId,
    required this.category,
    required this.relativePath,
    required this.plaintextSha256,
    required this.plaintextBytes,
    required this.storedSha256,
    required this.storedBytes,
    required this.encryptionMode,
    required this.verificationLevel,
    this.keyRef,
    this.restoreRelativePath,
  });

  final String objectId;
  final BackupDataCategory category;
  final String relativePath;
  final String plaintextSha256;
  final int plaintextBytes;
  final String storedSha256;
  final int storedBytes;
  final String encryptionMode;
  final String verificationLevel;
  final SecretRef? keyRef;
  final String? restoreRelativePath;

  Map<String, Object?> toJson() => {
        'object_id': objectId,
        'category': category.name,
        'path': relativePath,
        'plaintext_sha256': plaintextSha256,
        'plaintext_bytes': plaintextBytes,
        'stored_sha256': storedSha256,
        'stored_bytes': storedBytes,
        'encryption_mode': encryptionMode,
        'key_id': keyRef?.value,
        'verification_level': verificationLevel,
        if (restoreRelativePath != null) 'restore_path': restoreRelativePath,
      };

  factory BackupObjectEntry.fromJson(Map<String, Object?> json) {
    final category = BackupDataCategory.values.firstWhere(
      (value) => value.name == json['category'],
      orElse: () => throw FormatException('Unsupported backup object category.'),
    );
    final key = json['key_id'];
    if (json['object_id'] is! String ||
        json['path'] is! String ||
        json['plaintext_sha256'] is! String ||
        json['plaintext_bytes'] is! int ||
        json['stored_sha256'] is! String ||
        json['stored_bytes'] is! int ||
        json['encryption_mode'] is! String ||
        json['verification_level'] is! String ||
        (json['restore_path'] != null && json['restore_path'] is! String) ||
        (key != null && key is! String)) {
      throw const FormatException('Backup object entry fields are invalid.');
    }
    final entry = BackupObjectEntry(
      objectId: json['object_id'] as String,
      category: category,
      relativePath: json['path'] as String,
      plaintextSha256: json['plaintext_sha256'] as String,
      plaintextBytes: _int(json['plaintext_bytes']),
      storedSha256: json['stored_sha256'] as String,
      storedBytes: _int(json['stored_bytes']),
      encryptionMode: json['encryption_mode'] as String,
      verificationLevel: json['verification_level'] as String,
      keyRef: key is String ? SecretRef(key) : null,
      restoreRelativePath: json['restore_path'] as String?,
    );
    _validateBackupObject(entry);
    return entry;
  }
}

final class BackupManifest {
  const BackupManifest({
    required this.backupId,
    required this.vaultId,
    required this.createdAtUtc,
    required this.databaseSchemaVersion,
    required this.databaseObject,
    required this.assets,
    required this.encryptionPolicy,
    this.packVersions = const [],
  });

  final String backupId;
  final String vaultId;
  final DateTime createdAtUtc;
  final int databaseSchemaVersion;
  final BackupObjectEntry databaseObject;
  final List<BackupObjectEntry> assets;
  final BackupEncryptionPolicy encryptionPolicy;
  final List<BackupPackVersion> packVersions;

  List<BackupObjectEntry> get objects => [databaseObject, ...assets];

  Map<String, Object?> toJson() => {
        'schema_version': '1.1',
        'backup_id': backupId,
        'vault_id': vaultId,
        'created_at_utc': createdAtUtc.toUtc().toIso8601String(),
        'database_schema_version': databaseSchemaVersion,
        'database_object': databaseObject.toJson(),
        'assets': assets.map((entry) => entry.toJson()).toList(growable: false),
        'encryption_policy': encryptionPolicy.toJson(),
        'pack_versions': packVersions.map((entry) => entry.toJson()).toList(growable: false),
      };

  factory BackupManifest.fromJson(Map<String, Object?> json) {
    if (json['schema_version'] != '1.0' && json['schema_version'] != '1.1') {
      throw const FormatException('Unsupported backup manifest version.');
    }
    final database = json['database_object'];
    final assets = json['assets'];
    if (database is! Map<String, Object?> ||
        assets is! List ||
        json['backup_id'] is! String ||
        json['vault_id'] is! String ||
        json['created_at_utc'] is! String ||
        json['database_schema_version'] is! int) {
      throw const FormatException('Backup manifest object list is invalid.');
    }
    final policy = json['encryption_policy'];
    if (policy is! Map<String, Object?>) throw const FormatException('Backup encryption policy is invalid.');
    final manifest = BackupManifest(
      backupId: json['backup_id'] as String,
      vaultId: json['vault_id'] as String,
      createdAtUtc: DateTime.parse(json['created_at_utc'] as String).toUtc(),
      databaseSchemaVersion: _int(json['database_schema_version']),
      databaseObject: BackupObjectEntry.fromJson(database),
      assets: assets.map((value) {
        if (value is! Map<String, Object?>) throw const FormatException('Backup asset entry is invalid.');
        return BackupObjectEntry.fromJson(value);
      }).toList(growable: false),
      encryptionPolicy: BackupEncryptionPolicy(
        databaseKey: _keyFromClass(policy['database']),
        assetKey: _keyFromClass(policy['asset']),
      ),
      packVersions: (json['pack_versions'] as List<dynamic>? ?? const <dynamic>[]).map((value) {
        if (value is! Map<String, Object?>) throw const FormatException('Backup Pack version entry is invalid.');
        return BackupPackVersion.fromJson(value);
      }).toList(growable: false),
    );
    _validateBackupManifest(manifest);
    return manifest;
  }

  static SecretRef? _keyFromClass(Object? value) {
    if (value is! Map<String, Object?>) throw const FormatException('Backup category policy is invalid.');
    final key = value['key_id'];
    if (key != null && key is! String) throw const FormatException('Backup policy key reference is invalid.');
    return key is String ? SecretRef(key) : null;
  }
}

final class BackupSnapshotResult {
  const BackupSnapshotResult({
    required this.backupId,
    required this.snapshotDirectory,
    required this.manifest,
    required this.state,
    required this.completedAtUtc,
    this.remoteTargetId,
    this.remoteState,
    this.warnings = const [],
  });

  final String backupId;
  final String snapshotDirectory;
  final BackupManifest manifest;
  final String state;
  final DateTime completedAtUtc;
  final String? remoteTargetId;
  final String? remoteState;
  final List<String> warnings;
  bool get succeeded => state == 'complete' || state == 'local_complete_remote_failed';
}

final class BackupRestoreResult {
  const BackupRestoreResult({
    required this.restoreId,
    required this.backupId,
    required this.destinationDirectory,
    required this.databaseFilePath,
    required this.vaultId,
    required this.verifiedObjects,
    required this.completedAtUtc,
      this.warnings = const [],
  });

  final String restoreId;
  final String backupId;
  final String destinationDirectory;
  final String databaseFilePath;
  final String vaultId;
  final int verifiedObjects;
  final DateTime completedAtUtc;
  final List<String> warnings;
}

final class BackupKeyDependencyException implements Exception {
  const BackupKeyDependencyException(this.keyIds);
  final List<String> keyIds;
  @override
  String toString() => 'BACKUP_KEY_REQUIRED: restore requires keys: ${keyIds.join(', ')}';
}

/// Optional remote transport implemented by the sync target adapter.
abstract interface class BackupRemoteTransfer {
  Future<void> uploadBackupSnapshot({
    required String targetId,
    required String backupId,
    required String snapshotDirectory,
  });

  Future<String> downloadBackupSnapshot({
    required String targetId,
    required String backupId,
    required String destinationDirectory,
    int? targetEpoch,
  });
}

int _int(Object? value) => switch (value) {
      int number => number,
      num number => number.toInt(),
      _ => 0,
    };

void _validateBackupObject(BackupObjectEntry entry) {
  if (entry.objectId.isEmpty ||
      !_safeBackupPath(entry.relativePath) ||
      (entry.restoreRelativePath != null && !_safeBackupPath(entry.restoreRelativePath!)) ||
      !RegExp(r'^[a-f0-9]{64}$').hasMatch(entry.plaintextSha256) ||
      !RegExp(r'^[a-f0-9]{64}$').hasMatch(entry.storedSha256) ||
      entry.plaintextBytes < 0 ||
      entry.storedBytes <= 0 ||
      !const {'none', 'aes_gcm_chunked_v1'}.contains(entry.encryptionMode) ||
      (entry.encryptionMode == 'none' && entry.keyRef != null) ||
      (entry.encryptionMode == 'aes_gcm_chunked_v1' && entry.keyRef == null)) {
    throw const FormatException('Backup object entry is malformed.');
  }
}

void _validateBackupManifest(BackupManifest manifest) {
  if (!_safeBackupToken(manifest.backupId) ||
      !_safeBackupToken(manifest.vaultId) ||
      manifest.databaseSchemaVersion <= 0 ||
      manifest.databaseObject.category != BackupDataCategory.database ||
      manifest.databaseObject.objectId != 'database' ||
      (manifest.databaseObject.restoreRelativePath != 'workspace.sqlite3' &&
          manifest.databaseObject.restoreRelativePath != 'db/workspace.sqlite')) {
    throw const FormatException('Backup manifest identity or database object is invalid.');
  }
  final objects = manifest.objects;
  final ids = <String>{};
  final sourcePaths = <String>{};
  final restorePaths = <String>{};
  for (final object in objects) {
    if (!ids.add(object.objectId) || !sourcePaths.add(object.relativePath)) {
      throw const FormatException('Backup manifest contains duplicate objects or paths.');
    }
    final restorePath = object.restoreRelativePath;
    if (restorePath != null && !restorePaths.add(restorePath)) {
      throw const FormatException('Backup manifest contains duplicate restore paths.');
    }
  }
  final database = manifest.databaseObject;
  final expectedDatabasePath = database.encryptionMode == 'none'
      ? 'database/workspace.sqlite3'
      : 'database/workspace.sqlite3.lwe';
  if (database.relativePath != expectedDatabasePath ||
      database.plaintextBytes == 0 ||
      database.keyRef?.value != manifest.encryptionPolicy.databaseKey?.value) {
    throw const FormatException('Backup database object does not match its encryption policy.');
  }
  final assetKey = manifest.encryptionPolicy.assetKey?.value;
  for (final asset in manifest.assets) {
    if (asset.category != BackupDataCategory.asset ||
        asset.objectId != 'asset:${asset.plaintextSha256}' ||
        asset.keyRef?.value != assetKey) {
      throw const FormatException('Backup asset object identity or encryption policy is invalid.');
    }
    final sha = asset.plaintextSha256;
    final base = 'objects/sha256/${sha.substring(0, 2)}/${sha.substring(2, 4)}/$sha';
    final expectedPath = asset.encryptionMode == 'none' ? base : '$base.lwe';
    final expectedRestore = 'store/objects/sha256/${sha.substring(0, 2)}/${sha.substring(2, 4)}/$sha';
    if (asset.relativePath != expectedPath || asset.restoreRelativePath != expectedRestore) {
      throw const FormatException('Backup asset path is inconsistent with its SHA-256 identity.');
    }
  }
}

bool _safeBackupPath(String value) =>
    value.isNotEmpty &&
    !value.contains('\\') &&
    !value.startsWith('/') &&
    !RegExp(r'^[a-zA-Z]:').hasMatch(value) &&
    value.split('/').every((segment) => segment.isNotEmpty && segment != '.' && segment != '..');

bool _safeBackupToken(String value) =>
    value.isNotEmpty && value.length <= 128 && RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(value);
