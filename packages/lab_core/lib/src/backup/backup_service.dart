import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../assets/asset_gateway.dart';
import '../domain/commands.dart';
import '../domain/events.dart';
import '../domain/ids.dart';
import '../domain/security.dart';
import '../domain/vault.dart';
import '../persistence/workspace_database.dart';
import 'backup_models.dart';
import 'chunked_aes_gcm.dart';

/// Snapshot and restore service. Database files are created only through
/// WorkspaceDatabase.backupToFile (SQLite Online Backup API); active SQLite
/// files and WAL files are never copied into a backup.
final class BackupService {
  BackupService({
    required VaultContext vault,
    required AssetGateway assets,
    SecretStore? secrets,
    BackupRemoteTransfer? remoteTransfer,
    ChunkedAesGcm? encryption,
    DateTime Function()? clock,
  })  : _vault = vault,
        _assets = assets,
        _secrets = secrets,
        _remoteTransfer = remoteTransfer,
        _encryption = encryption ?? ChunkedAesGcm(),
        _clock = clock ?? DateTime.now;

  final VaultContext _vault;
  final AssetGateway _assets;
  final SecretStore? _secrets;
  final BackupRemoteTransfer? _remoteTransfer;
  final ChunkedAesGcm _encryption;
  final DateTime Function() _clock;

