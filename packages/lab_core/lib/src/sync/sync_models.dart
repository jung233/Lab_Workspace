import '../domain/security.dart';

typedef SyncTargetId = String;

enum SyncProvider { oneDrive, s3 }

enum RemoteEncryptionMode { none, encryptMetadata, encryptAll, custom }

enum LargeUploadPolicy { manual, wifiOnly, automatic, off }

enum SyncTargetState {
  ready,
  credentialRequired,
  keyRequired,
  disabled,
  unavailable,
  error,
}

/// Native Microsoft Identity adapter for a separate Files-scoped OneDrive
/// authorization. Implementations read and rotate tokens through SecretStore;
/// SQLite stores only the [SecretRef].
abstract interface class OneDriveAccessTokenProvider {
  Future<String?> accessToken(SecretRef credentialRef);
}

final class RemoteEncryptionPolicy {
  const RemoteEncryptionPolicy({
    this.mode = RemoteEncryptionMode.none,
    this.encryptMetadata = false,
    this.encryptSmallFiles = false,
    this.encryptLargeFiles = false,
    this.keyRef,
    this.largeFileThresholdBytes = 64 * 1024 * 1024,
  });

  final RemoteEncryptionMode mode;
  final bool encryptMetadata;
  final bool encryptSmallFiles;
  final bool encryptLargeFiles;
  final SecretRef? keyRef;
  final int largeFileThresholdBytes;

  bool encryptsObject({required bool metadata, required int byteSize}) {
    if (metadata) {
      return encryptMetadata || mode == RemoteEncryptionMode.encryptMetadata ||
          mode == RemoteEncryptionMode.encryptAll;
    }
    if (mode == RemoteEncryptionMode.encryptAll) return true;
    if (mode == RemoteEncryptionMode.encryptMetadata) return false;
    return byteSize >= largeFileThresholdBytes
        ? encryptLargeFiles
        : encryptSmallFiles;
  }

  Map<String, Object?> toJson() => {
        'mode': mode.name,
        'encrypt_metadata': encryptMetadata,
        'encrypt_small_files': encryptSmallFiles,
        'encrypt_large_files': encryptLargeFiles,
        'key_id': keyRef?.value,
        'large_file_threshold_bytes': largeFileThresholdBytes,
      };

  factory RemoteEncryptionPolicy.fromJson(Map<String, Object?> json) {
    final modeName = json['mode'] as String? ?? 'none';
    return RemoteEncryptionPolicy(
      mode: RemoteEncryptionMode.values.firstWhere(
        (value) => value.name == modeName,
        orElse: () => throw FormatException('Unsupported encryption mode: $modeName'),
      ),
      encryptMetadata: json['encrypt_metadata'] == true,
      encryptSmallFiles: json['encrypt_small_files'] == true,
      encryptLargeFiles: json['encrypt_large_files'] == true,
      keyRef: json['key_id'] is String ? SecretRef(json['key_id']! as String) : null,
      largeFileThresholdBytes: _intValue(
        json['large_file_threshold_bytes'],
        fallback: 64 * 1024 * 1024,
      ),
    );
  }
}

final class SyncTarget {
  const SyncTarget({
    required this.targetId,
    required this.epoch,
    required this.provider,
    required this.displayName,
    required this.encryption,
    required this.largeUploadPolicy,
    required this.syncEnabled,
    required this.backupEnabled,
    required this.state,
    this.secretRef,
    this.encryptionSecretRef,
    this.expectedEncryptionKeyFingerprint,
    this.endpoint,
    this.region,
    this.bucket,
    this.driveId,
    this.lastVerifiedAtUtc,
    this.lastError,
  });

