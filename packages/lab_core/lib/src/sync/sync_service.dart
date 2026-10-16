import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../assets/asset_gateway.dart';
import '../assets/asset_models.dart';
import '../assets/asset_remote_event_projection.dart';
import '../application/event_application_service.dart';
import '../backup/chunked_aes_gcm.dart';
import '../backup/backup_models.dart';
import '../calculation/remote_calculation_projection.dart';
import '../domain/commands.dart';
import '../domain/events.dart';
import '../domain/ids.dart';
import '../domain/json_value.dart';
import '../domain/security.dart';
import '../domain/vault.dart';
import '../persistence/workspace_database.dart';
import 'remote_object_connectors.dart';
import 'sync_models.dart';

/// Device-local synchronization coordinator. It exchanges immutable v2/v3 event
/// envelopes and SHA-addressed blobs. Safe core events are projected through
/// EventApplicationService; conflicts and unsupported events remain in inbox.
final class SyncService implements BackupRemoteTransfer {
  SyncService({
    required VaultContext vault,
    required AssetGateway assets,
    SecretStore? secrets,
    OneDriveAccessTokenProvider? oneDriveTokenProvider,
    ChunkedAesGcm? encryption,
    DateTime Function()? clock,
  })  : _vault = vault,
        _assets = assets,
        _eventApplication = EventApplicationService(
          vault,
          handlers: [
            AssetRemoteEventProjectionHandler(),
            CalculationRemoteEventProjection(),
          ],
        ),
        _secrets = secrets,
        _oneDriveTokenProvider = oneDriveTokenProvider,
        _encryption = encryption ?? ChunkedAesGcm(),
        _clock = clock ?? DateTime.now;

  final VaultContext _vault;
  final AssetGateway _assets;
  final EventApplicationService _eventApplication;
  final SecretStore? _secrets;
  final OneDriveAccessTokenProvider? _oneDriveTokenProvider;
  final ChunkedAesGcm _encryption;
  final DateTime Function() _clock;

  Future<List<SyncTarget>> listTargets() async {
    final rows = _vault.database.query(
      'SELECT * FROM remote_targets ORDER BY created_at_utc,target_id',
    );
    final result = <SyncTarget>[];
    for (final row in rows) {
      result.add(await _targetFromRow(row));
    }
    return result;
  }

  /// Lists the append-only target policy history. Each row can locate and
  /// decrypt only its own immutable remote epoch; old SecretRefs remain
  /// explicit dependencies until the corresponding backups are retired.
  Future<List<SyncTarget>> listTargetEpochs({required String targetId}) async {
    final rows = _vault.database.query(
      'SELECT target_id,epoch,policy_json,secret_ref,authority_generation FROM remote_target_epochs '
      'WHERE target_id=? ORDER BY epoch DESC',
      [targetId],
    );
    final epochs = <SyncTarget>[];
    for (final row in rows) {
      epochs.add(await _targetFromEpochRow(row));
    }
    return List<SyncTarget>.unmodifiable(epochs);
  }

  /// Lists policy history with the current installation's authorization state.
  /// A stale epoch is shown as unavailable until the user saves fresh local
  /// credentials and, when needed, the historical encryption key.
  Future<List<SyncHistoricalEpoch>> listHistoricalEpochs({required String targetId}) async {
    final rows = _vault.database.query(
      'SELECT target_id,epoch,policy_json,secret_ref,authority_generation FROM remote_target_epochs '
      'WHERE target_id=? ORDER BY epoch DESC',
      [targetId],
    );
    final result = <SyncHistoricalEpoch>[];
    for (final row in rows) {
      final target = await _targetFromEpochRow(row);
      final policy = jsonDecode(row['policy_json'] as String) as Map<String, Object?>;
      final generation = _asInt(row['authority_generation']);
      final endpointFingerprint = _endpointFingerprint(
        targetId: targetId,
        epoch: _asInt(row['epoch']),
        provider: target.provider,
        policy: policy,
      );
      final latestAuthorization = _epochAuthorizationRow(targetId, target.epoch);
      final validAuthorization = latestAuthorization != null && _authorizationMatches(
        latestAuthorization,
        targetId,
        target.epoch,
        target.provider,
        policy,
      );
      final needsAuthorization =
          target.state == SyncTargetState.credentialRequired ||
          target.state == SyncTargetState.keyRequired ||
          (generation != _vault.database.authorityGeneration && !validAuthorization);
      result.add(SyncHistoricalEpoch(
        target: target,
        recordedAuthorityGeneration: generation,
        currentAuthorityGeneration: _vault.database.authorityGeneration,
        endpointFingerprint: endpointFingerprint,
        historicalKeyId: target.encryption.keyRef?.value,
        requiresReauthorization: needsAuthorization,
        reauthorizationReason: needsAuthorization
            ? (validAuthorization
                ? target.state == SyncTargetState.credentialRequired
                    ? 'The newly authorized credential is unavailable or malformed in local SecretStore.'
                    : 'The newly authorized encryption key is unavailable or does not match its approved fingerprint.'
                : _authorizationFailureReason(
                    latestAuthorization,
                    targetId,
                    target.epoch,
                    target.provider,
                    policy,
                  ))
            : null,
        authorizedKeyFingerprint: validAuthorization
            ? latestAuthorization['key_fingerprint'] as String?
            : null,
      ));
    }
    return List<SyncHistoricalEpoch>.unmodifiable(result);
  }

  /// Computes the exact local-approval scope for explicit historical epoch
  /// reauthorization. The returned scope contains identifiers and fingerprints,
  /// never credential or encryption-key bytes.
  Future<Map<String, Object?>> historicalEpochAuthorizationScope({
    required String targetId,
    required int epoch,
    required SecretRef credentialRef,
    SecretRef? encryptionSecretRef,
  }) async {
    final record = _historicalEpochRecord(targetId, epoch);
    final policy = jsonDecode(record['policy_json'] as String) as Map<String, Object?>;
    final provider = _providerFromPolicy(policy);
    final oldCredentialRef = record['secret_ref'] as String?;
    if (credentialRef.value == oldCredentialRef) {
      throw StateError('SYNC_EPOCH_REAUTH_REQUIRES_FRESH_CREDENTIAL: save a new local credential reference.');
    }
    final credential = await _readAndValidateCredential(credentialRef, provider, policy);
    credential.fillRange(0, credential.length, 0);

    final encryption = _encryptionFromPolicy(policy);
    final encrypted = _policyRequiresEncryption(encryption);
    final historicalKeyId = encryption.keyRef?.value;
    String? keyFingerprint;
    if (encrypted) {
      if (historicalKeyId == null || encryptionSecretRef == null) {
        throw StateError('SYNC_EPOCH_KEY_REQUIRED: this historical epoch needs its original encryption key.');
      }
      if (encryptionSecretRef.value == historicalKeyId) {
        throw StateError('SYNC_EPOCH_REAUTH_REQUIRES_FRESH_KEY: save the historical key under a new local reference.');
      }
      keyFingerprint = await _secretFingerprint(encryptionSecretRef);
    } else if (encryptionSecretRef != null) {
      throw ArgumentError.value(encryptionSecretRef, 'encryptionSecretRef', 'This epoch has no encryption-key dependency.');
    }
    return <String, Object?>{
      'target_id': targetId,
      'epoch': epoch,
      'provider': _providerName(provider),
      'endpoint_fingerprint': _endpointFingerprint(
        targetId: targetId,
        epoch: epoch,
        provider: provider,
        policy: policy,
      ),
      'key_id': historicalKeyId,
      'key_fingerprint': keyFingerprint,
    };
  }

  /// Adds an immutable local authorization overlay for a historical epoch.
  /// The approval must have been issued on this installation for the exact
  /// scope returned by [historicalEpochAuthorizationScope].
  Future<SyncHistoricalEpoch> reauthorizeHistoricalEpoch({
    required String targetId,
    required int epoch,
    required SecretRef credentialRef,
    SecretRef? encryptionSecretRef,
    required ApprovalRef approvalRef,
    String? commandId,
  }) async {
    final scope = await historicalEpochAuthorizationScope(
      targetId: targetId,
      epoch: epoch,
      credentialRef: credentialRef,
      encryptionSecretRef: encryptionSecretRef,
    );
    final now = _clock().toUtc();
    final actualCommandId = commandId ?? newUuidV7(at: now);
    final providerName = scope['provider'] as String;
    final credential = credentialRef.value;
    final keyRef = encryptionSecretRef?.value;
    final generation = _vault.database.authorityGeneration;
    final authorizationId = newUuidV7(at: now);
    _vault.database.transaction((tx) {
      final priorCommand = tx.query(
        'SELECT provider,endpoint_fingerprint,key_id,key_fingerprint,credential_secret_ref,'
        'encryption_secret_ref,approval_ref FROM remote_target_epoch_authorizations '
        'WHERE target_id=? AND epoch=? AND authority_generation=? AND command_id=?',
        [targetId, epoch, generation, actualCommandId],
      );
      if (priorCommand.isNotEmpty) {
        final row = priorCommand.single;
        if (row['provider'] == providerName &&
            row['endpoint_fingerprint'] == scope['endpoint_fingerprint'] &&
            row['key_id'] == scope['key_id'] &&
            row['key_fingerprint'] == scope['key_fingerprint'] &&
            row['credential_secret_ref'] == credential &&
            row['encryption_secret_ref'] == keyRef &&
            row['approval_ref'] == approvalRef.value) {
          return null;
        }
        throw StateError('SYNC_EPOCH_AUTHORIZATION_COMMAND_REUSED: use a new command and approval for a reauthorization.');
      }
      final latestRevision = tx.query(
        'SELECT COALESCE(MAX(authorization_revision),0) AS revision FROM remote_target_epoch_authorizations '
        'WHERE target_id=? AND epoch=? AND authority_generation=?',
        [targetId, epoch, generation],
      );
      tx.requireApproval(
        approvalRef: approvalRef,
        action: 'sync.epoch.reauthorize',
        subjectType: 'remote_target_epoch',
        subjectId: '$targetId@$epoch',
        atUtc: now,
        requiredScope: scope,
      );
      final revision = _asInt(latestRevision.single['revision']) + 1;
      tx.execute(
        '''INSERT INTO remote_target_epoch_authorizations
           (authorization_id,target_id,epoch,authority_generation,authorization_revision,
            provider,endpoint_fingerprint,key_id,key_fingerprint,
            credential_secret_ref,encryption_secret_ref,approval_ref,authorized_at_utc,command_id)
           VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)''',
        [authorizationId, targetId, epoch, generation, revision, providerName,
          scope['endpoint_fingerprint'], scope['key_id'],
          scope['key_fingerprint'], credential, keyRef, approvalRef.value,
          now.toIso8601String(), actualCommandId],
      );
      return null;
    });
    return (await listHistoricalEpochs(targetId: targetId))
        .singleWhere((item) => item.epoch == epoch);
  }

  /// Reads immutable backup catalog descriptors across retained policy epochs.
  /// Catalog entries use AEAD whenever metadata encryption is enabled, so an
  /// encrypted catalog needs its historical epoch key to reveal backup IDs.
  Future<List<RemoteBackupManifest>> listRemoteBackups({
    required String targetId,
    int? targetEpoch,
  }) async {
    var targets = await listTargetEpochs(targetId: targetId);
    if (targets.isEmpty) {
      final current = _targetRow(targetId);
      if (current != null) targets = [await _targetFromRow(current)];
    }
    if (targetEpoch != null) {
      targets = targets.where((target) => target.epoch == targetEpoch).toList(growable: false);
    }
    if (targets.isEmpty) {
      throw StateError('SYNC_EPOCH_METADATA_MISSING: no matching policy epoch is recorded.');
    }
    final manifests = <RemoteBackupManifest>[];
    for (final target in targets) {
      ({RemoteObjectConnector connector, Uint8List? encryptionKey})? opened;
      try {
        opened = await _openConnector(target, requireEncryptionKey: false);
        final entries = await opened.connector.list(_backupCatalogPrefix(target));
        for (final entry in entries) {
          final bytes = await opened.connector.getBytes(entry.key, maximumBytes: 1024 * 1024);
          final encrypted = target.encryption.encryptsObject(metadata: true, byteSize: bytes.length);
          if (encrypted && opened.encryptionKey == null) {
            throw SyncKeyRequiredException(target.encryption.keyRef);
          }
          final clear = encrypted ? await _encryption.decryptBytes(bytes, opened.encryptionKey!) : bytes;
          final decoded = jsonDecode(utf8.decode(clear)) as Map<String, Object?>;
          final manifest = RemoteBackupManifest.fromJson(decoded);
          if (manifest.vaultId != _vault.vaultId ||
              manifest.targetId != target.targetId ||
              manifest.targetEpoch != target.epoch) {
            throw const FormatException('Remote backup catalog belongs to a different Vault or target epoch.');
          }
          manifests.add(manifest);
        }
      } on SyncCredentialRequiredException {
        if (targetEpoch != null) rethrow;
      } on SyncKeyRequiredException {
        if (targetEpoch != null) rethrow;
      } finally {
        final key = opened?.encryptionKey;
        if (key != null) key.fillRange(0, key.length, 0);
      }
    }
    manifests.sort((left, right) {
      final byDate = right.createdAtUtc.compareTo(left.createdAtUtc);
      if (byDate != 0) return byDate;
      final byEpoch = right.targetEpoch.compareTo(left.targetEpoch);
      return byEpoch != 0 ? byEpoch : left.backupId.compareTo(right.backupId);
    });
    return List<RemoteBackupManifest>.unmodifiable(manifests);
  }

  Future<SyncTarget> configureOneDrive({
    required String displayName,
    required SecretRef credentialRef,
    String? driveId,
    RemoteEncryptionPolicy encryption = const RemoteEncryptionPolicy(),
    LargeUploadPolicy largeUploadPolicy = LargeUploadPolicy.automatic,
    bool syncEnabled = true,
    bool backupEnabled = false,
    String? targetId,
    String? commandId,
  }) => _configure(
        provider: SyncProvider.oneDrive,
        displayName: displayName,
        secretRef: credentialRef,
        endpoint: null,
        region: null,
        bucket: null,
        driveId: driveId,
        encryption: encryption,
        largeUploadPolicy: largeUploadPolicy,
        syncEnabled: syncEnabled,
        backupEnabled: backupEnabled,
        targetId: targetId,
        commandId: commandId,
      );

  Future<SyncTarget> configureS3({
    required String displayName,
    required SecretRef credentialRef,
    required String endpoint,
    required String region,
    required String bucket,
    RemoteEncryptionPolicy encryption = const RemoteEncryptionPolicy(),
    LargeUploadPolicy largeUploadPolicy = LargeUploadPolicy.automatic,
    bool syncEnabled = true,
    bool backupEnabled = false,
    String? targetId,
    String? commandId,
  }) => _configure(
        provider: SyncProvider.s3,
        displayName: displayName,
        secretRef: credentialRef,
        endpoint: endpoint,
        region: region,
        bucket: bucket,
        driveId: null,
        encryption: encryption,
        largeUploadPolicy: largeUploadPolicy,
        syncEnabled: syncEnabled,
        backupEnabled: backupEnabled,
        targetId: targetId,
        commandId: commandId,
      );

