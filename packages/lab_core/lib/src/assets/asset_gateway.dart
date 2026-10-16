import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../domain/commands.dart';
import '../domain/events.dart';
import '../domain/ids.dart' hide DeletionId;
import '../domain/security.dart';
import '../domain/vault.dart';
import '../persistence/workspace_database.dart';
import 'asset_models.dart';
import 'asset_store.dart';

/// Application-facing service for managed local assets and File Explorer.
///
/// Ingest uses a staged file plus a recoverable DB intent before atomic CAS
/// publication. No committed object is overwritten. Logical writes append
/// their immutable mutation event in the same SQLite transaction.
final class AssetGateway {
  AssetGateway({
    required VaultContext vault,
    Duration trashRetention = const Duration(days: 30),
    bool fullVerifyLargeFilesOnEveryOpen = false,
  })  : _vault = vault,
        _store = AssetStore(vaultRootDirectory: vault.rootDirectory),
        trashRetention = trashRetention,
        fullVerifyLargeFilesOnEveryOpen = fullVerifyLargeFilesOnEveryOpen;

  static const int defaultIntegrityThresholdBytes = defaultStrictSizeThresholdBytes;

  final VaultContext _vault;
  final AssetStore _store;
  final Duration trashRetention;
  final bool fullVerifyLargeFilesOnEveryOpen;
  final Map<String, Completer<void>> _blobLocks = <String, Completer<void>>{};
  bool _initialized = false;

  /// Creates managed directories and resumes incomplete two-phase imports.
  /// Call once during local Vault startup before Explorer or sync is enabled.
  Future<void> initialize() async {
    if (_initialized) return;
    await _store.initialize();
    await recoverInterruptedImports();
    await _recoverInterruptedSynchronizedBlobs();
    await _recoverGarbageCollectionClaims();
    await _removeUntrackedStagingFiles();
    _initialized = true;
  }

  Future<AssetImportResult> importFile(
    AssetImportSource source, {
    AssetKind kind = AssetKind.raw,
    AssetId? parentAssetId,
    Iterable<AssetLinkRef> links = const <AssetLinkRef>[],
    Map<String, Object?> metadata = const <String, Object?>{},
    String? commandId,
  }) async {
    await initialize();
    final displayName = _normalizeDisplayName(source.displayName);
    if (source.sizeHint != null && source.sizeHint! < 0) {
      throw ArgumentError.value(source.sizeHint, 'sizeHint', 'Cannot be negative.');
    }
    final actualCommandId = commandId ?? newUuidV7();
    final importId = actualCommandId;
    final appliedImport = _vault.database.query(
      'SELECT entity_id FROM mutation_events WHERE command_id=?',
      <Object?>[actualCommandId],
    );
    if (appliedImport.isNotEmpty) {
      final existingAssetId = _string(appliedImport.first['entity_id']);
      final existingRow = _assetRow(existingAssetId);
      if (existingRow == null) {
        throw StateError('Import command was already recorded but its Asset record is missing.');
      }
      return AssetImportResult(
        asset: _assetFromRow(existingRow, thresholdBytes: await _integrityThresholdBytes()),
        reusedBlob: true,
      );
    }
    final assetId = newUuidV7();
    final createdAt = DateTime.now().toUtc();
    final thresholdBytes = await _integrityThresholdBytes();
    final linkValues = links.toList(growable: false);
    final metadataJson = jsonEncode(metadata);
    final linkJson = jsonEncode(linkValues.map(_linkToJson).toList(growable: false));
    final staged = await _store.stageImport(source: source, importId: importId);
    final assetJson = jsonEncode(<String, Object?>{
      'asset_id': assetId,
      'blob_sha256': staged.blobSha256,
      'bytes': staged.byteSize,
      'display_name': displayName,
      'media_type': source.mediaType,
      'kind': kind.wireValue,
      'parent_asset_id': parentAssetId,
      'created_at_utc': createdAt.toIso8601String(),
      'threshold_bytes': thresholdBytes,
      'metadata': jsonDecode(metadataJson),
    });

    try {
      return await _withBlobLock(staged.blobSha256, () async {
      await _rejectIfGcClaimed(staged.blobSha256);
      final existing = _blobRow(staged.blobSha256);
      if (existing != null && _string(existing['state']) == 'committed') {
        final existingFile = _store.blobFile(staged.blobSha256);
        if (await existingFile.exists()) {
          final actualHash = await _store.fullHash(staged.blobSha256);
          if (actualHash != staged.blobSha256) {
            await _quarantineMismatch(staged.blobSha256, 'CAS object did not match its SHA-256.');
            // An exact re-import can restore the expected immutable bytes after
            // the corrupt copy has been isolated; it never adopts the bad bytes.
          } else {
            await _store.deleteStaging(staged.stagingRelativePath);
            final asset = await _commitAssetOnly(
              assetId: assetId,
              blobSha256: staged.blobSha256,
              byteSize: staged.byteSize,
              displayName: displayName,
              mediaType: source.mediaType,
              kind: kind,
              parentAssetId: parentAssetId,
              createdAt: createdAt,
              thresholdBytes: thresholdBytes,
              metadata: metadata,
              links: linkValues,
              commandId: actualCommandId,
              reusedBlob: true,
            );
            return AssetImportResult(asset: asset, reusedBlob: true);
          }
        } else {
          await _setBlobState(staged.blobSha256, 'missing');
        }
      }

      // Record the intent before publishing the file. If the process stops
      // after this point, initialize() can finish the CAS rename and commit.
      _vault.database.transaction((tx) {
        final gcClaims = tx.query(
          'SELECT claim_id FROM asset_blob_gc_claims WHERE blob_sha256=?',
          <Object?>[staged.blobSha256],
        );
        if (gcClaims.isNotEmpty) {
          throw StateError('CAS Blob is being permanently released; retry import later.');
        }
        final current = tx.query(
          'SELECT state FROM blob_objects WHERE sha256 = ?',
          <Object?>[staged.blobSha256],
        );
        if (current.isEmpty) {
          tx.execute(
            '''INSERT INTO blob_objects
               (sha256, byte_size, relative_path, state, imported_at_utc,
                last_full_verified_at, last_fast_checked_at, last_known_size,
                last_known_mtime_ns, last_file_id, threshold_at_import)
               VALUES (?, ?, ?, 'staged', ?, NULL, NULL, ?, ?, ?, ?)''',
            <Object?>[
              staged.blobSha256,
              staged.byteSize,
              _store.objectRelativePath(staged.blobSha256),
              createdAt.toIso8601String(),
              staged.fingerprint.size,
              staged.fingerprint.mtimeNs,
              staged.fingerprint.fileId,
              thresholdBytes,
            ],
          );
        } else if (_string(current.first['state']) != 'committed') {
          tx.execute(
            '''UPDATE blob_objects SET state = 'staged', relative_path = ?, byte_size = ?,
                 last_known_size = ?, last_known_mtime_ns = ?, last_file_id = ?,
                 threshold_at_import = ? WHERE sha256 = ?''',
            <Object?>[
              _store.objectRelativePath(staged.blobSha256),
              staged.byteSize,
              staged.fingerprint.size,
              staged.fingerprint.mtimeNs,
              staged.fingerprint.fileId,
              thresholdBytes,
              staged.blobSha256,
            ],
          );
        }
        tx.execute(
          '''INSERT OR REPLACE INTO pending_asset_imports
             (import_id, blob_sha256, staging_relative_path, asset_id, asset_json,
              link_refs_json, command_id, created_at_utc)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?)''',
          <Object?>[
            importId,
            staged.blobSha256,
            staged.stagingRelativePath,
            assetId,
            assetJson,
            linkJson,
            actualCommandId,
            createdAt.toIso8601String(),
          ],
        );
      });

      try {
        final published = await _store.publish(staged);
        final asset = _commitPendingImport(
          importId: importId,
          assetId: assetId,
          blobSha256: staged.blobSha256,
          byteSize: staged.byteSize,
          displayName: displayName,
          mediaType: source.mediaType,
          kind: kind,
          parentAssetId: parentAssetId,
          createdAt: createdAt,
          thresholdBytes: thresholdBytes,
          metadata: metadata,
          links: linkValues,
          commandId: actualCommandId,
          published: published,
        );
        return AssetImportResult(asset: asset, reusedBlob: published.reusedExisting);
      } catch (_) {
        // A CAS file published before a failed DB commit is deliberately left
        // in place. The pending import record makes recovery deterministic.
        rethrow;
      }
      });
    } catch (_) {
      final pending = _vault.database.query(
        'SELECT 1 FROM pending_asset_imports WHERE import_id=?',
        <Object?>[importId],
      );
      if (pending.isEmpty) {
        await _store.deleteStaging(staged.stagingRelativePath);
      }
      rethrow;
    }
  }

