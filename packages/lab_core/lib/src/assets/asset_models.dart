/// Public, platform-neutral value types for the local asset store.
///
/// Asset identifiers are device-independent strings. Blob identifiers are
/// lowercase SHA-256 digests; an Asset remains a separate logical record even
/// when it shares a blob with another Asset.
library;

import 'dart:typed_data';

typedef AssetId = String;
typedef BlobSha256 = String;
typedef DeletionId = String;
typedef AssetFolderId = String;

enum AssetKind {
  raw,
  derived,
  report,
  thumbnail,
  export;

  String get wireValue => name;

  static AssetKind parse(String value) => AssetKind.values.firstWhere(
        (kind) => kind.name == value,
        orElse: () => throw FormatException('Unsupported asset kind: $value'),
      );
}

enum AssetIntegrityStatus {
  verified,
  quickChecked,
  overdue,
  mismatch,
  missing,
  pending;

  String get wireValue => switch (this) {
        AssetIntegrityStatus.quickChecked => 'quick_checked',
        AssetIntegrityStatus.overdue => 'overdue',
        _ => name,
      };

  static AssetIntegrityStatus parse(String value) => switch (value) {
        'verified' => AssetIntegrityStatus.verified,
        'quick_checked' => AssetIntegrityStatus.quickChecked,
        'overdue' => AssetIntegrityStatus.overdue,
        'mismatch' => AssetIntegrityStatus.mismatch,
        'missing' => AssetIntegrityStatus.missing,
        'pending' => AssetIntegrityStatus.pending,
        _ => throw FormatException('Unsupported integrity status: $value'),
      };
}

/// How the bytes returned by one logical open were checked.
enum AssetValidationLevel {
  /// The bytes in the returned snapshot were hashed and matched the imported
  /// SHA-256. This is the only level that may be described as hash-verified.
  verified,

  /// The returned snapshot had matching file metadata, but was not hashed.
  /// This explicitly does not prove that the content is unchanged.
  quickChecked,
}

enum IntegrityCheckMode { fullSha256, metadataQuick, transferChecksum }

/// Metadata captured when the user chose a local source stream.
///
/// The source may be an OS-authorized picker URI, SAF stream, or an in-memory
/// generated file. Core never requires a `File` from the calling app.
final class AssetImportSource {
  const AssetImportSource({
    required this.displayName,
    required this.content,
    this.mediaType,
    this.sizeHint,
  });

  final String displayName;
  final String? mediaType;
  final int? sizeHint;
  final Stream<List<int>> content;
}

/// A typed link from an Asset to a domain entity such as a run, sample, or
/// calculation. The link is metadata only; it does not duplicate Blob bytes.
final class AssetLinkRef {
  const AssetLinkRef({
    required this.targetType,
    required this.targetId,
    required this.role,
    this.metadata = const <String, Object?>{},
  });

  final String targetType;
  final String targetId;
  final String role;
  final Map<String, Object?> metadata;
}

final class AssetRecord {
  const AssetRecord({
    required this.assetId,
    required this.blobSha256,
    required this.byteSize,
    required this.displayName,
    required this.kind,
    required this.createdAtUtc,
    required this.integrityStatus,
    required this.integrityThresholdBytes,
    this.mediaType,
    this.parentAssetId,
    this.deletedAtUtc,
    this.lastFullVerifiedAtUtc,
    this.lastFastCheckedAtUtc,
    this.lastKnownMtimeNs,
    this.lastKnownFileId,
    this.metadata = const <String, Object?>{},
  });

  final AssetId assetId;
  final BlobSha256 blobSha256;
  final int byteSize;
  final String displayName;
  final String? mediaType;
  final AssetKind kind;
  final AssetId? parentAssetId;
  final DateTime createdAtUtc;
  final DateTime? deletedAtUtc;
  final AssetIntegrityStatus integrityStatus;
  final int integrityThresholdBytes;
  final DateTime? lastFullVerifiedAtUtc;
  final DateTime? lastFastCheckedAtUtc;
  final int? lastKnownMtimeNs;
  final String? lastKnownFileId;
  final Map<String, Object?> metadata;

  bool get isDeleted => deletedAtUtc != null;
  bool get isLarge => byteSize > integrityThresholdBytes;
}

final class AssetImportResult {
  const AssetImportResult({required this.asset, required this.reusedBlob});

  final AssetRecord asset;
  final bool reusedBlob;
}