  Future<BackupSnapshotResult> snapshot({
    String? destinationDirectory,
    BackupEncryptionPolicy encryptionPolicy = const BackupEncryptionPolicy(),
    String? targetId,
    String? commandId,
  }) async {
    final createdAt = _clock().toUtc();
    final backupId = newUuidV7(at: createdAt);
    final destination = p.normalize(p.absolute(destinationDirectory ??
        p.join(_vault.rootDirectory, 'backups', backupId)));
    final finalDirectory = Directory(destination);
    if (await finalDirectory.exists()) {
      throw FileSystemException('Backup destination already exists.', destination);
    }
    final parent = finalDirectory.parent;
    await parent.create(recursive: true);
    final partialDirectory = Directory('$destination.partial-$backupId');
    if (await partialDirectory.exists()) {
      throw FileSystemException('Backup staging directory already exists.', partialDirectory.path);
    }
    Uint8List? dbKey;
    Uint8List? assetKey;
    var recorded = false;
    try {
      dbKey = await _loadKey(encryptionPolicy.databaseKey);
      assetKey = await _loadKey(encryptionPolicy.assetKey);
      await partialDirectory.create(recursive: true);
      final objects = <BackupObjectEntry>[];
      final databasePlain = File(p.join(partialDirectory.path, 'database', 'workspace.sqlite3'));
      await _vault.database.backupToFile(databasePlain.path);
      final dbPlainSha = await _hashFile(databasePlain.path);
      final dbPlainBytes = await databasePlain.length();
      final snapshotDb = await WorkspaceDatabase.open(filePath: databasePlain.path);
      List<DbRow> blobRows;
      late final int databaseSchemaVersion;
      late final List<BackupPackVersion> packVersions;
      try {
        databaseSchemaVersion = snapshotDb.schemaVersion;
        packVersions = snapshotDb.query('SELECT pack_id,version FROM installed_packs ORDER BY pack_id,version')
            .map((row) => BackupPackVersion(packId: row['pack_id']! as String, version: row['version']! as String))
            .toList(growable: false);
        final integrity = snapshotDb.query('PRAGMA integrity_check');
        if (integrity.isEmpty || integrity.first.values.first != 'ok') {
          throw StateError('SQLite Online Backup snapshot failed integrity_check.');
        }
        final vaultRows = snapshotDb.query('SELECT vault_id FROM vaults WHERE vault_id=?', [_vault.vaultId]);
        if (vaultRows.isEmpty) throw StateError('Online Backup snapshot does not contain this Vault id.');
        final foreignKeyErrors = snapshotDb.query('PRAGMA foreign_key_check');
        if (foreignKeyErrors.isNotEmpty) throw StateError('Online Backup snapshot has foreign key violations.');
        final invalidReferences = snapshotDb.query('''
          SELECT b.sha256,b.state FROM blob_objects b
          WHERE b.state<>'committed' AND (
            EXISTS(SELECT 1 FROM assets a WHERE a.blob_sha256=b.sha256) OR
            EXISTS(SELECT 1 FROM sync_received_blobs r WHERE r.sha256=b.sha256 AND r.state='available')
          ) LIMIT 1
        ''');
        if (invalidReferences.isNotEmpty) {
          throw StateError('Backup cannot be complete: a referenced Blob is not locally committed.');
        }
        blobRows = snapshotDb.query('''
          SELECT DISTINCT b.sha256,b.byte_size,b.relative_path,b.state FROM blob_objects b
          WHERE b.state='committed' AND (
            EXISTS(SELECT 1 FROM assets a WHERE a.blob_sha256=b.sha256) OR
            EXISTS(SELECT 1 FROM sync_received_blobs r WHERE r.sha256=b.sha256 AND r.state='available')
          ) ORDER BY b.sha256
        ''');
        if (blobRows.any((row) => row['sha256'] is! String || row['relative_path'] is! String)) {
          throw StateError('Online Backup snapshot contains an invalid blob record.');
        }
      } finally {
        await snapshotDb.close();
      }

      objects.add(await _storeBackupObject(
        source: databasePlain,
        partialRoot: partialDirectory,
        objectId: 'database',
        category: BackupDataCategory.database,
        plainSha: dbPlainSha,
        plainBytes: dbPlainBytes,
        keyRef: encryptionPolicy.databaseKey,
        keyBytes: dbKey,
        storedRelativePath: 'database/workspace.sqlite3',
        restoreRelativePath: 'workspace.sqlite3',
      ));

      for (final row in blobRows) {
        final sha = row['sha256'] as String;
        final byteSize = _asInt(row['byte_size']);
        final objectPath = _backupAssetPath(sha);
        final plainFile = File(p.join(partialDirectory.path, 'objects', 'sha256',
            sha.substring(0, 2), sha.substring(2, 4), sha));
        final verified = await _assets.writeVerifiedBlobSnapshot(
          blobSha256: sha,
          destinationPath: plainFile.path,
        );
        if (verified.sha256 != sha || verified.byteSize != byteSize) {
          throw StateError('Asset $sha changed while the snapshot was being captured.');
        }
        objects.add(await _storeBackupObject(
          source: plainFile,
          partialRoot: partialDirectory,
          objectId: 'asset:$sha',
          category: BackupDataCategory.asset,
          plainSha: sha,
          plainBytes: byteSize,
          keyRef: encryptionPolicy.assetKey,
          keyBytes: assetKey,
          storedRelativePath: objectPath,
          restoreRelativePath: 'store/objects/sha256/${sha.substring(0, 2)}/${sha.substring(2, 4)}/$sha',
        ));
      }

      final manifest = BackupManifest(
        backupId: backupId,
        vaultId: _vault.vaultId,
        createdAtUtc: createdAt,
        databaseSchemaVersion: databaseSchemaVersion,
        databaseObject: objects.first,
        assets: objects.skip(1).toList(growable: false),
        encryptionPolicy: encryptionPolicy,
        packVersions: packVersions,
      );
      final manifestBytes = utf8.encode(jsonEncode(manifest.toJson()));
      final manifestFile = File(p.join(partialDirectory.path, 'manifest.json'));
      await manifestFile.writeAsBytes(manifestBytes, flush: true);
      final manifestSha = sha256.convert(manifestBytes).toString();
      final checksumFile = File(p.join(partialDirectory.path, 'manifest.sha256'));
      await checksumFile.writeAsString('$manifestSha  manifest.json\n', flush: true);
      await _verifyWrittenManifest(partialDirectory, manifestSha, manifest);

      await partialDirectory.rename(finalDirectory.path);
      final finalManifest = BackupManifest.fromJson(
        jsonDecode(await File(p.join(finalDirectory.path, 'manifest.json')).readAsString())
            as Map<String, Object?>,
      );
      _recordSnapshot(
        manifest: finalManifest,
        manifestSha: manifestSha,
        directory: finalDirectory.path,
        targetId: targetId,
        commandId: commandId ?? newUuidV7(at: createdAt),
        state: 'local_complete',
      );
      recorded = true;

      var remoteState = targetId == null ? null : 'pending';
      final warnings = <String>[];
      if (targetId != null) {
        if (_remoteTransfer == null) {
          remoteState = 'unavailable';
          warnings.add('Backup remains local; no remote transfer adapter is configured.');
        } else {
          try {
            await _remoteTransfer.uploadBackupSnapshot(
              targetId: targetId,
              backupId: backupId,
              snapshotDirectory: finalDirectory.path,
            );
            remoteState = 'complete';
            _setSnapshotState(backupId, 'complete');
          } on Object catch (error) {
            remoteState = 'failed';
            warnings.add('Remote backup failed; verified local snapshot is available: ${_safeError(error)}');
            _setSnapshotState(backupId, 'local_complete_remote_failed');
          }
        }
      } else {
        _setSnapshotState(backupId, 'complete');
      }
      return BackupSnapshotResult(
        backupId: backupId,
        snapshotDirectory: finalDirectory.path,
        manifest: finalManifest,
        state: remoteState == 'failed' || remoteState == 'unavailable'
            ? 'local_complete_remote_failed'
            : 'complete',
        completedAtUtc: _clock().toUtc(),
        remoteTargetId: targetId,
        remoteState: remoteState,
        warnings: List.unmodifiable(warnings),
      );
    } on Object {
      if (await partialDirectory.exists()) await partialDirectory.delete(recursive: true);
      if (!recorded) {
        _recordFailedSnapshot(
          backupId: backupId,
          targetId: targetId,
          createdAt: createdAt,
          policy: encryptionPolicy,
          commandId: commandId ?? newUuidV7(at: createdAt),
        );
      }
      rethrow;
    } finally {
      if (dbKey != null) dbKey.fillRange(0, dbKey.length, 0);
      if (assetKey != null) assetKey.fillRange(0, assetKey.length, 0);
    }
  }