  Future<void> removeTarget(String targetId, {String? commandId}) async {
    final row = _targetRow(targetId);
    if (row == null) return;
    final now = _clock().toUtc();
    final actualCommand = commandId ?? newUuidV7(at: now);
    final policy = jsonDecode(row['policy_json'] as String) as Map<String, Object?>;
    policy['sync'] = false;
    policy['backup'] = false;
    _vault.database.transaction((tx) {
      tx.execute(
        'UPDATE remote_targets SET policy_json=?,secret_ref=NULL,updated_at_utc=?,authority_generation=? WHERE target_id=?',
        [jsonEncode(policy), now.toIso8601String(), _vault.database.authorityGeneration, targetId],
      );
      tx.appendMutation(MutationEventDraft(
        command: CommandMetadata(commandId: actualCommand, utcTime: now),
        deviceId: _vault.deviceId,
        entityType: 'remote_target',
        entityId: targetId,
        eventType: 'sync.target.removed',
        action: MutationAction.tombstone,
        payloadJson: jsonEncode({'target_id': targetId}),
      ));
      return null;
    });
  }

  Future<SyncPreview> preview({required String targetId}) async {
    final row = _targetRow(targetId);
    if (row == null) throw StateError('SYNC_TARGET_MISSING: $targetId');
    final target = await _targetFromRow(row);
    final warnings = <String>[];
    final pendingRows = _vault.database.query(
      'SELECT o.outbox_id,o.payload_json FROM outbox o '
      'LEFT JOIN sync_outbox_targets s ON s.target_id=? AND s.event_id=o.outbox_id '
      "WHERE (s.event_id IS NULL OR s.state!='sent') "
      "AND COALESCE(json_extract(o.payload_json,'\$.entity_kind'),'')<>'approval' "
      "AND COALESCE(json_extract(o.payload_json,'\$.event_type'),'') NOT IN ('approval.issued','approval.revoked') "
      'ORDER BY o.next_attempt_at_utc,o.outbox_id',
      [targetId],
    );
    final refs = <String>{};
    var eventBytes = 0;
    for (final row in pendingRows) {
      final payload = jsonDecode(row['payload_json'] as String) as Map<String, Object?>;
      _validateSyncEnvelope(payload, _vault.vaultId);
      eventBytes += utf8.encode(jsonEncode(payload)).length;
      refs.addAll((payload['sha_refs'] as List<dynamic>).cast<String>());
    }
    var blobBytes = 0;
    for (final sha in refs) {
      final rows = _vault.database.query(
        'SELECT byte_size FROM blob_objects WHERE sha256=?',
        [sha],
      );
      if (rows.isNotEmpty) blobBytes += _asInt(rows.single['byte_size']);
    }
    var incomingCount = 0;
    var incomingBytes = 0;
    if (target.syncEnabled &&
        (target.state == SyncTargetState.ready || target.state == SyncTargetState.keyRequired)) {
      try {
        final connection = await _openConnector(target, requireEncryptionKey: false);
        try {
          final base = _remoteBase(target);
          final hiddenEvents = target.encryption.encryptsObject(metadata: true, byteSize: 1);
          final objects = await connection.connector.list(
            hiddenEvents ? '$base/events/opaque/' : '$base/events/',
          );
          incomingCount = objects.length;
          incomingBytes = objects.fold<int>(0, (sum, object) => sum + object.byteSize);
          if (hiddenEvents && connection.encryptionKey == null && objects.isNotEmpty) {
            warnings.add('Current epoch lists ${objects.length} opaque event objects; its metadata key is required to inspect or migrate them.');
          }
          final historical = await listTargetEpochs(targetId: targetId);
          for (final source in historical.where((item) => item.epoch < target.epoch)) {
            ({RemoteObjectConnector connector, Uint8List? encryptionKey})? oldConnection;
            try {
              oldConnection = await _openConnector(source, requireEncryptionKey: false);
              final oldHiddenEvents = source.encryption.encryptsObject(metadata: true, byteSize: 1);
              final oldObjects = await oldConnection.connector.list(
                oldHiddenEvents
                    ? '${_remoteBase(source)}/events/opaque/'
                    : '${_remoteBase(source)}/events/',
              );
              incomingCount += oldObjects.length;
              incomingBytes += oldObjects.fold<int>(0, (sum, object) => sum + object.byteSize);
              if (oldHiddenEvents && oldConnection.encryptionKey == null && oldObjects.isNotEmpty) {
                final prior = _vault.database.query(
                  '''SELECT state,verified_event_count,source_event_count,verified_blob_count,source_blob_count
                     FROM sync_epoch_migrations WHERE target_id=? AND source_epoch=? AND destination_epoch=?''',
                  [targetId, source.epoch, target.epoch],
                );
                final verifiedEvents = prior.isEmpty ? 0 : _asInt(prior.single['verified_event_count']);
                final sourceEvents = prior.isEmpty ? 0 : _asInt(prior.single['source_event_count']);
                final verifiedBlobs = prior.isEmpty ? 0 : _asInt(prior.single['verified_blob_count']);
                final sourceBlobs = prior.isEmpty ? 0 : _asInt(prior.single['source_blob_count']);
                warnings.add(
                  'Historical epoch ${source.epoch}: $verifiedEvents/$sourceEvents events and '
                  '$verifiedBlobs/$sourceBlobs blobs are readback-verified; ${oldObjects.length} opaque '
                  'event objects cannot be matched without the epoch key. Migration remains incomplete.',
                );
              }
            } on Object catch (error) {
              warnings.add('Historical epoch ${source.epoch} is not ready for migration: ${_safeError(error)}');
            } finally {
              final oldKey = oldConnection?.encryptionKey;
              if (oldKey != null) oldKey.fillRange(0, oldKey.length, 0);
            }
          }
        } finally {
          final key = connection.encryptionKey;
          if (key != null) key.fillRange(0, key.length, 0);
        }
        final incompleteMigrations = _vault.database.query(
          "SELECT source_epoch,state,verified_event_count,source_event_count,verified_blob_count,source_blob_count,last_error "
          "FROM sync_epoch_migrations WHERE target_id=? AND destination_epoch=? AND state!='completed' ORDER BY source_epoch",
          [targetId, target.epoch],
        );
        for (final migration in incompleteMigrations) {
          warnings.add(
            'Historical epoch ${migration['source_epoch']} migration is ${migration['state']} '
            '(${migration['verified_event_count']}/${migration['source_event_count']} events, '
            '${migration['verified_blob_count']}/${migration['source_blob_count']} blobs readback-verified): '
            '${migration['last_error'] ?? 'pending'}',
          );
        }
      } on Object catch (error) {
        warnings.add(_safeError(error));
      }
    }
    if (target.state == SyncTargetState.credentialRequired) {
      warnings.add('Credentials are unavailable. Reauthorize this destination in native settings.');
    }
    if (target.state == SyncTargetState.keyRequired) {
      warnings.add('The destination encryption key is unavailable; transfer is disabled until restored.');
    }
    final conflicts = _vault.database.query("SELECT COUNT(*) AS count FROM sync_conflicts WHERE state='open'");
    return SyncPreview(
      target: target,
      pendingEvents: pendingRows.length,
      pendingBlobs: refs.length,
      incomingEvents: incomingCount,
      openConflicts: _asInt(conflicts.single['count']),
      bytesToUpload: eventBytes + blobBytes,
      bytesToDownload: incomingBytes,
      warnings: List<String>.unmodifiable(warnings),
    );
  }

  Future<SyncRunResult> syncNow({required String targetId}) async {
    final startedAt = _clock().toUtc();
    final row = _targetRow(targetId);
    if (row == null) throw StateError('SYNC_TARGET_MISSING: $targetId');
    final target = await _targetFromRow(row);
    if (!target.syncEnabled) {
      return _runResult(targetId, 'disabled', startedAt, warnings: const ['Sync is disabled for this target.']);
    }
    if (target.state != SyncTargetState.ready) {
      return _runResult(
        targetId,
        target.state == SyncTargetState.keyRequired ? 'key_required' : 'credential_required',
        startedAt,
        warnings: [target.lastError ?? target.state.name],
      );
    }
    late final ({RemoteObjectConnector connector, Uint8List? encryptionKey}) opened;
    try {
      opened = await _openConnector(target);
    } on Object catch (error) {
      return _runResult(
        targetId,
        'credential_error',
        startedAt,
        warnings: [_safeError(error)],
      );
    }
    final connector = opened.connector;
    final keyBytes = opened.encryptionKey;
    final base = _remoteBase(target);
    var eventsUploaded = 0;
    var eventsReceived = 0;
    var eventsApplied = 0;
    var eventsPendingReview = 0;
    var eventsBlocked = 0;
    var blobsUploaded = 0;
    var blobsReceived = 0;
    var conflicts = 0;
    var transferred = 0;
    final warnings = <String>[];
    try {
      final epochMigration = await _migrateHistoricalEpochs(
        target: target,
        destinationConnector: connector,
        destinationBase: base,
        destinationKey: keyBytes,
      );
      eventsUploaded += epochMigration.eventsUploaded;
      eventsReceived += epochMigration.eventsReceived;
      blobsUploaded += epochMigration.blobsUploaded;
      blobsReceived += epochMigration.blobsReceived;
      transferred += epochMigration.bytesTransferred;
      warnings.addAll(epochMigration.warnings);

      final outgoing = _vault.database.query(
        'SELECT o.outbox_id,o.payload_json FROM outbox o '
        'LEFT JOIN sync_outbox_targets s ON s.target_id=? AND s.event_id=o.outbox_id '
        "WHERE (s.event_id IS NULL OR s.state!='sent') "
        "AND COALESCE(json_extract(o.payload_json,'\$.entity_kind'),'')<>'approval' "
        "AND COALESCE(json_extract(o.payload_json,'\$.event_type'),'') NOT IN ('approval.issued','approval.revoked') "
        'ORDER BY o.next_attempt_at_utc,o.outbox_id',
        [targetId],
      );
      for (final item in outgoing) {
        final eventId = item['outbox_id'] as String;
        try {
          final document = jsonDecode(item['payload_json'] as String) as Map<String, Object?>;
          _validateSyncEnvelope(document, _vault.vaultId);
          final refs = (document['sha_refs'] as List<dynamic>).cast<String>();
          for (final sha in refs.toSet()) {
            final result = await _uploadBlob(target, connector, base, sha, keyBytes);
            if (result.uploaded) blobsUploaded++;
            transferred += result.bytes;
          }
          final clearBytes = utf8.encode(jsonEncode(document));
          final metadataEncrypted = target.encryption.encryptsObject(metadata: true, byteSize: clearBytes.length);
          final wireBytes = metadataEncrypted
              ? await _encryption.encryptBytes(clearBytes, keyBytes!)
              : Uint8List.fromList(clearBytes);
          final key = metadataEncrypted
              ? '$base/events/opaque/${_opaqueDigest(keyBytes!, 'event:$eventId')}'
              : '$base/events/${document['device_id']}/${_padSequence(_asInt(document['seq']))}-$eventId.json';
          if (metadataEncrypted) {
            await _putVerifiedEncryptedEvent(
              connector,
              key,
              wireBytes,
              clearBytes,
              keyBytes!,
            );
          } else {
            await _putVerifiedBytes(connector, key, wireBytes);
          }
          transferred += wireBytes.length;
          _markEventSent(targetId, eventId, key, _clock().toUtc());
          if (document['entity_kind'] == 'asset' && document['action'] == 'tombstone') {
            _vault.database.execute(
              "UPDATE asset_sync_tombstone_acks SET state='acknowledged',acknowledged_at_utc=? "
              'WHERE asset_id=? AND target_id=? AND state="pending"',
              [_clock().toUtc().toIso8601String(), document['entity_id'], targetId],
            );
          }
          eventsUploaded++;
        } on Object catch (error) {
          _markEventFailed(targetId, eventId, _safeError(error), _clock().toUtc());
          warnings.add('Event $eventId was not sent: ${_safeError(error)}');
        }
      }

      final received = await _receiveEvents(target, connector, base, keyBytes);
      eventsReceived += received.events;
      transferred += received.bytes;
      warnings.addAll(received.warnings);

      final remoteBlobs = await _receiveReferencedBlobs(target, connector, base, keyBytes);
      blobsReceived += remoteBlobs.count;
      transferred += remoteBlobs.bytes;

      final application = _applyReceivedEvents(targetId);
      eventsApplied += application.applied;
      eventsPendingReview += application.pendingReview;
      eventsBlocked += application.blocked;
      conflicts += application.conflicts;

      _markGlobalOutboxSentIfAllTargetsDelivered();
      _vault.database.execute(
        'UPDATE remote_targets SET last_verified_at_utc=?,updated_at_utc=? WHERE target_id=?',
        [_clock().toUtc().toIso8601String(), _clock().toUtc().toIso8601String(), targetId],
      );
      return SyncRunResult(
        targetId: targetId,
        state: warnings.isEmpty ? 'complete' : 'partial',
        eventsUploaded: eventsUploaded,
        eventsReceived: eventsReceived,
        eventsApplied: eventsApplied,
        eventsPendingReview: eventsPendingReview,
        eventsBlocked: eventsBlocked,
        blobsUploaded: blobsUploaded,
        blobsReceived: blobsReceived,
        conflictsPreserved: conflicts,
        bytesTransferred: transferred,
        completedAtUtc: _clock().toUtc(),
        warnings: List<String>.unmodifiable(warnings),
      );
    } on Object catch (error) {
      return SyncRunResult(
        targetId: targetId,
        state: 'failed',
        eventsUploaded: eventsUploaded,
        eventsReceived: eventsReceived,
        eventsApplied: eventsApplied,
        eventsPendingReview: eventsPendingReview,
        eventsBlocked: eventsBlocked,
        blobsUploaded: blobsUploaded,
        blobsReceived: blobsReceived,
        conflictsPreserved: conflicts,
        bytesTransferred: transferred,
        completedAtUtc: _clock().toUtc(),
        warnings: List<String>.unmodifiable(warnings),
        error: _safeError(error),
      );
    } finally {
      if (keyBytes != null) keyBytes.fillRange(0, keyBytes.length, 0);
    }
  }

