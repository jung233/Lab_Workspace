import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'asset_models.dart';

const int defaultStrictSizeThresholdBytes = 2 * 1024 * 1024 * 1024;

/// File-system implementation of the immutable, content-addressed object store.
/// It never writes to a user-selected source path and never replaces a
/// committed object. Database state transitions are coordinated by
/// [AssetGateway].
final class AssetStore {
  AssetStore({required this.vaultRootDirectory})
      : _root = Directory(p.join(vaultRootDirectory, 'store'));

  final String vaultRootDirectory;
  final Directory _root;

  Directory get rootDirectory => _root;
  Directory get objectsDirectory => Directory(p.join(_root.path, 'objects', 'sha256'));
  Directory get stagingDirectory => Directory(p.join(_root.path, 'staging'));
  Directory get quarantineDirectory => Directory(p.join(_root.path, 'quarantine'));

  Future<void> initialize() async {
    await objectsDirectory.create(recursive: true);
    await stagingDirectory.create(recursive: true);
    await quarantineDirectory.create(recursive: true);
  }

  Future<StagedAssetBlob> stageImport({
    required AssetImportSource source,
    required String importId,
  }) async {
    await initialize();
    final stagedRelativePath = p.join('staging', '$importId.part');
    final stagedFile = _fileForRelativePath(stagedRelativePath);
    await stagedFile.parent.create(recursive: true);
    await stagedFile.create(exclusive: true);

    RandomAccessFile? output;
    var byteSize = 0;
    var hashingClosed = false;
    final digestSink = _SingleDigestSink();
    final hashingSink = sha256.startChunkedConversion(digestSink);
    try {
      output = await stagedFile.open(mode: FileMode.writeOnly);
      await for (final chunk in source.content) {
        if (chunk.isEmpty) continue;
        hashingSink.add(chunk);
        await output.writeFrom(chunk);
        byteSize += chunk.length;
      }
      hashingClosed = true;
      hashingSink.close();
      await output.flush();
      await output.close();
      output = null;
      if (source.sizeHint != null && source.sizeHint != byteSize) {
        throw AssetSourceSizeChangedException(
          expectedBytes: source.sizeHint!,
          actualBytes: byteSize,
        );
      }
      final digest = digestSink.value.toString();
      final stat = await stagedFile.stat();
      if (stat.type != FileSystemEntityType.file || stat.size != byteSize) {
        throw const FileSystemException('Staging file size changed before commit.');
      }
      return StagedAssetBlob(
        importId: importId,
        blobSha256: digest,
        byteSize: byteSize,
        stagingRelativePath: stagedRelativePath,
        fingerprint: AssetFileFingerprint.fromStat(stat),
      );
    } catch (_) {
      if (!hashingClosed) hashingSink.close();
      await output?.close();
      if (await stagedFile.exists()) await stagedFile.delete();
      rethrow;
    }
  }

  /// Atomically publishes a staged file into the CAS. If the object already
  /// exists, its bytes are fully hashed before reuse, independent of the
  /// normal large-file access threshold.
  Future<PublishedAssetBlob> publish(StagedAssetBlob staged) async {
    final source = _fileForRelativePath(staged.stagingRelativePath);
    final destinationRelativePath = objectRelativePath(staged.blobSha256);
    final destination = _fileForRelativePath(destinationRelativePath);
    await destination.parent.create(recursive: true);

    if (await destination.exists()) {
      final existingStat = await destination.stat();
      if (existingStat.size != staged.byteSize) {
        throw AssetStoreCollisionException(staged.blobSha256);
      }
      final digest = await sha256.bind(destination.openRead()).first;
      if (digest.toString() != staged.blobSha256) {
        throw AssetStoreCollisionException(staged.blobSha256);
      }
      if (await source.exists()) await source.delete();
      return PublishedAssetBlob(
        blobSha256: staged.blobSha256,
        byteSize: staged.byteSize,
        relativePath: destinationRelativePath,
        fingerprint: AssetFileFingerprint.fromStat(existingStat),
        reusedExisting: true,
      );
    }

    if (!await source.exists()) {
      throw FileSystemException('Staged asset is missing.', source.path);
    }
    // `rename` is atomic because staging and objects live under the same Vault
    // root and therefore on the same filesystem.
    final published = await source.rename(destination.path);
    final stat = await published.stat();
    if (stat.size != staged.byteSize) {
      throw FileSystemException('Published CAS object has an unexpected size.', published.path);
    }
    return PublishedAssetBlob(
      blobSha256: staged.blobSha256,
      byteSize: staged.byteSize,
      relativePath: destinationRelativePath,
      fingerprint: AssetFileFingerprint.fromStat(stat),
      reusedExisting: false,
    );
  }

