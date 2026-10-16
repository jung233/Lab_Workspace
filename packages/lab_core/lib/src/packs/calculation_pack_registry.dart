import 'dart:convert';

import '../domain/commands.dart';
import '../domain/errors.dart';
import '../domain/events.dart';
import '../domain/ids.dart';
import '../domain/json_value.dart';
import '../domain/security.dart';
import '../domain/vault.dart';
import '../persistence/workspace_database.dart';
import 'built_in_pack_catalog.dart';
import 'calculation_pack.dart';
import 'calculation_pack_validator.dart';

/// Platform-backed Ed25519 signing port. The implementation must keep private
/// key bytes in the OS secure store and return a transport-safe signature.
abstract interface class CalculationPackSignaturePort {
  Future<String> sign(String canonicalPayload);

  Future<bool> verify(String canonicalPayload, String signature);
}

final class CalculationPackRegistry {
  CalculationPackRegistry({
    required WorkspaceDatabase database,
    required this.vault,
    required this.signatures,
    DateTime Function()? clock,
    String Function()? idGenerator,
  })  : database = database,
        _clock = clock ?? _utcNow,
        _idGenerator = idGenerator ?? newUuidV7 {
    if (!identical(database, vault.database)) {
      throw ArgumentError('CalculationPackRegistry database must match VaultContext.database.');
    }
  }

  final WorkspaceDatabase database;
  final VaultContext vault;
  final CalculationPackSignaturePort signatures;
  final DateTime Function() _clock;
  final String Function() _idGenerator;

  PackValidationReport validate(
    Map<String, Object?> document, {
    bool trustedBuiltIn = false,
  }) =>
      CalculationPackValidator.validate(document, trustedBuiltIn: trustedBuiltIn);

  PackGoldenTestReport testPack(
    Map<String, Object?> document, {
    bool trustedBuiltIn = false,
  }) =>
      CalculationPackValidator.testPack(document, trustedBuiltIn: trustedBuiltIn);