  /// Replays every immutable event/blob known from each historical remote
  /// epoch into the current namespace. Historical policy and SecretRef rows are
  /// authoritative for reads; they are never inferred from current settings.
  /// Each verified object is recorded independently so an interrupted transfer
  /// resumes idempotently on the next sync.
  Future<({
    int eventsUploaded,
    int eventsReceived,
    int blobsUploaded,
    int blobsReceived,
    int bytesTransferred,
    List<String> warnings,
  })> _migrateHistoricalEpochs({
    required SyncTarget target,
    required RemoteObjectConnector destinationConnector,
    required String destinationBase,
    required Uint8List? destinationKey,
  }) async {
    final epochRows = _vault.database.query(
      'SELECT target_id,epoch,policy_json,secret_ref,authority_generation FROM remote_target_epochs '
      'WHERE target_id=? AND epoch<? ORDER BY epoch',
      [target.targetId, target.epoch],
    );
    var eventsUploaded = 0;
    var eventsReceived = 0;
    var blobsUploaded = 0;
    var blobsReceived = 0;
    var bytesTransferred = 0;
    final warnings = <String>[];

    for (final epochRow in epochRows) {
      final source = await _targetFromEpochRow(epochRow);
      _beginEpochMigration(target.targetId, source.epoch, target.epoch, 0, 0);
      Uint8List? sourceKey;
      try {
        RemoteObjectConnector? sourceConnector;
        var sourceAuthorizationMissing = false;
        try {
          final sourceOpened = await _openConnector(source, requireEncryptionKey: false);
          sourceConnector = sourceOpened.connector;
          sourceKey = sourceOpened.encryptionKey;
        } on SyncCredentialRequiredException {
          // Locally retained immutable copies can still be migrated, but without
          // the epoch credential the remote inventory cannot be certified.
          sourceAuthorizationMissing = true;
        }
        final sourceBase = _remoteBase(source);
        final eventPrefix = '$sourceBase/events/';
        final events = <String, ({
          Map<String, Object?> document,
          String wireJson,
          Uint8List clearBytes,
          String clearSha,
        })>{};

        void addEvent(Map<String, Object?> document, String wireJson) {
          _validateSyncEnvelope(document, _vault.vaultId);
          if (document['entity_kind'] == 'approval' ||
              document['event_type'] == 'approval.issued' ||
              document['event_type'] == 'approval.revoked') {
            return;
          }
          final id = document['event_id'] as String;
          final clearBytes = Uint8List.fromList(utf8.encode(wireJson));
          final clearSha = sha256.convert(clearBytes).toString();
          final previous = events[id];
          if (previous != null && previous.clearSha != clearSha) {
            throw StateError('Immutable event $id has conflicting content across retained epochs.');
          }
          events[id] = (
            document: document,
            wireJson: wireJson,
            clearBytes: clearBytes,
            clearSha: clearSha,
          );
        }

        final hiddenEvents = source.encryption.encryptsObject(metadata: true, byteSize: 1);
        final remoteEvents = sourceConnector == null
            ? const <RemoteObject>[]
            : await sourceConnector.list(
                hiddenEvents ? '${eventPrefix}opaque/' : eventPrefix,
              );
        final remoteEventCoverageUnknown = sourceAuthorizationMissing ||
            (hiddenEvents && sourceKey == null && remoteEvents.isNotEmpty);
        final readableSourceConnector = sourceConnector;
        if (!remoteEventCoverageUnknown && readableSourceConnector != null) {
          for (final remote in remoteEvents) {
            final wireBytes = await readableSourceConnector.getBytes(remote.key, maximumBytes: 32 * 1024 * 1024);
            bytesTransferred += wireBytes.length;
            final clear = hiddenEvents
                ? await _encryption.decryptBytes(wireBytes, sourceKey!)
                : Uint8List.fromList(wireBytes);
            final wireJson = utf8.decode(clear, allowMalformed: false);
            final document = jsonDecode(wireJson) as Map<String, Object?>;
            addEvent(document, wireJson);
            if (document['device_id'] != _vault.deviceId) {
              final insertion = _recordRemoteEvent(
                target.targetId,
                document['event_id'] as String,
                document,
                sha256.convert(clear).toString(),
                wireJson,
                _clock().toUtc(),
              );
              if (insertion.inserted) eventsReceived++;
            }
          }
        }

        // Recover prior local sends from the immutable outbox even if a remote
        // listing entry was lost. Only rows whose recorded key belongs to this
        // source namespace are included here.
        final sentLocally = _vault.database.query(
          'SELECT o.outbox_id,o.payload_json FROM outbox o '
          'JOIN sync_outbox_targets s ON s.event_id=o.outbox_id '
          "WHERE s.target_id=? AND s.remote_key IS NOT NULL "
          "AND COALESCE(json_extract(o.payload_json,'\$.entity_kind'),'')<>'approval' "
          "AND COALESCE(json_extract(o.payload_json,'\$.event_type'),'') NOT IN ('approval.issued','approval.revoked') "
          'AND substr(s.remote_key,1,?)=? ORDER BY o.outbox_id',
          [target.targetId, eventPrefix.length, eventPrefix],
        );
        for (final row in sentLocally) {
          final wireJson = row['payload_json'] as String;
          addEvent(jsonDecode(wireJson) as Map<String, Object?>, wireJson);
        }

        // Keep exact bytes from prior intake. If an older row lacks wire_json,
        // reconstruct it only when its recorded immutable hash proves a byte
        // for byte match; otherwise fail closed and retain the blocked row.
        final retainedRows = _vault.database.query(
          '''SELECT e.event_id,e.device_id,e.sequence,e.lamport,e.entity_kind,e.entity_id,
                    e.base_revision,e.action,e.command_id,e.event_type,e.payload_json,e.asset_sha_refs_json,e.created_at_utc,
                    e.content_sha256,e.wire_json
             FROM sync_remote_events e JOIN sync_remote_event_targets t ON t.event_id=e.event_id
             WHERE t.target_id=? ORDER BY e.device_id,e.sequence,e.event_id''',
          [target.targetId],
        );
        for (final row in retainedRows) {
          var wireJson = row['wire_json'] as String?;
          if (wireJson == null) {
            final common = <String, Object?>{
              'schema_version': '2.0',
              'vault_id': _vault.vaultId,
              'device_id': row['device_id'],
              'seq': _asInt(row['sequence']),
              'lamport': _asInt(row['lamport']),
              'event_id': row['event_id'],
              'entity_kind': row['entity_kind'],
              'entity_id': row['entity_id'],
              'base_revision': row['base_revision'],
              'action': row['action'],
              'payload': jsonDecode(row['payload_json'] as String),
              'sha_refs': jsonDecode(row['asset_sha_refs_json'] as String),
              'created_at_utc': row['created_at_utc'],
            };
            final v2Bytes = jsonEncode(common);
            final v3 = <String, Object?>{
              ...common,
              'schema_version': '3.0',
              'command_id': row['command_id'],
              'event_type': row['event_type'],
            };
            final v3Bytes = jsonEncode(v3);
            final v2Matches = sha256.convert(utf8.encode(v2Bytes)).toString() == row['content_sha256'];
            final v3Matches = sha256.convert(utf8.encode(v3Bytes)).toString() == row['content_sha256'];
            if (v2Matches == v3Matches) {
              throw StateError(
                'Historical event ${row['event_id']} has no exact retained wire bytes and cannot be migrated.',
              );
            }
            wireJson = v2Matches ? v2Bytes : v3Bytes;
          }
          addEvent(jsonDecode(wireJson) as Map<String, Object?>, wireJson);
        }

        final blobRefs = <String>{};
        final blobSizes = <String, int>{};
        for (final entry in events.values) {
          final document = entry.document;
          final eventRefs = (document['sha_refs'] as List<dynamic>).cast<String>();
          blobRefs.addAll(eventRefs);
          final payload = document['payload'] as Map<String, Object?>;
          final payloadSha = payload['blob_sha256'];
          final payloadBytes = payload['byte_size'];
          if (payloadSha is String && payloadBytes is int) {
            if (!eventRefs.contains(payloadSha)) {
              throw StateError('Historical asset event ${document['event_id']} omits its Blob SHA reference.');
            }
            final previousBytes = blobSizes[payloadSha];
            if (previousBytes != null && previousBytes != payloadBytes) {
              throw StateError('Historical events disagree about the byte size for Blob $payloadSha.');
            }
            blobSizes[payloadSha] = payloadBytes;
          }
        }
        // Source counts include only identified events. Opaque or inaccessible
        // source inventory is reported separately and always keeps this epoch
        // incomplete; it is never represented as a verified or guessed count.
        final sourceEventInventory = events.length;
        _beginEpochMigration(target.targetId, source.epoch, target.epoch,
            sourceEventInventory, blobRefs.length);

        for (final sha in blobRefs.toList()..sort()) {
          try {
            final materialized = await _materializeHistoricalBlobFromEpochs(
              preferredSource: source,
              preferredConnector: sourceConnector,
              preferredKey: sourceKey,
              currentTarget: target,
              currentConnector: destinationConnector,
              currentKey: destinationKey,
              sha: sha,
              expectedBytes: blobSizes[sha],
            );
            if (materialized.downloaded) blobsReceived++;
            bytesTransferred += materialized.bytesTransferred;
            _setEpochMigrationItem(target.targetId, source.epoch, target.epoch,
                'blob', sha, sha, null, 'copied', null);
            final uploaded = await _uploadBlob(target, destinationConnector, destinationBase, sha, destinationKey);
            blobsUploaded += uploaded.uploaded ? 1 : 0;
            bytesTransferred += uploaded.bytes;
            _setEpochMigrationItem(target.targetId, source.epoch, target.epoch,
                'blob', sha, sha, sha, 'verified', null);
          } on Object catch (error) {
            _setEpochMigrationItem(target.targetId, source.epoch, target.epoch,
                'blob', sha, null, null, 'failed', _safeError(error));
            rethrow;
          }
        }

        final orderedEvents = events.values.toList()
          ..sort((left, right) {
            final device = (left.document['device_id'] as String).compareTo(right.document['device_id'] as String);
            if (device != 0) return device;
            final bySequence = _asInt(left.document['seq']).compareTo(_asInt(right.document['seq']));
            return bySequence != 0
                ? bySequence
                : (left.document['event_id'] as String).compareTo(right.document['event_id'] as String);
          });
        for (final entry in orderedEvents) {
          final eventId = entry.document['event_id'] as String;
          try {
            final published = await _publishEvent(
              target: target,
              connector: destinationConnector,
              base: destinationBase,
              document: entry.document,
              clearBytes: entry.clearBytes,
              keyBytes: destinationKey,
            );
            if (_vault.database.query('SELECT 1 FROM outbox WHERE outbox_id=?', [eventId]).isNotEmpty) {
              _markEventSent(target.targetId, eventId, published.remoteKey, _clock().toUtc());
            }
            _setEpochMigrationItem(target.targetId, source.epoch, target.epoch,
                'event', eventId, entry.clearSha, null, 'copied', null);
            _setEpochMigrationItem(target.targetId, source.epoch, target.epoch,
                'event', eventId, entry.clearSha, entry.clearSha, 'verified', null);
            eventsUploaded++;
            bytesTransferred += published.wireBytes;
          } on Object catch (error) {
            _setEpochMigrationItem(target.targetId, source.epoch, target.epoch,
                'event', eventId, entry.clearSha, null, 'failed', _safeError(error));
            rethrow;
          }
        }
        if (remoteEventCoverageUnknown) {
          if (sourceAuthorizationMissing) {
            throw StateError('SYNC_EPOCH_REAUTH_REQUIRED: local verified items were copied; remote source inventory is inaccessible.');
          }
          throw SyncKeyRequiredException(source.encryption.keyRef);
        }
        _finishEpochMigration(target.targetId, source.epoch, target.epoch);
      } on Object catch (error) {
        final message = _safeError(error);
        _failEpochMigration(target.targetId, source.epoch, target.epoch, message);
        warnings.add('Historical epoch ${source.epoch} was not fully migrated: $message');
        throw StateError('SYNC_EPOCH_MIGRATION_REQUIRED: ${warnings.last}');
      } finally {
        if (sourceKey != null) sourceKey.fillRange(0, sourceKey.length, 0);
      }
    }
    return (
      eventsUploaded: eventsUploaded,
      eventsReceived: eventsReceived,
      blobsUploaded: blobsUploaded,
      blobsReceived: blobsReceived,
      bytesTransferred: bytesTransferred,
      warnings: List<String>.unmodifiable(warnings),
    );
  }

  Future<({int size, bool downloaded, int bytesTransferred})> _materializeHistoricalBlobFromEpochs({
    required SyncTarget preferredSource,
    required RemoteObjectConnector? preferredConnector,
    required Uint8List? preferredKey,
    required SyncTarget currentTarget,
    required RemoteObjectConnector currentConnector,
    required Uint8List? currentKey,
    required String sha,
    required int? expectedBytes,
  }) async {
    final local = _vault.database.query('SELECT byte_size,state FROM blob_objects WHERE sha256=?', [sha]);
    if (local.isNotEmpty && local.single['state'] == 'committed') {
      final size = _asInt(local.single['byte_size']);
      if (expectedBytes != null && expectedBytes != size) {
        throw StateError('Historical event size does not match local Blob $sha.');
      }
      try {
        await _assets.verifyBlobForRemoteProjection(blobSha256: sha, expectedBytes: size);
        return (size: size, downloaded: false, bytesTransferred: 0);
      } on AssetMissingException {
        // Search every retained destination for a verified immutable copy.
      } on AssetIntegrityException {
        // A valid remote copy can repair this CAS object.
      }
    }

    final candidates = <SyncTarget>[preferredSource];
    final epochRows = _vault.database.query(
      'SELECT target_id,epoch,policy_json,secret_ref,authority_generation FROM remote_target_epochs WHERE target_id=? ORDER BY epoch DESC',
      [currentTarget.targetId],
    );
    final seen = <int>{preferredSource.epoch};
    for (final row in epochRows) {
      final epoch = _asInt(row['epoch']);
      if (seen.add(epoch)) candidates.add(await _targetFromEpochRow(row));
    }

    final errors = <String>[];
    for (final candidate in candidates) {
      RemoteObjectConnector connector;
      Uint8List? keyBytes;
      var ownsKey = false;
      if (candidate.epoch == preferredSource.epoch) {
        if (preferredConnector == null) {
          errors.add('epoch ${candidate.epoch}: current-generation authorization is required to read this source.');
          continue;
        }
        connector = preferredConnector;
        keyBytes = preferredKey;
      } else if (candidate.epoch == currentTarget.epoch) {
        connector = currentConnector;
        keyBytes = currentKey;
      } else {
        try {
          final opened = await _openConnector(candidate, requireEncryptionKey: false);
          connector = opened.connector;
          keyBytes = opened.encryptionKey;
          ownsKey = true;
        } on Object catch (error) {
          errors.add('epoch ${candidate.epoch}: ${_safeError(error)}');
          continue;
        }
      }
      try {
        final base = _remoteBase(candidate);
        final hidden = candidate.encryption.encryptsObject(metadata: true, byteSize: 1);
        if (hidden && keyBytes == null) {
          errors.add('epoch ${candidate.epoch}: metadata key is unavailable');
          continue;
        }
        final objectKey = hidden ? '$base/objects/opaque/${_opaqueDigest(keyBytes!, sha)}' : '$base/objects/sha256/$sha';
        final matches = await connector.list(objectKey);
        if (!matches.any((object) => object.key == objectKey)) continue;
        try {
          return await _materializeHistoricalBlob(
            source: candidate,
            connector: connector,
            base: base,
            keyBytes: keyBytes,
            sha: sha,
            expectedBytes: expectedBytes,
          );
        } on Object catch (error) {
          errors.add('epoch ${candidate.epoch}: ${_safeError(error)}');
        }
      } finally {
        if (ownsKey && keyBytes != null) keyBytes.fillRange(0, keyBytes.length, 0);
      }
    }
    final detail = errors.isEmpty ? 'No retained epoch contains the referenced object.' : errors.join('; ');
    throw StateError('Historical Blob $sha could not be recovered: $detail');
  }