  Future<BackupRestoreResult> restore({
    required String snapshotDirectory,
    required String destinationDirectory,
  }) async {
    final source = Directory(p.normalize(p.absolute(snapshotDirectory)));
    final sourceType = await FileSystemEntity.type(source.path, followLinks: false);
    if (sourceType != FileSystemEntityType.directory) {
      throw FileSystemException('Backup snapshot directory is missing or is a link.', source.path);
    }
    final manifest = await _readManifest(source);
    final missingKeys = <String>{};
    for (final entry in manifest.objects) {
      if (entry.encryptionMode == 'none') continue;
      final keyRef = entry.keyRef;
      final bytes = keyRef == null ? null : await _secrets?.read(keyRef);
      try {
        if (bytes == null || bytes.length != 32) missingKeys.add(keyRef?.value ?? '(missing key id)');
      } finally {
        if (bytes != null) bytes.fillRange(0, bytes.length, 0);
      }
    }
    if (missingKeys.isNotEmpty) {
      throw BackupKeyDependencyException(missingKeys.toList(growable: false));
    }

    final destination = Directory(p.normalize(p.absolute(destinationDirectory)));
    if (await destination.exists()) {
      throw FileSystemException('Restore destination already exists; restore never overwrites a Vault.', destination.path);
    }
    await destination.parent.create(recursive: true);
    final staging = Directory('${destination.path}.restore-partial-${newUuidV7()}');
    await staging.create(recursive: true);
    try {
      for (final entry in manifest.objects) {
        final sourceFile = await _safeExistingChild(source, entry.relativePath);
        if (await sourceFile.length() != entry.storedBytes ||
            await _hashFile(sourceFile.path) != entry.storedSha256) {
          throw StateError('Backup object ${entry.objectId} failed stored SHA-256 validation.');
        }
        final restoreRelative = entry.category == BackupDataCategory.database
            ? 'workspace.sqlite3'
            : (entry.restoreRelativePath ?? 'store/$entry.objectId');
        final restoredFile = _safeChild(staging, restoreRelative);
        await restoredFile.parent.create(recursive: true);
        if (entry.encryptionMode == 'none') {
          await sourceFile.copy(restoredFile.path);
        } else {
          final key = await _loadKey(entry.keyRef);
          final clearTemp = File('${restoredFile.path}.decrypt-partial');
          try {
            await _encryption.decryptFile(
              keyBytes: key!,
              sourcePath: sourceFile.path,
              destinationPath: clearTemp.path,
            );
            await clearTemp.rename(restoredFile.path);
          } finally {
            if (key != null) key.fillRange(0, key.length, 0);
            if (await clearTemp.exists()) await clearTemp.delete();
          }
        }
        if (await restoredFile.length() != entry.plaintextBytes ||
            await _hashFile(restoredFile.path) != entry.plaintextSha256) {
          throw StateError('Backup object ${entry.objectId} failed plaintext SHA-256 validation.');
        }
      }

      final databasePath = p.join(staging.path, 'workspace.sqlite3');
      await _validateRestoredDatabase(databasePath, manifest, restoreRoot: staging);
      final restoredDatabase = await WorkspaceDatabase.open(filePath: databasePath);
      late final String restoredDeviceId;
      try {
        restoredDeviceId = await restoredDatabase.prepareRestoredInstallation(
          restoredFromBackupId: manifest.backupId,
          atUtc: _clock().toUtc(),
        );
      } finally {
        await restoredDatabase.close();
      }
      if (restoredDeviceId.isEmpty) {
        throw StateError('Restored installation identity is empty.');
      }
      await staging.rename(destination.path);
      final finalDatabase = p.join(destination.path, 'workspace.sqlite3');
      final restoreId = newUuidV7(at: _clock().toUtc());
      final warnings = <String>[];
      try {
        _recordRestore(manifest, restoreId, destination.path);
      } on Object catch (error) {
        warnings.add(
          'The Vault was restored and is available at ${destination.path}, but the source Vault could not record the restore audit: ${_safeError(error)}',
        );
      }
      return BackupRestoreResult(
        restoreId: restoreId,
        backupId: manifest.backupId,
        destinationDirectory: destination.path,
        databaseFilePath: finalDatabase,
        vaultId: manifest.vaultId,
        verifiedObjects: manifest.objects.length,
        completedAtUtc: _clock().toUtc(),
        warnings: List<String>.unmodifiable(warnings),
      );
    } on Object {
      if (await staging.exists()) await staging.delete(recursive: true);
      rethrow;
    }
  }