  /// Requires a separate, exact approval receipt; model draft status is never
  /// treated as consent or as an installed Pack state.
  Future<InstalledPackRecord> approveAndInstall(
    Map<String, Object?> document,
    ApprovalRef approvalRef, {
    required PackValidationReport validation,
    required PackGoldenTestReport goldenReport,
    CalculationPackSourceProvenance? sourceProvenance,
  }) async {
    final draft = CalculationPackDraft(document: _asDraft(document));
    final freshValidation = validate(draft.document);
    if (!freshValidation.valid ||
        !validation.valid ||
        validation.contentSha256 != freshValidation.contentSha256) {
      throw ValidationException(
        'CALC_PACK_VALIDATION_STALE',
        'Pack must pass validation against its current immutable content.',
        details: {'errors': freshValidation.errors},
      );
    }
    if (!goldenReport.passed ||
        goldenReport.contentSha256 != freshValidation.contentSha256) {
      throw const ValidationException(
        'CALC_PACK_GOLDEN_TEST_REQUIRED',
        'A passing golden report for this exact Pack content is required.',
      );
    }
    final freshGoldenReport = testPack(draft.document);
    if (!freshGoldenReport.passed ||
        freshGoldenReport.contentSha256 != freshValidation.contentSha256) {
      throw ValidationException(
        'CALC_PACK_GOLDEN_TEST_REQUIRED',
        'Pack golden fixtures must pass again at the installation boundary.',
        details: {'errors': freshGoldenReport.errors},
      );
    }
    final approvedDocument = _approvedDocument(draft.document);
    final approvedValidation = validate(approvedDocument);
    if (!approvedValidation.valid ||
        approvedValidation.contentSha256 != draft.contentSha256) {
      throw const ValidationException(
        'CALC_PACK_CONTENT_HASH_CHANGED',
        'Approval metadata changed the calculation content hash.',
      );
    }
    final payload = _signaturePayload(
      draft.packId,
      draft.version,
      draft.contentSha256,
      sourceProvenance: sourceProvenance,
    );
    final signature = await signatures.sign(payload);
    if (signature.isEmpty || !await signatures.verify(payload, signature)) {
      throw const ValidationException(
        'CALC_PACK_SIGNATURE_INVALID',
        'The approved Pack signature could not be verified.',
      );
    }
    final approvedAt = _clock().toUtc();
    return database.transaction((tx) {
      final subjectId = draft.approvalSubjectId;
      tx.requireApproval(
        approvalRef: approvalRef,
        action: 'install_calculation_pack',
        subjectType: 'calculation_pack',
        subjectId: subjectId,
        atUtc: approvedAt,
        requiredScope: {
          'pack_id': draft.packId,
          'version': draft.version,
          'content_sha256': draft.contentSha256,
        },
      );
      final existing = tx.query(
        'SELECT manifest_sha256,status,origin,trust_level,installed_at_utc,manifest_json '
        'FROM calculation_packs WHERE pack_id=? AND version=?',
        [draft.packId, draft.version],
      );
      if (existing.isNotEmpty) {
        final row = existing.single;
        if (row['manifest_sha256'] != draft.contentSha256 ||
            row['status'] != 'approved' ||
            row['origin'] != 'local_user' ||
            canonicalJson(_sourceProvenanceFromManifest(row['manifest_json'])?.toJson()) !=
                canonicalJson(sourceProvenance?.toJson())) {
          throw const ValidationException(
            'CALC_PACK_VERSION_IMMUTABLE',
            'A Pack version already exists with different or immutable content.',
          );
        }
        final installed = tx.query(
          "SELECT state FROM installed_packs WHERE pack_id=? AND version=? AND state='installed'",
          [draft.packId, draft.version],
        );
        if (installed.isEmpty) {
          throw const ValidationException(
            'CALC_PACK_INSTALL_RECORD_MISSING',
            'Approved Pack version is missing its installation record.',
          );
        }
        return _recordFromRow(row, draft.packId, draft.version, draft.contentSha256);
      }
      _insertPack(
        tx,
        document: approvedDocument,
        contentSha256: draft.contentSha256,
        origin: 'local_user',
        trustLevel: 'user_approved_signed',
        approvalRef: approvalRef.value,
        approvedAtUtc: approvedAt,
        signature: signature,
        sourceProvenance: sourceProvenance,
      );
      _appendInstalledEvent(
        tx,
        packId: draft.packId,
        version: draft.version,
        contentSha256: draft.contentSha256,
        document: approvedDocument,
        origin: 'local_user',
        trustLevel: 'user_approved_signed',
        approvalRef: approvalRef.value,
        signature: signature,
        sourceProvenance: sourceProvenance,
        atUtc: approvedAt,
      );
      return InstalledPackRecord(
        packId: draft.packId,
        version: draft.version,
        contentSha256: draft.contentSha256,
        origin: 'local_user',
        trustLevel: 'user_approved_signed',
        installedAtUtc: approvedAt,
        sourceProvenance: sourceProvenance,
      );
    });
  }