  Future<({int size, bool downloaded, int bytesTransferred})> _materializeHistoricalBlob({
    required SyncTarget source,
    required RemoteObjectConnector connector,
    required String base,
    required Uint8List? keyBytes,
    required String sha,
    required int? expectedBytes,
  }) async {
    final local = _vault.database.query('SELECT byte_size,state FROM blob_objects WHERE sha256=?', [sha]);
    if (local.isNotEmpty && local.single['state'] == 'committed') {
      final size = _asInt(local.single['byte_size']);
      if (expectedBytes != null && expectedBytes != size) {
        throw StateError('Historical event size does not match local Blob $sha.');
      }
      try {
        await _assets.verifyBlobForRemoteProjection(blobSha256: sha, expectedBytes: size);
        return (size: size, downloaded: false, bytesTransferred: 0);
      } on AssetMissingException {
        // Fetch the historical immutable copy to repair a missing CAS object.
      } on AssetIntegrityException {
        // receiveSynchronizedBlob quarantines the damaged copy before repair.
      }
    }
    final hidden = source.encryption.encryptsObject(metadata: true, byteSize: 1);
    final remoteKey = hidden
        ? '$base/objects/opaque/${_opaqueDigest(keyBytes!, sha)}'
        : '$base/objects/sha256/$sha';
    final downloaded = File(p.join(Directory.systemTemp.path, 'lw-sync-epoch-$sha-${newUuidV7()}.part'));
    final clearFile = File('${downloaded.path}.clear');
    try {
      await connector.downloadToFile(remoteKey, downloaded.path);
      final encrypted = await _hasChunkedEncryptionHeader(downloaded);
      if (encrypted) {
        await _encryption.decryptFile(keyBytes: keyBytes!, sourcePath: downloaded.path, destinationPath: clearFile.path);
      } else {
        await downloaded.copy(clearFile.path);
      }
      final size = await clearFile.length();
      final policyRequiresEncryption = source.encryption.encryptsObject(metadata: false, byteSize: size);
      if (encrypted != policyRequiresEncryption) {
        throw StateError('Historical Blob encryption does not match its recorded epoch policy.');
      }
      if (expectedBytes != null && expectedBytes != size) {
        throw StateError('Historical Blob $sha byte size does not match its event.');
      }
      if (await _hashFile(clearFile.path) != sha) {
        throw StateError('Historical Blob $sha failed full SHA-256 verification.');
      }
      await _assets.receiveSynchronizedBlob(
        expectedSha256: sha,
        expectedBytes: size,
        sourceTargetId: source.targetId,
        content: clearFile.openRead(),
      );
      final transferBytes = await downloaded.length();
      _recordRemoteReplica(
        target: source,
        sha: sha,
        remoteKey: remoteKey,
        plaintextBytes: size,
        transferChecksum: await _hashFile(downloaded.path),
        encrypted: encrypted,
        verificationLevel: 'downloaded_sha256_verified',
      );
      return (size: size, downloaded: true, bytesTransferred: transferBytes);
    } finally {
      if (await downloaded.exists()) await downloaded.delete();
      if (await clearFile.exists()) await clearFile.delete();
    }
  }

  Future<({String remoteKey, int wireBytes})> _publishEvent({
    required SyncTarget target,
    required RemoteObjectConnector connector,
    required String base,
    required Map<String, Object?> document,
    required List<int> clearBytes,
    required Uint8List? keyBytes,
  }) async {
    final encrypted = target.encryption.encryptsObject(metadata: true, byteSize: clearBytes.length);
    final wireBytes = encrypted
        ? await _encryption.encryptBytes(clearBytes, keyBytes!)
        : Uint8List.fromList(clearBytes);
    final eventId = document['event_id'] as String;
    final remoteKey = encrypted
        ? '$base/events/opaque/${_opaqueDigest(keyBytes!, 'event:$eventId')}'
        : '$base/events/${document['device_id']}/${_padSequence(_asInt(document['seq']))}-$eventId.json';
    if (encrypted) {
      await _putVerifiedEncryptedEvent(connector, remoteKey, wireBytes, clearBytes, keyBytes!);
    } else {
      await _putVerifiedBytes(connector, remoteKey, wireBytes);
    }
    return (remoteKey: remoteKey, wireBytes: wireBytes.length);
  }

  void _beginEpochMigration(String targetId, int sourceEpoch, int destinationEpoch, int events, int blobs) {
    final now = _clock().toUtc().toIso8601String();
    _vault.database.execute(
      '''INSERT OR IGNORE INTO sync_epoch_migrations(target_id,source_epoch,destination_epoch,state,
           source_event_count,verified_event_count,source_blob_count,verified_blob_count,last_error,
           started_at_utc,updated_at_utc,completed_at_utc)
         VALUES(?,?,?,'pending',?,0,?,0,NULL,?,?,NULL)''',
      [targetId, sourceEpoch, destinationEpoch, events, blobs, now, now],
    );
    _vault.database.execute(
      '''UPDATE sync_epoch_migrations SET state='running',source_event_count=?,source_blob_count=?,
           verified_event_count=0,verified_blob_count=0,last_error=NULL,started_at_utc=?,updated_at_utc=?,
           completed_at_utc=NULL WHERE target_id=? AND source_epoch=? AND destination_epoch=?''',
      [events, blobs, now, now, targetId, sourceEpoch, destinationEpoch],
    );
  }

  void _setEpochMigrationItem(
    String targetId,
    int sourceEpoch,
    int destinationEpoch,
    String kind,
    String itemId,
    String? sourceSha,
    String? destinationSha,
    String state,
    String? error,
  ) {
    final now = _clock().toUtc().toIso8601String();
    _vault.database.execute(
      '''INSERT INTO sync_epoch_migration_items(target_id,source_epoch,destination_epoch,item_kind,item_id,
           source_sha256,destination_sha256,state,last_error,updated_at_utc)
         VALUES(?,?,?,?,?,?,?,?,?,?) ON CONFLICT(target_id,source_epoch,destination_epoch,item_kind,item_id)
         DO UPDATE SET source_sha256=excluded.source_sha256,destination_sha256=excluded.destination_sha256,
           state=excluded.state,last_error=excluded.last_error,updated_at_utc=excluded.updated_at_utc''',
      [targetId, sourceEpoch, destinationEpoch, kind, itemId, sourceSha, destinationSha, state, error, now],
    );
    _vault.database.execute(
      '''UPDATE sync_epoch_migrations SET verified_event_count=(SELECT COUNT(*) FROM sync_epoch_migration_items
             WHERE target_id=? AND source_epoch=? AND destination_epoch=? AND item_kind='event' AND state='verified'),
           verified_blob_count=(SELECT COUNT(*) FROM sync_epoch_migration_items
             WHERE target_id=? AND source_epoch=? AND destination_epoch=? AND item_kind='blob' AND state='verified'),
           updated_at_utc=? WHERE target_id=? AND source_epoch=? AND destination_epoch=?''',
      [targetId, sourceEpoch, destinationEpoch, targetId, sourceEpoch, destinationEpoch,
        now, targetId, sourceEpoch, destinationEpoch],
    );
  }

  void _finishEpochMigration(String targetId, int sourceEpoch, int destinationEpoch) {
    final now = _clock().toUtc().toIso8601String();
    _vault.database.execute(
      '''UPDATE sync_epoch_migrations SET state='completed',completed_at_utc=?,updated_at_utc=?,last_error=NULL
         WHERE target_id=? AND source_epoch=? AND destination_epoch=? AND
           verified_event_count=source_event_count AND verified_blob_count=source_blob_count''',
      [now, now, targetId, sourceEpoch, destinationEpoch],
    );
    final rows = _vault.database.query(
      'SELECT state FROM sync_epoch_migrations WHERE target_id=? AND source_epoch=? AND destination_epoch=?',
      [targetId, sourceEpoch, destinationEpoch],
    );
    if (rows.isEmpty || rows.single['state'] != 'completed') {
      throw StateError('Epoch migration verification counts do not match its source inventory.');
    }
  }

  void _failEpochMigration(String targetId, int sourceEpoch, int destinationEpoch, String message) {
    final now = _clock().toUtc().toIso8601String();
    _vault.database.execute(
      '''UPDATE sync_epoch_migrations SET state='failed',last_error=?,updated_at_utc=?
         WHERE target_id=? AND source_epoch=? AND destination_epoch=?''',
      [message, now, targetId, sourceEpoch, destinationEpoch],
    );
  }

  @override
  Future<void> uploadBackupSnapshot({
    required String targetId,
    required String backupId,
    required String snapshotDirectory,
  }) async {
    final row = _targetRow(targetId);
    if (row == null) throw StateError('SYNC_TARGET_MISSING: $targetId');
    final currentTarget = await _targetFromRow(row);
    if (!currentTarget.backupEnabled) throw StateError('BACKUP_DISABLED: target $targetId does not allow backups.');
    final snapshotRows = _vault.database.query(
      'SELECT target_id,target_epoch FROM backup_snapshots WHERE backup_id=?',
      [backupId],
    );
    if (snapshotRows.isEmpty || snapshotRows.single['target_id'] != targetId) {
      throw StateError('BACKUP_SNAPSHOT_MISSING: $backupId is not recorded for target $targetId.');
    }
    final targetEpoch = snapshotRows.single['target_epoch'] == null
        ? currentTarget.epoch
        : _asInt(snapshotRows.single['target_epoch']);
    _vault.database.execute(
      'UPDATE backup_snapshots SET target_epoch=? WHERE backup_id=? AND target_epoch IS NULL',
      [targetEpoch, backupId],
    );
    final target = targetEpoch == currentTarget.epoch
        ? currentTarget
        : await _targetForEpoch(targetId, targetEpoch);
    if (target.state != SyncTargetState.ready) {
      if (target.state == SyncTargetState.keyRequired) throw SyncKeyRequiredException(target.encryption.keyRef);
      throw SyncCredentialRequiredException(target.provider);
    }
    final opened = await _openConnector(target);
    try {
    final root = Directory(snapshotDirectory);
    if (await FileSystemEntity.type(root.path, followLinks: false) != FileSystemEntityType.directory) {
      throw FileSystemException('Backup directory is missing or is a link.', snapshotDirectory);
    }
    final manifestFile = await _safeExistingChild(root, 'manifest.json');
    final manifestBytes = await manifestFile.readAsBytes();
    final manifest = BackupManifest.fromJson(jsonDecode(utf8.decode(manifestBytes)) as Map<String, Object?>);
    if (manifest.backupId != backupId || manifest.vaultId != _vault.vaultId) {
      throw StateError('Backup manifest identity does not match the requested remote transfer.');
    }
    final sourceManifestSha = sha256.convert(manifestBytes).toString();
    final checksumFile = await _safeExistingChild(root, 'manifest.sha256');
    final checksumText = await checksumFile.readAsString();
    final expectedManifestSha = checksumText.trim().split(RegExp(r'\s+')).first;
    if (expectedManifestSha != sourceManifestSha) {
      throw const FormatException('Local backup manifest checksum does not match before upload.');
    }
    final expectedFiles = <String, ({String sha256, int bytes})>{
      'manifest.json': (sha256: sourceManifestSha, bytes: manifestBytes.length),
      'manifest.sha256': (sha256: await _hashFile(checksumFile.path), bytes: await checksumFile.length()),
    };
    for (final object in manifest.objects) {
      if (expectedFiles.containsKey(object.relativePath)) {
        throw const FormatException('Backup manifest contains duplicate object paths.');
      }
      expectedFiles[object.relativePath] = (
        sha256: object.storedSha256,
        bytes: object.storedBytes,
      );
    }
    final backupBase = _backupStorageBase(target, backupId, opened.encryptionKey);
    final uploadedFiles = <String>{};
    final objectEntries = <String, BackupObjectEntry>{
      for (final entry in manifest.objects) entry.relativePath: entry,
    };
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is Link) {
        throw FileSystemException('Backup snapshots cannot contain symbolic links.', entity.path);
      }
      if (entity is! File) continue;
      final relative = p.relative(entity.path, from: root.path).replaceAll('\\', '/');
      final expected = expectedFiles[relative];
      if (expected == null) {
        throw FileSystemException('Backup snapshot contains an unlisted file.', entity.path);
      }
      uploadedFiles.add(relative);
      if (await entity.length() != expected.bytes || await _hashFile(entity.path) != expected.sha256) {
        throw FileSystemException('Backup snapshot object changed after manifest validation.', entity.path);
      }
      final bytes = expected.bytes;
      final metadata = relative == 'manifest.json' || relative == 'manifest.sha256';
      final encrypt = target.encryption.encryptsObject(metadata: metadata, byteSize: bytes);
      final hideNames = target.encryption.encryptsObject(metadata: true, byteSize: 1);
      final remoteKey = hideNames
          ? '$backupBase/files/opaque/${_opaqueDigest(opened.encryptionKey!, '$backupId:$relative')}'
          : '$backupBase/files/$relative';
      var uploadPath = entity.path;
      var tempEncryptedPath = '';
      if (encrypt) {
        tempEncryptedPath = '${entity.path}.remote-${newUuidV7()}.part';
        await _encryption.encryptFile(
          keyBytes: opened.encryptionKey!,
          sourcePath: entity.path,
          destinationPath: tempEncryptedPath,
        );
        uploadPath = tempEncryptedPath;
      }
      try {
        await _putVerifiedFile(
          opened.connector,
          remoteKey,
          uploadPath,
          expectedPlainSha: expected.sha256,
          encrypted: encrypt,
          keyBytes: opened.encryptionKey,
        );
        final object = objectEntries[relative];
        if (object != null) {
          _vault.database.execute(
            'UPDATE backup_snapshot_objects SET remote_key=? WHERE backup_id=? AND object_id=?',
            [remoteKey, backupId, object.objectId],
          );
        }
      } finally {
        if (tempEncryptedPath.isNotEmpty && await File(tempEncryptedPath).exists()) {
          await File(tempEncryptedPath).delete();
        }
      }
    }
    if (!uploadedFiles.containsAll(expectedFiles.keys)) {
      throw StateError('Backup snapshot is missing one or more manifest objects.');
    }