  final SyncTargetId targetId;
  final int epoch;
  final SyncProvider provider;
  final String displayName;
  final RemoteEncryptionPolicy encryption;
  final LargeUploadPolicy largeUploadPolicy;
  final bool syncEnabled;
  final bool backupEnabled;
  final SyncTargetState state;
  final SecretRef? secretRef;
  /// Local SecretStore locator used for this epoch's encryption key. For an
  /// authorized historical epoch this can differ from the immutable key id in
  /// [encryption], because restored installations must save the key again.
  final SecretRef? encryptionSecretRef;
  final String? expectedEncryptionKeyFingerprint;
  final String? endpoint;
  final String? region;
  final String? bucket;
  final String? driveId;
  final DateTime? lastVerifiedAtUtc;
  final String? lastError;
}

/// Local view of an immutable remote policy epoch and its current-installation
/// authorization state. Secret references from an older authority generation
/// are never executable; a fresh overlay is required to read that epoch.
final class SyncHistoricalEpoch {
  const SyncHistoricalEpoch({
    required this.target,
    required this.recordedAuthorityGeneration,
    required this.currentAuthorityGeneration,
    required this.endpointFingerprint,
    required this.historicalKeyId,
    required this.requiresReauthorization,
    this.reauthorizationReason,
    this.authorizedKeyFingerprint,
  });

  final SyncTarget target;
  final int recordedAuthorityGeneration;
  final int currentAuthorityGeneration;
  final String endpointFingerprint;
  final String? historicalKeyId;
  final bool requiresReauthorization;
  final String? reauthorizationReason;
  final String? authorizedKeyFingerprint;

  String get targetId => target.targetId;
  int get epoch => target.epoch;
  SyncProvider get provider => target.provider;
  bool get requiresEncryptionKey => historicalKeyId != null;
}

/// Immutable policy pointer stored beside a remote backup. It contains only
/// the historical epoch and key reference; credential and encryption key
/// bytes remain in the platform SecretStore.
final class RemoteBackupManifest {
  const RemoteBackupManifest({
    required this.backupId,
    required this.vaultId,
    required this.targetId,
    required this.targetEpoch,
    required this.createdAtUtc,
    required this.sourceManifestSha256,
    required this.encryption,
    this.credentialRef,
  });

  final String backupId;
  final String vaultId;
  final SyncTargetId targetId;
  final int targetEpoch;
  final DateTime createdAtUtc;
  final String sourceManifestSha256;
  final RemoteEncryptionPolicy encryption;
  final SecretRef? credentialRef;

  String get encryptionAlgorithm => _hasEncryption(encryption) ? 'LWAE/1' : 'none';

  SecretRef? get keyRef => _hasEncryption(encryption) ? encryption.keyRef : null;

  Map<String, Object?> toJson() => {
        'schema_version': 'remote-backup-manifest-v1',
        'backup_id': backupId,
        'vault_id': vaultId,
        'target_id': targetId,
        'target_epoch': targetEpoch,
        'created_at_utc': createdAtUtc.toUtc().toIso8601String(),
        'source_manifest_sha256': sourceManifestSha256,
        'encryption_algorithm': encryptionAlgorithm,
        'key_ref': keyRef?.value,
        'target_encryption_policy': encryption.toJson(),
      };