  Future<BackupManifest> _readManifest(Directory directory) async {
    final manifestFile = await _safeExistingChild(directory, 'manifest.json');
    final checksumFile = await _safeExistingChild(directory, 'manifest.sha256');
    final bytes = await manifestFile.readAsBytes();
    final actual = sha256.convert(bytes).toString();
    final expected = (await checksumFile.readAsString()).trim().split(RegExp(r'\s+')).first;
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(expected) || actual != expected) {
      throw const FormatException('Backup manifest checksum does not match.');
    }
    final value = jsonDecode(utf8.decode(bytes)) as Map<String, Object?>;
    return BackupManifest.fromJson(value);
  }

  Future<BackupObjectEntry> _storeBackupObject({
    required File source,
    required Directory partialRoot,
    required String objectId,
    required BackupDataCategory category,
    required String plainSha,
    required int plainBytes,
    required SecretRef? keyRef,
    required List<int>? keyBytes,
    required String storedRelativePath,
    required String restoreRelativePath,
  }) async {
    final storedPath = _safeChild(partialRoot, storedRelativePath);
    await storedPath.parent.create(recursive: true);
    var mode = 'none';
    if (keyRef != null) {
      if (keyBytes == null) throw BackupKeyDependencyException([keyRef.value]);
      final encryptedPath = File('${storedPath.path}.lwe');
      await _encryption.encryptFile(
        keyBytes: keyBytes,
        sourcePath: source.path,
        destinationPath: encryptedPath.path,
      );
      if (await source.exists()) await source.delete();
      mode = 'aes_gcm_chunked_v1';
      final storedSha = await _hashFile(encryptedPath.path);
      final storedBytes = await encryptedPath.length();
      final verify = File('${encryptedPath.path}.verify');
      await _encryption.decryptFile(keyBytes: keyBytes, sourcePath: encryptedPath.path, destinationPath: verify.path);
      if (await verify.length() != plainBytes || await _hashFile(verify.path) != plainSha) {
        await verify.delete();
        throw StateError('Encrypted backup object $objectId failed authenticated read-back.');
      }
      await verify.delete();
      return BackupObjectEntry(
        objectId: objectId,
        category: category,
        relativePath: _slashPath(p.relative(encryptedPath.path, from: partialRoot.path)),
        plaintextSha256: plainSha,
        plaintextBytes: plainBytes,
        storedSha256: storedSha,
        storedBytes: storedBytes,
        encryptionMode: mode,
        verificationLevel: 'full_sha256_and_aes_gcm_readback',
        keyRef: keyRef,
        restoreRelativePath: restoreRelativePath,
      );
    }
    if (p.normalize(source.path) != p.normalize(storedPath.path)) {
      if (await storedPath.exists()) await storedPath.delete();
      await source.rename(storedPath.path);
    }
    final storedSha = await _hashFile(storedPath.path);
    final storedBytes = await storedPath.length();
    if (storedSha != plainSha || storedBytes != plainBytes) {
      throw StateError('Plaintext backup object $objectId failed SHA-256 verification.');
    }
    return BackupObjectEntry(
      objectId: objectId,
      category: category,
      relativePath: _slashPath(p.relative(storedPath.path, from: partialRoot.path)),
      plaintextSha256: plainSha,
      plaintextBytes: plainBytes,
      storedSha256: storedSha,
      storedBytes: storedBytes,
      encryptionMode: 'none',
      verificationLevel: 'full_sha256',
      restoreRelativePath: restoreRelativePath,
    );
  }

  Future<Uint8List?> _loadKey(SecretRef? keyRef) async {
    if (keyRef == null) return null;
    final supplied = await _secrets?.read(keyRef);
    if (supplied == null || supplied.length != 32) {
      supplied?.fillRange(0, supplied.length, 0);
      throw BackupKeyDependencyException([keyRef.value]);
    }
    try {
      return Uint8List.fromList(supplied);
    } finally {
      supplied.fillRange(0, supplied.length, 0);
    }
  }

  Future<void> _verifyWrittenManifest(
    Directory directory,
    String expectedSha,
    BackupManifest manifest,
  ) async {
    final reread = await _readManifest(directory);
    if (reread.backupId != manifest.backupId || reread.vaultId != _vault.vaultId) {
      throw StateError('Backup manifest identity changed during snapshot.');
    }
    for (final object in manifest.objects) {
      final file = await _safeExistingChild(directory, object.relativePath);
      if (await file.length() != object.storedBytes ||
          await _hashFile(file.path) != object.storedSha256) {
        throw StateError('Backup object ${object.objectId} failed final manifest validation.');
      }
    }
    if (await _hashFile(p.join(directory.path, 'manifest.json')) != expectedSha) {
      throw const FormatException('Manifest SHA-256 changed after final validation.');
    }
    final dbEntry = manifest.databaseObject;
    if (dbEntry.encryptionMode == 'none') {
      await _validateSnapshotDatabase((await _safeExistingChild(directory, dbEntry.relativePath)).path, manifest);
    } else {
      final key = await _loadKey(dbEntry.keyRef);
      final temp = File(p.join(directory.path, 'database', 'verify-workspace.sqlite3'));
      try {
        await _encryption.decryptFile(
          keyBytes: key!,
          sourcePath: (await _safeExistingChild(directory, dbEntry.relativePath)).path,
          destinationPath: temp.path,
        );
        if (await _hashFile(temp.path) != dbEntry.plaintextSha256 || await temp.length() != dbEntry.plaintextBytes) {
          throw StateError('Encrypted database backup did not decrypt to the recorded SHA-256.');
        }
        await _validateSnapshotDatabase(temp.path, manifest);
      } finally {
        if (key != null) key.fillRange(0, key.length, 0);
        if (await temp.exists()) await temp.delete();
      }
    }
  }

  Future<void> _validateSnapshotDatabase(String path, BackupManifest manifest) async {
    final database = await WorkspaceDatabase.open(filePath: path);
    try {
      final integrity = database.query('PRAGMA integrity_check');
      if (integrity.isEmpty || integrity.first.values.first != 'ok') {
        throw StateError('Backup database failed SQLite integrity_check.');
      }
      final vaults = database.query('SELECT vault_id FROM vaults WHERE vault_id=?', [manifest.vaultId]);
      if (vaults.isEmpty) throw StateError('Backup database contains a different Vault id.');
      if (database.schemaVersion != manifest.databaseSchemaVersion) {
        throw StateError('Backup database schema version does not match its manifest.');
      }
      if (database.query('PRAGMA foreign_key_check').isNotEmpty) {
        throw StateError('Backup database has foreign key violations.');
      }
    } finally {
      await database.close();
    }
  }

  Future<void> _validateRestoredDatabase(
    String path,
    BackupManifest manifest, {
    required Directory restoreRoot,
  }) async {
    await _validateSnapshotDatabase(path, manifest);
    final database = await WorkspaceDatabase.open(filePath: path);
    late final List<DbRow> blobs;
    try {
      blobs = database.query('''
        SELECT DISTINCT b.sha256,b.byte_size,b.relative_path FROM blob_objects b
        WHERE b.state='committed' AND (
          EXISTS(SELECT 1 FROM assets a WHERE a.blob_sha256=b.sha256) OR
          EXISTS(SELECT 1 FROM sync_received_blobs r WHERE r.sha256=b.sha256 AND r.state='available')
        ) ORDER BY b.sha256
      ''');
    } finally {
      await database.close();
    }
    final assetEntries = <String, BackupObjectEntry>{
      for (final entry in manifest.assets) entry.plaintextSha256: entry,
    };
    if (blobs.length != assetEntries.length) {
      throw StateError('Restored database Blob inventory does not match the backup manifest.');
    }
    for (final blob in blobs) {
      final sha = blob['sha256'];
      if (sha is! String || !RegExp(r'^[a-f0-9]{64}$').hasMatch(sha)) {
        throw StateError('Restored database contains an invalid Blob SHA-256.');
      }
      final entry = assetEntries[sha];
      final bytes = _asInt(blob['byte_size']);
      final relative = blob['relative_path'];
      final expectedRelative = 'objects/sha256/${sha.substring(0, 2)}/${sha.substring(2, 4)}/$sha';
      if (entry == null ||
          entry.plaintextBytes != bytes ||
          relative != expectedRelative) {
        throw StateError('Restored database Blob metadata is inconsistent with the backup manifest.');
      }
      final restoredFile = _safeChild(restoreRoot, entry.restoreRelativePath!);
      if (await FileSystemEntity.type(restoredFile.path, followLinks: false) != FileSystemEntityType.file ||
          await restoredFile.length() != bytes ||
          await _hashFile(restoredFile.path) != sha) {
        throw StateError('Restored CAS Blob $sha does not match the database inventory.');
      }
    }
  }

  void _recordSnapshot({
    required BackupManifest manifest,
    required String manifestSha,
    required String directory,
    required String? targetId,
    required String commandId,
    required String state,
  }) {
    final now = _clock().toUtc();
    _vault.database.transaction((tx) {
      tx.execute(
        'INSERT INTO backup_snapshots(backup_id,target_id,state,manifest_sha256,encryption_mode,created_at_utc,'
        'db_schema_version,vault_id,sqlite_snapshot_path,asset_manifest_json,encryption_policy_json,'
        'checksum_policy_json,pack_versions_json) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)',
        [manifest.backupId, targetId, state, manifestSha, _encryptionSummary(manifest),
          manifest.createdAtUtc.toIso8601String(), manifest.databaseSchemaVersion, manifest.vaultId,
          p.join(directory, manifest.databaseObject.relativePath),
          jsonEncode(manifest.assets.map((object) => object.toJson()).toList(growable: false)),
          jsonEncode(manifest.encryptionPolicy.toJson()),
          jsonEncode({'algorithm': 'sha256', 'manifest_sidecar': true, 'full_asset_hash': true}),
          jsonEncode(manifest.packVersions.map((entry) => entry.toJson()).toList(growable: false))],
      );
      for (final object in manifest.objects) {
        tx.execute(
          'INSERT INTO backup_snapshot_objects(backup_id,object_id,content_sha256,remote_key,byte_size,'
          'encryption_mode,key_id,verification_level) VALUES(?,?,?,NULL,?,?,?,?)',
          [manifest.backupId, object.objectId, object.plaintextSha256, object.plaintextBytes,
            object.encryptionMode, object.keyRef?.value, object.verificationLevel],
        );
      }
      tx.appendMutation(MutationEventDraft(
        command: CommandMetadata(commandId: commandId, utcTime: now),
        deviceId: _vault.deviceId,
        entityType: 'backup_snapshot',
        entityId: manifest.backupId,
        eventType: 'BackupSnapshotCreated',
        action: MutationAction.create,
        payloadJson: jsonEncode({
          'backup_id': manifest.backupId,
          'manifest_sha256': manifestSha,
          'state': state,
          'encrypted_categories': manifest.encryptionPolicy.toJson(),
        }),
      ));
      return null;
    });
  }

  void _recordFailedSnapshot({
    required String backupId,
    required String? targetId,
    required DateTime createdAt,
    required BackupEncryptionPolicy policy,
    required String commandId,
  }) {
    try {
      _vault.database.transaction((tx) {
        tx.execute(
          'INSERT INTO backup_snapshots(backup_id,target_id,state,manifest_sha256,encryption_mode,created_at_utc,'
          'db_schema_version,vault_id,asset_manifest_json,encryption_policy_json,checksum_policy_json,pack_versions_json) '
          'VALUES(?,?,?,?,?,?,?,?,?,?,?,?)',
          [backupId, targetId, 'failed', List.filled(64, '0').join(),
            '${policy.databaseKey == null ? 'none' : 'aes_gcm_chunked_v1'},${policy.assetKey == null ? 'none' : 'aes_gcm_chunked_v1'}',
            createdAt.toIso8601String(), _vault.database.schemaVersion, _vault.vaultId, '[]',
            jsonEncode(policy.toJson()), jsonEncode({'algorithm': 'sha256'}), '[]'],
        );
        tx.appendMutation(MutationEventDraft(
          command: CommandMetadata(commandId: commandId, utcTime: createdAt),
          deviceId: _vault.deviceId,
          entityType: 'backup_snapshot',
          entityId: backupId,
          eventType: 'BackupSnapshotFailed',
          action: MutationAction.append,
          payloadJson: jsonEncode({'backup_id': backupId, 'state': 'failed'}),
        ));
        return null;
      });
    } on Object {
      // A failed local database write must not be misreported as a backup.
    }
  }

  void _setSnapshotState(String backupId, String state) {
    _vault.database.transaction((tx) {
      tx.execute('UPDATE backup_snapshots SET state=? WHERE backup_id=?', [state, backupId]);
      tx.appendMutation(MutationEventDraft(
        command: CommandMetadata(commandId: newUuidV7(at: _clock().toUtc()), utcTime: _clock().toUtc()),
        deviceId: _vault.deviceId,
        entityType: 'backup_snapshot',
        entityId: backupId,
        eventType: 'BackupSnapshotStateChanged',
        action: MutationAction.patch,
        payloadJson: jsonEncode({'backup_id': backupId, 'state': state}),
      ));
      return null;
    });
  }

  void _recordRestore(BackupManifest manifest, String restoreId, String destination) {
    final existing = _vault.database.query('SELECT backup_id FROM backup_snapshots WHERE backup_id=?', [manifest.backupId]);
    if (existing.isEmpty) return;
    final now = _clock().toUtc();
    _vault.database.transaction((tx) {
      tx.execute(
        'INSERT INTO backup_restore_reports(restore_id,backup_id,state,report_json,tested_at_utc) VALUES(?,?,?,?,?)',
        [restoreId, manifest.backupId, 'restored_and_verified',
          jsonEncode({'destination': destination, 'vault_id': manifest.vaultId, 'object_count': manifest.objects.length}),
          now.toIso8601String()],
      );
      tx.appendMutation(MutationEventDraft(
        command: CommandMetadata(commandId: newUuidV7(at: now), utcTime: now),
        deviceId: _vault.deviceId,
        entityType: 'backup_restore',
        entityId: restoreId,
        eventType: 'BackupRestoreVerified',
        action: MutationAction.append,
        payloadJson: jsonEncode({'restore_id': restoreId, 'backup_id': manifest.backupId, 'state': 'restored_and_verified'}),
      ));
      return null;
    });
  }

  static String _encryptionSummary(BackupManifest manifest) => manifest.objects
      .where((object) => object.encryptionMode != 'none')
      .map((object) => object.category.name)
      .toSet()
      .join(',');
}