  /// Installs the source-controlled built-in catalog after its static hash pins
  /// and golden fixtures validate. This method is available to the app bootstrap
  /// but is not invoked while editing or statically reviewing these Packs.
  Future<List<InstalledPackRecord>> installTrustedBuiltIns() async {
    final records = <InstalledPackRecord>[];
    for (final builtIn in BuiltInCalculationPackCatalog.all) {
      final document = builtIn.document;
      final validation = validate(document, trustedBuiltIn: true);
      if (!validation.valid || validation.contentSha256 != builtIn.contentSha256) {
        throw ValidationException(
          'CALC_BUILTIN_HASH_MISMATCH',
          'Built-in Pack ${builtIn.ref} does not match its pinned catalog content.',
          details: {'errors': validation.errors},
        );
      }
      final golden = testPack(document, trustedBuiltIn: true);
      if (!golden.passed || golden.contentSha256 != builtIn.contentSha256) {
        throw ValidationException(
          'CALC_BUILTIN_GOLDEN_FAILED',
          'Built-in Pack ${builtIn.ref} failed its declared golden fixtures.',
          details: {'errors': golden.errors},
        );
      }
      final installedAt = _clock().toUtc();
      records.add(database.transaction((tx) {
        final existing = tx.query(
          'SELECT manifest_sha256,status,origin,trust_level,installed_at_utc,manifest_json '
          'FROM calculation_packs WHERE pack_id=? AND version=?',
          [builtIn.packId, builtIn.version],
        );
        if (existing.isNotEmpty) {
          final row = existing.single;
          if (row['manifest_sha256'] != builtIn.contentSha256 ||
              row['origin'] != 'trusted_builtin' ||
              row['status'] != 'approved') {
            throw const ValidationException(
              'CALC_BUILTIN_VERSION_COLLISION',
              'A built-in Pack version conflicts with existing content.',
            );
          }
          final installed = tx.query(
            "SELECT state FROM installed_packs WHERE pack_id=? AND version=? AND state='installed'",
            [builtIn.packId, builtIn.version],
          );
          if (installed.isEmpty) {
            throw const ValidationException(
              'CALC_BUILTIN_INSTALL_RECORD_MISSING',
              'Approved built-in Pack is missing its installation record.',
            );
          }
          return _recordFromRow(row, builtIn.packId, builtIn.version, builtIn.contentSha256);
        }
        _insertPack(
          tx,
          document: document,
          forms: builtIn.forms,
          contentSha256: builtIn.contentSha256,
          origin: 'trusted_builtin',
          trustLevel: 'pinned_builtin',
          approvalRef: 'trusted_builtin:${builtIn.ref}',
          approvedAtUtc: installedAt,
          signature: null,
        );
        _appendInstalledEvent(
          tx,
          packId: builtIn.packId,
          version: builtIn.version,
          contentSha256: builtIn.contentSha256,
          document: document,
          origin: 'trusted_builtin',
          trustLevel: 'pinned_builtin',
          approvalRef: 'trusted_builtin:${builtIn.ref}',
          signature: null,
          atUtc: installedAt,
        );
        return InstalledPackRecord(
          packId: builtIn.packId,
          version: builtIn.version,
          contentSha256: builtIn.contentSha256,
          origin: 'trusted_builtin',
          trustLevel: 'pinned_builtin',
          installedAtUtc: installedAt,
        );
      }));
    }
    return List<InstalledPackRecord>.unmodifiable(records);
  }

  Future<List<InstalledPackRecord>> listInstalled() async {
    final rows = database.query(
      '''SELECT cp.pack_id,cp.version,cp.manifest_sha256,cp.origin,cp.trust_level,cp.manifest_json,
                COALESCE(cp.installed_at_utc,ip.approved_at_utc) AS installed_at_utc
         FROM calculation_packs cp JOIN installed_packs ip
           ON ip.pack_id=cp.pack_id AND ip.version=cp.version
         WHERE cp.status='approved' AND ip.state='installed'
         ORDER BY cp.pack_id,cp.version''',
    );
    return List<InstalledPackRecord>.unmodifiable(
      rows.map((row) => InstalledPackRecord(
        packId: row['pack_id']! as String,
        version: row['version']! as String,
        contentSha256: row['manifest_sha256']! as String,
        origin: row['origin']! as String,
        trustLevel: row['trust_level']! as String,
        installedAtUtc: DateTime.parse(row['installed_at_utc']! as String).toUtc(),
        sourceProvenance: _sourceProvenanceFromManifest(row['manifest_json']),
      )),
    );
  }