/// An opaque, verified snapshot of a CAS object for one read operation.
///
/// [openRead] must read the same temporary snapshot whose integrity level was
/// established by `AssetGateway.open`; the underlying CAS path is never
/// exposed to callers. Callers must `close` when finished.
final class AssetOpenHandle {
  const AssetOpenHandle({
    required this.asset,
    required this.validationLevel,
    required Stream<List<int>> Function() openRead,
    required Future<void> Function() close,
  })  : _openRead = openRead,
        _close = close;

  final AssetRecord asset;
  final AssetValidationLevel validationLevel;
  final Stream<List<int>> Function() _openRead;
  final Future<void> Function() _close;

  String get validationDescription => switch (validationLevel) {
        AssetValidationLevel.verified => 'Full SHA-256 verification passed for this read.',
        AssetValidationLevel.quickChecked =>
          'Metadata quick check passed; this is not SHA-256 verification.',
      };

  Stream<List<int>> openRead() => _openRead();
  Future<void> close() => _close();
}

/// A stream adapter used by the file Explorer and native Open/Share adapters.
/// It is intentionally bounded and does not expose a path to an arbitrary
/// caller. `readAll` is suitable only for already size-limited previews.
extension AssetOpenHandleBytes on AssetOpenHandle {
  Future<Uint8List> readAll({required int maxBytes}) async {
    if (asset.byteSize > maxBytes) {
      throw StateError('Asset exceeds the requested in-memory read limit.');
    }
    final output = BytesBuilder(copy: false);
    await for (final chunk in openRead()) {
      output.add(chunk);
    }
    final bytes = output.takeBytes();
    if (bytes.length != asset.byteSize) {
      throw StateError('Asset snapshot size changed while it was read.');
    }
    return bytes;
  }
}

enum VirtualFolderKind {
  all,
  raw,
  derived,
  reports,
  orphans,
  recent,
  localOnly,
  remoteOnly,
  integrityWarnings,
  trash,
  custom,
}

final class ExplorerQuery {
  const ExplorerQuery({
    this.folder = VirtualFolderKind.all,
    this.customFolderId,
    this.searchText,
    this.kind,
    this.minimumBytes,
    this.maximumBytes,
    this.createdAfterUtc,
    this.createdBeforeUtc,
    this.targetType,
    this.targetId,
    this.largeOnly = false,
    this.pageSize = 100,
    this.pageOffset = 0,
  });

  final VirtualFolderKind folder;
  final AssetFolderId? customFolderId;
  final String? searchText;
  final AssetKind? kind;
  final int? minimumBytes;
  final int? maximumBytes;
  final DateTime? createdAfterUtc;
  final DateTime? createdBeforeUtc;
  final String? targetType;
  final String? targetId;
  final bool largeOnly;
  final int pageSize;
  final int pageOffset;
}

final class ExplorerAsset {
  const ExplorerAsset({
    required this.asset,
    required this.activeLinkCount,
    required this.referenceLabels,
    required this.remoteReplicaStates,
    required this.retainedBackupCount,
  });

  final AssetRecord asset;
  final int activeLinkCount;
  final List<String> referenceLabels;
  final Map<String, String> remoteReplicaStates;
  final int retainedBackupCount;
}

final class ExplorerPage {
  const ExplorerPage({
    required this.items,
    required this.totalCount,
    required this.pageSize,
    required this.pageOffset,
  });

  final List<ExplorerAsset> items;
  final int totalCount;
  final int pageSize;
  final int pageOffset;
}

final class IntegrityResult {
  const IntegrityResult({
    required this.assetId,
    required this.blobSha256,
    required this.mode,
    required this.status,
    required this.checkedAtUtc,
    required this.bytesChecked,
    this.actualSha256,
    this.message,
  });

  final AssetId assetId;
  final BlobSha256 blobSha256;
  final IntegrityCheckMode mode;
  final AssetIntegrityStatus status;
  final DateTime checkedAtUtc;
  final int bytesChecked;
  final String? actualSha256;
  final String? message;

  bool get isCryptographicallyVerified =>
      mode == IntegrityCheckMode.fullSha256 &&
      status == AssetIntegrityStatus.verified;
}

final class AssetReferenceImpact {
  const AssetReferenceImpact({
    required this.targetType,
    required this.targetId,
    required this.role,
    this.displayLabel,
  });

  final String targetType;
  final String targetId;
  final String role;
  final String? displayLabel;
}

final class DeletionImpact {
  const DeletionImpact({
    required this.assetId,
    required this.blobSha256,
    required this.logicalBytes,
    required this.reclaimablePhysicalBytes,
    required this.activeLinks,
    required this.otherActiveAssetsSharingBlob,
    required this.trashAssetsSharingBlob,
    required this.retainedBackupCount,
    required this.remoteReplicaStates,
    required this.activeLeaseCount,
    required this.pendingSyncTombstones,
    required this.purgeEligibleNow,
  });