  Future<AssetSnapshotFile> materializeReadSnapshot({
    required BlobSha256 sha256Digest,
    required int? expectedBytes,
    required int? expectedMtimeNs,
    required bool verifySha256,
  }) async {
    final source = blobFile(sha256Digest);
    if (!await source.exists()) throw FileSystemException('CAS object is missing.', source.path);

    final before = await source.stat();
    if (before.type != FileSystemEntityType.file ||
        (expectedBytes != null && before.size != expectedBytes)) {
      throw const AssetStoreMetadataMismatchException('Stored object size changed.');
    }
    final beforeFingerprint = AssetFileFingerprint.fromStat(before);
    if (expectedMtimeNs != null && beforeFingerprint.mtimeNs != expectedMtimeNs) {
      throw const AssetStoreMetadataMismatchException('Stored object modification time changed.');
    }

    final snapshotId = _randomId();
    final snapshotRelativePath = p.join('staging', 'read-$snapshotId.snapshot');
    final snapshot = _fileForRelativePath(snapshotRelativePath);
    await snapshot.create(exclusive: true);
    RandomAccessFile? output;
    var hashingClosed = false;
    final digestSink = _SingleDigestSink();
    final hashingSink = verifySha256 ? sha256.startChunkedConversion(digestSink) : null;
    var copiedBytes = 0;
    try {
      output = await snapshot.open(mode: FileMode.writeOnly);
      await for (final chunk in source.openRead()) {
        if (chunk.isEmpty) continue;
        hashingSink?.add(chunk);
        await output.writeFrom(chunk);
        copiedBytes += chunk.length;
      }
      if (hashingSink != null) {
        hashingClosed = true;
        hashingSink.close();
      }
      await output.flush();
      await output.close();
      output = null;
      final after = await source.stat();
      final afterFingerprint = AssetFileFingerprint.fromStat(after);
      if ((expectedBytes != null && copiedBytes != expectedBytes) ||
          after.type != FileSystemEntityType.file ||
          after.size != before.size ||
          afterFingerprint.mtimeNs != beforeFingerprint.mtimeNs ||
          afterFingerprint.size != beforeFingerprint.size) {
        throw const AssetStoreMetadataMismatchException(
          'Stored object changed while the read snapshot was being made.',
        );
      }
      final actualSha256 = verifySha256 ? digestSink.value.toString() : null;
      return AssetSnapshotFile(
        file: snapshot,
        relativePath: snapshotRelativePath,
        byteSize: copiedBytes,
        actualSha256: actualSha256,
        fingerprint: beforeFingerprint,
      );
    } catch (_) {
      if (hashingSink != null && !hashingClosed) hashingSink.close();
      await output?.close();
      if (await snapshot.exists()) await snapshot.delete();
      rethrow;
    }
  }

  Future<String> fullHash(BlobSha256 sha256Digest) async {
    final file = blobFile(sha256Digest);
    if (!await file.exists()) throw FileSystemException('CAS object is missing.', file.path);
    return (await sha256.bind(file.openRead()).first).toString();
  }

  Future<AssetFileFingerprint> fingerprint(BlobSha256 sha256Digest) async {
    final file = blobFile(sha256Digest);
    if (!await file.exists()) throw FileSystemException('CAS object is missing.', file.path);
    return AssetFileFingerprint.fromStat(await file.stat());
  }

  Future<int> deleteBlob(BlobSha256 sha256Digest) async {
    final file = blobFile(sha256Digest);
    var releasedBytes = 0;
    if (await file.exists()) {
      releasedBytes = await file.length();
      await file.delete();
    }
    await _deleteEmptyParents(file.parent);
    return releasedBytes;
  }

  Future<void> deleteStaging(String relativePath) async {
    final file = _fileForRelativePath(relativePath);
    if (await file.exists()) await file.delete();
  }

  Future<List<File>> listStagingFiles() async {
    if (!await stagingDirectory.exists()) return const <File>[];
    final result = <File>[];
    await for (final entity in stagingDirectory.list(recursive: true, followLinks: false)) {
      if (entity is File) result.add(entity);
    }
    return result;
  }

  Future<List<File>> listBlobFiles() async {
    if (!await objectsDirectory.exists()) return const <File>[];
    final result = <File>[];
    await for (final entity in objectsDirectory.list(recursive: true, followLinks: false)) {
      if (entity is File) result.add(entity);
    }
    return result;
  }

  Future<int> directoryBytes(Directory directory) async {
    if (!await directory.exists()) return 0;
    var total = 0;
    await for (final entity in directory.list(recursive: true, followLinks: false)) {
      if (entity is File) total += (await entity.stat()).size;
    }
    return total;
  }

