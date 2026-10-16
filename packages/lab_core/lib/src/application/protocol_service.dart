import 'dart:convert';

import '../domain/commands.dart';
import '../domain/errors.dart';
import '../domain/events.dart';
import '../domain/json_value.dart';
import '../domain/protocol_document.dart';
import '../domain/records.dart';
import '../domain/security.dart';
import '../domain/vault.dart';
import '../persistence/workspace_database.dart';
import 'protocol_execution_validator.dart';
import '_service_support.dart';

final class ProtocolService {
  ProtocolService(this.vault, {ProtocolExecutionValidator? executionValidator})
      : _executionValidator = executionValidator;

  final VaultContext vault;
  ProtocolExecutionValidator? _executionValidator;
  WorkspaceDatabase get _database => vault.database;

  /// Connects the device's approved-pack verifier at the application boundary.
  /// It may be configured once; swapping the verifier after use could weaken
  /// the approval policy for the same Vault.
  void configureExecutionValidator(ProtocolExecutionValidator validator) {
    final current = _executionValidator;
    if (current != null && !identical(current, validator)) {
      throw StateError('Protocol execution validator is already configured.');
    }
    _executionValidator = validator;
  }

  ProtocolVersionRecord saveDraft({
    required Map<String, Object?> document,
    CommandMetadata? command,
    Map<String, Object?> provenance = const <String, Object?>{},
  }) {
    final draft = Map<String, Object?>.from(document);
    draft['schema_version'] = '2.0';
    draft['status'] = 'draft';
    final report = ProtocolDocument.validate(draft);
    if (!report.isValid) {
      throw ValidationException(
        'PROTOCOL_INVALID',
        'Protocol draft failed v2 validation.',
        details: {'errors': report.errors},
      );
    }
    final protocolId = draft['protocol_id']! as String;
    final version = draft['version']! as String;
    final title = normalizedText(draft['title']! as String, 'title');
    final frozen = freezeJsonObject(draft);
    final payloadJson = jsonEncode(frozen);
    final digest = ProtocolDocument.contentSha256(frozen);
    final actualCommand = serviceCommand(command: command);
    final frozenProvenance = freezeJsonObject(provenance);
    final mutationPayload = <String, Object?>{
      'protocol_id': protocolId,
      'version': version,
      'title': title,
      'document': frozen,
      'payload_sha256': digest,
      'status': 'draft',
      'provenance': frozenProvenance,
    };

    return _database.transaction((tx) {
      final prior = tx.findMutationByCommandId(actualCommand.commandId);
      if (prior != null) {
        if (prior.entityType != 'protocol_version' ||
            prior.entityId != '$protocolId@$version' ||
            prior.eventType != 'protocol.draft_saved' ||
            !const {
              MutationAction.create,
              MutationAction.patch,
            }.contains(prior.action) ||
            canonicalJson(prior.payload) != canonicalJson(mutationPayload)) {
          throw CommandAlreadyAppliedException(actualCommand.commandId);
        }
        final rows = tx.query(
          'SELECT * FROM protocol_versions WHERE protocol_id=? AND version=?',
          [protocolId, version],
        );
        if (rows.isEmpty)
          throw MissingEntityException(
            'ProtocolVersion',
            '$protocolId@$version',
          );
        return _recordFromRow(rows.single);
      }
      _requireProtocolSources(tx, frozen);
      final protocol = tx.query(
        'SELECT protocol_id FROM protocols WHERE protocol_id=?',
        [protocolId],
      );
      if (protocol.isEmpty) {
        tx.execute(
          'INSERT INTO protocols(protocol_id,title,current_version,revision) VALUES(?,?,NULL,1)',
          [protocolId, title],
        );
      }
      final existing = tx.query(
        'SELECT status,approved_at_utc FROM protocol_versions WHERE protocol_id=? AND version=?',
        [protocolId, version],
      );
      if (existing.isNotEmpty &&
          (existing.single['status'] == 'approved' ||
              existing.single['approved_at_utc'] != null)) {
        throw const ValidationException(
          'APPROVED_PROTOCOL_IMMUTABLE',
          'An approved ProtocolVersion is immutable; save a new version.',
        );
      }
      final isNewVersion = existing.isEmpty;
      final now = actualCommand.normalizedUtcTime.toIso8601String();
      if (existing.isEmpty) {
        tx.execute(
          '''INSERT INTO protocol_versions
             (protocol_id,version,payload_json,status,payload_sha256,approved_at_utc,
              created_at_utc,validation_report_json,provenance_json)
             VALUES(?,?,?,'draft',?,NULL,?,?,?)''',
          [
            protocolId,
            version,
            payloadJson,
            digest,
            now,
            jsonEncode({'errors': report.errors, 'warnings': report.warnings}),
            jsonEncode(frozenProvenance),
          ],
        );
      } else {
        tx.execute(
          '''UPDATE protocol_versions SET payload_json=?,status='draft',payload_sha256=?,
               validation_report_json=?,provenance_json=?
             WHERE protocol_id=? AND version=? AND approved_at_utc IS NULL AND status<>'approved' ''',
          [
            payloadJson,
            digest,
            jsonEncode({'errors': report.errors, 'warnings': report.warnings}),
            jsonEncode(frozenProvenance),
            protocolId,
            version,
          ],
        );
      }
      tx.execute(
        'UPDATE protocols SET title=?,revision=revision+1 WHERE protocol_id=?',
        [title, protocolId],
      );
      appendServiceMutation(
        tx: tx,
        command: actualCommand,
        deviceId: vault.deviceId,
        entityType: 'protocol_version',
        entityId: '$protocolId@$version',
        eventType: 'protocol.draft_saved',
        action: isNewVersion ? MutationAction.create : MutationAction.patch,
        payload: mutationPayload,
        assetShaRefs: _sourceHashes(frozen),
      );
      return _recordFromRow(
        tx.query(
          'SELECT * FROM protocol_versions WHERE protocol_id=? AND version=?',
          [protocolId, version],
        ).single,
      );
    });
  }