  final AssetId assetId;
  final BlobSha256 blobSha256;
  final int logicalBytes;
  final int reclaimablePhysicalBytes;
  final List<AssetReferenceImpact> activeLinks;
  final List<AssetId> otherActiveAssetsSharingBlob;
  final List<AssetId> trashAssetsSharingBlob;
  final int retainedBackupCount;
  final Map<String, String> remoteReplicaStates;
  final int activeLeaseCount;
  final bool pendingSyncTombstones;
  final bool purgeEligibleNow;

  bool get requiresRiskConfirmation => activeLinks.isNotEmpty;
}

final class StorageUsage {
  const StorageUsage({
    required this.logicalBytes,
    required this.uniqueBlobBytes,
    required this.trashBytes,
    required this.cacheBytes,
    required this.remoteOnlyBytes,
    required this.backupBytes,
    required this.blobCount,
    required this.assetCount,
    required this.trashAssetCount,
  });

  final int logicalBytes;
  final int uniqueBlobBytes;
  final int trashBytes;
  final int cacheBytes;
  final int remoteOnlyBytes;
  final int backupBytes;
  final int blobCount;
  final int assetCount;
  final int trashAssetCount;
}

final class AssetTrashRequest {
  const AssetTrashRequest({
    required this.assetId,
    required this.approvalRef,
    required this.reason,
    this.commandId,
    this.sourceEventId,
  });

  final AssetId assetId;
  final String approvalRef;
  final String reason;
  final String? commandId;
  final String? sourceEventId;
}

final class AssetPurgeRequest {
  const AssetPurgeRequest({
    required this.assetId,
    required this.approvalRef,
    required this.reason,
    this.commandId,
  });

  final AssetId assetId;
  final String approvalRef;
  final String reason;
  final String? commandId;
}

enum RemoteAssetDeletionReviewStatus { pending, accepted, rejected, auditOnly }

/// A remote delete request retained for an explicit decision on this device.
/// [sourceApprovalRef] is immutable provenance from the source event only; it
/// is never an authorization token for this device.
final class RemoteAssetDeletionReview {
  const RemoteAssetDeletionReview({
    required this.sourceEventId,
    required this.targetId,
    required this.assetId,
    required this.blobSha256,
    required this.sourceDeletionId,
    required this.requestedScope,
    required this.reason,
    required this.requestedAtUtc,
    required this.sourceDeviceId,
    required this.sourceSequence,
    required this.status,
    this.sourceApprovalRef,
    this.localDeletionId,
    this.reviewedAtUtc,
    this.dismissedAtUtc,
    this.resolutionNote,
  });

  final String sourceEventId;
  final String targetId;
  final AssetId assetId;
  final BlobSha256 blobSha256;
  final DeletionId sourceDeletionId;
  final String requestedScope;
  final String? sourceApprovalRef;
  final String reason;
  final DateTime requestedAtUtc;
  final String sourceDeviceId;
  final int sourceSequence;
  final RemoteAssetDeletionReviewStatus status;
  final DeletionId? localDeletionId;
  final DateTime? reviewedAtUtc;
  final DateTime? dismissedAtUtc;
  final String? resolutionNote;

  bool get isTrashRequest => requestedScope == 'trash';
  bool get isPurgeAudit => requestedScope == 'purge' &&
      status == RemoteAssetDeletionReviewStatus.auditOnly;
  bool get canAccept => isTrashRequest &&
      status == RemoteAssetDeletionReviewStatus.pending;
}

final class AssetIntegrityException implements Exception {
  const AssetIntegrityException({
    required this.assetId,
    required this.expectedSha256,
    required this.actualSha256,
  });

  final AssetId assetId;
  final String expectedSha256;
  final String actualSha256;

  @override
  String toString() =>
      'ASSET_SHA_MISMATCH: $assetId expected $expectedSha256 but found $actualSha256';
}

final class AssetMissingException implements Exception {
  const AssetMissingException(this.assetId);

  final AssetId assetId;

  @override
  String toString() => 'ASSET_REMOTE_MISSING: local Blob for $assetId is missing';
}

final class AssetConfirmationRequiredException implements Exception {
  const AssetConfirmationRequiredException(this.impact);

  final DeletionImpact impact;

  @override
  String toString() => 'ASSET_REFERENCED_DELETE_REVIEW: ${impact.assetId}';
}