  Future<VersionedCalculationPack> getInstalled(String packId, String version) async {
    final rows = database.query(
      '''SELECT cp.*,ip.state AS installation_state
         FROM calculation_packs cp JOIN installed_packs ip
           ON ip.pack_id=cp.pack_id AND ip.version=cp.version
         WHERE cp.pack_id=? AND cp.version=? AND cp.status='approved'
           AND ip.state='installed' ''',
      [packId, version],
    );
    if (rows.isEmpty) throw MissingEntityException('InstalledCalculationPack', '$packId@$version');
    final row = rows.single;
    final sourceProvenance = _sourceProvenanceFromManifest(row['manifest_json']);
    final documentJson = row['pipeline_json'];
    if (documentJson is! String) throw const FormatException('Installed Pack document is missing.');
    final decoded = jsonDecode(documentJson);
    if (decoded is! Map) throw const FormatException('Installed Pack document must be an object.');
    final document = requireJsonObject(decoded, 'installed Pack');
    final storedHash = row['manifest_sha256']! as String;
    final actualHash = calculationPackContentSha256(document);
    if (storedHash != actualHash) {
      throw const ValidationException(
        'CALC_PACK_HASH_MISMATCH',
        'Installed Pack content no longer matches its stored approval hash.',
      );
    }
    final origin = row['origin']! as String;
    final trustedBuiltIn = origin == 'trusted_builtin';
    final storedForms = row['forms_json'];
    if (storedForms is! String) {
      throw const ValidationException(
        'CALC_PACK_FORMS_MISSING',
        'Installed Pack form metadata is missing.',
      );
    }
    final decodedForms = jsonDecode(storedForms);
    if (decodedForms is! Map) {
      throw const ValidationException(
        'CALC_PACK_FORMS_INVALID',
        'Installed Pack form metadata is not a JSON object.',
      );
    }
    final expectedForms = trustedBuiltIn
        ? BuiltInCalculationPackCatalog.find(packId, version)?.forms
        : _formsForDocument(document);
    if (expectedForms == null ||
        canonicalJson(requireJsonObject(decodedForms, 'forms_json')) !=
            canonicalJson(expectedForms)) {
      throw const ValidationException(
        'CALC_PACK_FORMS_HASH_MISMATCH',
        'Installed Pack form metadata does not match its approved source.',
      );
    }
    if (trustedBuiltIn) {
      final builtIn = BuiltInCalculationPackCatalog.find(packId, version);
      if (builtIn == null || builtIn.contentSha256 != storedHash ||
          canonicalJson(builtIn.document) != canonicalJson(document)) {
        throw const ValidationException(
          'CALC_BUILTIN_HASH_MISMATCH',
          'Installed built-in Pack is not in the compiled trusted catalog.',
        );
      }
    } else {
      final signature = row['signature'];
      if (signature is! String ||
          !await signatures.verify(
            _signaturePayload(packId, version, storedHash, sourceProvenance: sourceProvenance),
            signature,
          )) {
        throw const ValidationException(
          'CALC_PACK_SIGNATURE_INVALID',
          'Installed Pack signature is missing or invalid.',
        );
      }
      final approvalJson = row['approval_ref_json'];
      if (approvalJson is! String) throw const ValidationException(
        'CALC_PACK_APPROVAL_MISSING',
        'Installed user Pack has no approval reference.',
      );
      final approvalDecoded = jsonDecode(approvalJson);
      if (approvalDecoded is! Map || approvalDecoded['approval_ref'] is! String) {
        throw const ValidationException(
          'CALC_PACK_APPROVAL_INVALID',
          'Installed user Pack approval reference is invalid.',
        );
      }
      final approvalRef = ApprovalRef(approvalDecoded['approval_ref'] as String);
      database.transaction((tx) {
        tx.requireApproval(
          approvalRef: approvalRef,
          action: 'install_calculation_pack',
          subjectType: 'calculation_pack',
          subjectId: '$packId@$version#$storedHash',
          atUtc: _clock().toUtc(),
          requiredScope: {
            'pack_id': packId,
            'version': version,
            'content_sha256': storedHash,
          },
        );
      });
    }
    final report = validate(document, trustedBuiltIn: trustedBuiltIn);
    if (!report.valid || report.contentSha256 != storedHash) {
      throw ValidationException(
        'CALC_PACK_INVALID_INSTALLED_VERSION',
        'Installed Pack no longer passes the allowlist validator.',
        details: {'errors': report.errors},
      );
    }
    final approvalJson = row['approval_ref_json'];
    String? approvalRef;
    if (approvalJson is String) {
      final approvalDecoded = jsonDecode(approvalJson);
      if (approvalDecoded is Map && approvalDecoded['approval_ref'] is String) {
        approvalRef = approvalDecoded['approval_ref'] as String;
      }
    }
    return VersionedCalculationPack(
      document: document,
      contentSha256: storedHash,
      origin: origin,
      trustLevel: row['trust_level']! as String,
      approvalRef: approvalRef,
      approvedAtUtc: DateTime.parse(row['approved_at_utc']! as String).toUtc(),
      signature: row['signature'] as String?,
      sourceProvenance: sourceProvenance,
    );
  }