  Future<ProtocolVersionRecord> approveVersion({
    required String protocolId,
    required String version,
    required ApprovalRef approvalRef,
    CommandMetadata? command,
  }) async {
    final actualCommand = serviceCommand(command: command);
    final entityId = '$protocolId@$version';
    final mutationPayload = <String, Object?>{
      'protocol_id': protocolId,
      'version': version,
      'approval_ref': approvalRef.value,
    };

    final replayed = _database.transaction((tx) {
      final prior = tx.findMutationByCommandId(actualCommand.commandId);
      if (prior == null) return null;
      final priorPayload = prior.payload;
      if (prior.entityType != 'protocol_version' ||
          prior.entityId != entityId ||
          prior.eventType != 'protocol.approved' ||
          prior.action != MutationAction.patch ||
          priorPayload['protocol_id'] != protocolId ||
          priorPayload['version'] != version ||
          priorPayload['approval_ref'] != approvalRef.value) {
        throw CommandAlreadyAppliedException(actualCommand.commandId);
      }
      final rows = tx.query(
        'SELECT * FROM protocol_versions WHERE protocol_id=? AND version=?',
        [protocolId, version],
      );
      if (rows.isEmpty) throw MissingEntityException('ProtocolVersion', entityId);
      return _recordFromRow(rows.single);
    });
    if (replayed != null) return replayed;

    // Workflow validation involves resolving installed Packs and verifying
    // their approval/signature, so it must run before opening the SQLite write
    // transaction. The content hash is checked again in that transaction to
    // ensure the inspected draft is still the one being approved.
    final draftRows = _database.query(
      'SELECT payload_json,status,payload_sha256,provenance_json,approved_at_utc '
      'FROM protocol_versions WHERE protocol_id=? AND version=?',
      [protocolId, version],
    );
    if (draftRows.isEmpty) {
      throw MissingEntityException('ProtocolVersion', entityId);
    }
    if (draftRows.single['status'] != 'draft' ||
        draftRows.single['approved_at_utc'] != null) {
      throw const ValidationException(
        'APPROVED_PROTOCOL_IMMUTABLE',
        'Only a draft ProtocolVersion can be approved.',
      );
    }
    final draftDocument = requireJsonObject(
      jsonDecode(draftRows.single['payload_json']! as String),
      'protocol draft',
    );
    final draftProvenance = requireJsonObject(
      jsonDecode(draftRows.single['provenance_json']! as String),
      'protocol provenance',
    );
    final inspectedHash = ProtocolDocument.contentSha256(draftDocument);
    if (inspectedHash != draftRows.single['payload_sha256']) {
      throw const ValidationException(
        'PROTOCOL_VERSION_HASH_MISMATCH',
        'Protocol draft content no longer matches its stored hash.',
      );
    }
    await (_executionValidator ?? const ProtocolExecutionValidator()).validate(
      draftDocument,
      provenance: draftProvenance,
    );

    return _database.transaction((tx) {
      final prior = tx.findMutationByCommandId(actualCommand.commandId);
      if (prior != null) {
        final priorPayload = prior.payload;
        if (prior.entityType != 'protocol_version' ||
            prior.entityId != entityId ||
            prior.eventType != 'protocol.approved' ||
            prior.action != MutationAction.patch ||
            priorPayload['protocol_id'] != protocolId ||
            priorPayload['version'] != version ||
            priorPayload['approval_ref'] != approvalRef.value) {
          throw CommandAlreadyAppliedException(actualCommand.commandId);
        }
        return _recordFromRow(
          tx.query(
            'SELECT * FROM protocol_versions WHERE protocol_id=? AND version=?',
            [protocolId, version],
          ).single,
        );
      }
      final rows = tx.query(
        'SELECT * FROM protocol_versions WHERE protocol_id=? AND version=?',
        [protocolId, version],
      );
      if (rows.isEmpty)
        throw MissingEntityException('ProtocolVersion', entityId);
      final existing = _recordFromRow(rows.single);
      final persistedProvenance = requireJsonObject(
        jsonDecode(rows.single['provenance_json']! as String),
        'protocol provenance',
      );
      if (canonicalJson(persistedProvenance) != canonicalJson(draftProvenance)) {
        throw const ValidationException(
          'PROTOCOL_APPROVAL_RACE',
          'Protocol provenance changed while workflow bindings were being checked; reload and review it again.',
        );
      }
      tx.requireApproval(
        approvalRef: approvalRef,
        action: 'protocol.approve',
        subjectType: 'protocol_version',
        subjectId: entityId,
        atUtc: actualCommand.normalizedUtcTime,
        requiredScope: <String, Object?>{
          'payload_sha256': existing.payloadSha256,
          'reviewed': true,
        },
      );
      if (existing.isApproved) {
        throw const ValidationException(
          'APPROVED_PROTOCOL_IMMUTABLE',
          'This ProtocolVersion is already approved; create a new version to change it.',
        );
      }
      if (existing.payloadSha256 != inspectedHash) {
        throw const ValidationException(
          'PROTOCOL_APPROVAL_RACE',
          'ProtocolVersion changed while workflow bindings were being checked; reload and review it again.',
        );
      }
      final approvedDocument = Map<String, Object?>.from(existing.document);
      approvedDocument['status'] = 'approved';
      final review = Map<String, Object?>.from(
        requireJsonObject(approvedDocument['review'], 'review'),
      );
      review['approved_by_user'] = true;
      approvedDocument['review'] = review;
      ProtocolDocument.requireValid(approvedDocument);
      final payloadJson = jsonEncode(freezeJsonObject(approvedDocument));
      final digest = ProtocolDocument.contentSha256(approvedDocument);
      final approvedAt = actualCommand.normalizedUtcTime.toIso8601String();
      final changed = tx.execute(
        '''UPDATE protocol_versions SET payload_json=?,status='approved',payload_sha256=?,
             approval_ref=?,approved_at_utc=?,validation_report_json=?
           WHERE protocol_id=? AND version=? AND status='draft' AND approved_at_utc IS NULL''',
        [
          payloadJson,
          digest,
          approvalRef.value,
          approvedAt,
          jsonEncode({
            'errors': <String>[],
            'warnings': ProtocolDocument.validate(approvedDocument).warnings,
          }),
          protocolId,
          version,
        ],
      );
      if (changed != 1) {
        throw const ValidationException(
          'PROTOCOL_APPROVAL_RACE',
          'ProtocolVersion changed during approval; reload and review it again.',
        );
      }
      tx.execute(
        'UPDATE protocols SET current_version=?,revision=revision+1 WHERE protocol_id=?',
        [version, protocolId],
      );
      appendServiceMutation(
        tx: tx,
        command: actualCommand,
        deviceId: vault.deviceId,
        entityType: 'protocol_version',
        entityId: entityId,
        eventType: 'protocol.approved',
        action: MutationAction.patch,
        payload: <String, Object?>{
          ...mutationPayload,
          'document': approvedDocument,
          'payload_sha256': digest,
          'approved_at_utc': approvedAt,
        },
        assetShaRefs: _sourceHashes(existing.document),
      );
      return _recordFromRow(
        tx.query(
          'SELECT * FROM protocol_versions WHERE protocol_id=? AND version=?',
          [protocolId, version],
        ).single,
      );
    });
  }