  factory RemoteBackupManifest.fromJson(Map<String, Object?> json) {
    if (json['schema_version'] != 'remote-backup-manifest-v1') {
      throw const FormatException('Unsupported remote backup manifest schema.');
    }
    final policyValue = json['target_encryption_policy'];
    if (policyValue is! Map<String, Object?>) {
      throw const FormatException('Remote backup encryption policy is invalid.');
    }
    final encryption = RemoteEncryptionPolicy.fromJson(policyValue);
    final algorithm = json['encryption_algorithm'];
    final expectedAlgorithm = _hasEncryption(encryption) ? 'LWAE/1' : 'none';
    final expectedKeyRef = _hasEncryption(encryption) ? encryption.keyRef?.value : null;
    if (algorithm != expectedAlgorithm || json['key_ref'] != expectedKeyRef) {
      throw const FormatException('Remote backup encryption identity does not match its policy.');
    }
    final sha = json['source_manifest_sha256'];
    if (sha is! String || !RegExp(r'^[a-f0-9]{64}$').hasMatch(sha)) {
      throw const FormatException('Remote backup manifest SHA-256 is invalid.');
    }
    final backupId = json['backup_id'];
    final vaultId = json['vault_id'];
    final targetId = json['target_id'];
    final epoch = json['target_epoch'];
    if (backupId is! String || !_safeId(backupId) ||
        vaultId is! String || !_safeId(vaultId) ||
        targetId is! String || !_safeId(targetId) ||
        epoch is! int || epoch < 1) {
      throw const FormatException('Remote backup identity or target epoch is invalid.');
    }
    final credentialRef = json['credential_ref'];
    if (credentialRef != null && credentialRef is! String) {
      throw const FormatException('Remote backup credential reference is invalid.');
    }
    return RemoteBackupManifest(
      backupId: backupId,
      vaultId: vaultId,
      targetId: targetId,
      targetEpoch: epoch,
      createdAtUtc: DateTime.parse(json['created_at_utc'] as String).toUtc(),
      sourceManifestSha256: sha,
      encryption: encryption,
      credentialRef: credentialRef is String ? SecretRef(credentialRef) : null,
    );
  }
}

bool _hasEncryption(RemoteEncryptionPolicy policy) =>
    policy.mode == RemoteEncryptionMode.encryptMetadata ||
    policy.mode == RemoteEncryptionMode.encryptAll || policy.encryptMetadata ||
    policy.encryptSmallFiles || policy.encryptLargeFiles;

bool _safeId(String value) =>
    value.isNotEmpty && value.length <= 128 && RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(value);

final class SyncPreview {
  const SyncPreview({
    required this.target,
    required this.pendingEvents,
    required this.pendingBlobs,
    required this.incomingEvents,
    required this.openConflicts,
    required this.bytesToUpload,
    required this.bytesToDownload,
    required this.warnings,
  });

  final SyncTarget target;
  final int pendingEvents;
  final int pendingBlobs;
  final int incomingEvents;
  final int openConflicts;
  final int bytesToUpload;
  final int bytesToDownload;
  final List<String> warnings;
  bool get canRun => target.state == SyncTargetState.ready;
}

final class SyncRunResult {
  const SyncRunResult({
    required this.targetId,
    required this.state,
    required this.eventsUploaded,
    required this.eventsReceived,
    required this.eventsApplied,
    required this.eventsPendingReview,
    required this.eventsBlocked,
    required this.blobsUploaded,
    required this.blobsReceived,
    required this.conflictsPreserved,
    required this.bytesTransferred,
    required this.completedAtUtc,
    this.warnings = const [],
    this.error,
  });

  final SyncTargetId targetId;
  final String state;
  final int eventsUploaded;
  final int eventsReceived;
  final int eventsApplied;
  final int eventsPendingReview;
  final int eventsBlocked;
  final int blobsUploaded;
  final int blobsReceived;
  final int conflictsPreserved;
  final int bytesTransferred;
  final DateTime completedAtUtc;
  final List<String> warnings;
  final String? error;
  bool get succeeded => state == 'complete';
}

final class RemoteObject {
  const RemoteObject({required this.key, required this.byteSize, this.etag});

  final String key;
  final int byteSize;
  final String? etag;
}

final class SyncCredentialRequiredException implements Exception {
  const SyncCredentialRequiredException(this.provider);
  final SyncProvider provider;
  @override
  String toString() => 'CREDENTIAL_REQUIRED: ${provider.name} credentials are unavailable.';
}

final class SyncKeyRequiredException implements Exception {
  const SyncKeyRequiredException(this.keyRef);
  final SecretRef? keyRef;
  @override
  String toString() => 'ENCRYPTION_KEY_REQUIRED: a configured remote key is unavailable.';
}

int _intValue(Object? value, {required int fallback}) => switch (value) {
      int number => number,
      BigInt number => number.toInt(),
      _ => fallback,
    };