    final remoteManifest = RemoteBackupManifest(
      backupId: backupId,
      vaultId: _vault.vaultId,
      targetId: targetId,
      targetEpoch: target.epoch,
      createdAtUtc: manifest.createdAtUtc,
      sourceManifestSha256: sourceManifestSha,
      encryption: target.encryption,
    );
    final catalogClear = utf8.encode(jsonEncode(remoteManifest.toJson()));
    final catalogEncrypted = target.encryption.encryptsObject(metadata: true, byteSize: catalogClear.length);
    final catalogBytes = catalogEncrypted
        ? await _encryption.encryptBytes(catalogClear, opened.encryptionKey!)
        : catalogClear;
    await _putVerifiedBytes(
      opened.connector,
      _backupCatalogKey(target, backupId, opened.encryptionKey),
      catalogBytes,
    );
    } finally {
      final key = opened.encryptionKey;
      if (key != null) key.fillRange(0, key.length, 0);
    }
  }

  @override
  Future<String> downloadBackupSnapshot({
    required String targetId,
    required String backupId,
    required String destinationDirectory,
    int? targetEpoch,
  }) async {
    final localRows = _vault.database.query(
      'SELECT target_epoch FROM backup_snapshots WHERE backup_id=? AND target_id=?',
      [backupId, targetId],
    );
    final preferredEpoch = targetEpoch ??
        (localRows.isEmpty || localRows.single['target_epoch'] == null
            ? null
            : _asInt(localRows.single['target_epoch']));
    if (preferredEpoch == null) {
      final epochs = await listHistoricalEpochs(targetId: targetId);
      final unavailable = epochs.where((item) => item.target.state != SyncTargetState.ready).toList(growable: false);
      if (unavailable.isNotEmpty) {
        throw StateError(
          'REMOTE_BACKUP_EPOCH_SELECTION_REQUIRED: choose and reauthorize the authoritative epoch before restoring; '
          'unavailable epochs: ${unavailable.map((item) => item.epoch).join(', ')}.',
        );
      }
    }
    final catalogs = await listRemoteBackups(targetId: targetId, targetEpoch: preferredEpoch);
    final candidates = catalogs.where((item) => item.backupId == backupId).toList(growable: false);
    if (candidates.isEmpty) {
      throw StateError('REMOTE_BACKUP_MISSING: $backupId is not present in the selected target epoch.');
    }
    if (candidates.length != 1) {
      throw StateError(
        'REMOTE_BACKUP_AMBIGUOUS: $backupId has multiple catalog entries; select its authoritative target epoch.',
      );
    }
    final remoteManifest = candidates.single;
    final target = await _targetForEpoch(targetId, remoteManifest.targetEpoch);
    if (!_sameEncryptionPolicy(remoteManifest.encryption, target.encryption)) {
      throw const FormatException('Remote backup catalog does not match its immutable encryption epoch.');
    }
    if (target.state != SyncTargetState.ready) {
      if (target.state == SyncTargetState.keyRequired) throw SyncKeyRequiredException(target.encryption.keyRef);
      throw SyncCredentialRequiredException(target.provider);
    }
    final opened = await _openConnector(target);
    final destination = Directory(p.normalize(p.absolute(destinationDirectory)));
    if (await destination.exists()) throw FileSystemException('Remote restore destination already exists.', destination.path);
    await destination.create(recursive: true);
    final backupBase = _backupStorageBase(target, backupId, opened.encryptionKey);
    final hideNames = target.encryption.encryptsObject(metadata: true, byteSize: 1);
    String remoteKey(String relative) => hideNames
        ? '$backupBase/files/opaque/${_opaqueDigest(opened.encryptionKey!, '$backupId:$relative')}'
        : '$backupBase/files/$relative';
    Future<File> fetch(String relative, {required bool metadata, required int knownBytes}) async {
      final remoteFile = File(p.join(destination.path, '.download-${newUuidV7()}.part'));
      final encrypt = target.encryption.encryptsObject(metadata: metadata, byteSize: knownBytes);
      final clearFile = _safeChild(destination, relative);
      await clearFile.parent.create(recursive: true);
      try {
        await opened.connector.downloadToFile(remoteKey(relative), remoteFile.path);
        if (encrypt) {
          await _encryption.decryptFile(
            keyBytes: opened.encryptionKey!,
            sourcePath: remoteFile.path,
            destinationPath: clearFile.path,
          );
        } else {
          await remoteFile.copy(clearFile.path);
        }
      } finally {
        if (await remoteFile.exists()) await remoteFile.delete();
      }
      return clearFile;
    }

    try {
      final manifestFile = await fetch('manifest.json', metadata: true, knownBytes: 1);
      if (await _hashFile(manifestFile.path) != remoteManifest.sourceManifestSha256) {
        throw const FormatException('Remote backup manifest SHA-256 does not match its encrypted catalog.');
      }
      final manifest = BackupManifest.fromJson(
        jsonDecode(await manifestFile.readAsString()) as Map<String, Object?>,
      );
      if (manifest.backupId != backupId ||
          manifest.vaultId != _vault.vaultId ||
          manifest.createdAtUtc.toUtc() != remoteManifest.createdAtUtc.toUtc()) {
        throw StateError('Remote backup manifest belongs to a different Vault or backup id.');
      }
      final checksum = await fetch('manifest.sha256', metadata: true, knownBytes: 1);
      final manifestHash = await _hashFile(manifestFile.path);
      final expected = (await checksum.readAsString()).trim().split(RegExp(r'\s+')).first;
      if (manifestHash != expected) throw const FormatException('Remote backup manifest checksum mismatch.');
      for (final object in manifest.objects) {
        final file = await fetch(object.relativePath, metadata: false, knownBytes: object.storedBytes);
        if (await file.length() != object.storedBytes || await _hashFile(file.path) != object.storedSha256) {
          throw FileSystemException('Downloaded backup object does not match its declared stored hash.', file.path);
        }
      }
      return destination.path;
    } on Object {
      if (await destination.exists()) await destination.delete(recursive: true);
      rethrow;
    } finally {
      final key = opened.encryptionKey;
      if (key != null) key.fillRange(0, key.length, 0);
    }
  }

  Future<SyncTarget> _configure({
    required SyncProvider provider,
    required String displayName,
    required SecretRef secretRef,
    required String? endpoint,
    required String? region,
    required String? bucket,
    required String? driveId,
    required RemoteEncryptionPolicy encryption,
    required LargeUploadPolicy largeUploadPolicy,
    required bool syncEnabled,
    required bool backupEnabled,
    String? targetId,
    String? commandId,
  }) async {
    if (displayName.trim().isEmpty) throw ArgumentError.value(displayName, 'displayName');
    if (encryption.encryptMetadata || encryption.encryptSmallFiles || encryption.encryptLargeFiles ||
        encryption.mode != RemoteEncryptionMode.none) {
      if (encryption.keyRef == null) throw const SyncKeyRequiredException(null);
    }
    if (provider == SyncProvider.s3) {
      final configuredEndpoint = endpoint;
      final configuredRegion = region;
      final configuredBucket = bucket;
      if (configuredEndpoint == null ||
          configuredRegion == null ||
          configuredBucket == null ||
          configuredRegion.trim().isEmpty ||
          configuredBucket.trim().isEmpty) {
        throw ArgumentError('S3 requires an HTTPS endpoint, region, and bucket.');
      }
      final uri = Uri.parse(configuredEndpoint);
      if (!uri.isScheme('https') || !uri.hasAuthority) {
        throw ArgumentError('S3 requires an HTTPS endpoint, region, and bucket.');
      }
    }
    final actualId = targetId ?? newUuidV7();
    final now = _clock().toUtc();
    final policy = <String, Object?>{
      'schema_version': '2.0',
      'target_id': actualId,
      'provider': provider == SyncProvider.oneDrive ? 'onedrive' : 's3',
      'encryption': encryption.mode.name,
      'encrypt_metadata': encryption.encryptMetadata,
      'encrypt_small_files': encryption.encryptSmallFiles,
      'encrypt_large_files': encryption.encryptLargeFiles,
      'key_id': encryption.keyRef?.value,
      'large_file_threshold_bytes': encryption.largeFileThresholdBytes,
      'large_upload': _policyName(largeUploadPolicy),
      'backup': backupEnabled,
      'sync': syncEnabled,
      if (endpoint != null) 'endpoint': endpoint,
      if (region != null) 'region': region,
      if (bucket != null) 'bucket': bucket,
      if (driveId != null) 'drive_id': driveId,
    };
    final command = commandId ?? newUuidV7(at: now);
    _vault.database.transaction((tx) {
      final priorRows = tx.query('SELECT * FROM remote_targets WHERE target_id=?', [actualId]);
      final exists = priorRows.isNotEmpty;
      var epoch = 1;
      var createEpochRecord = true;
      if (exists) {
        final prior = priorRows.single;
        final oldPolicy = jsonDecode(prior['policy_json'] as String) as Map<String, Object?>;
        final oldEpoch = _asInt(prior['epoch']);
        epoch = oldEpoch;
        final oldSecretRef = prior['secret_ref'] as String?;
        if (_epochStoragePolicyChanged(oldPolicy, policy) || oldSecretRef != secretRef.value) {
          final oldEpochRows = tx.query(
            'SELECT 1 FROM remote_target_epochs WHERE target_id=? AND epoch=?',
            [actualId, oldEpoch],
          );
          if (oldEpochRows.isEmpty) {
            final priorGeneration = _asInt(prior['authority_generation']);
            if (priorGeneration != _vault.database.authorityGeneration) {
              throw StateError('SYNC_EPOCH_METADATA_MISSING: stale target history cannot be recreated as current authority.');
            }
            tx.execute(
              'INSERT INTO remote_target_epochs(target_id,epoch,policy_json,secret_ref,created_at_utc,authority_generation) '
              'VALUES(?,?,?,?,?,?)',
              [actualId, oldEpoch, jsonEncode(oldPolicy), oldSecretRef,
                prior['created_at_utc'] ?? now.toIso8601String(), priorGeneration],
            );
          }
          epoch = oldEpoch + 1;
          createEpochRecord = true;
        } else {
          final epochRows = tx.query(
            'SELECT 1 FROM remote_target_epochs WHERE target_id=? AND epoch=?',
            [actualId, epoch],
          );
          createEpochRecord = epochRows.isEmpty;
        }
      }
      final action = exists ? MutationAction.patch : MutationAction.create;
      if (exists) {
        tx.execute(
          'UPDATE remote_targets SET provider=?,policy_json=?,secret_ref=?,display_name=?,epoch=?,updated_at_utc=?,authority_generation=? WHERE target_id=?',
          [provider == SyncProvider.oneDrive ? 'onedrive' : 's3', jsonEncode(policy), secretRef.value,
            displayName.trim(), epoch, now.toIso8601String(), _vault.database.authorityGeneration, actualId],
        );
      } else {
        tx.execute(
          'INSERT INTO remote_targets(target_id,provider,policy_json,secret_ref,epoch,created_at_utc,display_name,updated_at_utc,authority_generation) '
          'VALUES(?,?,?,?,?,?,?,?,?)',
          [actualId, provider == SyncProvider.oneDrive ? 'onedrive' : 's3', jsonEncode(policy), secretRef.value,
            epoch, now.toIso8601String(), displayName.trim(), now.toIso8601String(), _vault.database.authorityGeneration],
        );
      }
      if (createEpochRecord) {
        tx.execute(
          'INSERT OR IGNORE INTO remote_target_epochs(target_id,epoch,policy_json,secret_ref,created_at_utc,authority_generation) '
          'VALUES(?,?,?,?,?,?)',
          [actualId, epoch, jsonEncode(policy), secretRef.value, now.toIso8601String(), _vault.database.authorityGeneration],
        );
      }
      tx.appendMutation(MutationEventDraft(
        command: CommandMetadata(commandId: command, utcTime: now),
        deviceId: _vault.deviceId,
        entityType: 'remote_target',
        entityId: actualId,
        eventType: exists ? 'sync.target.updated' : 'sync.target.created',
        action: action,
        payloadJson: jsonEncode(policy..['display_name'] = displayName.trim()),
      ));
      return null;
    });
    final row = _targetRow(actualId)!;
    return _targetFromRow(row);
  }

  Future<SyncTarget> _targetFromRow(DbRow row) async {
    final providerValue = row['provider'] as String;
    final provider = switch (providerValue) {
      'onedrive' => SyncProvider.oneDrive,
      's3' => SyncProvider.s3,
      _ => throw FormatException('Unsupported sync provider $providerValue'),
    };
    final policy = jsonDecode(row['policy_json'] as String) as Map<String, Object?>;
    final encryption = RemoteEncryptionPolicy.fromJson({
      'mode': policy['encryption'] ?? 'none',
      'encrypt_metadata': policy['encrypt_metadata'],
      'encrypt_small_files': policy['encrypt_small_files'],
      'encrypt_large_files': policy['encrypt_large_files'],
      'key_id': policy['key_id'],
      'large_file_threshold_bytes': policy['large_file_threshold_bytes'],
    });
    final targetId = row['target_id'] as String;
    final epoch = _asInt(row['epoch']);
    final rowGeneration = _asInt(row['authority_generation']);
    final staleGeneration = rowGeneration != _vault.database.authorityGeneration;
    DbRow? overlay;
    if (staleGeneration) {
      overlay = _epochAuthorizationRow(targetId, epoch);
      if (overlay != null && !_authorizationMatches(overlay, targetId, epoch, provider, policy)) {
        overlay = null;
      }
    }
    String? refValue;
    if (staleGeneration) {
      final overlayRef = overlay == null ? null : overlay['credential_secret_ref'];
      refValue = overlayRef is String ? overlayRef : null;
    } else {
      refValue = row['secret_ref'] as String?;
    }
    final secretRef = refValue == null ? null : SecretRef(refValue);
    String? encryptionRefValue;
    if (staleGeneration) {
      final overlayRef = overlay == null ? null : overlay['encryption_secret_ref'];
      encryptionRefValue = overlayRef is String ? overlayRef : null;
    } else {
      encryptionRefValue = row['encryption_secret_ref'] as String? ?? encryption.keyRef?.value;
    }
    final encryptionSecretRef = encryptionRefValue == null ? null : SecretRef(encryptionRefValue);
    String? expectedKeyFingerprint;
    if (staleGeneration) {
      final overlayFingerprint = overlay == null ? null : overlay['key_fingerprint'];
      expectedKeyFingerprint = overlayFingerprint is String ? overlayFingerprint : null;
    } else {
      expectedKeyFingerprint = row['expected_key_fingerprint'] as String?;
    }
    var state = SyncTargetState.ready;
    String? error;
    if (secretRef == null || _secrets == null) {
      state = SyncTargetState.credentialRequired;
      error = 'Credential storage is unavailable or no reference is configured.';
    } else {
      final credential = await _secrets.read(secretRef);
      if (credential == null) {
        state = SyncTargetState.credentialRequired;
        error = 'The referenced credential is missing. Reauthorize the target.';
      } else {
        try {
          if (!_isCredentialDocumentValid(provider, credential, policy)) {
            state = SyncTargetState.credentialRequired;
            error = 'The saved credential is malformed. Reauthorize this destination.';
          } else if (provider == SyncProvider.oneDrive && _oneDriveTokenProvider == null) {
            state = SyncTargetState.credentialRequired;
            error = 'A Files-scoped OneDrive token adapter is unavailable. Reauthorize this destination.';
          }
        } finally {
          credential.fillRange(0, credential.length, 0);
        }
      }
    }
    if (state == SyncTargetState.ready && _policyRequiresEncryption(encryption)) {
      final key = encryptionSecretRef == null || _secrets == null
          ? null
          : await _secrets.read(encryptionSecretRef);
      if (key == null) {
        state = SyncTargetState.keyRequired;
        error = 'The configured encryption key is unavailable.';
      } else {
        try {
          if (key.length != 32 ||
              (expectedKeyFingerprint != null && sha256.convert(key).toString() != expectedKeyFingerprint)) {
            state = SyncTargetState.keyRequired;
            error = 'The historical encryption key does not match its approved fingerprint.';
          }
        } finally {
          key.fillRange(0, key.length, 0);
        }
      }
    }
    final verified = row['last_verified_at_utc'] as String?;
    return SyncTarget(
      targetId: row['target_id'] as String,
      epoch: _asInt(row['epoch']),
      provider: provider,
      displayName: row['display_name'] as String? ?? provider.name,
      encryption: encryption,
      largeUploadPolicy: _parseUploadPolicy(policy['large_upload'] as String? ?? 'automatic'),
      syncEnabled: policy['sync'] == true,
      backupEnabled: policy['backup'] == true,
      state: state,
      secretRef: secretRef,
      encryptionSecretRef: encryptionSecretRef,
      expectedEncryptionKeyFingerprint: expectedKeyFingerprint,
      endpoint: policy['endpoint'] as String?,
      region: policy['region'] as String?,
      bucket: policy['bucket'] as String?,
      driveId: policy['drive_id'] as String?,
      lastVerifiedAtUtc: verified == null ? null : DateTime.parse(verified).toUtc(),
      lastError: error,
    );
  }

  Future<SyncTarget> _targetFromEpochRow(DbRow row) async {
    final policyJson = row['policy_json'] as String;
    final policy = jsonDecode(policyJson) as Map<String, Object?>;
    final provider = _providerFromPolicy(policy);
    final generation = _asInt(row['authority_generation']);
    final staleGeneration = generation != _vault.database.authorityGeneration;
    final latestOverlay = _epochAuthorizationRow(row['target_id'] as String, _asInt(row['epoch']));
    DbRow? usableOverlay = latestOverlay;
    if (usableOverlay != null && !_authorizationMatches(
      usableOverlay,
      row['target_id'] as String,
      _asInt(row['epoch']),
      provider,
      policy,
    )) {
      usableOverlay = null;
    }
    final useHistoricalReferences = !staleGeneration && latestOverlay == null;
    final secretRef = useHistoricalReferences
        ? row['secret_ref']
        : usableOverlay?['credential_secret_ref'];
    final keyRef = useHistoricalReferences
        ? _encryptionFromPolicy(policy).keyRef?.value
        : usableOverlay?['encryption_secret_ref'];
    final keyFingerprint = useHistoricalReferences ? null : usableOverlay?['key_fingerprint'];
    return _targetFromRow(<String, Object?>{
      'target_id': row['target_id'],
      'epoch': row['epoch'],
      'provider': _providerName(provider),
      'policy_json': policyJson,
      'secret_ref': secretRef,
      'encryption_secret_ref': keyRef,
      'authority_generation': _vault.database.authorityGeneration,
      'expected_key_fingerprint': keyFingerprint,
      'display_name': policy['display_name'] ?? '${provider == SyncProvider.oneDrive ? 'OneDrive' : 'S3'} epoch ${row['epoch']}',
      'last_verified_at_utc': null,
    });
  }

  Future<SyncTarget> _targetForEpoch(String targetId, int epoch) async {
    final rows = _vault.database.query(
      'SELECT target_id,epoch,policy_json,secret_ref,authority_generation FROM remote_target_epochs '
      'WHERE target_id=? AND epoch=?',
      [targetId, epoch],
    );
    if (rows.isEmpty) {
      throw StateError('SYNC_EPOCH_METADATA_MISSING: target $targetId epoch $epoch is not recorded.');
    }
    return _targetFromEpochRow(rows.single);
  }

  DbRow _historicalEpochRecord(String targetId, int epoch) {
    if (epoch < 1) throw ArgumentError.value(epoch, 'epoch', 'Epoch must be positive.');
    final rows = _vault.database.query(
      'SELECT target_id,epoch,policy_json,secret_ref,authority_generation FROM remote_target_epochs '
      'WHERE target_id=? AND epoch=?',
      [targetId, epoch],
    );
    if (rows.isEmpty) {
      throw StateError('SYNC_EPOCH_METADATA_MISSING: target $targetId epoch $epoch is not recorded.');
    }
    return rows.single;
  }

  DbRow? _epochAuthorizationRow(String targetId, int epoch) {
    final rows = _vault.database.query(
      '''SELECT target_id,epoch,authority_generation,provider,endpoint_fingerprint,key_id,key_fingerprint,
                authorization_id,authorization_revision,credential_secret_ref,encryption_secret_ref,
                approval_ref,authorized_at_utc,command_id
         FROM remote_target_epoch_authorizations
         WHERE target_id=? AND epoch=? AND authority_generation=?
         ORDER BY authorization_revision DESC LIMIT 1''',
      [targetId, epoch, _vault.database.authorityGeneration],
    );
    return rows.isEmpty ? null : rows.single;
  }

  String _authorizationFailureReason(
    DbRow? authorization,
    String targetId,
    int epoch,
    SyncProvider provider,
    Map<String, Object?> policy,
  ) {
    if (authorization == null) {
      return 'This epoch needs fresh credentials and a local approval for the current installation.';
    }
    if (_asInt(authorization['authority_generation']) != _vault.database.authorityGeneration) {
      return 'The latest authorization belongs to an older installation authority. Reauthorize this epoch.';
    }
    final approvalRef = authorization['approval_ref'];
    if (approvalRef is! String) return 'The latest authorization has no local approval receipt.';
    final receiptRows = _vault.database.query(
      '''SELECT revoked_at_utc,expires_at_utc,issuer_device_id,authority_generation
         FROM approval_receipts WHERE approval_ref=?''',
      [approvalRef],
    );
    if (receiptRows.isEmpty) return 'The latest authorization approval receipt is unavailable.';
    final receipt = receiptRows.single;
    if (receipt['revoked_at_utc'] != null) {
      return 'The latest authorization was revoked. Add a new authorization revision to use this epoch.';
    }
    final expiryValue = receipt['expires_at_utc'];
    final expiry = expiryValue is String ? DateTime.tryParse(expiryValue)?.toUtc() : null;
    if (expiryValue is String && (expiry == null || !expiry.isAfter(_clock().toUtc()))) {
      return 'The latest authorization has expired. Add a new authorization revision to use this epoch.';
    }
    if (receipt['issuer_device_id'] != _vault.database.activeDeviceId ||
        _asInt(receipt['authority_generation']) != _vault.database.authorityGeneration) {
      return 'The latest approval belongs to another local authority. Reauthorize this epoch.';
    }
    if (!_authorizationMatches(authorization, targetId, epoch, provider, policy)) {
      return 'The latest authorization does not match the recorded endpoint, policy, key, or approval scope.';
    }
    return 'The latest authorization is unavailable. Add a new authorization revision to use this epoch.';
  }

  static SyncProvider _providerFromPolicy(Map<String, Object?> policy) => switch (policy['provider']) {
        'onedrive' => SyncProvider.oneDrive,
        's3' => SyncProvider.s3,
        _ => throw const FormatException('Historical sync epoch has an unsupported provider.'),
      };

  static String _providerName(SyncProvider provider) =>
      provider == SyncProvider.oneDrive ? 'onedrive' : 's3';

  static RemoteEncryptionPolicy _encryptionFromPolicy(Map<String, Object?> policy) =>
      RemoteEncryptionPolicy.fromJson(<String, Object?>{
        'mode': policy['encryption'] ?? 'none',
        'encrypt_metadata': policy['encrypt_metadata'],
        'encrypt_small_files': policy['encrypt_small_files'],
        'encrypt_large_files': policy['encrypt_large_files'],
        'key_id': policy['key_id'],
        'large_file_threshold_bytes': policy['large_file_threshold_bytes'],
      });

  static bool _policyRequiresEncryption(RemoteEncryptionPolicy encryption) =>
      encryption.mode != RemoteEncryptionMode.none ||
      encryption.encryptMetadata ||
      encryption.encryptSmallFiles ||
      encryption.encryptLargeFiles;

  static String _endpointFingerprint({
    required String targetId,
    required int epoch,
    required SyncProvider provider,
    required Map<String, Object?> policy,
  }) {
    final location = <String, Object?>{
      'target_id': targetId,
      'epoch': epoch,
      'provider': _providerName(provider),
      'endpoint': policy['endpoint'],
      'region': policy['region'],
      'bucket': policy['bucket'],
      'drive_id': policy['drive_id'],
    };
    return sha256.convert(utf8.encode(canonicalJson(location))).toString();
  }

  bool _authorizationMatches(
    DbRow authorization,
    String targetId,
    int epoch,
    SyncProvider provider,
    Map<String, Object?> policy,
  ) {
    final encryption = _encryptionFromPolicy(policy);
    final historical = _historicalEpochRecord(targetId, epoch);
    final sourceCredentialRef = historical['secret_ref'] as String?;
    final credentialSecretRef = authorization['credential_secret_ref'];
    final encryptionSecretRef = authorization['encryption_secret_ref'];
    if (authorization['target_id'] != targetId ||
        _asInt(authorization['epoch']) != epoch ||
        _asInt(authorization['authority_generation']) != _vault.database.authorityGeneration ||
        authorization['provider'] != _providerName(provider) ||
        authorization['endpoint_fingerprint'] != _endpointFingerprint(
          targetId: targetId,
          epoch: epoch,
          provider: provider,
          policy: policy,
        ) ||
        authorization['key_id'] != encryption.keyRef?.value ||
        credentialSecretRef is! String || credentialSecretRef.isEmpty ||
        credentialSecretRef == sourceCredentialRef ||
        (encryptionSecretRef is String && encryptionSecretRef == encryption.keyRef?.value) ||
        ((authorization['key_id'] == null &&
                (authorization['key_fingerprint'] != null || encryptionSecretRef != null)) ||
            (authorization['key_id'] != null &&
                (authorization['key_fingerprint'] is! String ||
                    encryptionSecretRef is! String ||
                    encryptionSecretRef.isEmpty))) ||
        (_policyRequiresEncryption(encryption) && authorization['key_id'] == null)) {
      return false;
    }
    final approvalRef = authorization['approval_ref'];
    if (approvalRef is! String) return false;
    final approvalRows = _vault.database.query(
      '''SELECT action,subject_type,subject_id,scope_json,approved_at_utc,expires_at_utc,revoked_at_utc,
                issuer_device_id,authority_generation
         FROM approval_receipts WHERE approval_ref=?''',
      [approvalRef],
    );
    if (approvalRows.isEmpty) return false;
    final receipt = approvalRows.single;
    final authorizedAtValue = authorization['authorized_at_utc'];
    final approvedAtValue = receipt['approved_at_utc'];
    if (authorizedAtValue is! String || approvedAtValue is! String) return false;
    final authorizedAt = DateTime.tryParse(authorizedAtValue)?.toUtc();
    final approvedAt = DateTime.tryParse(approvedAtValue)?.toUtc();
    final expiresAtValue = receipt['expires_at_utc'];
    final expiresAt = expiresAtValue is String ? DateTime.tryParse(expiresAtValue)?.toUtc() : null;
    if (authorizedAt == null || approvedAt == null || (expiresAtValue is String && expiresAt == null)) return false;
    final expectedScope = <String, Object?>{
      'target_id': targetId,
      'epoch': epoch,
      'provider': _providerName(provider),
      'endpoint_fingerprint': authorization['endpoint_fingerprint'],
      'key_id': authorization['key_id'],
      'key_fingerprint': authorization['key_fingerprint'],
    };
    Object? storedScope;
    try {
      storedScope = jsonDecode(receipt['scope_json'] as String);
    } on Object {
      return false;
    }
    return receipt['action'] == 'sync.epoch.reauthorize' &&
        receipt['subject_type'] == 'remote_target_epoch' &&
        receipt['subject_id'] == '$targetId@$epoch' &&
        receipt['issuer_device_id'] == _vault.database.activeDeviceId &&
        _asInt(receipt['authority_generation']) == _vault.database.authorityGeneration &&
        receipt['revoked_at_utc'] == null &&
        (expiresAt == null ||
            (expiresAt.isAfter(authorizedAt) && expiresAt.isAfter(_clock().toUtc()))) &&
        !approvedAt.isAfter(authorizedAt) &&
        storedScope is Map<String, Object?> &&
        canonicalJson(storedScope) == canonicalJson(expectedScope);
  }

  Future<Uint8List> _readAndValidateCredential(
    SecretRef reference,
    SyncProvider provider,
    Map<String, Object?> policy,
  ) async {
    final credential = await _secrets?.read(reference);
    if (credential == null) throw SyncCredentialRequiredException(provider);
    if (!_isCredentialDocumentValid(provider, credential, policy)) {
      credential.fillRange(0, credential.length, 0);
      throw const FormatException('Selected historical credential is malformed for its immutable provider/location.');
    }
    if (provider == SyncProvider.oneDrive && _oneDriveTokenProvider == null) {
      credential.fillRange(0, credential.length, 0);
      throw const FormatException('A Files-scoped OneDrive token adapter is unavailable.');
    }
    return credential;
  }

  Future<String> _secretFingerprint(SecretRef reference) async {
    final key = await _secrets?.read(reference);
    if (key == null) throw SyncKeyRequiredException(reference);
    try {
      if (key.length != 32) throw const FormatException('Historical encryption key must contain exactly 32 bytes.');
      return sha256.convert(key).toString();
    } finally {
      key.fillRange(0, key.length, 0);
    }
  }

  static bool _epochStoragePolicyChanged(
    Map<String, Object?> oldPolicy,
    Map<String, Object?> newPolicy,
  ) {
    const storageKeys = <String>[
      'provider',
      'encryption',
      'encrypt_metadata',
      'encrypt_small_files',
      'encrypt_large_files',
      'key_id',
      'large_file_threshold_bytes',
      'endpoint',
      'region',
      'bucket',
      'drive_id',
    ];
    return storageKeys.any((key) => oldPolicy[key] != newPolicy[key]);
  }

  Future<({RemoteObjectConnector connector, Uint8List? encryptionKey})> _openConnector(
    SyncTarget target, {
    bool requireEncryptionKey = true,
  }) async {
    if (_secrets == null || target.secretRef == null) throw SyncCredentialRequiredException(target.provider);
    final raw = await _secrets.read(target.secretRef!);
    if (raw == null) throw SyncCredentialRequiredException(target.provider);
    late final Map<String, Object?> decoded;
    try {
      final value = jsonDecode(utf8.decode(raw));
      if (value is! Map<String, Object?> || !_isCredentialDocumentValid(target.provider, raw, {
        'drive_id': target.driveId,
        'endpoint': target.endpoint,
        'region': target.region,
        'bucket': target.bucket,
      })) {
        throw const FormatException('Saved remote credentials are malformed.');
      }
      decoded = value;
    } finally {
      raw.fillRange(0, raw.length, 0);
    }
    final credential = decoded;
    final keyRequired = target.encryption.encryptMetadata ||
        target.encryption.encryptSmallFiles ||
        target.encryption.encryptLargeFiles ||
        target.encryption.mode != RemoteEncryptionMode.none;
    Uint8List? key;
    if (keyRequired) {
      if (target.encryption.keyRef == null) {
        if (requireEncryptionKey) throw const SyncKeyRequiredException(null);
      } else {
        final keyRef = target.encryptionSecretRef ?? target.encryption.keyRef!;
        key = await _secrets.read(keyRef);
        if (key == null || key.length != 32) {
          key?.fillRange(0, key.length, 0);
          if (requireEncryptionKey) throw SyncKeyRequiredException(target.encryption.keyRef);
          key = null;
        } else if (target.expectedEncryptionKeyFingerprint != null &&
            sha256.convert(key).toString() != target.expectedEncryptionKeyFingerprint) {
          key.fillRange(0, key.length, 0);
          throw SyncKeyRequiredException(target.encryption.keyRef);
        }
      }
    }
    final connector = switch (target.provider) {
      SyncProvider.oneDrive => OneDriveGraphConnector(
          accessTokenProvider: () => _oneDriveTokenProvider!.accessToken(target.secretRef!),
          driveId: target.driveId ?? credential['drive_id'] as String?,
        ),
      SyncProvider.s3 => S3ObjectConnector(
          endpoint: Uri.parse(target.endpoint!),
          region: target.region!,
          bucket: target.bucket!,
          accessKeyId: credential['access_key_id'] as String? ?? '',
          secretAccessKey: credential['secret_access_key'] as String? ?? '',
          sessionToken: credential['session_token'] as String?,
          journalDirectory: p.join(_vault.rootDirectory, 'sync', 'multipart', target.targetId),
        ),
    };
    return (connector: connector, encryptionKey: key);
  }

  Future<({bool uploaded, int bytes})> _uploadBlob(
    SyncTarget target,
    RemoteObjectConnector connector,
    String base,
    String sha,
    Uint8List? keyBytes,
  ) async {
    final known = _vault.database.query(
      '''SELECT b.byte_size,b.state,
                (SELECT a.asset_id FROM assets a WHERE a.blob_sha256=b.sha256
                 ORDER BY a.deleted_at_utc IS NULL DESC,a.created_at_utc LIMIT 1) AS asset_id
         FROM blob_objects b WHERE b.sha256=?''',
      [sha],
    );
    if (known.isEmpty || known.single['state'] != 'committed') throw AssetMissingException(sha);
    final assetId = known.single['asset_id'] as String?;
    final temporary = File(p.join(Directory.systemTemp.path, 'lw-sync-$sha-${newUuidV7()}.part'));
    final verified = await _assets.writeVerifiedBlobSnapshot(
      blobSha256: sha,
      destinationPath: temporary.path,
    );
    try {
      if (verified.sha256 != sha || verified.byteSize != _asInt(known.single['byte_size'])) {
        throw AssetIntegrityException(
          assetId: assetId ?? 'blob:$sha',
          expectedSha256: sha,
          actualSha256: verified.sha256,
        );
      }
      String sourcePath = temporary.path;
      final encrypt = target.encryption.encryptsObject(metadata: false, byteSize: verified.byteSize);
      if (encrypt) {
        final encryptedPath = temporary.path + '.enc';
        await _encryption.encryptFile(keyBytes: keyBytes!, sourcePath: temporary.path, destinationPath: encryptedPath);
        sourcePath = encryptedPath;
      }
      final hideMetadata = target.encryption.encryptsObject(metadata: true, byteSize: 1);
      final objectKey = hideMetadata
          ? '$base/objects/opaque/${_opaqueDigest(keyBytes!, sha)}'
          : '$base/objects/sha256/$sha';
      await _putVerifiedFile(connector, objectKey, sourcePath, expectedPlainSha: sha,
          encrypted: encrypt, keyBytes: keyBytes);
      final transferSize = await File(sourcePath).length();
      final transferChecksum = await _hashFile(sourcePath);
      final plaintextSize = verified.byteSize;
      _vault.database.transaction((tx) {
        final old = tx.query(
          'SELECT replica_id FROM remote_replicas WHERE target_id=? AND blob_sha256=?',
          [target.targetId, sha],
        );
        final replicaId = old.isEmpty ? newUuidV7() : old.single['replica_id'] as String;
        if (old.isEmpty) {
          tx.execute(
            'INSERT INTO remote_replicas(replica_id,target_id,blob_sha256,remote_object_key,encryption_mode,'
            'last_transfer_checksum,state,verified_at_utc,content_sha256,key_id,format_version,source_asset_id,'
            'byte_size,verification_level,updated_at_utc,policy_epoch) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)',
            [replicaId, target.targetId, sha, objectKey, encrypt ? 'aes_gcm_chunked_v1' : 'none',
              transferChecksum, 'available', _clock().toUtc().toIso8601String(), sha,
              encrypt ? target.encryption.keyRef?.value : null,
              encrypt ? 'LWAE/1' : null, assetId, plaintextSize,
              'downloaded_sha256_verified', _clock().toUtc().toIso8601String(), target.epoch],
          );
        } else {
          tx.execute(
            'UPDATE remote_replicas SET remote_object_key=?,encryption_mode=?,last_transfer_checksum=?,'
            'state=?,verified_at_utc=?,content_sha256=?,key_id=?,format_version=?,source_asset_id=?,byte_size=?,'
            'verification_level=?,updated_at_utc=? WHERE replica_id=?',
            [objectKey, encrypt ? 'aes_gcm_chunked_v1' : 'none', transferChecksum, 'available',
              _clock().toUtc().toIso8601String(), sha, encrypt ? target.encryption.keyRef?.value : null,
              encrypt ? 'LWAE/1' : null, assetId, plaintextSize,
              'downloaded_sha256_verified', _clock().toUtc().toIso8601String(), replicaId],
          );
        }
        return null;
      });
      return (uploaded: true, bytes: transferSize);
    } finally {
      if (await temporary.exists()) await temporary.delete();
      final encryptedFile = File(temporary.path + '.enc');
      if (await encryptedFile.exists()) await encryptedFile.delete();
    }
  }

  Future<({int events, int bytes, List<String> warnings})> _receiveEvents(
    SyncTarget target,
    RemoteObjectConnector connector,
    String base,
    Uint8List? keyBytes,
  ) async {
    final encrypted = target.encryption.encryptsObject(metadata: true, byteSize: 1);
    final keys = <String>[
      for (final object in await connector.list(encrypted ? '$base/events/opaque/' : '$base/events/')) object.key,
    ]..sort();
    var count = 0;
    var bytes = 0;
    final warnings = <String>[];
    for (final key in keys) {
      try {
        final wire = await connector.getBytes(key, maximumBytes: 32 * 1024 * 1024);
        bytes += wire.length;
        final clear = encrypted ? await _encryption.decryptBytes(wire, keyBytes!) : wire;
        final text = utf8.decode(clear, allowMalformed: false);
        final document = jsonDecode(text) as Map<String, Object?>;
        _validateSyncEnvelope(document, _vault.vaultId);
        if (document['device_id'] == _vault.deviceId) continue;
        final eventId = document['event_id'] as String;
        final contentHash = sha256.convert(clear).toString();
        final insertion = _recordRemoteEvent(
          target.targetId,
          eventId,
          document,
          contentHash,
          text,
          _clock().toUtc(),
        );
        if (insertion.inserted) count++;
      } on Object catch (error) {
        final warning = 'Remote event $key was retained or skipped: ${_safeError(error)}';
        warnings.add(warning);
      }
    }
    return (
      events: count,
      bytes: bytes,
      warnings: List<String>.unmodifiable(warnings),
    );
  }

  /// Materializes events only after their referenced immutable blobs have
  /// arrived. Events are ordered per originating device by sequence so parent
  /// records precede child records. Only a missing-parent block is retried;
  /// unknown or invalid handlers stay blocked for review.
  ({int applied, int pendingReview, int blocked, int conflicts}) _applyReceivedEvents(String targetId) {
    final outcomes = <String, RemoteEventApplicationResult>{};
    var retry = true;
    while (retry) {
      retry = false;
      final rows = _vault.database.query(
        '''SELECT e.event_id,e.device_id,e.sequence,e.application_state,e.application_error
           FROM sync_remote_events e
           JOIN sync_remote_event_targets t ON t.event_id=e.event_id
           WHERE t.target_id=? AND (e.application_state='received' OR
             (e.application_state='blocked' AND e.application_error='REMOTE_PARENT_MISSING'))
           ORDER BY e.device_id,e.sequence,e.event_id''',
        [targetId],
      );
      for (final row in rows) {
        final eventId = row['event_id'] as String;
        final application = _vault.database.transaction((tx) => _eventApplication.applyReceived(
              tx,
              eventId: eventId,
              targetId: targetId,
              atUtc: _clock().toUtc(),
            ));
        outcomes[eventId] = application;
        if (application.state == RemoteEventApplicationState.applied ||
            application.state == RemoteEventApplicationState.conflicted) {
          retry = true;
        }
      }
    }
    var applied = 0;
    var pendingReview = 0;
    var blocked = 0;
    var conflicts = 0;
    for (final result in outcomes.values) {
      switch (result.state) {
        case RemoteEventApplicationState.applied:
          applied++;
          break;
        case RemoteEventApplicationState.conflicted:
          pendingReview++;
          conflicts++;
          break;
        case RemoteEventApplicationState.blocked:
          blocked++;
          break;
      }
    }
    _assets.releaseMaterializedSynchronizedBlobs();
    return (applied: applied, pendingReview: pendingReview, blocked: blocked, conflicts: conflicts);
  }

  Future<({int count, int bytes})> _receiveReferencedBlobs(
    SyncTarget target,
    RemoteObjectConnector connector,
    String base,
    Uint8List? keyBytes,
  ) async {
    final events = _vault.database.query(
      '''SELECT e.asset_sha_refs_json,e.payload_json FROM sync_remote_events e
         JOIN sync_remote_event_targets t ON t.event_id=e.event_id
         WHERE t.target_id=? AND (e.application_state='received' OR
           (e.application_state='blocked' AND e.application_error='REMOTE_PARENT_MISSING'))''',
      [target.targetId],
    );
    final refs = <String>{};
    final expectedBytesBySha = <String, int>{};
    for (final event in events) {
      final value = jsonDecode(event['asset_sha_refs_json'] as String) as List<dynamic>;
      refs.addAll(value.cast<String>());
      final payload = jsonDecode(event['payload_json'] as String) as Map<String, Object?>;
      if (payload['blob_sha256'] is String && payload['byte_size'] is int) {
        expectedBytesBySha[payload['blob_sha256'] as String] = payload['byte_size'] as int;
      }
    }
    var received = 0;
    var total = 0;
    for (final sha in refs) {
      final local = _vault.database.query('SELECT byte_size,state FROM blob_objects WHERE sha256=?', [sha]);
      if (local.isNotEmpty && local.single['state'] == 'committed') {
        try {
          await _assets.verifyBlobForRemoteProjection(
            blobSha256: sha,
            expectedBytes: _asInt(local.single['byte_size']),
          );
          continue;
        } on AssetMissingException {
          // Fetch the immutable remote copy to repair a missing local CAS file.
        } on AssetIntegrityException {
          // receiveSynchronizedBlob quarantines a corrupt local copy before repair.
        }
      }
      final expectedBytes = expectedBytesBySha[sha] ??
          (local.isEmpty ? null : _asInt(local.single['byte_size']));
      final key = target.encryption.encryptsObject(metadata: true, byteSize: 1)
          ? '$base/objects/opaque/${_opaqueDigest(keyBytes!, sha)}'
          : '$base/objects/sha256/$sha';
      final downloaded = File(p.join(Directory.systemTemp.path, 'lw-sync-in-$sha-${newUuidV7()}.part'));
      await connector.downloadToFile(key, downloaded.path);
      final encryptedFile = downloaded.path + '.enc';
      var clearPath = downloaded.path;
      try {
        if (await _hasChunkedEncryptionHeader(downloaded)) {
          await _encryption.decryptFile(keyBytes: keyBytes!, sourcePath: downloaded.path, destinationPath: encryptedFile);
          clearPath = encryptedFile;
        } else if (target.encryption.encryptsObject(
          metadata: false,
          byteSize: expectedBytes ?? await downloaded.length(),
        )) {
          throw StateError('Remote Blob is plaintext although this target policy requires encryption.');
        }
        final digest = await _hashFile(clearPath);
        if (digest != sha) throw StateError('Downloaded blob $sha failed SHA-256 verification.');
        final size = await File(clearPath).length();
        await _assets.receiveSynchronizedBlob(
          expectedSha256: sha,
          expectedBytes: size,
          sourceTargetId: target.targetId,
          content: File(clearPath).openRead(),
        );
        final transferChecksum = await _hashFile(downloaded.path);
        final transferSize = await downloaded.length();
        _recordRemoteReplica(
          target: target,
          sha: sha,
          remoteKey: key,
          plaintextBytes: size,
          transferChecksum: transferChecksum,
          encrypted: clearPath != downloaded.path,
          verificationLevel: 'downloaded_sha256_verified',
        );
        total += transferSize;
        received++;
      } finally {
        if (await downloaded.exists()) await downloaded.delete();
        final clearFile = File(encryptedFile);
        if (await clearFile.exists()) await clearFile.delete();
      }
    }
    return (count: received, bytes: total);
  }

  void _recordRemoteReplica({
    required SyncTarget target,
    required String sha,
    required String remoteKey,
    required int plaintextBytes,
    required String transferChecksum,
    required bool encrypted,
    required String verificationLevel,
  }) {
    _vault.database.transaction((tx) {
      final rows = tx.query(
        'SELECT replica_id FROM remote_replicas WHERE target_id=? AND blob_sha256=?',
        [target.targetId, sha],
      );
      final now = _clock().toUtc().toIso8601String();
      final replicaId = rows.isEmpty ? newUuidV7() : rows.single['replica_id'] as String;
      if (rows.isEmpty) {
        tx.execute(
          'INSERT INTO remote_replicas(replica_id,target_id,blob_sha256,remote_object_key,encryption_mode,'
          'last_transfer_checksum,state,verified_at_utc,content_sha256,key_id,format_version,byte_size,'
          'verification_level,updated_at_utc,policy_epoch) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)',
          [replicaId, target.targetId, sha, remoteKey, encrypted ? 'aes_gcm_chunked_v1' : 'none',
            transferChecksum, 'verified', now, sha, encrypted ? target.encryption.keyRef?.value : null,
            encrypted ? 'LWAE/1' : null, plaintextBytes, verificationLevel, now, target.epoch],
        );
      } else {
        tx.execute(
          'UPDATE remote_replicas SET remote_object_key=?,encryption_mode=?,last_transfer_checksum=?,'
          'state=?,verified_at_utc=?,content_sha256=?,key_id=?,format_version=?,byte_size=?,'
          'verification_level=?,updated_at_utc=?,policy_epoch=? WHERE replica_id=?',
          [remoteKey, encrypted ? 'aes_gcm_chunked_v1' : 'none', transferChecksum, 'verified', now, sha,
            encrypted ? target.encryption.keyRef?.value : null, encrypted ? 'LWAE/1' : null,
            plaintextBytes, verificationLevel, now, target.epoch, replicaId],
        );
      }
      return null;
    });
  }

  ({bool inserted, bool conflict}) _recordRemoteEvent(
    String targetId,
    String eventId,
    Map<String, Object?> document,
    String contentHash,
    String wireJson,
    DateTime now,
  ) {
    return _vault.database.transaction((tx) {
      final schemaVersion = document['schema_version'] as String;
      final indexedCommandId = schemaVersion == '3.0' ? document['command_id'] as String : eventId;
      final indexedEventType = schemaVersion == '3.0'
          ? document['event_type'] as String
          : 'remote.${document['action']}';
      final existing = tx.query(
        'SELECT content_sha256,application_state,wire_json,command_id,event_type '
        'FROM sync_remote_events WHERE event_id=?',
        [eventId],
      );
      if (existing.isNotEmpty && existing.single['content_sha256'] != contentHash) {
        throw StateError('Immutable event id $eventId was reused with different content.');
      }
      final isNew = existing.isEmpty;
      if (isNew) {
        tx.execute(
          'INSERT INTO sync_remote_events(event_id,command_id,device_id,sequence,lamport,entity_kind,entity_id,'
          'base_revision,event_type,action,payload_json,wire_json,asset_sha_refs_json,created_at_utc,content_sha256,source_target_id) '
          'VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)',
          [eventId, indexedCommandId, document['device_id'], document['seq'], document['lamport'], document['entity_kind'],
            document['entity_id'], document['base_revision'], indexedEventType, document['action'],
            jsonEncode(document['payload']), wireJson, jsonEncode(document['sha_refs']), document['created_at_utc'], contentHash, targetId],
        );
      } else if (existing.single['wire_json'] == null) {
        tx.execute(
          'UPDATE sync_remote_events SET wire_json=?,command_id=?,event_type=? WHERE event_id=?',
          [wireJson, indexedCommandId, indexedEventType, eventId],
        );
      }
      tx.execute(
        'INSERT INTO sync_remote_event_targets(target_id,event_id,received_at_utc,state) VALUES(?,?,?,?) '
        'ON CONFLICT(target_id,event_id) DO UPDATE SET received_at_utc=excluded.received_at_utc',
        [targetId, eventId, now.toIso8601String(),
          isNew ? 'received' : existing.single['application_state']],
      );
      final cursor = tx.query('SELECT received_seq FROM sync_cursors WHERE target_id=? AND device_id=?',
          [targetId, document['device_id']]);
      final sequence = _asInt(document['seq']);
      if (cursor.isEmpty) {
        tx.execute('INSERT INTO sync_cursors(target_id,device_id,received_seq) VALUES(?,?,?)',
            [targetId, document['device_id'], sequence]);
      } else if (sequence > _asInt(cursor.single['received_seq'])) {
        tx.execute('UPDATE sync_cursors SET received_seq=? WHERE target_id=? AND device_id=?',
            [sequence, targetId, document['device_id']]);
      }
      if (!isNew) return (inserted: false, conflict: false);
      final local = tx.query(
        'SELECT event_id,device_id,base_revision,action,payload_json FROM mutation_events WHERE entity_kind=? AND entity_id=? AND device_id<>?',
        [document['entity_kind'], document['entity_id'], document['device_id']],
      );
      final remote = tx.query(
        'SELECT event_id,device_id,base_revision,action,payload_json FROM sync_remote_events WHERE entity_kind=? AND entity_id=? AND event_id<>?',
        [document['entity_kind'], document['entity_id'], eventId],
      );
      final currentPayload = document['payload'] as Map<String, Object?>;
      final concurrent = <DbRow>[...local, ...remote].where((candidate) {
        final candidatePayload = jsonDecode(candidate['payload_json'] as String) as Map<String, Object?>;
        final deleteRestore = candidate['device_id'] != document['device_id'] && _isDeleteRestorePair(
          candidate['action'] as String,
          candidatePayload,
          document['action'] as String,
          currentPayload,
        );
        return deleteRestore ||
            (candidate['base_revision'] != null && candidate['base_revision'] == document['base_revision']);
      });
      var conflict = false;
      for (final candidate in concurrent) {
        final a = candidate['event_id'] as String;
        final pair = [a, eventId]..sort();
        final duplicate = tx.query(
          'SELECT 1 FROM sync_conflicts WHERE event_id_a=? AND event_id_b=? AND state="open"',
          pair,
        );
        if (duplicate.isEmpty) {
          tx.execute(
            'INSERT INTO sync_conflicts(conflict_id,entity_kind,entity_id,event_id_a,event_id_b,state,created_at_utc) '
            'VALUES(?,?,?,?,?,?,?)',
            [newUuidV7(at: now), document['entity_kind'], document['entity_id'], pair[0], pair[1], 'open', now.toIso8601String()],
          );
          conflict = true;
        }
      }
      return (inserted: true, conflict: conflict);
    });
  }

  Future<void> _putVerifiedBytes(RemoteObjectConnector connector, String key, List<int> bytes) async {
    try {
      await connector.putBytes(key, bytes);
    } on StateError catch (error) {
      if (!error.toString().contains('already exists')) rethrow;
      final existing = await connector.getBytes(key, maximumBytes: bytes.length + 1);
      if (sha256.convert(existing) != sha256.convert(bytes)) rethrow;
    }
    final existing = await connector.getBytes(key, maximumBytes: bytes.length + 1);
    if (sha256.convert(existing) != sha256.convert(bytes)) {
      throw StateError('Remote event $key failed read-after-write SHA-256 verification.');
    }
  }

  Future<void> _putVerifiedEncryptedEvent(
    RemoteObjectConnector connector,
    String key,
    List<int> ciphertext,
    List<int> cleartext,
    Uint8List keyBytes,
  ) async {
    try {
      await connector.putBytes(key, ciphertext);
    } on StateError catch (error) {
      if (!error.toString().contains('already exists')) rethrow;
    }
    final stored = await connector.getBytes(key, maximumBytes: ciphertext.length + 1);
    final decrypted = await _encryption.decryptBytes(stored, keyBytes);
    if (sha256.convert(decrypted).toString() != sha256.convert(cleartext).toString()) {
      throw StateError('Encrypted remote event $key failed authenticated read-after-write verification.');
    }
  }

  static bool _isCredentialDocumentValid(
    SyncProvider provider,
    List<int> bytes,
    Map<String, Object?> policy,
  ) {
    try {
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map<String, Object?>) return false;
      if (provider == SyncProvider.oneDrive) {
        final token = decoded['access_token'];
        return token is String && token.trim().isNotEmpty;
      }
      final accessKey = decoded['access_key_id'];
      final secret = decoded['secret_access_key'];
      final endpoint = policy['endpoint'];
      final region = policy['region'];
      final bucket = policy['bucket'];
      if (accessKey is! String || accessKey.trim().isEmpty ||
          secret is! String || secret.isEmpty ||
          endpoint is! String || region is! String || region.trim().isEmpty ||
          bucket is! String || bucket.trim().isEmpty) {
        return false;
      }
      final uri = Uri.parse(endpoint);
      return uri.isScheme('https') && uri.hasAuthority;
    } on Object {
      return false;
    }
  }

  Future<void> _putVerifiedFile(
    RemoteObjectConnector connector,
    String key,
    String filePath, {
    required String expectedPlainSha,
    required bool encrypted,
    required Uint8List? keyBytes,
  }) async {
    try {
      await connector.putFile(key, filePath);
    } on StateError catch (error) {
      if (!error.toString().contains('already exists')) rethrow;
    }
    final remoteFile = File(p.join(Directory.systemTemp.path, 'lw-sync-verify-${newUuidV7()}.part'));
    final decodedFile = File(remoteFile.path + '.clear');
    try {
      await connector.downloadToFile(key, remoteFile.path);
      if (encrypted) {
        await _encryption.decryptFile(keyBytes: keyBytes!, sourcePath: remoteFile.path, destinationPath: decodedFile.path);
        if (await _hashFile(decodedFile.path) != expectedPlainSha) {
          throw StateError('Remote object $key failed plaintext SHA-256 verification.');
        }
      } else if (await _hashFile(remoteFile.path) != expectedPlainSha) {
        throw StateError('Remote object $key failed SHA-256 verification.');
      }
    } finally {
      if (await remoteFile.exists()) await remoteFile.delete();
      if (await decodedFile.exists()) await decodedFile.delete();
    }
  }

  void _markEventSent(String targetId, String eventId, String key, DateTime now) {
    _vault.database.transaction((tx) {
      tx.execute(
        'INSERT INTO sync_outbox_targets(target_id,event_id,state,attempts,next_attempt_at_utc,last_error,remote_key,updated_at_utc) '
        'VALUES(?,?,?,1,?,NULL,?,?) ON CONFLICT(target_id,event_id) DO UPDATE SET '
        'state=excluded.state,attempts=sync_outbox_targets.attempts+1,last_error=NULL,remote_key=excluded.remote_key,updated_at_utc=excluded.updated_at_utc',
        [targetId, eventId, 'sent', now.toIso8601String(), key, now.toIso8601String()],
      );
      return null;
    });
  }

  void _markEventFailed(String targetId, String eventId, String error, DateTime now) {
    _vault.database.execute(
      'INSERT INTO sync_outbox_targets(target_id,event_id,state,attempts,next_attempt_at_utc,last_error,remote_key,updated_at_utc) '
      'VALUES(?,?,?,1,?,?,NULL,?) ON CONFLICT(target_id,event_id) DO UPDATE SET '
      'state=excluded.state,attempts=sync_outbox_targets.attempts+1,next_attempt_at_utc=excluded.next_attempt_at_utc,'
      'last_error=excluded.last_error,updated_at_utc=excluded.updated_at_utc',
      [targetId, eventId, 'failed', now.toIso8601String(), error, now.toIso8601String()],
    );
  }

  void _markGlobalOutboxSentIfAllTargetsDelivered() {
    _vault.database.execute(
      "UPDATE outbox SET state='sent' WHERE NOT EXISTS ("
      'SELECT 1 FROM remote_targets t LEFT JOIN sync_outbox_targets s ON s.target_id=t.target_id AND s.event_id=outbox.outbox_id '
      "WHERE json_extract(t.policy_json,'\$.sync')=1 AND (s.event_id IS NULL OR s.state!='sent'))",
    );
  }

  static bool _isDeleteRestorePair(
    String firstAction,
    Map<String, Object?> firstPayload,
    String secondAction,
    Map<String, Object?> secondPayload,
  ) {
    final firstIsDelete = firstAction == 'tombstone' && firstPayload.containsKey('deletion_id');
    final firstIsRestore = firstAction == 'patch' && firstPayload.containsKey('restored_at_utc');
    final secondIsDelete = secondAction == 'tombstone' && secondPayload.containsKey('deletion_id');
    final secondIsRestore = secondAction == 'patch' && secondPayload.containsKey('restored_at_utc');
    return (firstIsDelete && secondIsRestore) || (secondIsDelete && firstIsRestore);
  }

  DbRow? _targetRow(String targetId) {
    final rows = _vault.database.query('SELECT * FROM remote_targets WHERE target_id=?', [targetId]);
    return rows.isEmpty ? null : rows.single;
  }

  String _remoteBase(SyncTarget target) => 'lab-workspace/v2/${_vault.vaultId}/epoch-${target.epoch}';

  String _backupCatalogPrefix(SyncTarget target) => '${_remoteBase(target)}/backup-index/';

  String _backupCatalogKey(SyncTarget target, String backupId, Uint8List? keyBytes) {
    final prefix = _backupCatalogPrefix(target);
    if (target.encryption.encryptsObject(metadata: true, byteSize: 1)) {
      if (keyBytes == null) throw SyncKeyRequiredException(target.encryption.keyRef);
      return '$prefix${_opaqueDigest(keyBytes, 'backup-catalog:$backupId')}';
    }
    return '$prefix$backupId.json';
  }

  String _backupStorageBase(SyncTarget target, String backupId, Uint8List? keyBytes) {
    final prefix = '${_remoteBase(target)}/backups/';
    if (target.encryption.encryptsObject(metadata: true, byteSize: 1)) {
      if (keyBytes == null) throw SyncKeyRequiredException(target.encryption.keyRef);
      return '$prefix${_opaqueDigest(keyBytes, 'backup:$backupId')}';
    }
    return '$prefix$backupId';
  }

  SyncRunResult _runResult(String targetId, String state, DateTime startedAt,
          {List<String> warnings = const []}) =>
      SyncRunResult(
        targetId: targetId,
        state: state,
        eventsUploaded: 0,
        eventsReceived: 0,
        eventsApplied: 0,
        eventsPendingReview: 0,
        eventsBlocked: 0,
        blobsUploaded: 0,
        blobsReceived: 0,
        conflictsPreserved: 0,
        bytesTransferred: 0,
        completedAtUtc: _clock().toUtc(),
        warnings: warnings,
      );
}