  /// Receives a remote immutable Blob into this device's CAS without applying
  /// the remote event or inventing a local Asset record. The retention row
  /// keeps it safe until an approved materializer links/releases it.
  Future<void> receiveSynchronizedBlob({
    required String expectedSha256,
    required int expectedBytes,
    required String sourceTargetId,
    required Stream<List<int>> content,
  }) async {
    await initialize();
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(expectedSha256) || expectedBytes < 0) {
      throw ArgumentError('A lowercase SHA-256 and non-negative byte size are required.');
    }
    final importId = newUuidV7();
    final staged = await _store.stageImport(
      source: AssetImportSource(
        displayName: 'synchronized-$expectedSha256',
        content: content,
        sizeHint: expectedBytes,
      ),
      importId: importId,
    );
    if (staged.blobSha256 != expectedSha256 || staged.byteSize != expectedBytes) {
      await _store.deleteStaging(staged.stagingRelativePath);
      throw AssetIntegrityException(
        assetId: 'sync:$sourceTargetId',
        expectedSha256: expectedSha256,
        actualSha256: staged.blobSha256,
      );
    }
    await _withBlobLock(expectedSha256, () async {
      await _rejectIfGcClaimed(expectedSha256);
      final existing = _blobRow(expectedSha256);
      final casFile = _store.blobFile(expectedSha256);
      if (await casFile.exists()) {
        final validExisting = await casFile.length() == expectedBytes &&
            await _store.fullHash(expectedSha256) == expectedSha256;
        if (validExisting && existing != null && _string(existing['state']) == 'committed') {
          await _store.deleteStaging(staged.stagingRelativePath);
          _retainReceivedBlob(expectedSha256, sourceTargetId, DateTime.now().toUtc());
          return;
        }
        if (!validExisting) {
          await _quarantineMismatch(expectedSha256, 'Local CAS bytes failed verification before remote repair.');
        }
      }

      final relativePath = _store.objectRelativePath(expectedSha256);
      final now = DateTime.now().toUtc();
      final thresholdBytes = await _integrityThresholdBytes();
      _vault.database.transaction((tx) {
        if (tx.query('SELECT 1 FROM asset_blob_gc_claims WHERE blob_sha256=?', [expectedSha256]).isNotEmpty) {
          throw StateError('Blob GC currently holds a deletion claim for $expectedSha256.');
        }
        if (existing == null) {
          tx.execute(
            'INSERT INTO blob_objects(sha256,byte_size,relative_path,state,imported_at_utc,last_known_size,'
            'last_known_mtime_ns,last_file_id,threshold_at_import,staging_path,integrity_policy_snapshot) '
            'VALUES(?,?,?,\'staged\',?,?,?,?,?,?,?)',
            [expectedSha256, expectedBytes, relativePath, now.toIso8601String(), staged.fingerprint.size,
              staged.fingerprint.mtimeNs, staged.fingerprint.fileId, thresholdBytes,
              staged.stagingRelativePath, jsonEncode({'source': 'sync', 'target_id': sourceTargetId})],
          );
        } else {
          tx.execute(
            "UPDATE blob_objects SET state='staged',staging_path=?,byte_size=?,relative_path=? WHERE sha256=?",
            [staged.stagingRelativePath, expectedBytes, relativePath, expectedSha256],
          );
        }
        tx.execute(
          'INSERT INTO pending_sync_blobs(sha256,staging_relative_path,byte_size,created_at_utc,source_target_id) '
          'VALUES(?,?,?,?,?) '
          'ON CONFLICT(sha256) DO UPDATE SET staging_relative_path=excluded.staging_relative_path,'
          'byte_size=excluded.byte_size,created_at_utc=excluded.created_at_utc,'
          'source_target_id=excluded.source_target_id',
          [expectedSha256, staged.stagingRelativePath, expectedBytes, now.toIso8601String(), sourceTargetId],
        );
        return null;
      });

      final published = await _store.publish(staged);
      _vault.database.transaction((tx) {
        tx.execute(
          "UPDATE blob_objects SET state='committed',relative_path=?,byte_size=?,staging_path=NULL,"
          'last_full_verified_at=?,last_known_size=?,last_known_mtime_ns=?,last_file_id=? WHERE sha256=?',
          [published.relativePath, published.byteSize, now.toIso8601String(), published.fingerprint.size,
            published.fingerprint.mtimeNs, published.fingerprint.fileId, expectedSha256],
        );
        tx.execute('DELETE FROM pending_sync_blobs WHERE sha256=?', [expectedSha256]);
        tx.execute(
          'INSERT INTO sync_received_blobs(sha256,source_target_id,received_at_utc,state) VALUES(?,?,?,?) '
          'ON CONFLICT(sha256) DO UPDATE SET source_target_id=excluded.source_target_id,'
          'received_at_utc=excluded.received_at_utc,state=\'available\'',
          [expectedSha256, sourceTargetId, now.toIso8601String(), 'available'],
        );
        return null;
      });
    });
  }

  /// Releases the sync cache guard after a domain/event materializer has made
  /// the received Blob reachable through an Asset or has discarded it.
  void releaseSynchronizedBlob(String sha256) {
    _vault.database.execute(
      "UPDATE sync_received_blobs SET state='released' WHERE sha256=? AND state='available'",
      <Object?>[sha256],
    );
  }

  /// Rehashes an already local CAS object before a received event is allowed to
  /// attach a new Asset or scientific record to it. This protects projection
  /// from trusting stale filesystem metadata or an earlier verification.
  Future<void> verifyBlobForRemoteProjection({
    required String blobSha256,
    required int expectedBytes,
  }) async {
    await initialize();
    final row = _blobRow(blobSha256);
    if (row == null || _string(row['state']) != 'committed' ||
        _int(row['byte_size']) != expectedBytes) {
      throw AssetMissingException('blob:$blobSha256');
    }
    final leaseId = newUuidV7();
    _acquireLease(leaseId, blobSha256, 'remote-event-projection');
    AssetSnapshotFile? snapshot;
    try {
      try {
        snapshot = await _store.materializeReadSnapshot(
          sha256Digest: blobSha256,
          expectedBytes: expectedBytes,
          expectedMtimeNs: _int(row['last_known_mtime_ns']),
          verifySha256: true,
        );
      } on AssetStoreMetadataMismatchException {
        // Metadata drift is not a cryptographic failure. Retry against the
        // current immutable snapshot and decide from its full content hash.
        snapshot = await _store.materializeReadSnapshot(
          sha256Digest: blobSha256,
          expectedBytes: expectedBytes,
          expectedMtimeNs: null,
          verifySha256: true,
        );
      }
      if (snapshot.actualSha256 != blobSha256 || snapshot.byteSize != expectedBytes) {
        _vault.database.execute("UPDATE blob_objects SET state='mismatch' WHERE sha256=?", [blobSha256]);
        _writeIntegrityCheck(
          blobSha256,
          IntegrityCheckMode.fullSha256,
          AssetIntegrityStatus.mismatch,
          snapshot.byteSize,
          <String, Object?>{
            'during': 'remote_event_projection',
            'expected_sha256': blobSha256,
            'actual_sha256': snapshot.actualSha256,
          },
        );
        throw AssetIntegrityException(
          assetId: 'blob:$blobSha256',
          expectedSha256: blobSha256,
          actualSha256: snapshot.actualSha256 ?? 'unavailable',
        );
      }
      _vault.database.execute(
        'UPDATE blob_objects SET last_full_verified_at=?,last_known_size=?,last_known_mtime_ns=? WHERE sha256=?',
        [DateTime.now().toUtc().toIso8601String(), snapshot.fingerprint.size,
          snapshot.fingerprint.mtimeNs, blobSha256],
      );
      _writeIntegrityCheck(
        blobSha256,
        IntegrityCheckMode.fullSha256,
        AssetIntegrityStatus.verified,
        expectedBytes,
        <String, Object?>{'during': 'remote_event_projection'},
      );
    } on AssetStoreMetadataMismatchException catch (error) {
      _vault.database.execute("UPDATE blob_objects SET state='mismatch' WHERE sha256=?", [blobSha256]);
      _writeIntegrityCheck(
        blobSha256,
        IntegrityCheckMode.fullSha256,
        AssetIntegrityStatus.mismatch,
        expectedBytes,
        <String, Object?>{
          'during': 'remote_event_projection',
          'message': error.message,
          'expected_sha256': blobSha256,
          'actual_sha256': null,
        },
      );
      throw AssetIntegrityException(
        assetId: 'blob:$blobSha256',
        expectedSha256: blobSha256,
        actualSha256: 'unavailable (snapshot changed during verification)',
      );
    } on FileSystemException {
      _markBlobMissing(blobSha256, 'CAS object is missing before remote event projection.');
      throw AssetMissingException('blob:$blobSha256');
    } finally {
      await snapshot?.dispose();
      _releaseLease(leaseId);
    }
  }

  /// Drops temporary sync retention only when every event that references a
  /// received Blob has been applied and an Asset now owns the reference.
  void releaseMaterializedSynchronizedBlobs() {
    _vault.database.execute('''
      UPDATE sync_received_blobs
      SET state='released'
      WHERE state='available'
        AND EXISTS(SELECT 1 FROM assets a WHERE a.blob_sha256=sync_received_blobs.sha256)
        AND NOT EXISTS(
          SELECT 1 FROM sync_remote_events e,json_each(e.asset_sha_refs_json) r
          WHERE r.value=sync_received_blobs.sha256
            AND e.application_state IN('received','conflicted','blocked')
        )
    ''');
  }

  Future<void> _recoverInterruptedSynchronizedBlobs() async {
    final pending = _vault.database.query(
      'SELECT p.sha256,p.staging_relative_path,p.byte_size,p.source_target_id '
      'FROM pending_sync_blobs p ORDER BY p.created_at_utc',
    );
    for (final row in pending) {
      final sha = _string(row['sha256']);
      final expectedBytes = _int(row['byte_size']) ?? -1;
      if (expectedBytes < 0) throw StateError('Pending synchronized Blob has an invalid byte size.');
      final relative = _string(row['staging_relative_path']);
      final stagedFile = File(p.join(_store.rootDirectory.path, relative));
      final destination = _store.blobFile(sha);
      try {
        if (await destination.exists()) {
          if (await destination.length() != expectedBytes || await _store.fullHash(sha) != sha) {
            throw AssetStoreCollisionException(sha);
          }
        } else {
          if (!await stagedFile.exists() || await stagedFile.length() != expectedBytes ||
              (await sha256.bind(stagedFile.openRead()).first).toString() != sha) {
            throw AssetMissingException(sha);
          }
          final stat = await stagedFile.stat();
          final staged = StagedAssetBlob(
            importId: p.basenameWithoutExtension(relative),
            blobSha256: sha,
            byteSize: expectedBytes,
            stagingRelativePath: relative,
            fingerprint: AssetFileFingerprint.fromStat(stat),
          );
          await _store.publish(staged);
        }
        final fingerprint = await _store.fingerprint(sha);
        final now = DateTime.now().toUtc();
        final sourceTargetId = _string(row['source_target_id']);
        _vault.database.transaction((tx) {
          tx.execute(
            "UPDATE blob_objects SET state='committed',relative_path=?,staging_path=NULL,last_full_verified_at=?,"
            'last_known_size=?,last_known_mtime_ns=?,last_file_id=? WHERE sha256=?',
            [_store.objectRelativePath(sha), now.toIso8601String(), fingerprint.size, fingerprint.mtimeNs,
              fingerprint.fileId, sha],
          );
          tx.execute('DELETE FROM pending_sync_blobs WHERE sha256=?', [sha]);
          tx.execute(
            'INSERT INTO sync_received_blobs(sha256,source_target_id,received_at_utc,state) VALUES(?,?,?,?) '
            'ON CONFLICT(sha256) DO UPDATE SET source_target_id=excluded.source_target_id,'
            "received_at_utc=excluded.received_at_utc,state='available'",
            [sha, sourceTargetId, now.toIso8601String(), 'available'],
          );
          return null;
        });
      } catch (error) {
        _vault.database.transaction((tx) {
          final state = error is AssetMissingException ? 'missing' : 'mismatch';
          tx.execute('UPDATE blob_objects SET state=? WHERE sha256=? AND state=\'staged\'', [state, sha]);
          tx.execute('DELETE FROM pending_sync_blobs WHERE sha256=?', [sha]);
          return null;
        });
        if (await stagedFile.exists()) await stagedFile.delete();
      }
    }
  }

  void _retainReceivedBlob(String sha, String targetId, DateTime now) {
    _vault.database.execute(
      'INSERT INTO sync_received_blobs(sha256,source_target_id,received_at_utc,state) VALUES(?,?,?,?) '
      'ON CONFLICT(sha256) DO UPDATE SET source_target_id=excluded.source_target_id,'
      'received_at_utc=excluded.received_at_utc,state=\'available\'',
      <Object?>[sha, targetId, now.toIso8601String(), 'available'],
    );
  }

  Future<ExplorerPage> list(ExplorerQuery query) async {
    await initialize();
    final pageSize = query.pageSize.clamp(1, 500).toInt();
    final offset = query.pageOffset < 0 ? 0 : query.pageOffset;
    final clauses = <String>[];
    final bindings = <Object?>[];

    switch (query.folder) {
      case VirtualFolderKind.trash:
        clauses.add('a.deleted_at_utc IS NOT NULL');
        break;
      case VirtualFolderKind.raw:
        clauses.add("a.deleted_at_utc IS NULL AND a.kind = 'raw'");
        break;
      case VirtualFolderKind.derived:
        clauses.add("a.deleted_at_utc IS NULL AND a.kind IN ('derived','thumbnail')");
        break;
      case VirtualFolderKind.reports:
        clauses.add("a.deleted_at_utc IS NULL AND a.kind = 'report'");
        break;
      case VirtualFolderKind.orphans:
        clauses.add('a.deleted_at_utc IS NULL AND NOT EXISTS '
            '(SELECT 1 FROM asset_links l WHERE l.asset_id=a.asset_id AND l.removed_at_utc IS NULL)');
        break;
      case VirtualFolderKind.localOnly:
        clauses.add('a.deleted_at_utc IS NULL AND b.state = \'committed\' AND NOT EXISTS '
            '(SELECT 1 FROM remote_replicas r WHERE r.blob_sha256=b.sha256 '
            "AND r.state IN ('verified','remote_available','uploaded'))");
        break;
      case VirtualFolderKind.remoteOnly:
        clauses.add("a.deleted_at_utc IS NULL AND b.state IN ('missing','purged') AND EXISTS "
            '(SELECT 1 FROM remote_replicas r WHERE r.blob_sha256=b.sha256 '
            "AND r.state IN ('verified','remote_available','uploaded'))");
        break;
      case VirtualFolderKind.integrityWarnings:
        clauses.add("a.deleted_at_utc IS NULL AND b.state IN ('missing','mismatch','staged')");
        break;
      case VirtualFolderKind.custom:
        if (query.customFolderId == null) {
          throw ArgumentError('customFolderId is required for a custom virtual folder.');
        }
        clauses.add('a.deleted_at_utc IS NULL AND EXISTS '
            '(SELECT 1 FROM asset_folder_memberships m WHERE m.asset_id=a.asset_id AND m.folder_id=?)');
        bindings.add(query.customFolderId);
        break;
      case VirtualFolderKind.all:
      case VirtualFolderKind.recent:
        clauses.add('a.deleted_at_utc IS NULL');
        break;
    }
    if (query.kind != null) {
      clauses.add('a.kind = ?');
      bindings.add(query.kind!.wireValue);
    }
    final searchText = query.searchText?.trim();
    if (searchText != null && searchText.isNotEmpty) {
      clauses.add('lower(a.display_name) LIKE ?');
      bindings.add('%${searchText.toLowerCase()}%');
    }
    if (query.minimumBytes != null) {
      clauses.add('b.byte_size >= ?');
      bindings.add(query.minimumBytes);
    }
    if (query.maximumBytes != null) {
      clauses.add('b.byte_size <= ?');
      bindings.add(query.maximumBytes);
    }
    if (query.largeOnly) {
      clauses.add('b.byte_size > ?');
      bindings.add(await _integrityThresholdBytes());
    }
    if (query.createdAfterUtc != null) {
      clauses.add('a.created_at_utc >= ?');
      bindings.add(query.createdAfterUtc!.toUtc().toIso8601String());
    }
    if (query.createdBeforeUtc != null) {
      clauses.add('a.created_at_utc <= ?');
      bindings.add(query.createdBeforeUtc!.toUtc().toIso8601String());
    }
    if (query.targetType != null && query.targetId != null) {
      clauses.add('EXISTS (SELECT 1 FROM asset_links l WHERE l.asset_id=a.asset_id '
          'AND l.entity_type=? AND l.entity_id=? AND l.removed_at_utc IS NULL)');
      bindings
        ..add(query.targetType)
        ..add(query.targetId);
    }
    final whereSql = clauses.isEmpty ? '' : 'WHERE ${clauses.join(' AND ')}';
    final order = query.folder == VirtualFolderKind.recent
        ? "COALESCE(json_extract(a.metadata_json, '\$.last_opened_at_utc'), a.created_at_utc) DESC"
        : 'a.created_at_utc DESC, a.asset_id';
    final countRows = _vault.database.query(
      '''SELECT COUNT(*) AS total_count FROM assets a
         JOIN blob_objects b ON b.sha256=a.blob_sha256 $whereSql''',
      bindings,
    );
    final totalCount = _int(countRows.firstOrNull?['total_count']) ?? 0;
    final rows = _vault.database.query(
      '''SELECT a.asset_id,a.blob_sha256,a.display_name,a.media_type,a.kind,
                a.parent_asset_id,a.created_at_utc,a.deleted_at_utc,a.metadata_json,
                b.byte_size,b.state AS blob_state,b.last_full_verified_at,
                b.last_fast_checked_at,b.last_known_size,b.last_known_mtime_ns,
                b.last_file_id,b.threshold_at_import
         FROM assets a JOIN blob_objects b ON b.sha256=a.blob_sha256
         $whereSql ORDER BY $order LIMIT ? OFFSET ?''',
      <Object?>[...bindings, pageSize, offset],
    );
    final threshold = await _integrityThresholdBytes();
    final items = <ExplorerAsset>[];
    for (final row in rows) {
      final assetId = _string(row['asset_id']);
      final sha = _string(row['blob_sha256']);
      final links = _vault.database.query(
        '''SELECT entity_type,entity_id,relation FROM asset_links
           WHERE asset_id=? AND removed_at_utc IS NULL ORDER BY created_at_utc''',
        <Object?>[assetId],
      );
      final replicas = _vault.database.query(
        'SELECT target_id,state FROM remote_replicas WHERE blob_sha256=? ORDER BY target_id',
        <Object?>[sha],
      );
      final backup = _vault.database.query(
        '''SELECT COUNT(*) AS retained_count FROM backup_snapshot_objects o
           JOIN backup_snapshots s ON s.backup_id=o.backup_id
           WHERE o.content_sha256=? AND s.state IN ('complete','verified')''',
        <Object?>[sha],
      );
      items.add(ExplorerAsset(
        asset: _assetFromRow(row, thresholdBytes: threshold),
        activeLinkCount: links.length,
        referenceLabels: links
            .map((link) => '${_string(link['entity_type'])}:${_string(link['entity_id'])}/${_string(link['relation'])}')
            .toList(growable: false),
        remoteReplicaStates: <String, String>{
          for (final replica in replicas) _string(replica['target_id']): _string(replica['state']),
        },
        retainedBackupCount: _int(backup.firstOrNull?['retained_count']) ?? 0,
      ));
    }
    return ExplorerPage(
      items: items,
      totalCount: totalCount,
      pageSize: pageSize,
      pageOffset: offset,
    );
  }

  Future<AssetRecord> resolve(AssetId assetId) async {
    await initialize();
    final row = _assetRow(assetId);
    if (row == null) throw AssetMissingException(assetId);
    return _assetFromRow(row, thresholdBytes: await _integrityThresholdBytes());
  }

  Future<AssetOpenHandle> open(
    AssetId assetId, {
    bool requireFullSha256 = false,
    bool includeTrashed = false,
  }) async {
    await initialize();
    final asset = await resolve(assetId);
    if (asset.isDeleted && !includeTrashed) {
      throw StateError('Asset is in the trash; restore it before opening.');
    }
    final blob = _blobRow(asset.blobSha256);
    if (blob == null) throw AssetMissingException(assetId);
    final blobState = _string(blob['state']);
    if (blobState == 'missing' || blobState == 'purged') throw AssetMissingException(assetId);
    if (blobState == 'mismatch') {
      throw AssetIntegrityException(
        assetId: assetId,
        expectedSha256: asset.blobSha256,
        actualSha256: 'unavailable',
      );
    }
    final fullHash = requireFullSha256 ||
        fullVerifyLargeFilesOnEveryOpen ||
        asset.byteSize <= asset.integrityThresholdBytes;
    final leaseId = newUuidV7();
    _acquireLease(leaseId, asset.blobSha256, 'asset-open');
    AssetSnapshotFile? snapshot;
    var leaseTransferredToHandle = false;
    try {
      snapshot = await _store.materializeReadSnapshot(
        sha256Digest: asset.blobSha256,
        expectedBytes: asset.byteSize,
        expectedMtimeNs: _int(blob['last_known_mtime_ns']),
        verifySha256: fullHash,
      );
      if (fullHash && snapshot.actualSha256 != asset.blobSha256) {
        final actualSha256 = snapshot.actualSha256;
        await snapshot.dispose();
        snapshot = null;
        await _recordIntegrityResult(
          assetId: assetId,
          blobSha256: asset.blobSha256,
          mode: IntegrityCheckMode.fullSha256,
          status: AssetIntegrityStatus.mismatch,
          expectedSha256: asset.blobSha256,
          actualSha256: actualSha256,
          bytesChecked: asset.byteSize,
          message: 'SHA-256 mismatch during logical open.',
        );
        throw AssetIntegrityException(
          assetId: assetId,
          expectedSha256: asset.blobSha256,
          actualSha256: actualSha256 ?? 'unavailable',
        );
      }
      final now = DateTime.now().toUtc();
      if (fullHash) {
        _vault.database.execute(
          '''UPDATE blob_objects SET state='committed',last_full_verified_at=?,
                 last_known_size=?,last_known_mtime_ns=? WHERE sha256=?''',
          <Object?>[
            now.toIso8601String(),
            snapshot.fingerprint.size,
            snapshot.fingerprint.mtimeNs,
            asset.blobSha256,
          ],
        );
        _writeIntegrityCheck(
          asset.blobSha256,
          IntegrityCheckMode.fullSha256,
          AssetIntegrityStatus.verified,
          asset.byteSize,
          <String, Object?>{'during': 'logical_open'},
        );
      } else {
        _vault.database.execute(
          '''UPDATE blob_objects SET last_fast_checked_at=?,last_known_size=?,
                 last_known_mtime_ns=? WHERE sha256=?''',
          <Object?>[
            now.toIso8601String(),
            snapshot.fingerprint.size,
            snapshot.fingerprint.mtimeNs,
            asset.blobSha256,
          ],
        );
        _writeIntegrityCheck(
          asset.blobSha256,
          IntegrityCheckMode.metadataQuick,
          AssetIntegrityStatus.quickChecked,
          asset.byteSize,
          <String, Object?>{
            'during': 'logical_open',
            'message': 'Metadata quick check passed; this is not SHA-256 verification.',
          },
        );
      }
      await _recordOpenedAt(assetId, now);
      final readSnapshot = snapshot;
      snapshot = null;
      leaseTransferredToHandle = true;
      return AssetOpenHandle(
        asset: asset,
        validationLevel: fullHash
            ? AssetValidationLevel.verified
            : AssetValidationLevel.quickChecked,
        openRead: readSnapshot.openRead,
        close: () async {
          try {
            await readSnapshot.dispose();
          } finally {
            _releaseLease(leaseId);
          }
        },
      );
    } on AssetIntegrityException {
      rethrow;
    } on AssetStoreMetadataMismatchException catch (error) {
      await _recordIntegrityResult(
        assetId: assetId,
        blobSha256: asset.blobSha256,
        mode: IntegrityCheckMode.metadataQuick,
        status: AssetIntegrityStatus.mismatch,
        expectedSha256: asset.blobSha256,
        actualSha256: null,
        bytesChecked: 0,
        message: error.message,
      );
      throw StateError('Stored object changed; opening is blocked. ${error.message}');
    } on FileSystemException {
      _markBlobMissing(asset.blobSha256, 'CAS object disappeared during open.');
      throw AssetMissingException(assetId);
    } finally {
      await snapshot?.dispose();
      if (!leaseTransferredToHandle) _releaseLease(leaseId);
    }
  }

  /// Opens a read snapshot only after hashing the exact bytes returned by
  /// [AssetOpenHandle.openRead], regardless of the configured large-file
  /// threshold. Use for quantitative image analysis and other strict reads.
  Future<AssetOpenHandle> openVerified(AssetId assetId) =>
      open(assetId, requireFullSha256: true);

  /// Strictly verifies a snapshot asset, including one in the trash, for
  /// backup capture. This never exposes the CAS path and still holds a lease
  /// until its returned handle is closed.
  Future<AssetOpenHandle> openForBackup(AssetId assetId) =>
      open(assetId, requireFullSha256: true, includeTrashed: true);

  /// Copies an exact, fully hashed CAS snapshot to a backup-owned destination.
  /// This also includes synchronized blobs that have not yet been materialized
  /// into a local Asset record.
  Future<({int byteSize, String sha256})> writeVerifiedBlobSnapshot({
    required String blobSha256,
    required String destinationPath,
  }) async {
    await initialize();
    final row = _blobRow(blobSha256);
    if (row == null || _string(row['state']) != 'committed') {
      throw AssetMissingException(blobSha256);
    }
    final leaseId = newUuidV7();
    _acquireLease(leaseId, blobSha256, 'backup-snapshot');
    AssetSnapshotFile? snapshot;
    final destination = File(destinationPath);
    try {
      snapshot = await _store.materializeReadSnapshot(
        sha256Digest: blobSha256,
        expectedBytes: _int(row['byte_size']),
        expectedMtimeNs: _int(row['last_known_mtime_ns']),
        verifySha256: true,
      );
      if (snapshot.actualSha256 != blobSha256) {
        throw AssetIntegrityException(
          assetId: 'blob:$blobSha256',
          expectedSha256: blobSha256,
          actualSha256: snapshot.actualSha256 ?? '',
        );
      }
      await destination.parent.create(recursive: true);
      await destination.create(exclusive: true);
      final sink = destination.openWrite(mode: FileMode.writeOnly);
      try {
        await snapshot.openRead().pipe(sink);
      } on Object {
        await sink.close();
        if (await destination.exists()) await destination.delete();
        rethrow;
      }
      if (await destination.length() != snapshot.byteSize) {
        await destination.delete();
        throw StateError('Backup snapshot copy has an unexpected byte size.');
      }
      return (byteSize: snapshot.byteSize, sha256: snapshot.actualSha256!);
    } finally {
      await snapshot?.dispose();
      _releaseLease(leaseId);
    }
  }

  Future<IntegrityResult> fullVerify(AssetId assetId) async {
    await initialize();
    final asset = await resolve(assetId);
    final leaseId = newUuidV7();
    _acquireLease(leaseId, asset.blobSha256, 'asset-full-verify');
    try {
      return await _fullVerifySnapshot(asset);
    } finally {
      _releaseLease(leaseId);
    }
  }

  Future<IntegrityResult> _fullVerifySnapshot(AssetRecord asset) async {
    final assetId = asset.assetId;
    final now = DateTime.now().toUtc();
    AssetSnapshotFile? snapshot;
    try {
      snapshot = await _store.materializeReadSnapshot(
        sha256Digest: asset.blobSha256,
        expectedBytes: null,
        expectedMtimeNs: null,
        verifySha256: true,
      );
    } on FileSystemException {
      _markBlobMissing(asset.blobSha256, 'CAS object is missing during full verification.');
      final result = IntegrityResult(
        assetId: assetId,
        blobSha256: asset.blobSha256,
        mode: IntegrityCheckMode.fullSha256,
        status: AssetIntegrityStatus.missing,
        checkedAtUtc: now,
        bytesChecked: 0,
        message: 'The local CAS object is missing.',
      );
      _writeIntegrityCheck(
        asset.blobSha256,
        IntegrityCheckMode.fullSha256,
        AssetIntegrityStatus.missing,
        0,
        <String, Object?>{'message': result.message},
      );
      return result;
    } on AssetStoreMetadataMismatchException catch (error) {
      const message = 'The CAS object changed while the full SHA-256 check was running.';
      await _recordIntegrityResult(
        assetId: assetId,
        blobSha256: asset.blobSha256,
        mode: IntegrityCheckMode.fullSha256,
        status: AssetIntegrityStatus.mismatch,
        expectedSha256: asset.blobSha256,
        actualSha256: null,
        bytesChecked: 0,
        message: '$message ${error.message}',
      );
      return IntegrityResult(
        assetId: assetId,
        blobSha256: asset.blobSha256,
        mode: IntegrityCheckMode.fullSha256,
        status: AssetIntegrityStatus.mismatch,
        checkedAtUtc: now,
        bytesChecked: 0,
        message: '$message ${error.message}',
      );
    } finally {
      await snapshot?.dispose();
    }
    final verifiedSnapshot = snapshot;
    final actual = verifiedSnapshot.actualSha256;
    final passed = verifiedSnapshot.byteSize == asset.byteSize && actual == asset.blobSha256;
    final status = passed ? AssetIntegrityStatus.verified : AssetIntegrityStatus.mismatch;
    await _recordIntegrityResult(
      assetId: assetId,
      blobSha256: asset.blobSha256,
      mode: IntegrityCheckMode.fullSha256,
      status: status,
      expectedSha256: asset.blobSha256,
      actualSha256: actual,
      bytesChecked: verifiedSnapshot.byteSize,
      message: passed
          ? 'Full SHA-256 verification passed.'
          : 'SHA-256 or file-size mismatch; the original digest was preserved.',
      fingerprint: verifiedSnapshot.fingerprint,
    );
    return IntegrityResult(
      assetId: assetId,
      blobSha256: asset.blobSha256,
      mode: IntegrityCheckMode.fullSha256,
      status: status,
      checkedAtUtc: now,
      bytesChecked: verifiedSnapshot.byteSize,
      actualSha256: actual,
      message: passed
          ? 'Full SHA-256 verification passed.'
          : 'SHA-256 or file-size mismatch; the original digest was preserved.',
    );
  }

  Future<DeletionImpact> previewDelete(AssetId assetId) async {
    await initialize();
    final asset = await resolve(assetId);
    final links = _vault.database.query(
      '''SELECT entity_type,entity_id,relation FROM asset_links
         WHERE asset_id=? AND removed_at_utc IS NULL ORDER BY entity_type,entity_id''',
      <Object?>[assetId],
    );
    final activeAssets = _vault.database.query(
      '''SELECT asset_id FROM assets WHERE blob_sha256=? AND asset_id<>?
         AND deleted_at_utc IS NULL ORDER BY asset_id''',
      <Object?>[asset.blobSha256, assetId],
    );
    final trashAssets = _vault.database.query(
      '''SELECT asset_id,deleted_at_utc FROM assets WHERE blob_sha256=? AND asset_id<>?
         AND deleted_at_utc IS NOT NULL ORDER BY asset_id''',
      <Object?>[asset.blobSha256, assetId],
    );
    final backupRows = _vault.database.query(
      '''SELECT COUNT(*) AS retained_count FROM backup_snapshot_objects o
         JOIN backup_snapshots s ON s.backup_id=o.backup_id
         WHERE o.content_sha256=? AND s.state IN ('complete','verified')''',
      <Object?>[asset.blobSha256],
    );
    final replicas = _vault.database.query(
      'SELECT target_id,state FROM remote_replicas WHERE blob_sha256=? ORDER BY target_id',
      <Object?>[asset.blobSha256],
    );
    final leases = _vault.database.query(
      'SELECT COUNT(*) AS lease_count FROM asset_blob_leases WHERE blob_sha256=? AND expires_at_utc>?',
      <Object?>[asset.blobSha256, DateTime.now().toUtc().toIso8601String()],
    );
    final tombstones = _vault.database.query(
      '''SELECT COUNT(*) AS pending_count FROM asset_sync_tombstone_acks t
         JOIN assets a ON a.asset_id=t.asset_id
         WHERE a.blob_sha256=? AND t.state<>'acknowledged' ''',
      <Object?>[asset.blobSha256],
    );
    final trashWithinRetention = trashAssets.where((row) {
      final deleted = _dateTime(row['deleted_at_utc']);
      return deleted != null && DateTime.now().toUtc().difference(deleted) < trashRetention;
    }).toList(growable: false);
    final leaseCount = _int(leases.firstOrNull?['lease_count']) ?? 0;
    final pendingTombstones = (_int(tombstones.firstOrNull?['pending_count']) ?? 0) > 0;
    // References require an explicit risk confirmation, but they do not mean
    // the immutable bytes are shared. They remain visible as historical links
    // to the tombstoned Asset. Only other live/trash Assets, leases, and
    // unacknowledged remote tombstones protect the CAS object itself.
    final eligible = activeAssets.isEmpty &&
        trashWithinRetention.isEmpty &&
        leaseCount == 0 &&
        !pendingTombstones;
    return DeletionImpact(
      assetId: assetId,
      blobSha256: asset.blobSha256,
      logicalBytes: asset.byteSize,
      reclaimablePhysicalBytes: eligible ? asset.byteSize : 0,
      activeLinks: links
          .map((row) => AssetReferenceImpact(
                targetType: _string(row['entity_type']),
                targetId: _string(row['entity_id']),
                role: _string(row['relation']),
              ))
          .toList(growable: false),
      otherActiveAssetsSharingBlob: activeAssets.map((row) => _string(row['asset_id'])).toList(growable: false),
      trashAssetsSharingBlob: trashAssets.map((row) => _string(row['asset_id'])).toList(growable: false),
      retainedBackupCount: _int(backupRows.firstOrNull?['retained_count']) ?? 0,
      remoteReplicaStates: <String, String>{
        for (final row in replicas) _string(row['target_id']): _string(row['state']),
      },
      activeLeaseCount: leaseCount,
      pendingSyncTombstones: pendingTombstones,
      purgeEligibleNow: eligible,
    );
  }

  /// Lists remote trash requests awaiting a local decision and immutable purge
  /// audit records. Source approval references are provenance only.
  Future<List<RemoteAssetDeletionReview>> listPendingRemoteDeletions({
    int limit = 100,
  }) async {
    await initialize();
    if (limit < 1 || limit > 1000) {
      throw ArgumentError.value(limit, 'limit', 'Must be between 1 and 1000.');
    }
    final rows = _vault.database.query(
      '''SELECT r.source_event_id,r.target_id,r.asset_id,r.blob_sha256,
                r.source_deletion_id,r.requested_scope,r.source_approval_ref,r.reason,
                r.requested_at_utc,r.status,r.local_deletion_id,r.local_approval_ref,
                r.reviewed_at_utc,r.dismissed_at_utc,r.resolution_note,e.device_id,e.sequence
         FROM remote_asset_deletion_reviews r
         JOIN sync_remote_events e ON e.event_id=r.source_event_id
         WHERE r.status='pending' OR (r.status='audit_only' AND r.dismissed_at_utc IS NULL)
         ORDER BY r.requested_at_utc DESC,r.source_event_id LIMIT ?''',
      <Object?>[limit],
    );
    return List<RemoteAssetDeletionReview>.unmodifiable(
      rows.map(_remoteDeletionReviewFromRow),
    );
  }

  Future<DeletionImpact> previewRemoteDeletion(String sourceEventId) async {
    await initialize();
    final review = _remoteDeletionReview(sourceEventId);
    if (!review.canAccept) {
      throw StateError('REMOTE_ASSET_DELETE_NOT_REVIEWABLE: only a pending trash request can be accepted.');
    }
    return previewDelete(review.assetId);
  }

  /// Accepts a remote trash request with a fresh receipt issued on this device.
  /// The source event remains immutable and its receipt is never consulted.
  Future<DeletionId> acceptRemoteDeletion(
    String sourceEventId, {
    required String approvalRef,
    String? commandId,
  }) async {
    await initialize();
    final review = _remoteDeletionReview(sourceEventId);
    if (review.status == RemoteAssetDeletionReviewStatus.accepted &&
        review.localDeletionId != null) {
      return review.localDeletionId!;
    }
    if (!review.canAccept) {
      throw StateError('REMOTE_ASSET_DELETE_NOT_REVIEWABLE: only a pending trash request can be accepted.');
    }
    return trash(AssetTrashRequest(
      assetId: review.assetId,
      approvalRef: approvalRef,
      reason: 'Accepted remote deletion ${review.sourceDeletionId}: ${review.reason}',
      commandId: commandId,
      sourceEventId: sourceEventId,
    ));
  }

  /// Keeps the local Asset and records a local rejection for a pending remote
  /// trash request. This does not reuse or issue an approval receipt.
  Future<void> rejectRemoteDeletion(
    String sourceEventId, {
    required String note,
  }) async {
    await initialize();
    final cleanNote = note.trim();
    if (cleanNote.isEmpty || cleanNote.length > 2000) {
      throw ArgumentError.value(note, 'note', 'A review note of 1 to 2000 characters is required.');
    }
    final now = DateTime.now().toUtc();
    _vault.database.transaction((tx) {
      final rows = tx.query(
        '''SELECT asset_id,requested_scope,status FROM remote_asset_deletion_reviews
           WHERE source_event_id=?''',
        <Object?>[sourceEventId],
      );
      if (rows.isEmpty || rows.single['requested_scope'] != 'trash' || rows.single['status'] != 'pending') {
        throw StateError('REMOTE_ASSET_DELETE_NOT_REVIEWABLE: request is missing or already resolved.');
      }
      tx.execute(
        '''UPDATE remote_asset_deletion_reviews
           SET status='rejected',reviewed_at_utc=?,resolution_note=?
           WHERE source_event_id=? AND status='pending' ''',
        <Object?>[now.toIso8601String(), cleanNote, sourceEventId],
      );
    });
  }

  /// Marks a remote purge audit item as seen. It never deletes local data.
  Future<void> dismissRemoteDeletionReview(
    String sourceEventId, {
    required String note,
  }) async {
    await initialize();
    final cleanNote = note.trim();
    if (cleanNote.isEmpty || cleanNote.length > 2000) {
      throw ArgumentError.value(note, 'note', 'A review note of 1 to 2000 characters is required.');
    }
    final now = DateTime.now().toUtc();
    _vault.database.transaction((tx) {
      final rows = tx.query(
        '''SELECT requested_scope,status FROM remote_asset_deletion_reviews
           WHERE source_event_id=?''',
        <Object?>[sourceEventId],
      );
      if (rows.isEmpty || rows.single['requested_scope'] != 'purge' || rows.single['status'] != 'audit_only') {
        throw StateError('REMOTE_ASSET_DELETE_NOT_AUDIT: item is missing or is not a purge audit.');
      }
      tx.execute(
        '''UPDATE remote_asset_deletion_reviews
           SET dismissed_at_utc=?,resolution_note=?
           WHERE source_event_id=? AND status='audit_only' ''',
        <Object?>[now.toIso8601String(), cleanNote, sourceEventId],
      );
    });
  }

  RemoteAssetDeletionReview _remoteDeletionReview(String sourceEventId) {
    final rows = _vault.database.query(
      '''SELECT r.source_event_id,r.target_id,r.asset_id,r.blob_sha256,
                r.source_deletion_id,r.requested_scope,r.source_approval_ref,r.reason,
                r.requested_at_utc,r.status,r.local_deletion_id,r.local_approval_ref,
                r.reviewed_at_utc,r.dismissed_at_utc,r.resolution_note,e.device_id,e.sequence
         FROM remote_asset_deletion_reviews r
         JOIN sync_remote_events e ON e.event_id=r.source_event_id
         WHERE r.source_event_id=?''',
      <Object?>[sourceEventId],
    );
    if (rows.isEmpty) throw StateError('REMOTE_ASSET_DELETE_REVIEW_MISSING: $sourceEventId');
    return _remoteDeletionReviewFromRow(rows.single);
  }

  Future<DeletionId> trash(AssetTrashRequest request) async {
    await initialize();
    _requireApproval(request.approvalRef);
    final commandId = request.commandId ?? newUuidV7();
    final priorDeletion = _deletionForCommand(
      commandId,
      assetId: request.assetId,
      scope: 'trash',
    );
    if (priorDeletion != null) return priorDeletion;
    final asset = await resolve(request.assetId);
    if (asset.isDeleted) throw StateError('Asset is already in the trash.');
    final impact = await previewDelete(request.assetId);
    final now = DateTime.now().toUtc();
    final deletionId = newUuidV7();
    final purgeAfter = now.add(trashRetention);
    final impactJson = _impactJson(impact);
    _vault.database.transaction((tx) {
      tx.requireApproval(
        approvalRef: ApprovalRef(request.approvalRef),
        action: 'asset.trash',
        subjectType: 'asset',
        subjectId: request.assetId,
        atUtc: now,
        requiredScope: <String, Object?>{
          'blob_sha256': asset.blobSha256,
          'purge': false,
          'impact_reviewed': true,
        },
      );
      final assetUpdated = tx.execute(
        'UPDATE assets SET deleted_at_utc=? WHERE asset_id=? AND deleted_at_utc IS NULL',
        <Object?>[now.toIso8601String(), request.assetId],
      );
      if (assetUpdated != 1) throw StateError('Asset changed before the trash command committed.');
      String? sourceTargetId;
      if (request.sourceEventId != null) {
        final reviews = tx.query(
          '''SELECT target_id,asset_id,requested_scope,status FROM remote_asset_deletion_reviews
             WHERE source_event_id=?''',
          <Object?>[request.sourceEventId],
        );
        if (reviews.isEmpty || reviews.single['asset_id'] != request.assetId ||
            reviews.single['requested_scope'] != 'trash' || reviews.single['status'] != 'pending') {
          throw StateError('REMOTE_ASSET_DELETE_NOT_REVIEWABLE: request is missing or already resolved.');
        }
        sourceTargetId = _string(reviews.single['target_id']);
      }
      tx.execute(
        '''INSERT INTO deletion_records
           (deletion_id,asset_id,scope,impact_json,state,created_at_utc,purge_eligible_at_utc,reason,approval_ref,confirmed_at_utc,command_id)
           VALUES (?,?, 'trash', ?, 'trashed', ?, ?, ?, ?, ?, ?)''',
        <Object?>[
          deletionId,
          request.assetId,
          impactJson,
          now.toIso8601String(),
          purgeAfter.toIso8601String(),
          request.reason,
          request.approvalRef,
          now.toIso8601String(),
          commandId,
        ],
      );
      _appendMutation(
        tx,
        commandId: commandId,
        entityId: request.assetId,
        eventType: 'AssetTrashed',
        action: MutationAction.tombstone,
        approvalRef: request.approvalRef,
        payload: <String, Object?>{
          'asset_id': request.assetId,
          'blob_sha256': asset.blobSha256,
          'deletion_id': deletionId,
          'impact': impactJson,
          'reason': request.reason,
          'approval_ref': request.approvalRef,
          'deleted_at_utc': now.toIso8601String(),
          'scope': 'trash',
          if (request.sourceEventId != null) 'source_event_id': request.sourceEventId,
        },
        shaRefs: <String>[asset.blobSha256],
      );
      tx.execute(
        '''INSERT OR IGNORE INTO asset_sync_tombstone_acks(asset_id,target_id,state,created_at_utc)
           SELECT ?,target_id,'pending',? FROM remote_targets WHERE json_extract(policy_json,'\$.sync')=1''',
        <Object?>[request.assetId, now.toIso8601String()],
      );
      if (request.sourceEventId != null) {
        final reviewUpdated = tx.execute(
          '''UPDATE remote_asset_deletion_reviews
             SET status='accepted',local_deletion_id=?,local_approval_ref=?,reviewed_at_utc=?,resolution_note=NULL
             WHERE source_event_id=? AND status='pending' ''',
          <Object?>[deletionId, request.approvalRef, now.toIso8601String(), request.sourceEventId],
        );
        if (reviewUpdated != 1) throw StateError('Remote deletion review changed before acceptance committed.');
        tx.execute(
          '''UPDATE sync_remote_events SET application_state='applied',application_error=NULL
             WHERE event_id=?''',
          <Object?>[request.sourceEventId],
        );
        tx.execute(
          '''UPDATE sync_remote_event_targets SET state='applied'
             WHERE target_id=? AND event_id=?''',
          <Object?>[sourceTargetId, request.sourceEventId],
        );
      }
    });
    return deletionId;
  }

  Future<DeletionId> restore(AssetId assetId, {String? commandId}) async {
    await initialize();
    final actualCommandId = commandId ?? newUuidV7();
    final priorDeletion = _deletionForCommand(
      actualCommandId,
      assetId: assetId,
      scope: 'unlink',
    );
    if (priorDeletion != null) return priorDeletion;
    final row = _assetRow(assetId);
    if (row == null) throw AssetMissingException(assetId);
    if (row['deleted_at_utc'] == null) throw StateError('Asset is not in the trash.');
    final now = DateTime.now().toUtc();
    final deletionId = newUuidV7();
    final asset = _assetFromRow(row, thresholdBytes: await _integrityThresholdBytes());
    await _withBlobLock(asset.blobSha256, () async {
      final blob = _blobRow(asset.blobSha256);
      if (blob == null || _string(blob['state']) == 'purged' || _string(blob['state']) == 'missing') {
        throw AssetMissingException(assetId);
      }
      _vault.database.transaction((tx) {
        tx.execute('UPDATE assets SET deleted_at_utc=NULL WHERE asset_id=?', <Object?>[assetId]);
        tx.execute(
          '''UPDATE deletion_records SET state='recovered'
             WHERE asset_id=? AND scope='trash' AND state='trashed' ''',
          <Object?>[assetId],
        );
        tx.execute(
          '''DELETE FROM asset_sync_tombstone_acks
             WHERE asset_id=? AND state='pending' ''',
          <Object?>[assetId],
        );
        tx.execute(
          '''INSERT INTO deletion_records
             (deletion_id,asset_id,scope,impact_json,state,created_at_utc,reason,confirmed_at_utc,command_id)
             VALUES (?,?,'unlink','{}','recovered',?,'Asset restored from trash',?,?)''',
          <Object?>[deletionId, assetId, now.toIso8601String(), now.toIso8601String(), actualCommandId],
        );
        _appendMutation(
          tx,
          commandId: actualCommandId,
          entityId: assetId,
          eventType: 'AssetRestored',
          action: MutationAction.patch,
          payload: <String, Object?>{
            'asset_id': assetId,
            'blob_sha256': asset.blobSha256,
            'restored_at_utc': now.toIso8601String(),
          },
          shaRefs: <String>[asset.blobSha256],
        );
      });
    });
    return deletionId;
  }

  Future<DeletionId> purge(AssetPurgeRequest request) async {
    await initialize();
    _requireApproval(request.approvalRef);
    final commandId = request.commandId ?? newUuidV7();
    final priorDeletion = _deletionForCommand(
      commandId,
      assetId: request.assetId,
      scope: 'purge',
    );
    if (priorDeletion != null) return priorDeletion;
    final asset = await resolve(request.assetId);
    final now = DateTime.now().toUtc();
    final deletionId = newUuidV7();
    final purgeClaim = newUuidV7();

    await _withBlobLock(asset.blobSha256, () async {
      final freshImpact = await previewDelete(request.assetId);
      _vault.database.transaction((tx) {
        tx.requireApproval(
          approvalRef: ApprovalRef(request.approvalRef),
          action: 'asset.purge',
          subjectType: 'asset',
          subjectId: request.assetId,
          atUtc: now,
          requiredScope: <String, Object?>{
            'blob_sha256': asset.blobSha256,
            'purge': true,
            'impact_reviewed': true,
          },
        );
        final claimExists = tx.query(
          'SELECT claim_id FROM asset_blob_gc_claims WHERE blob_sha256=?',
          <Object?>[asset.blobSha256],
        );
        if (claimExists.isNotEmpty) throw StateError('A garbage-collection operation is already active.');
        tx.execute(
          '''INSERT INTO asset_blob_gc_claims
             (blob_sha256,claim_id,claimed_at_utc,operation,deletion_id)
             VALUES (?,?,?,'purge',?)''',
          <Object?>[asset.blobSha256, purgeClaim, now.toIso8601String(), deletionId],
        );
        tx.execute(
          'UPDATE assets SET deleted_at_utc=COALESCE(deleted_at_utc,?) WHERE asset_id=?',
          <Object?>[now.toIso8601String(), request.assetId],
        );
        tx.execute(
          '''INSERT INTO deletion_records
             (deletion_id,asset_id,scope,impact_json,state,created_at_utc,purge_eligible_at_utc,reason,approval_ref,confirmed_at_utc,command_id)
             VALUES (?,?, 'purge', ?, 'requested', ?, ?, ?, ?, ?, ?)''',
          <Object?>[
            deletionId,
            request.assetId,
            _impactJson(freshImpact),
            now.toIso8601String(),
            now.toIso8601String(),
            request.reason,
            request.approvalRef,
            now.toIso8601String(),
            commandId,
          ],
        );
        tx.execute(
          '''INSERT OR IGNORE INTO asset_sync_tombstone_acks(asset_id,target_id,state,created_at_utc)
             SELECT ?,target_id,'pending',? FROM remote_targets WHERE json_extract(policy_json,'\$.sync')=1''',
          <Object?>[request.assetId, now.toIso8601String()],
        );
        _appendMutation(
          tx,
          commandId: commandId,
          entityId: request.assetId,
          eventType: 'AssetPurged',
          action: MutationAction.tombstone,
          approvalRef: request.approvalRef,
          payload: <String, Object?>{
            'asset_id': request.assetId,
            'blob_sha256': asset.blobSha256,
            'deletion_id': deletionId,
            'impact': _impactJson(freshImpact),
            'reason': request.reason,
            'approval_ref': request.approvalRef,
            'deleted_at_utc': now.toIso8601String(),
            'scope': 'purge',
          },
          shaRefs: <String>[asset.blobSha256],
        );
      });

      // An active duplicate Asset, an unexpired trash Asset, a reader/compute
      // lease, or an unacknowledged tombstone protects the shared CAS bytes.
      // The logical Asset remains as a tombstone and historical links survive.
      final current = await previewDelete(request.assetId);
      final hasUnexpiredOtherTrash = _hasUnexpiredOtherTrash(asset.blobSha256, request.assetId);
      final canDeleteBlob = current.otherActiveAssetsSharingBlob.isEmpty &&
          !hasUnexpiredOtherTrash &&
          current.activeLeaseCount == 0 &&
          !current.pendingSyncTombstones;
      if (canDeleteBlob) {
        final releasedBytes = await _store.deleteBlob(asset.blobSha256);
        _vault.database.transaction((tx) {
          tx.execute(
            "UPDATE blob_objects SET state='purged' WHERE sha256=?",
            <Object?>[asset.blobSha256],
          );
          tx.execute(
            "UPDATE deletion_records SET state='purged' WHERE deletion_id=?",
            <Object?>[deletionId],
          );
          _appendMutation(
            tx,
            commandId: newUuidV7(),
            entityId: request.assetId,
            eventType: 'AssetBlobReleased',
            action: MutationAction.append,
            payload: <String, Object?>{
              'asset_id': request.assetId,
              'blob_sha256': asset.blobSha256,
              'deletion_id': deletionId,
              'physical_bytes_released': releasedBytes,
              'released_at_utc': DateTime.now().toUtc().toIso8601String(),
            },
            shaRefs: <String>[asset.blobSha256],
          );
          tx.execute('DELETE FROM asset_blob_gc_claims WHERE blob_sha256=? AND claim_id=?',
              <Object?>[asset.blobSha256, purgeClaim]);
        });
      } else {
        _vault.database.transaction((tx) {
          tx.execute(
            "UPDATE deletion_records SET state='blocked' WHERE deletion_id=?",
            <Object?>[deletionId],
          );
          tx.execute('DELETE FROM asset_blob_gc_claims WHERE blob_sha256=? AND claim_id=?',
              <Object?>[asset.blobSha256, purgeClaim]);
        });
      }
    });
    return deletionId;
  }

  Future<StorageUsage> storageUsage() async {
    await initialize();
    final rows = _vault.database.query('''
      SELECT
        COALESCE(SUM(CASE WHEN a.deleted_at_utc IS NULL THEN b.byte_size ELSE 0 END),0) AS logical_bytes,
        COUNT(DISTINCT CASE WHEN b.state='committed' THEN b.sha256 END) AS blob_count,
        COALESCE(SUM(DISTINCT CASE WHEN b.state='committed' THEN b.byte_size ELSE 0 END),0) AS unique_blob_bytes,
        COALESCE(SUM(CASE WHEN a.deleted_at_utc IS NOT NULL THEN b.byte_size ELSE 0 END),0) AS trash_bytes,
        COUNT(CASE WHEN a.deleted_at_utc IS NULL THEN a.asset_id END) AS asset_count,
        COUNT(CASE WHEN a.deleted_at_utc IS NOT NULL THEN a.asset_id END) AS trash_asset_count
      FROM assets a JOIN blob_objects b ON b.sha256=a.blob_sha256
    ''');
    final row = rows.firstOrNull ?? const <String, Object?>{};
    final cacheDirectory = Directory(p.join(_vault.rootDirectory, 'caches'));
    final backupDirectory = Directory(p.join(_vault.rootDirectory, 'backups'));
    final remoteOnlyRows = _vault.database.query('''
      SELECT COALESCE(SUM(b.byte_size),0) AS bytes
      FROM blob_objects b WHERE b.state IN ('missing','purged') AND EXISTS
        (SELECT 1 FROM remote_replicas r WHERE r.blob_sha256=b.sha256
         AND r.state IN ('verified','remote_available','uploaded'))
    ''');
    return StorageUsage(
      logicalBytes: _int(row['logical_bytes']) ?? 0,
      uniqueBlobBytes: await _store.directoryBytes(_store.objectsDirectory),
      trashBytes: _int(row['trash_bytes']) ?? 0,
      cacheBytes: await _store.directoryBytes(cacheDirectory) +
          await _store.directoryBytes(_store.stagingDirectory),
      remoteOnlyBytes: _int(remoteOnlyRows.firstOrNull?['bytes']) ?? 0,
      backupBytes: await _store.directoryBytes(backupDirectory),
      blobCount: _int(row['blob_count']) ?? 0,
      assetCount: _int(row['asset_count']) ?? 0,
      trashAssetCount: _int(row['trash_asset_count']) ?? 0,
    );
  }

  Future<AssetFolderId> createVirtualFolder(String name, {AssetFolderId? parentFolderId}) async {
    await initialize();
    final folderId = newUuidV7();
    final normalizedName = name.trim();
    if (normalizedName.isEmpty) throw ArgumentError.value(name, 'name', 'Cannot be empty.');
    final now = DateTime.now().toUtc();
    _vault.database.transaction((tx) {
      tx.execute(
        'INSERT INTO asset_virtual_folders(folder_id,parent_folder_id,name,created_at_utc) VALUES (?,?,?,?)',
        <Object?>[folderId, parentFolderId, normalizedName, now.toIso8601String()],
      );
      _appendMutation(
        tx,
        commandId: newUuidV7(),
        entityType: 'asset_folder',
        entityId: folderId,
        eventType: 'AssetFolderCreated',
        action: MutationAction.create,
        payload: <String, Object?>{
          'folder_id': folderId,
          'parent_folder_id': parentFolderId,
          'name': normalizedName,
          'created_at_utc': now.toIso8601String(),
        },
      );
    });
    return folderId;
  }

  Future<void> addToVirtualFolder(AssetFolderId folderId, AssetId assetId) async {
    await initialize();
    final now = DateTime.now().toUtc();
    _vault.database.transaction((tx) {
      final changed = tx.execute(
        'INSERT OR IGNORE INTO asset_folder_memberships(folder_id,asset_id,created_at_utc) VALUES (?,?,?)',
        <Object?>[folderId, assetId, now.toIso8601String()],
      );
      if (changed == 0) return;
      _appendMutation(
        tx,
        commandId: newUuidV7(),
        entityType: 'asset_folder_membership',
        entityId: '$folderId/$assetId',
        eventType: 'AssetAddedToFolder',
        action: MutationAction.append,
        payload: <String, Object?>{
          'folder_id': folderId,
          'asset_id': assetId,
          'created_at_utc': now.toIso8601String(),
        },
      );
    });
  }

  Future<void> removeFromVirtualFolder(AssetFolderId folderId, AssetId assetId) async {
    await initialize();
    _vault.database.transaction((tx) {
      final changed = tx.execute(
        'DELETE FROM asset_folder_memberships WHERE folder_id=? AND asset_id=?',
        <Object?>[folderId, assetId],
      );
      if (changed == 0) return;
      _appendMutation(
        tx,
        commandId: newUuidV7(),
        entityType: 'asset_folder_membership',
        entityId: '$folderId/$assetId',
        eventType: 'AssetRemovedFromFolder',
        action: MutationAction.tombstone,
        payload: <String, Object?>{
          'folder_id': folderId,
          'asset_id': assetId,
          'removed_at_utc': DateTime.now().toUtc().toIso8601String(),
        },
      );
    });
  }

  /// Completes imports whose process stopped between durable staging and the
  /// final database commit, and marks impossible entries for recovery review.
  Future<void> recoverInterruptedImports() async {
    await _store.initialize();
    final pending = _vault.database.query('SELECT * FROM pending_asset_imports ORDER BY created_at_utc');
    for (final row in pending) {
      final importId = _string(row['import_id']);
      final sha = _string(row['blob_sha256']);
      final stagedRelative = _string(row['staging_relative_path']);
      final stagingFile = File(p.join(_store.rootDirectory.path, stagedRelative));
      final expectedAssetJson = _decodeMap(_string(row['asset_json']));
      final links = _decodeList(_string(row['link_refs_json']));
      final expectedBytes = _int(expectedAssetJson['bytes']) ?? 0;
      final stagedExists = await stagingFile.exists();
      final objectExists = await _store.blobFile(sha).exists();
      try {
        if (stagedExists) {
          final stagedSha = await sha256Digest(stagingFile);
          if (stagedSha != sha || (await stagingFile.length()) != expectedBytes) {
            await _setBlobState(sha, 'mismatch');
            continue;
          }
          final stat = await stagingFile.stat();
          final staged = StagedAssetBlob(
            importId: importId,
            blobSha256: sha,
            byteSize: expectedBytes,
            stagingRelativePath: stagedRelative,
            fingerprint: AssetFileFingerprint.fromStat(stat),
          );
          await _store.publish(staged);
        } else if (!objectExists) {
          await _setBlobState(sha, 'missing');
          continue;
        }
        final actual = await _store.fullHash(sha);
        if (actual != sha) {
          await _quarantineMismatch(sha, 'Interrupted import CAS bytes failed SHA-256.');
          continue;
        }
        final publishedStat = await _store.blobFile(sha).stat();
        final published = PublishedAssetBlob(
          blobSha256: sha,
          byteSize: expectedBytes,
          relativePath: _store.objectRelativePath(sha),
          fingerprint: AssetFileFingerprint.fromStat(publishedStat),
          reusedExisting: objectExists,
        );
        await _commitRecoveredImport(
          importId: importId,
          assetJson: expectedAssetJson,
          linkRows: links,
          published: published,
          commandId: _string(row['command_id']),
        );
      } on FileSystemException {
        await _setBlobState(sha, 'missing');
      } on AssetStoreCollisionException {
        await _setBlobState(sha, 'mismatch');
      }
    }
  }

  /// Resolves a process stop after a GC/purge claim was committed. A present
  /// object means deletion had not completed and can be retried; an absent GC
  /// object is recorded as no longer locally available. An absent object in a
  /// user purge is left blocked for review because the interrupted operation
  /// cannot prove how many bytes it actually released.
  Future<void> _recoverGarbageCollectionClaims() async {
    final claims = _vault.database.query(
      'SELECT blob_sha256,claim_id,operation,deletion_id FROM asset_blob_gc_claims ORDER BY claimed_at_utc',
    );
    for (final claim in claims) {
      final sha = _string(claim['blob_sha256']);
      final claimId = _string(claim['claim_id']);
      final operation = _string(claim['operation']);
      final deletionId = _nullableString(claim['deletion_id']);
      final file = _store.blobFile(sha);
      final exists = await file.exists();

      if (operation != 'purge' || deletionId == null) {
        _vault.database.transaction((tx) {
          if (!exists) {
            tx.execute("UPDATE blob_objects SET state='purged' WHERE sha256=?", <Object?>[sha]);
            _appendMutation(
              tx,
              commandId: newUuidV7(),
              entityType: 'blob',
              entityId: sha,
              eventType: 'AssetBlobReleased',
              action: MutationAction.append,
              payload: <String, Object?>{
                'blob_sha256': sha,
                'physical_bytes_released': 0,
                'recovered_after_interruption': true,
                'released_at_utc': DateTime.now().toUtc().toIso8601String(),
              },
              shaRefs: <String>[sha],
            );
          }
          tx.execute(
            'DELETE FROM asset_blob_gc_claims WHERE blob_sha256=? AND claim_id=?',
            <Object?>[sha, claimId],
          );
        });
        continue;
      }

      final deletionRows = _vault.database.query(
        'SELECT asset_id,state FROM deletion_records WHERE deletion_id=? AND scope=\'purge\'',
        <Object?>[deletionId],
      );
      if (deletionRows.isEmpty || _string(deletionRows.single['state']) != 'requested') {
        _vault.database.execute(
          'DELETE FROM asset_blob_gc_claims WHERE blob_sha256=? AND claim_id=?',
          <Object?>[sha, claimId],
        );
        continue;
      }
      final assetId = _string(deletionRows.single['asset_id']);
      if (!exists) {
        final now = DateTime.now().toUtc().toIso8601String();
        _vault.database.transaction((tx) {
          tx.execute("UPDATE blob_objects SET state='missing' WHERE sha256=?", <Object?>[sha]);
          tx.execute(
            '''UPDATE deletion_records SET state='blocked',
                 reason=COALESCE(reason,'') || '; interrupted purge found no local object to verify'
               WHERE deletion_id=? AND state='requested' ''',
            <Object?>[deletionId],
          );
          tx.execute(
            'DELETE FROM asset_blob_gc_claims WHERE blob_sha256=? AND claim_id=?',
            <Object?>[sha, claimId],
          );
          _appendMutation(
            tx,
            commandId: newUuidV7(),
            entityId: assetId,
            eventType: 'AssetPurgeRecoveryRequired',
            action: MutationAction.append,
            payload: <String, Object?>{
              'asset_id': assetId,
              'blob_sha256': sha,
              'deletion_id': deletionId,
              'status': 'missing',
              'physical_bytes_released': 0,
              'recovered_at_utc': now,
            },
            shaRefs: <String>[sha],
          );
        });
        continue;
      }

      await _withBlobLock(sha, () async {
        final eligible = _canDeleteBlob(sha, assetId, DateTime.now().toUtc());
        if (!eligible) {
          _vault.database.transaction((tx) {
            tx.execute(
              "UPDATE deletion_records SET state='blocked' WHERE deletion_id=? AND state='requested'",
              <Object?>[deletionId],
            );
            tx.execute(
              'DELETE FROM asset_blob_gc_claims WHERE blob_sha256=? AND claim_id=?',
              <Object?>[sha, claimId],
            );
          });
          return;
        }
        final releasedBytes = await _store.deleteBlob(sha);
        final now = DateTime.now().toUtc().toIso8601String();
        _vault.database.transaction((tx) {
          tx.execute("UPDATE blob_objects SET state='purged' WHERE sha256=?", <Object?>[sha]);
          tx.execute(
            "UPDATE deletion_records SET state='purged' WHERE deletion_id=? AND state='requested'",
            <Object?>[deletionId],
          );
          tx.execute(
            'DELETE FROM asset_blob_gc_claims WHERE blob_sha256=? AND claim_id=?',
            <Object?>[sha, claimId],
          );
          _appendMutation(
            tx,
            commandId: newUuidV7(),
            entityId: assetId,
            eventType: 'AssetBlobReleased',
            action: MutationAction.append,
            payload: <String, Object?>{
              'asset_id': assetId,
              'blob_sha256': sha,
              'deletion_id': deletionId,
              'physical_bytes_released': releasedBytes,
              'recovered_after_interruption': true,
              'released_at_utc': now,
            },
            shaRefs: <String>[sha],
          );
        });
      });
    }
  }

  Future<int> collectGarbage({DateTime? atUtc}) async {
    await initialize();
    final now = (atUtc ?? DateTime.now().toUtc()).toUtc();
    final candidates = _vault.database.query('''
      SELECT b.sha256,b.byte_size FROM blob_objects b
      WHERE b.state='committed'
        AND NOT EXISTS (SELECT 1 FROM assets a WHERE a.blob_sha256=b.sha256 AND a.deleted_at_utc IS NULL)
        AND NOT EXISTS (SELECT 1 FROM assets a WHERE a.blob_sha256=b.sha256 AND a.deleted_at_utc IS NOT NULL
                        AND a.deleted_at_utc>?)
        AND NOT EXISTS (SELECT 1 FROM asset_blob_leases l WHERE l.blob_sha256=b.sha256 AND l.expires_at_utc>?)
        AND NOT EXISTS (SELECT 1 FROM asset_sync_tombstone_acks t JOIN assets a ON a.asset_id=t.asset_id
                        WHERE a.blob_sha256=b.sha256 AND t.state<>'acknowledged')
        AND NOT EXISTS (SELECT 1 FROM pending_asset_imports p WHERE p.blob_sha256=b.sha256)
        AND NOT EXISTS (SELECT 1 FROM pending_sync_blobs p WHERE p.sha256=b.sha256)
        AND NOT EXISTS (SELECT 1 FROM sync_received_blobs r WHERE r.sha256=b.sha256 AND r.state='available')
        AND NOT EXISTS (SELECT 1 FROM asset_blob_gc_claims c WHERE c.blob_sha256=b.sha256)
    ''', <Object?>[
      now.subtract(trashRetention).toIso8601String(),
      now.toIso8601String(),
    ]);
    var released = 0;
    for (final candidate in candidates) {
      final sha = _string(candidate['sha256']);
      await _withBlobLock(sha, () async {
        final claimId = newUuidV7();
        final nowText = now.toIso8601String();
        final claimed = _vault.database.transaction((tx) {
          final stillEligible = tx.query('''
            SELECT b.sha256 FROM blob_objects b
            WHERE b.sha256=? AND b.state='committed'
              AND NOT EXISTS (SELECT 1 FROM assets a WHERE a.blob_sha256=b.sha256 AND a.deleted_at_utc IS NULL)
              AND NOT EXISTS (SELECT 1 FROM assets a WHERE a.blob_sha256=b.sha256 AND a.deleted_at_utc IS NOT NULL
                              AND a.deleted_at_utc>?)
              AND NOT EXISTS (SELECT 1 FROM asset_blob_leases l WHERE l.blob_sha256=b.sha256 AND l.expires_at_utc>?)
              AND NOT EXISTS (SELECT 1 FROM asset_sync_tombstone_acks t JOIN assets a ON a.asset_id=t.asset_id
                              WHERE a.blob_sha256=b.sha256 AND t.state<>'acknowledged')
              AND NOT EXISTS (SELECT 1 FROM pending_asset_imports p WHERE p.blob_sha256=b.sha256)
              AND NOT EXISTS (SELECT 1 FROM pending_sync_blobs p WHERE p.sha256=b.sha256)
              AND NOT EXISTS (SELECT 1 FROM sync_received_blobs r WHERE r.sha256=b.sha256 AND r.state='available')
              AND NOT EXISTS (SELECT 1 FROM asset_blob_gc_claims c WHERE c.blob_sha256=b.sha256)
          ''', <Object?>[
            sha,
            now.subtract(trashRetention).toIso8601String(),
            nowText,
          ]);
          if (stillEligible.isEmpty) return false;
          tx.execute(
            'INSERT INTO asset_blob_gc_claims(blob_sha256,claim_id,claimed_at_utc) VALUES (?,?,?)',
            <Object?>[sha, claimId, nowText],
          );
          return true;
        });
        if (!claimed) return;
        try {
          final releasedBytes = await _store.deleteBlob(sha);
          _vault.database.transaction((tx) {
            tx.execute("UPDATE blob_objects SET state='purged' WHERE sha256=?", <Object?>[sha]);
            tx.execute('DELETE FROM asset_blob_gc_claims WHERE blob_sha256=? AND claim_id=?', <Object?>[sha, claimId]);
            _appendMutation(
              tx,
              commandId: newUuidV7(),
              entityId: sha,
              entityType: 'blob',
              eventType: 'AssetBlobReleased',
              action: MutationAction.append,
              payload: <String, Object?>{
                'blob_sha256': sha,
                'physical_bytes_released': releasedBytes,
                'released_at_utc': nowText,
              },
              shaRefs: <String>[sha],
            );
          });
          released += releasedBytes;
        } catch (_) {
          _vault.database.execute(
            'DELETE FROM asset_blob_gc_claims WHERE blob_sha256=? AND claim_id=?',
            <Object?>[sha, claimId],
          );
          rethrow;
        }
      });
    }
    return released;
  }

  DeletionId? _deletionForCommand(
    String commandId, {
    required AssetId assetId,
    required String scope,
  }) {
    final rows = _vault.database.query(
      'SELECT deletion_id,asset_id,scope FROM deletion_records WHERE command_id=? LIMIT 1',
      <Object?>[commandId],
    );
    if (rows.isEmpty) return null;
    final prior = rows.single;
    if (_string(prior['asset_id']) != assetId || _string(prior['scope']) != scope) {
      throw StateError('Command id was already used for a different Asset deletion.');
    }
    return _string(prior['deletion_id']);
  }

  Future<void> _commitRecoveredImport({
    required String importId,
    required Map<String, Object?> assetJson,
    required List<Object?> linkRows,
    required PublishedAssetBlob published,
    required String commandId,
  }) async {
    final assetId = _string(assetJson['asset_id']);
    final sha = _string(assetJson['blob_sha256']);
    final now = DateTime.now().toUtc();
    _vault.database.transaction((tx) {
      _upsertCommittedBlob(
        tx,
        sha,
        published.byteSize,
        published.relativePath,
        published.fingerprint,
        _int(assetJson['threshold_bytes']) ?? defaultIntegrityThresholdBytes,
        now,
      );
      final existingAsset = tx.query('SELECT asset_id FROM assets WHERE asset_id=?', <Object?>[assetId]);
      if (existingAsset.isEmpty) _insertAssetFromJson(tx, assetJson);
      for (final link in linkRows.cast<Map<String, Object?>>()) {
        _insertLinkFromJson(tx, assetId, link, now);
      }
      _appendMutation(
        tx,
        commandId: commandId,
        entityId: assetId,
        eventType: 'AssetImported',
        action: MutationAction.create,
        payload: <String, Object?>{
          'asset_id': assetId,
          'blob_sha256': sha,
          'byte_size': published.byteSize,
          'display_name': assetJson['display_name'],
          'media_type': assetJson['media_type'],
          'kind': assetJson['kind'],
          'parent_asset_id': assetJson['parent_asset_id'],
          'created_at_utc': assetJson['created_at_utc'],
          'metadata': assetJson['metadata'] ?? const <String, Object?>{},
          'links': _wireLinks(linkRows.cast<Map<String, Object?>>()),
          'recovered_after_interruption': true,
        },
        shaRefs: <String>[sha],
      );
      tx.execute('DELETE FROM pending_asset_imports WHERE import_id=?', <Object?>[importId]);
    });
  }

  AssetRecord _commitPendingImport({
    required String importId,
    required String assetId,
    required String blobSha256,
    required int byteSize,
    required String displayName,
    required String? mediaType,
    required AssetKind kind,
    required AssetId? parentAssetId,
    required DateTime createdAt,
    required int thresholdBytes,
    required Map<String, Object?> metadata,
    required List<AssetLinkRef> links,
    required String commandId,
    required PublishedAssetBlob published,
  }) {
    _vault.database.transaction((tx) {
      _upsertCommittedBlob(
        tx,
        blobSha256,
        byteSize,
        published.relativePath,
        published.fingerprint,
        thresholdBytes,
        createdAt,
      );
      tx.execute(
        '''INSERT INTO assets
           (asset_id,blob_sha256,display_name,media_type,kind,parent_asset_id,created_at_utc,deleted_at_utc,metadata_json)
           VALUES (?,?,?,?,?,?,?,NULL,?)''',
        <Object?>[
          assetId,
          blobSha256,
          displayName,
          mediaType,
          kind.wireValue,
          parentAssetId,
          createdAt.toIso8601String(),
          jsonEncode(metadata),
        ],
      );
      for (final link in links) {
        tx.execute(
          '''INSERT INTO asset_links(link_id,asset_id,entity_type,entity_id,relation,removed_at_utc,created_at_utc,metadata_json)
             VALUES (?,?,?,?,?,NULL,?,?)''',
          <Object?>[
            newUuidV7(),
            assetId,
            link.targetType,
            link.targetId,
            link.role,
            createdAt.toIso8601String(),
            jsonEncode(link.metadata),
          ],
        );
      }
      _appendMutation(
        tx,
        commandId: commandId,
        entityId: assetId,
        eventType: 'AssetImported',
        action: MutationAction.create,
        payload: <String, Object?>{
          'asset_id': assetId,
          'blob_sha256': blobSha256,
          'byte_size': byteSize,
          'display_name': displayName,
          'media_type': mediaType,
          'kind': kind.wireValue,
          'parent_asset_id': parentAssetId,
          'created_at_utc': createdAt.toIso8601String(),
          'metadata': metadata,
          'links': _wireLinks(links.map(_linkToJson).toList(growable: false)),
          'reused_blob': published.reusedExisting,
        },
        shaRefs: <String>[blobSha256],
      );
      tx.execute('DELETE FROM pending_asset_imports WHERE import_id=?', <Object?>[importId]);
    });
    final row = _assetRow(assetId);
    if (row == null) throw StateError('Asset commit did not produce a row.');
    return _assetFromRow(row, thresholdBytes: thresholdBytes);
  }

  Future<AssetRecord> _commitAssetOnly({
    required String assetId,
    required String blobSha256,
    required int byteSize,
    required String displayName,
    required String? mediaType,
    required AssetKind kind,
    required String? parentAssetId,
    required DateTime createdAt,
    required int thresholdBytes,
    required Map<String, Object?> metadata,
    required List<AssetLinkRef> links,
    required String commandId,
    required bool reusedBlob,
  }) async {
    _vault.database.transaction((tx) {
      final state = tx.query('SELECT state FROM blob_objects WHERE sha256=?', <Object?>[blobSha256]);
      if (state.isEmpty || _string(state.first['state']) != 'committed') {
        throw StateError('Blob was not committed while importing an Asset.');
      }
      tx.execute(
        '''INSERT INTO assets
           (asset_id,blob_sha256,display_name,media_type,kind,parent_asset_id,created_at_utc,deleted_at_utc,metadata_json)
           VALUES (?,?,?,?,?,?,?,NULL,?)''',
        <Object?>[
          assetId,
          blobSha256,
          displayName,
          mediaType,
          kind.wireValue,
          parentAssetId,
          createdAt.toIso8601String(),
          jsonEncode(metadata),
        ],
      );
      for (final link in links) {
        tx.execute(
          '''INSERT INTO asset_links(link_id,asset_id,entity_type,entity_id,relation,removed_at_utc,created_at_utc,metadata_json)
             VALUES (?,?,?,?,?,NULL,?,?)''',
          <Object?>[
            newUuidV7(),
            assetId,
            link.targetType,
            link.targetId,
            link.role,
            createdAt.toIso8601String(),
            jsonEncode(link.metadata),
          ],
        );
      }
      _appendMutation(
        tx,
        commandId: commandId,
        entityId: assetId,
        eventType: 'AssetImported',
        action: MutationAction.create,
        payload: <String, Object?>{
          'asset_id': assetId,
          'blob_sha256': blobSha256,
          'byte_size': byteSize,
          'display_name': displayName,
          'media_type': mediaType,
          'kind': kind.wireValue,
          'parent_asset_id': parentAssetId,
          'created_at_utc': createdAt.toIso8601String(),
          'metadata': metadata,
          'links': _wireLinks(links.map(_linkToJson).toList(growable: false)),
          'reused_blob': reusedBlob,
        },
        shaRefs: <String>[blobSha256],
      );
    });
    final row = _assetRow(assetId);
    if (row == null) throw StateError('Asset commit did not produce a row.');
    return _assetFromRow(row, thresholdBytes: thresholdBytes);
  }

  void _upsertCommittedBlob(
    WorkspaceTransaction tx,
    String sha,
    int byteSize,
    String relativePath,
    AssetFileFingerprint fingerprint,
    int threshold,
    DateTime verifiedAt,
  ) {
    final existing = tx.query('SELECT state,byte_size FROM blob_objects WHERE sha256=?', <Object?>[sha]);
    if (existing.isEmpty) {
      tx.execute(
        '''INSERT INTO blob_objects
           (sha256,byte_size,relative_path,state,imported_at_utc,last_full_verified_at,
            last_fast_checked_at,last_known_size,last_known_mtime_ns,last_file_id,threshold_at_import)
           VALUES (?,?,?,'committed',?,?,NULL,?,?,?,?)''',
        <Object?>[
          sha,
          byteSize,
          relativePath,
          verifiedAt.toIso8601String(),
          verifiedAt.toIso8601String(),
          fingerprint.size,
          fingerprint.mtimeNs,
          fingerprint.fileId,
          threshold,
        ],
      );
      return;
    }
    if ((_int(existing.first['byte_size']) ?? byteSize) != byteSize) {
      throw StateError('CAS database size conflicts with the content digest.');
    }
    tx.execute(
      '''UPDATE blob_objects SET state='committed',relative_path=?,last_full_verified_at=?,
           last_known_size=?,last_known_mtime_ns=?,last_file_id=? WHERE sha256=?''',
      <Object?>[
        relativePath,
        verifiedAt.toIso8601String(),
        fingerprint.size,
        fingerprint.mtimeNs,
        fingerprint.fileId,
        sha,
      ],
    );
  }

  void _insertAssetFromJson(WorkspaceTransaction tx, Map<String, Object?> json) {
    tx.execute(
      '''INSERT INTO assets
         (asset_id,blob_sha256,display_name,media_type,kind,parent_asset_id,created_at_utc,deleted_at_utc,metadata_json)
         VALUES (?,?,?,?,?,?,?,NULL,?)''',
      <Object?>[
        json['asset_id'],
        json['blob_sha256'],
        json['display_name'],
        json['media_type'],
        json['kind'],
        json['parent_asset_id'],
        json['created_at_utc'],
        jsonEncode(_decodeMap(jsonEncode(json['metadata'] ?? const <String, Object?>{}))),
      ],
    );
  }

  void _insertLinkFromJson(WorkspaceTransaction tx, String assetId, Map<String, Object?> json, DateTime now) {
    tx.execute(
      '''INSERT OR IGNORE INTO asset_links
         (link_id,asset_id,entity_type,entity_id,relation,removed_at_utc,created_at_utc,metadata_json)
         VALUES (?,?,?,?,?,NULL,?,?)''',
      <Object?>[
        newUuidV7(),
        assetId,
        json['target_type'],
        json['target_id'],
        json['role'],
        now.toIso8601String(),
        jsonEncode(json['metadata'] ?? const <String, Object?>{}),
      ],
    );
  }

  Future<void> _recordOpenedAt(AssetId assetId, DateTime at) async {
    final row = _vault.database.query('SELECT metadata_json FROM assets WHERE asset_id=?', <Object?>[assetId]);
    if (row.isEmpty) return;
    final metadata = _decodeMap(_string(row.first['metadata_json']));
    metadata['last_opened_at_utc'] = at.toIso8601String();
    _vault.database.execute(
      'UPDATE assets SET metadata_json=? WHERE asset_id=?',
      <Object?>[jsonEncode(metadata), assetId],
    );
  }

  Future<void> _recordIntegrityResult({
    required String assetId,
    required String blobSha256,
    required IntegrityCheckMode mode,
    required AssetIntegrityStatus status,
    required String expectedSha256,
    required String? actualSha256,
    required int bytesChecked,
    required String? message,
    AssetFileFingerprint? fingerprint,
  }) async {
    final now = DateTime.now().toUtc();
    _vault.database.transaction((tx) {
      final blobState = switch (status) {
        AssetIntegrityStatus.verified => 'committed',
        AssetIntegrityStatus.missing => 'missing',
        _ => 'mismatch',
      };
      tx.execute('UPDATE blob_objects SET state=? WHERE sha256=?', <Object?>[blobState, blobSha256]);
      if (status == AssetIntegrityStatus.verified) {
        tx.execute(
          '''UPDATE blob_objects SET last_full_verified_at=?,
                 last_known_size=COALESCE(?,last_known_size),
                 last_known_mtime_ns=COALESCE(?,last_known_mtime_ns) WHERE sha256=?''',
          <Object?>[
            now.toIso8601String(),
            fingerprint?.size,
            fingerprint?.mtimeNs,
            blobSha256,
          ],
        );
      }
      tx.execute(
        '''INSERT INTO integrity_checks
           (check_id,blob_sha256,mode,status,started_at_utc,finished_at_utc,details_json,verification_level)
           VALUES (?,?,?,?,?,?,?,?)''',
        <Object?>[
          newUuidV7(),
          blobSha256,
          _integrityModeWire(mode),
          status == AssetIntegrityStatus.mismatch || status == AssetIntegrityStatus.missing
              ? 'failed'
              : 'passed',
          now.toIso8601String(),
          now.toIso8601String(),
          jsonEncode(<String, Object?>{
            'asset_id': assetId,
            'expected_sha256': expectedSha256,
            'actual_sha256': actualSha256,
            'bytes_checked': bytesChecked,
            'message': message,
            'file_id_checked': false,
          }),
          _verificationLevel(mode, status),
        ],
      );
      if (status == AssetIntegrityStatus.mismatch || status == AssetIntegrityStatus.missing) {
        _appendMutation(
          tx,
          commandId: newUuidV7(),
          entityId: assetId,
          eventType: 'AssetIntegrityFailed',
          action: MutationAction.append,
          payload: <String, Object?>{
            'asset_id': assetId,
            'blob_sha256': blobSha256,
            'expected_sha256': expectedSha256,
            'actual_sha256': actualSha256,
            'status': status.wireValue,
            'mode': _integrityModeWire(mode),
            'verification_level': _verificationLevel(mode, status),
            'message': message,
          },
          shaRefs: <String>[blobSha256],
        );
      }
    });
  }

  void _writeIntegrityCheck(
    String blobSha256,
    IntegrityCheckMode mode,
    AssetIntegrityStatus status,
    int bytesChecked,
    Map<String, Object?> details,
  ) {
    final now = DateTime.now().toUtc();
    _vault.database.execute(
      '''INSERT INTO integrity_checks
         (check_id,blob_sha256,mode,status,started_at_utc,finished_at_utc,details_json,verification_level)
         VALUES (?,?,?,?,?,?,?,?)''',
      <Object?>[
        newUuidV7(),
        blobSha256,
        _integrityModeWire(mode),
        status == AssetIntegrityStatus.mismatch || status == AssetIntegrityStatus.missing ? 'failed' : 'passed',
        now.toIso8601String(),
        now.toIso8601String(),
        jsonEncode(<String, Object?>{...details, 'bytes_checked': bytesChecked}),
        _verificationLevel(mode, status),
      ],
    );
  }

  static String _verificationLevel(
    IntegrityCheckMode mode,
    AssetIntegrityStatus status,
  ) {
    if (status == AssetIntegrityStatus.missing) return 'missing';
    if (status == AssetIntegrityStatus.mismatch) return 'mismatch';
    return switch (mode) {
      IntegrityCheckMode.fullSha256 => 'verified',
      IntegrityCheckMode.metadataQuick => 'quick_checked',
      IntegrityCheckMode.transferChecksum => 'transfer_checksum',
    };
  }

  void _markBlobMissing(String sha, String message) {
    _vault.database.transaction((tx) {
      tx.execute("UPDATE blob_objects SET state='missing' WHERE sha256=?", <Object?>[sha]);
      _appendMutation(
        tx,
        commandId: newUuidV7(),
        entityId: sha,
        entityType: 'blob',
        eventType: 'AssetIntegrityFailed',
        action: MutationAction.append,
        payload: <String, Object?>{'blob_sha256': sha, 'status': 'missing', 'message': message},
        shaRefs: <String>[sha],
      );
    });
  }

  Future<void> _quarantineMismatch(String sha, String reason) async {
    final file = _store.blobFile(sha);
    if (await file.exists()) {
      final quarantineName = '$sha-${DateTime.now().toUtc().microsecondsSinceEpoch}.mismatch';
      final quarantinePath = File(p.join(_store.quarantineDirectory.path, quarantineName));
      await quarantinePath.parent.create(recursive: true);
      await file.rename(quarantinePath.path);
    }
    _vault.database.transaction((tx) {
      tx.execute("UPDATE blob_objects SET state='mismatch' WHERE sha256=?", <Object?>[sha]);
      _appendMutation(
        tx,
        commandId: newUuidV7(),
        entityId: sha,
        entityType: 'blob',
        eventType: 'AssetIntegrityFailed',
        action: MutationAction.append,
        payload: <String, Object?>{'blob_sha256': sha, 'status': 'mismatch', 'message': reason},
        shaRefs: <String>[sha],
      );
    });
  }

  Future<void> _setBlobState(String sha, String state) async {
    _vault.database.execute('UPDATE blob_objects SET state=? WHERE sha256=?', <Object?>[state, sha]);
  }

  void _acquireLease(String leaseId, String blobSha, String owner) {
    final now = DateTime.now().toUtc();
    _vault.database.transaction((tx) {
      final claims = tx.query(
        'SELECT claim_id FROM asset_blob_gc_claims WHERE blob_sha256=?',
        <Object?>[blobSha],
      );
      if (claims.isNotEmpty) {
        throw StateError('CAS Blob is being permanently released; opening is blocked.');
      }
      tx.execute(
        '''INSERT INTO asset_blob_leases(lease_id,blob_sha256,owner,created_at_utc,expires_at_utc)
           VALUES (?,?,?,?,?)''',
        <Object?>[
          leaseId,
          blobSha,
          owner,
          now.toIso8601String(),
          now.add(const Duration(hours: 1)).toIso8601String(),
        ],
      );
    });
  }

  void _releaseLease(String leaseId) {
    _vault.database.execute('DELETE FROM asset_blob_leases WHERE lease_id=?', <Object?>[leaseId]);
  }

  Future<void> _rejectIfGcClaimed(String blobSha) async {
    final claims = _vault.database.query(
      'SELECT claim_id FROM asset_blob_gc_claims WHERE blob_sha256=?',
      <Object?>[blobSha],
    );
    if (claims.isNotEmpty) throw StateError('CAS Blob is being permanently released; retry import later.');
  }

  bool _hasUnexpiredOtherTrash(String sha, String excludingAssetId) {
    final rows = _vault.database.query(
      '''SELECT deleted_at_utc FROM assets WHERE blob_sha256=? AND asset_id<>?
         AND deleted_at_utc IS NOT NULL''',
      <Object?>[sha, excludingAssetId],
    );
    final now = DateTime.now().toUtc();
    return rows.any((row) {
      final deleted = _dateTime(row['deleted_at_utc']);
      return deleted != null && now.difference(deleted) < trashRetention;
    });
  }

  bool _canDeleteBlob(String sha, String excludingAssetId, DateTime now) {
    final active = _vault.database.query(
      '''SELECT 1 FROM assets WHERE blob_sha256=? AND deleted_at_utc IS NULL LIMIT 1''',
      <Object?>[sha],
    );
    if (active.isNotEmpty || _hasUnexpiredOtherTrash(sha, excludingAssetId)) return false;
    final leases = _vault.database.query(
      'SELECT 1 FROM asset_blob_leases WHERE blob_sha256=? AND expires_at_utc>? LIMIT 1',
      <Object?>[sha, now.toIso8601String()],
    );
    if (leases.isNotEmpty) return false;
    final pendingTombstones = _vault.database.query(
      '''SELECT 1 FROM asset_sync_tombstone_acks t
         JOIN assets a ON a.asset_id=t.asset_id
         WHERE a.blob_sha256=? AND t.state<>'acknowledged' LIMIT 1''',
      <Object?>[sha],
    );
    if (pendingTombstones.isNotEmpty) return false;
    final pendingImports = _vault.database.query(
      'SELECT 1 FROM pending_asset_imports WHERE blob_sha256=? LIMIT 1',
      <Object?>[sha],
    );
    if (pendingImports.isNotEmpty) return false;
    final pendingSync = _vault.database.query(
      'SELECT 1 FROM pending_sync_blobs WHERE sha256=? LIMIT 1',
      <Object?>[sha],
    );
    if (pendingSync.isNotEmpty) return false;
    final syncedRetention = _vault.database.query(
      "SELECT 1 FROM sync_received_blobs WHERE sha256=? AND state='available' LIMIT 1",
      <Object?>[sha],
    );
    return syncedRetention.isEmpty;
  }

  Future<void> _removeUntrackedStagingFiles() async {
    final pendingPaths = _vault.database.query('SELECT staging_relative_path FROM pending_asset_imports')
        .map((row) => p.normalize(_string(row['staging_relative_path'])))
        .toSet();
    pendingPaths.addAll(_vault.database.query('SELECT staging_relative_path FROM pending_sync_blobs')
        .map((row) => p.normalize(_string(row['staging_relative_path']))));
    final cutoff = DateTime.now().toUtc().subtract(const Duration(days: 1));
    for (final file in await _store.listStagingFiles()) {
      final relative = p.normalize(p.relative(file.path, from: _store.rootDirectory.path));
      if (relative.startsWith('read-') || relative.contains('${p.separator}read-')) continue;
      if (pendingPaths.contains(relative)) continue;
      final stat = await file.stat();
      if (stat.modified.toUtc().isBefore(cutoff)) await file.delete();
    }
  }

  Map<String, Object?>? _assetRow(String assetId) {
    final rows = _vault.database.query('''
      SELECT a.asset_id,a.blob_sha256,a.display_name,a.media_type,a.kind,a.parent_asset_id,
             a.created_at_utc,a.deleted_at_utc,a.metadata_json,b.byte_size,b.state AS blob_state,
             b.last_full_verified_at,b.last_fast_checked_at,b.last_known_size,
             b.last_known_mtime_ns,b.last_file_id,b.threshold_at_import
      FROM assets a JOIN blob_objects b ON b.sha256=a.blob_sha256 WHERE a.asset_id=?
    ''', <Object?>[assetId]);
    return rows.firstOrNull;
  }

  Map<String, Object?>? _blobRow(String sha) {
    final rows = _vault.database.query(
      '''SELECT sha256,byte_size,relative_path,state,last_full_verified_at,
                last_fast_checked_at,last_known_size,last_known_mtime_ns,last_file_id,threshold_at_import
         FROM blob_objects WHERE sha256=?''',
      <Object?>[sha],
    );
    return rows.firstOrNull;
  }

  AssetRecord _assetFromRow(Map<String, Object?> row, {required int thresholdBytes}) {
    final blobState = _string(row['blob_state']);
    final lastFull = _dateTime(row['last_full_verified_at']);
    final integrityStatus = switch (blobState) {
      'missing' => AssetIntegrityStatus.missing,
      'mismatch' => AssetIntegrityStatus.mismatch,
      'staged' => AssetIntegrityStatus.pending,
      'purged' => AssetIntegrityStatus.missing,
      _ when lastFull != null => AssetIntegrityStatus.verified,
      _ when row['last_fast_checked_at'] != null => AssetIntegrityStatus.quickChecked,
      _ => AssetIntegrityStatus.overdue,
    };
    return AssetRecord(
      assetId: _string(row['asset_id']),
      blobSha256: _string(row['blob_sha256']),
      byteSize: _int(row['byte_size']) ?? 0,
      displayName: _string(row['display_name']),
      mediaType: _nullableString(row['media_type']),
      kind: AssetKind.parse(_string(row['kind'])),
      parentAssetId: _nullableString(row['parent_asset_id']),
      createdAtUtc: _dateTime(row['created_at_utc']) ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      deletedAtUtc: _dateTime(row['deleted_at_utc']),
      integrityStatus: integrityStatus,
      integrityThresholdBytes: thresholdBytes,
      lastFullVerifiedAtUtc: lastFull,
      lastFastCheckedAtUtc: _dateTime(row['last_fast_checked_at']),
      lastKnownMtimeNs: _int(row['last_known_mtime_ns']),
      lastKnownFileId: _nullableString(row['last_file_id']),
      metadata: _decodeMap(_string(row['metadata_json'])),
    );
  }

  Future<int> _integrityThresholdBytes() async {
    final rows = _vault.database.query(
      'SELECT integrity_threshold_bytes FROM vaults WHERE vault_id=?',
      <Object?>[_vault.vaultId],
    );
    final value = rows.firstOrNull?['integrity_threshold_bytes'];
    final threshold = _int(value);
    return threshold != null && threshold >= 0 ? threshold : defaultIntegrityThresholdBytes;
  }

  void _appendMutation(
    WorkspaceTransaction tx, {
    required String commandId,
    required String entityId,
    String entityType = 'asset',
    required String eventType,
    required Map<String, Object?> payload,
    List<String> shaRefs = const <String>[],
    MutationAction action = MutationAction.append,
    String? approvalRef,
  }) {
    final now = DateTime.now().toUtc();
    tx.appendMutation(MutationEventDraft(
      command: CommandMetadata(
        commandId: commandId,
        utcTime: now,
        actor: 'local_user',
        approvalRef: approvalRef == null ? null : ApprovalRef(approvalRef),
      ),
      deviceId: _vault.deviceId,
      entityType: entityType,
      entityId: entityId,
      eventType: eventType,
      action: action,
      payloadJson: jsonEncode(payload),
      assetShaRefs: shaRefs,
    ));
  }

  Future<T> _withBlobLock<T>(String blobSha, Future<T> Function() action) async {
    while (_blobLocks.containsKey(blobSha)) {
      await _blobLocks[blobSha]!.future;
    }
    final gate = Completer<void>();
    _blobLocks[blobSha] = gate;
    try {
      return await action();
    } finally {
      _blobLocks.remove(blobSha);
      gate.complete();
    }
  }

  static void _requireApproval(String approvalRef) {
    if (approvalRef.trim().isEmpty) {
      throw ArgumentError.value(approvalRef, 'approvalRef', 'A user approval reference is required.');
    }
  }

  static String _normalizeDisplayName(String value) {
    final normalized = value.replaceAll(RegExp(r'[\x00-\x1f]'), '').trim();
    if (normalized.isEmpty || normalized == '.' || normalized == '..') {
      throw ArgumentError.value(value, 'displayName', 'Must be a visible file name.');
    }
    return normalized;
  }

  static Map<String, Object?> _linkToJson(AssetLinkRef link) => <String, Object?>{
        'target_type': link.targetType,
        'target_id': link.targetId,
        'role': link.role,
        'metadata': link.metadata,
      };

  static List<Map<String, Object?>> _wireLinks(List<Map<String, Object?>> values) =>
      values.map((link) => <String, Object?>{
            'entity_type': link['target_type'] ?? link['entity_type'],
            'entity_id': link['target_id'] ?? link['entity_id'],
            'relation': link['role'] ?? link['relation'],
            'metadata': link['metadata'] ?? const <String, Object?>{},
          }).toList(growable: false);

  static String _impactJson(DeletionImpact impact) => jsonEncode(<String, Object?>{
        'asset_id': impact.assetId,
        'blob_sha256': impact.blobSha256,
        'logical_bytes': impact.logicalBytes,
        'reclaimable_physical_bytes': impact.reclaimablePhysicalBytes,
        'active_links': impact.activeLinks
            .map((link) => <String, Object?>{
                  'target_type': link.targetType,
                  'target_id': link.targetId,
                  'role': link.role,
                })
            .toList(growable: false),
        'other_active_assets_sharing_blob': impact.otherActiveAssetsSharingBlob,
        'trash_assets_sharing_blob': impact.trashAssetsSharingBlob,
        'retained_backup_count': impact.retainedBackupCount,
        'remote_replica_states': impact.remoteReplicaStates,
        'active_lease_count': impact.activeLeaseCount,
        'pending_sync_tombstones': impact.pendingSyncTombstones,
        'purge_eligible_now': impact.purgeEligibleNow,
      });

  static String _integrityModeWire(IntegrityCheckMode mode) => switch (mode) {
        IntegrityCheckMode.fullSha256 => 'full_sha256',
        IntegrityCheckMode.metadataQuick => 'metadata_quick',
        IntegrityCheckMode.transferChecksum => 'transfer_checksum',
      };

  static RemoteAssetDeletionReview _remoteDeletionReviewFromRow(Map<String, Object?> row) {
    final status = switch (_string(row['status'])) {
      'pending' => RemoteAssetDeletionReviewStatus.pending,
      'accepted' => RemoteAssetDeletionReviewStatus.accepted,
      'rejected' => RemoteAssetDeletionReviewStatus.rejected,
      'audit_only' => RemoteAssetDeletionReviewStatus.auditOnly,
      final value => throw FormatException('Unsupported remote deletion review state: $value'),
    };
    final requestedAt = _dateTime(row['requested_at_utc']);
    if (requestedAt == null) throw const FormatException('Remote deletion review timestamp is invalid.');
    return RemoteAssetDeletionReview(
      sourceEventId: _string(row['source_event_id']),
      targetId: _string(row['target_id']),
      assetId: _string(row['asset_id']),
      blobSha256: _string(row['blob_sha256']),
      sourceDeletionId: _string(row['source_deletion_id']),
      requestedScope: _string(row['requested_scope']),
      sourceApprovalRef: _nullableString(row['source_approval_ref']),
      reason: _string(row['reason']),
      requestedAtUtc: requestedAt,
      sourceDeviceId: _string(row['device_id']),
      sourceSequence: _int(row['sequence']) ?? 0,
      status: status,
      localDeletionId: _nullableString(row['local_deletion_id']),
      reviewedAtUtc: _dateTime(row['reviewed_at_utc']),
      dismissedAtUtc: _dateTime(row['dismissed_at_utc']),
      resolutionNote: _nullableString(row['resolution_note']),
    );
  }

  static int? _int(Object? value) => value is int ? value : int.tryParse('$value');
  static String _string(Object? value) => value?.toString() ?? '';
  static String? _nullableString(Object? value) => value == null ? null : value.toString();
  static DateTime? _dateTime(Object? value) => value == null ? null : DateTime.tryParse(value.toString())?.toUtc();
  static Map<String, Object?> _decodeMap(String json) {
    if (json.isEmpty) return <String, Object?>{};
    try {
      final decoded = jsonDecode(json);
      if (decoded is Map<String, Object?>) return decoded;
      if (decoded is Map) return decoded.map((key, value) => MapEntry(key.toString(), value));
    } on FormatException {
      return <String, Object?>{};
    }
    return <String, Object?>{};
  }

  static List<Object?> _decodeList(String json) {
    if (json.isEmpty) return <Object?>[];
    try {
      final decoded = jsonDecode(json);
      return decoded is List ? decoded.cast<Object?>() : <Object?>[];
    } on FormatException {
      return <Object?>[];
    }
  }

  static Future<String> sha256Digest(File file) async =>
      (await sha256.bind(file.openRead()).first).toString();

}

extension _IterableFirstOrNull<E> on Iterable<E> {
  E? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