  void _insertPack(
    WorkspaceTransaction tx, {
    required Map<String, Object?> document,
    Map<String, Object?>? forms,
    required String contentSha256,
    required String origin,
    required String trustLevel,
    required String approvalRef,
    required DateTime approvedAtUtc,
    required String? signature,
    CalculationPackSourceProvenance? sourceProvenance,
  }) {
    final packId = document['pack_id']! as String;
    final version = document['version']! as String;
    final approvalJson = jsonEncode({
      'approval_ref': approvalRef,
      'subject_id': '$packId@$version#$contentSha256',
      'approval_kind': origin == 'trusted_builtin' ? 'trusted_builtin' : 'user_approval',
    });
    final manifest = jsonEncode({
      'schema_version': '2.0',
      'pack_id': packId,
      'version': version,
      'title': document['title'],
      'content_sha256': contentSha256,
      if (sourceProvenance != null) 'source_provenance': sourceProvenance.toJson(),
    });
    final installedAt = approvedAtUtc.toIso8601String();
    tx.execute(
      '''INSERT INTO calculation_packs
         (pack_id,version,manifest_sha256,pipeline_json,status,created_at_utc,
          manifest_json,forms_json,origin,trust_level,approval_ref_json,
          approved_at_utc,installed_at_utc,signature,engine_compatibility)
         VALUES(?,?,?,?,'approved',?,?,?,?,?,?,?,?,?,?)''',
      [
        packId,
        version,
        contentSha256,
        jsonEncode(document),
        installedAt,
        manifest,
        jsonEncode(forms ?? _formsForDocument(document)),
        origin,
        trustLevel,
        approvalJson,
        installedAt,
        installedAt,
        signature,
        jsonEncode({'primitive_build': 'lab-core-primitives-2.1'}),
      ],
    );
    tx.execute(
      '''INSERT INTO installed_packs(pack_id,version,pack_kind,manifest_hash,
                                     approved_at_utc,state)
         VALUES(?,?,'calculation',?,?,'installed')''',
      [packId, version, contentSha256, installedAt],
    );
  }

  void _appendInstalledEvent(
    WorkspaceTransaction tx, {
    required String packId,
    required String version,
    required String contentSha256,
    required Map<String, Object?> document,
    required String origin,
    required String trustLevel,
    required String approvalRef,
    required String? signature,
    CalculationPackSourceProvenance? sourceProvenance,
    required DateTime atUtc,
  }) {
    if (calculationPackContentSha256(document) != contentSha256 ||
        document['pack_id'] != packId || document['version'] != version) {
      throw const ValidationException(
        'CALC_PACK_EVENT_SNAPSHOT_MISMATCH',
        'Installed Pack event must include the exact immutable content it names.',
      );
    }
    final command = CommandMetadata(
      commandId: _idGenerator(),
      utcTime: atUtc,
      actor: origin == 'trusted_builtin' ? 'trusted_builtin_catalog' : 'local_user',
    );
    tx.appendMutation(MutationEventDraft(
      command: command,
      deviceId: vault.deviceId,
      entityType: 'calculation_pack',
      entityId: '$packId@$version',
      eventType: 'calculation_pack.installed',
      action: MutationAction.create,
      payloadJson: canonicalJson({
        'record_kind': 'calculation_pack_install_v2',
        'event_type': 'calculation_pack.installed',
        'pack_envelope': {
          'pack_id': packId,
          'version': version,
          'content_sha256': contentSha256,
          'document': document,
          'origin': origin,
          'trust_level': trustLevel,
          'source_approval_ref': approvalRef,
          'signature': signature,
          if (sourceProvenance != null) 'source_provenance': sourceProvenance.toJson(),
          'approved_at_utc': atUtc.toUtc().toIso8601String(),
        },
      }),
    ));
  }