void _validateSyncEnvelope(Map<String, Object?> document, String vaultId) {
  const v3EventTypes = <String>{
    'project.created', 'project.updated', 'experiment.created', 'experiment.updated',
    'group.created', 'group.updated', 'protocol.draft_saved', 'protocol.approved',
    'run.created', 'run.sample_attached', 'run.closed', 'schedule.rebuilt',
    'step.added', 'step.started', 'step.completed', 'sample.created',
    'treatment.recorded', 'treatment.corrected', 'measurement.recorded',
    'measurement.corrected', 'measurement.confirmed', 'measurement.external_reviewed',
    'task.created', 'task.updated', 'task.completed', 'task.deleted',
    'reminder.created', 'reminder.delivery_updated', 'setting.updated',
    'calculation.completed', 'calculation.failed', 'calculation_pack.installed',
    'AssetImported', 'AssetTrashed', 'AssetPurged', 'AssetRestored',
    'AssetBlobReleased', 'AssetFolderCreated', 'AssetAddedToFolder',
    'AssetRemovedFromFolder', 'AssetPurgeRecoveryRequired', 'AssetIntegrityFailed',
    'sync.target.created', 'sync.target.updated', 'sync.target.removed',
    'BackupSnapshotCreated', 'BackupSnapshotFailed', 'BackupSnapshotStateChanged',
    'BackupRestoreVerified',
  };
  const v2Fields = <String>{
    'schema_version', 'vault_id', 'device_id', 'seq', 'lamport', 'event_id',
    'entity_kind', 'entity_id', 'base_revision', 'action', 'payload', 'sha_refs', 'created_at_utc',
  };
  const v3Fields = <String>{
    ...v2Fields,
    'command_id',
    'event_type',
  };
  final version = document['schema_version'];
  final required = switch (version) {
    '2.0' => v2Fields,
    '3.0' => v3Fields,
    _ => throw const FormatException('Sync envelope schema version is unsupported.'),
  };
  if (document.keys.toSet().difference(required).isNotEmpty ||
      !document.keys.toSet().containsAll(required)) {
    throw FormatException('Sync envelope does not match $version fields.');
  }
  if (document['vault_id'] != vaultId) {
    throw const FormatException('Sync envelope schema or Vault id is invalid.');
  }
  final textFields = <String>[
    'device_id', 'event_id', 'entity_kind', 'entity_id', 'action', 'created_at_utc',
    if (version == '3.0') 'command_id',
    if (version == '3.0') 'event_type',
  ];
  for (final field in textFields) {
    if (document[field] is! String || (document[field] as String).isEmpty) {
      throw FormatException('Sync envelope field $field is invalid.');
    }
  }
  if (!['create', 'patch', 'append', 'tombstone', 'resolve'].contains(document['action']) ||
      document['seq'] is! int || (document['seq'] as int) < 1 ||
      document['lamport'] is! int || (document['lamport'] as int) < 1 ||
      (document['base_revision'] != null &&
          (document['base_revision'] is! int || (document['base_revision'] as int) < 1)) ||
      document['payload'] is! Map<String, Object?> || document['sha_refs'] is! List) {
    throw const FormatException('Sync envelope field types or action are invalid.');
  }
  if (version == '3.0' && !v3EventTypes.contains(document['event_type'])) {
    throw const FormatException('Sync envelope event_type is not in sync-event-v3.');
  }
  final refs = (document['sha_refs'] as List<dynamic>).cast<Object?>();
  if (refs.any((value) => value is! String || !RegExp(r'^[a-f0-9]{64}$').hasMatch(value))) {
    throw const FormatException('Sync SHA references must be lowercase SHA-256 digests.');
  }
  DateTime.parse(document['created_at_utc'] as String).toUtc();
}