File _safeChild(Directory root, String relativePath) {
  final normalizedSeparators = relativePath.replaceAll('\\', '/');
  if (normalizedSeparators.startsWith('/') ||
      normalizedSeparators.split('/').any((segment) => segment == '..' || segment.isEmpty)) {
    throw ArgumentError.value(relativePath, 'relativePath', 'Backup path must be a safe relative path.');
  }
  final normalized = p.normalize(normalizedSeparators);
  if (p.isAbsolute(normalized) || normalized == '..' || normalized.startsWith('..${p.separator}')) {
    throw ArgumentError.value(relativePath, 'relativePath', 'Backup path escapes the selected directory.');
  }
  final path = p.join(root.path, normalized);
  if (!p.isWithin(root.path, path)) throw ArgumentError.value(relativePath, 'relativePath');
  return File(path);
}

Future<File> _safeExistingChild(Directory root, String relativePath) async {
  final rootType = await FileSystemEntity.type(root.path, followLinks: false);
  if (rootType != FileSystemEntityType.directory) {
    throw FileSystemException('Backup source directory is missing or is a link.', root.path);
  }
  final file = _safeChild(root, relativePath);
  final segments = relativePath.replaceAll('\\', '/').split('/');
  var current = root.path;
  for (var index = 0; index < segments.length; index++) {
    current = p.join(current, segments[index]);
    final type = await FileSystemEntity.type(current, followLinks: false);
    if (type == FileSystemEntityType.link) {
      throw FileSystemException('Backup paths cannot contain symbolic links.', current);
    }
    final expected = index == segments.length - 1
        ? FileSystemEntityType.file
        : FileSystemEntityType.directory;
    if (type != expected) {
      throw FileSystemException('Backup path component has an unexpected type.', current);
    }
  }
  return file;
}

String _backupAssetPath(String sha) =>
    'objects/sha256/${sha.substring(0, 2)}/${sha.substring(2, 4)}/$sha';

String _slashPath(String path) => path.replaceAll('\\', '/');

int _asInt(Object? value) => switch (value) {
      int number => number,
      BigInt number => number.toInt(),
      num number => number.toInt(),
      _ => 0,
    };

Future<String> _hashFile(String path) async => (await sha256.bind(File(path).openRead()).first).toString();

String _safeError(Object error) {
  final value = error.toString().replaceAll(RegExp(r'(Bearer\s+)[^\s]+', caseSensitive: false), r'$1[redacted]');
  return value.length > 400 ? value.substring(0, 400) : value;
}