  ProtocolVersionRecord? getVersion(String protocolId, String version) {
    final rows = _database.query(
      'SELECT * FROM protocol_versions WHERE protocol_id=? AND version=?',
      [protocolId, version],
    );
    return rows.isEmpty ? null : _recordFromRow(rows.single);
  }

  List<ProtocolSummaryRecord> listProtocols({bool includeArchived = false}) =>
      _database
          .query('''SELECT protocol_id,title,current_version FROM protocols
           ${includeArchived ? '' : 'WHERE archived_at_utc IS NULL'}
           ORDER BY title COLLATE NOCASE,protocol_id''')
          .map(
            (row) => ProtocolSummaryRecord(
              protocolId: row['protocol_id']! as String,
              title: row['title']! as String,
              currentVersion: row['current_version'] as String?,
            ),
          )
          .toList(growable: false);

  List<ProtocolVersionRecord> listVersions(String protocolId) => _database
      .query(
        'SELECT * FROM protocol_versions WHERE protocol_id=? ORDER BY created_at_utc DESC,version',
        [protocolId],
      )
      .map(_recordFromRow)
      .toList(growable: false);

  void _requireProtocolSources(
    WorkspaceTransaction tx,
    Map<String, Object?> document,
  ) {
    final sources = document['sources'] as List;
    for (final sourceValue in sources) {
      final source = requireJsonObject(sourceValue, 'protocol source');
      final rows = tx.query(
        '''SELECT a.blob_sha256,b.state FROM assets a
           JOIN blob_objects b ON b.sha256=a.blob_sha256
           WHERE a.asset_id=? AND a.deleted_at_utc IS NULL''',
        [source['asset_id']],
      );
      if (rows.isEmpty ||
          rows.single['state'] != 'committed' ||
          rows.single['blob_sha256'] != source['sha256']) {
        throw ValidationException(
          'PROTOCOL_SOURCE_MISMATCH',
          'Protocol source Asset is missing, deleted, uncommitted, or has a different SHA-256.',
          details: {'asset_id': source['asset_id']},
        );
      }
    }
  }

  List<String> _sourceHashes(Map<String, Object?> document) =>
      (document['sources'] as List)
          .map(
            (value) =>
                requireJsonObject(value, 'protocol source')['sha256']!
                    as String,
          )
          .toList(growable: false);

  ProtocolVersionRecord _recordFromRow(DbRow row) => ProtocolVersionRecord(
    protocolId: row['protocol_id']! as String,
    version: row['version']! as String,
    title:
        requireJsonObject(
              jsonDecode(row['payload_json']! as String),
              'protocol',
            )['title']!
            as String,
    status: row['status']! as String,
    document: requireJsonObject(
      jsonDecode(row['payload_json']! as String),
      'protocol',
    ),
    payloadSha256: row['payload_sha256']! as String,
    createdAtUtc: dateFromDb(row['created_at_utc']),
    approvalRef: row['approval_ref'] as String?,
    approvedAtUtc: optionalDateFromDb(row['approved_at_utc']),
  );
}