String _opaqueDigest(List<int> key, String contentHash) =>
    Hmac(sha256, key).convert(utf8.encode(contentHash)).toString();

String _padSequence(int value) => value.toString().padLeft(20, '0');

String _policyName(LargeUploadPolicy value) => switch (value) {
      LargeUploadPolicy.wifiOnly => 'wifi_only',
      _ => value.name,
    };

LargeUploadPolicy _parseUploadPolicy(String value) => switch (value) {
      'manual' => LargeUploadPolicy.manual,
      'wifi_only' => LargeUploadPolicy.wifiOnly,
      'automatic' => LargeUploadPolicy.automatic,
      'off' => LargeUploadPolicy.off,
      _ => throw FormatException('Unsupported large upload policy: $value'),
    };

int _asInt(Object? value) => switch (value) {
      int number => number,
      BigInt number => number.toInt(),
      num number => number.toInt(),
      _ => 0,
    };

Future<String> _hashFile(String path) async => (await sha256.bind(File(path).openRead()).first).toString();

Future<bool> _hasChunkedEncryptionHeader(File file) async {
  if (!await file.exists() || await file.length() < 4) return false;
  final input = await file.open(mode: FileMode.read);
  try {
    final header = await input.read(4);
    return header.length == 4 && header[0] == 0x4c && header[1] == 0x57 &&
        header[2] == 0x41 && header[3] == 0x45;
  } finally {
    await input.close();
  }
}