  Map<String, Object?> _approvedDocument(Map<String, Object?> draft) {
    final document = jsonDecode(canonicalJson(draft)) as Map<String, Object?>;
    document['status'] = 'approved';
    final review = document['review'];
    if (review is! Map<String, Object?>) {
      throw const ValidationException('CALC_PACK_REVIEW_MISSING', 'Pack review record is required.');
    }
    review['approved_by_user'] = true;
    return document;
  }

  Map<String, Object?> _formsForDocument(Map<String, Object?> document) {
    final rawInputs = document['inputs'];
    final rawOutputs = document['outputs'];
    final inputs = rawInputs is List ? rawInputs.whereType<Map>() : const <Map>[];
    final outputs = rawOutputs is List ? rawOutputs.whereType<Map>() : const <Map>[];
    return {
      'schema_version': '2.0',
      'title': document['title'],
      'fields': [
        for (final raw in inputs)
          {
            'key': raw['key'],
            'label': raw['key'],
            'widget': raw['kind'],
            'unit': raw['unit'],
            'required': raw['required'],
          },
      ],
      'outputs': [
        for (final raw in outputs)
          {
            'key': raw['key'],
            'label': raw['key'],
            'unit': raw['unit'],
            'show_trace_button': true,
          },
      ],
    };
  }

  Map<String, Object?> _asDraft(Map<String, Object?> document) {
    final copy = jsonDecode(canonicalJson(document)) as Map<String, Object?>;
    if (copy['status'] != 'draft') {
      throw const ValidationException(
        'CALC_PACK_DRAFT_REQUIRED',
        'Only an isolated draft can be reviewed and installed.',
      );
    }
    final review = copy['review'];
    if (review is Map<String, Object?> && review['approved_by_user'] == true) {
      throw const ValidationException(
        'CALC_PACK_DRAFT_CLAIMS_APPROVAL',
        'A Pack draft cannot claim user approval before the registry gate.',
      );
    }
    return copy;
  }

  String _signaturePayload(
    String packId,
    String version,
    String hash, {
    CalculationPackSourceProvenance? sourceProvenance,
  }) => canonicalJson({
        'schema_version': '2.0',
        'purpose': 'lab-workspace-calculation-pack',
        'pack_id': packId,
        'version': version,
        'content_sha256': hash,
        if (sourceProvenance != null) 'source_provenance': sourceProvenance.toJson(),
      });

  CalculationPackSourceProvenance? _sourceProvenanceFromManifest(Object? manifestJson) {
    if (manifestJson is! String) {
      throw const ValidationException(
        'CALC_PACK_MANIFEST_MISSING',
        'Installed Pack manifest metadata is missing.',
      );
    }
    final decoded = jsonDecode(manifestJson);
    if (decoded is! Map) {
      throw const ValidationException(
        'CALC_PACK_MANIFEST_INVALID',
        'Installed Pack manifest metadata is not an object.',
      );
    }
    final manifest = requireJsonObject(decoded, 'calculation pack manifest');
    final source = manifest['source_provenance'];
    if (source == null) return null;
    if (source is! Map) {
      throw const ValidationException(
        'CALC_PACK_PROVENANCE_INVALID',
        'Installed Pack publisher provenance is not an object.',
      );
    }
    return CalculationPackSourceProvenance.fromJson(
      requireJsonObject(source, 'source_provenance'),
    );
  }

  InstalledPackRecord _recordFromRow(
    DbRow row,
    String packId,
    String version,
    String hash,
  ) =>
      InstalledPackRecord(
        packId: packId,
        version: version,
        contentSha256: hash,
        origin: row['origin']! as String,
        trustLevel: row['trust_level']! as String,
        installedAtUtc: DateTime.parse(row['installed_at_utc']! as String).toUtc(),
        sourceProvenance: _sourceProvenanceFromManifest(row['manifest_json']),
      );
}

DateTime _utcNow() => DateTime.now().toUtc();