  File blobFile(BlobSha256 sha256Digest) =>
      _fileForRelativePath(objectRelativePath(sha256Digest));

  String objectRelativePath(BlobSha256 sha256Digest) {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(sha256Digest)) {
      throw ArgumentError.value(sha256Digest, 'sha256Digest', 'Expected lowercase SHA-256.');
    }
    return p.join(
      'objects',
      'sha256',
      sha256Digest.substring(0, 2),
      sha256Digest.substring(2, 4),
      sha256Digest,
    );
  }

  File _fileForRelativePath(String relativePath) {
    final normalized = p.normalize(relativePath);
    if (p.isAbsolute(normalized) || normalized == '..' || normalized.startsWith('..${p.separator}')) {
      throw ArgumentError.value(relativePath, 'relativePath', 'Path must stay inside the asset store.');
    }
    return File(p.join(_root.path, normalized));
  }

  Future<void> _deleteEmptyParents(Directory directory) async {
    final rootPath = p.normalize(_root.path);
    var current = directory;
    while (p.normalize(current.path) != rootPath && p.isWithin(rootPath, current.path)) {
      try {
        await current.delete();
      } on FileSystemException {
        break;
      }
      current = current.parent;
    }
  }

  static String _randomId() {
    final random = Random.secure();
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    for (var i = 0; i < 6; i++) {
      bytes[5 - i] = (now >> (8 * i)) & 0xff;
    }
    bytes[6] = (bytes[6] & 0x0f) | 0x70;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-'
        '${hex.substring(16, 20)}-${hex.substring(20)}';
  }
}

final class StagedAssetBlob {
  const StagedAssetBlob({
    required this.importId,
    required this.blobSha256,
    required this.byteSize,
    required this.stagingRelativePath,
    required this.fingerprint,
  });

  final String importId;
  final BlobSha256 blobSha256;
  final int byteSize;
  final String stagingRelativePath;
  final AssetFileFingerprint fingerprint;
}

final class PublishedAssetBlob {
  const PublishedAssetBlob({
    required this.blobSha256,
    required this.byteSize,
    required this.relativePath,
    required this.fingerprint,
    required this.reusedExisting,
  });

  final BlobSha256 blobSha256;
  final int byteSize;
  final String relativePath;
  final AssetFileFingerprint fingerprint;
  final bool reusedExisting;
}

final class AssetSnapshotFile {
  const AssetSnapshotFile({
    required this.file,
    required this.relativePath,
    required this.byteSize,
    required this.actualSha256,
    required this.fingerprint,
  });

  final File file;
  final String relativePath;
  final int byteSize;
  final String? actualSha256;
  final AssetFileFingerprint fingerprint;

  Stream<List<int>> openRead() => file.openRead();

  Future<void> dispose() async {
    if (await file.exists()) await file.delete();
  }
}

final class AssetFileFingerprint {
  const AssetFileFingerprint({
    required this.size,
    required this.mtimeNs,
    required this.fileId,
  });

  final int size;
  final int mtimeNs;
  final String? fileId;

  factory AssetFileFingerprint.fromStat(FileStat stat) =>
      AssetFileFingerprint(
        size: stat.size,
        // Dart FileStat currently exposes modified time as DateTime rather than
        // a native file ID/high-resolution timestamp. Store the available
        // timestamp in nanosecond units and keep fileId null when unavailable.
        mtimeNs: stat.modified.toUtc().microsecondsSinceEpoch * 1000,
        fileId: null,
      );
}

final class AssetStoreCollisionException implements Exception {
  const AssetStoreCollisionException(this.blobSha256);

  final BlobSha256 blobSha256;

  @override
  String toString() => 'CAS object at $blobSha256 does not match its content address.';
}

final class AssetStoreMetadataMismatchException implements Exception {
  const AssetStoreMetadataMismatchException(this.message);

  final String message;

  @override
  String toString() => 'ASSET_FAST_CHECK_ONLY: $message';
}

final class AssetSourceSizeChangedException implements Exception {
  const AssetSourceSizeChangedException({required this.expectedBytes, required this.actualBytes});

  final int expectedBytes;
  final int actualBytes;

  @override
  String toString() => 'Source size hint was $expectedBytes bytes; received $actualBytes bytes.';
}

final class _SingleDigestSink implements Sink<Digest> {
  Digest? _value;

  Digest get value => _value ?? (throw StateError('SHA-256 conversion produced no digest.'));

  @override
  void add(Digest value) {
    if (_value != null) {
      throw StateError('SHA-256 conversion produced more than one digest.');
    }
    _value = value;
  }

  @override
  void close() {}
}