String _safeError(Object error) {
  final text = error.toString().replaceAll(RegExp(r'(Bearer\s+)[^\s]+', caseSensitive: false), r'$1[redacted]');
  return text.length > 400 ? text.substring(0, 400) : text;
}

bool _sameEncryptionPolicy(RemoteEncryptionPolicy left, RemoteEncryptionPolicy right) =>
    left.mode == right.mode &&
    left.encryptMetadata == right.encryptMetadata &&
    left.encryptSmallFiles == right.encryptSmallFiles &&
    left.encryptLargeFiles == right.encryptLargeFiles &&
    left.keyRef?.value == right.keyRef?.value &&
    left.largeFileThresholdBytes == right.largeFileThresholdBytes;

File _safeChild(Directory root, String relativePath) {
  final portable = relativePath.replaceAll('\\', '/');
  if (portable.startsWith('/') ||
      RegExp(r'^[a-zA-Z]:').hasMatch(portable) ||
      portable.split('/').any((segment) => segment == '..' || segment.isEmpty)) {
    throw ArgumentError.value(relativePath, 'relativePath', 'Remote backup path must be relative and safe.');
  }
  final normalizedRoot = p.normalize(p.absolute(root.path));
  final path = p.normalize(p.join(normalizedRoot, portable));
  if (!p.isWithin(normalizedRoot, path)) {
    throw ArgumentError.value(relativePath, 'relativePath', 'Remote backup path escapes its destination.');
  }
  return File(path);
}

Future<File> _safeExistingChild(Directory root, String relativePath) async {
  if (await FileSystemEntity.type(root.path, followLinks: false) != FileSystemEntityType.directory) {
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
