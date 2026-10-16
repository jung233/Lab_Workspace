import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';

import '../domain/json_value.dart';
import '../domain/security.dart';
import '../persistence/workspace_database.dart';
import '../packs/calculation_pack.dart';
import '../packs/calculation_pack_registry.dart';
import '../packs/calculation_pack_validator.dart';

abstract interface class CommunityPackCatalogTransport {
  Future<Map<String, Object?>> getJson(Uri uri);
}

abstract interface class CommunityPackPublisherTrustStore {
  Future<CommunityPackPublisherKey?> getTrusted(String publisherId);

  Future<List<CommunityPackPublisherKey>> list();

  Future<void> pin({required String publisherId, required String publicKeyBase64});

  Future<void> setEnabled(String publisherId, bool enabled);
}

class CommunityPackPublisherKey {
  CommunityPackPublisherKey({required this.publisherId, required List<int> publicKeyBytes, required this.trustedAtUtc, this.enabled = true})
      : publicKeyBytes = List<int>.unmodifiable(publicKeyBytes);

  final String publisherId;
  final List<int> publicKeyBytes;
  final DateTime trustedAtUtc;
  final bool enabled;

  String get fingerprint => sha256.convert(publicKeyBytes).toString();
}

final class SqliteCommunityPackPublisherTrustStore implements CommunityPackPublisherTrustStore {
  SqliteCommunityPackPublisherTrustStore(this.database) {
    if (!database.query("SELECT name FROM sqlite_master WHERE type='table' AND name='community_pack_publishers'").isNotEmpty) {
      throw StateError('Community publisher trust migration is not installed.');
    }
  }

  final WorkspaceDatabase database;

  @override
  Future<CommunityPackPublisherKey?> getTrusted(String publisherId) async {
    final rows = database.query('SELECT publisher_id,public_key_base64,key_fingerprint,trusted_at_utc,enabled FROM community_pack_publishers WHERE publisher_id=?', [publisherId]);
    if (rows.isEmpty || rows.single['enabled'] != 1) return null;
    return _key(rows.single);
  }

  @override
  Future<List<CommunityPackPublisherKey>> list() async => List<CommunityPackPublisherKey>.unmodifiable(
        database.query('SELECT publisher_id,public_key_base64,key_fingerprint,trusted_at_utc,enabled FROM community_pack_publishers ORDER BY publisher_id').map(_key),
      );

  @override
  Future<void> pin({required String publisherId, required String publicKeyBase64}) async {
    if (!RegExp(r'^[A-Za-z0-9._-]{1,128}$').hasMatch(publisherId)) {
      throw const FormatException('Community publisher ID is invalid.');
    }
    final bytes = base64.decode(base64.normalize(publicKeyBase64));
    if (bytes.length != 32) throw const FormatException('An Ed25519 public key must contain 32 bytes.');
    final fingerprint = sha256.convert(bytes).toString();
    final existing = database.query('SELECT public_key_base64,key_fingerprint FROM community_pack_publishers WHERE publisher_id=?', [publisherId]);
    if (existing.isNotEmpty) {
      if (existing.single['key_fingerprint'] == fingerprint && existing.single['public_key_base64'] == base64Encode(bytes)) return;
      throw const FormatException('Publisher key pins are immutable; use a new publisher ID for key rotation.');
    }
    final now = DateTime.now().toUtc().toIso8601String();
    database.execute(
      'INSERT INTO community_pack_publishers(publisher_id,public_key_base64,key_fingerprint,trusted_at_utc,enabled,revision,updated_at_utc) VALUES(?,?,?,?,1,1,?)',
      [publisherId, base64Encode(bytes), fingerprint, now, now],
    );
  }

  @override
  Future<void> setEnabled(String publisherId, bool enabled) async {
    final now = DateTime.now().toUtc().toIso8601String();
    final changed = database.execute(
      'UPDATE community_pack_publishers SET enabled=?,revision=revision+1,updated_at_utc=? WHERE publisher_id=?',
      [enabled ? 1 : 0, now, publisherId],
    );
    if (changed == 0) throw StateError('Community publisher pin does not exist.');
  }

  static CommunityPackPublisherKey _key(DbRow row) {
    final key = base64.decode(row['public_key_base64']! as String);
    final fingerprint = sha256.convert(key).toString();
    final storedFingerprint = row['key_fingerprint'];
    if (key.length != 32 || (storedFingerprint != null && storedFingerprint != fingerprint)) {
      throw const FormatException('Stored community publisher key failed its fingerprint check.');
    }
    return CommunityPackPublisherKey(
      publisherId: row['publisher_id']! as String,
      publicKeyBytes: key,
      trustedAtUtc: DateTime.parse(row['trusted_at_utc']! as String).toUtc(),
      enabled: row['enabled'] == 1,
    );
  }
}

class VerifiedCommunityPack {
  const VerifiedCommunityPack({
    required this.catalogUri,
    required this.documentUri,
    required this.publisherId,
    required this.keyFingerprint,
    required this.publisherSignature,
    required this.contentSha256,
    required this.document,
    required this.validation,
    required this.golden,
    required this.description,
    required this.permissionSummary,
  });

  final Uri catalogUri;
  final Uri documentUri;
  final String publisherId;
  final String keyFingerprint;
  final String publisherSignature;
  final String contentSha256;
  final Map<String, Object?> document;
  final PackValidationReport validation;
  final PackGoldenTestReport golden;
  final String description;
  final List<String> permissionSummary;
}

/// Reads signed, declarative community packs. Trust is always rooted in an
/// independently pinned publisher key; a valid signature alone never installs
/// or executes a pack.
final class CommunityPackCatalogService {
  CommunityPackCatalogService({
    required this.transport,
    required this.trustStore,
    required this.registry,
    Ed25519? algorithm,
    DateTime Function()? clock,
  }) : _algorithm = algorithm ?? Ed25519(),
       _clock = clock ?? DateTime.now;

  final CommunityPackCatalogTransport transport;
  final CommunityPackPublisherTrustStore trustStore;
  final CalculationPackRegistry registry;
  final Ed25519 _algorithm;
  final DateTime Function() _clock;

  Future<List<VerifiedCommunityPack>> fetch(Uri catalogUri) async {
    _validateHttps(catalogUri);
    final catalog = await transport.getJson(catalogUri);
    if (catalog['schema_version'] != 'lab-workspace-community-catalog-v1' ||
        catalog['publisher_id'] is! String || catalog['key_fingerprint'] is! String ||
        catalog['signature'] is! String || catalog['entries'] is! List) {
      throw const FormatException('Community catalog manifest is invalid.');
    }
    final publisherId = catalog['publisher_id'] as String;
    final key = await trustStore.getTrusted(publisherId);
    if (key == null || !key.enabled) throw const FormatException('Publisher key is not independently trusted on this device.');
    final fingerprint = key.fingerprint;
    if (catalog['key_fingerprint'] != fingerprint || key.publisherId != publisherId) {
      throw const FormatException('Community publisher key fingerprint does not match the trusted pin.');
    }
    final signature = catalog['signature'] as String;
    final catalogPayload = Map<String, Object?>.from(catalog)..remove('signature');
    if (!await _verify(canonicalJson(catalogPayload), signature, key.publicKeyBytes)) {
      throw const FormatException('Community catalog signature is invalid.');
    }
    final results = <VerifiedCommunityPack>[];
    for (final raw in (catalog['entries'] as List).whereType<Map>()) {
      final entry = raw.map((key, value) => MapEntry(key.toString(), value));
      final packId = entry['pack_id'];
      final version = entry['version'];
      final digest = entry['content_sha256'];
      final url = entry['document_url'];
      final packSignature = entry['signature'];
      final description = entry['description'];
      final permissionSummary = entry['permissions'];
      if (packId is! String || version is! String || digest is! String ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(digest) || url is! String ||
          packSignature is! String || description is! String ||
          permissionSummary is! List || permissionSummary.any((item) => item is! String) || permissionSummary.isNotEmpty) {
        continue;
      }
      final documentUri = catalogUri.resolve(url);
      _validateHttps(documentUri);
      final document = await transport.getJson(documentUri);
      if (document['pack_id'] != packId || document['version'] != version ||
          document['status'] != 'draft') {
        continue;
      }
      final actualHash = calculationPackContentSha256(document);
      if (actualHash != digest) continue;
      final packPayload = canonicalJson({
        'schema_version': 'lab-workspace-community-pack-v1',
        'publisher_id': publisherId,
        'pack_id': packId,
        'version': version,
        'content_sha256': digest,
        'permissions': permissionSummary,
      });
      if (!await _verify(packPayload, packSignature, key.publicKeyBytes)) continue;
      final validation = CalculationPackValidator.validate(document);
      if (!validation.valid || validation.unsupportedOperations.isNotEmpty ||
          validation.requiresUserInput.isNotEmpty || validation.contentSha256 != digest) {
        continue;
      }
      final golden = CalculationPackValidator.testPack(document);
      if (!golden.passed || golden.contentSha256 != digest) continue;
      results.add(VerifiedCommunityPack(
        catalogUri: catalogUri,
        documentUri: documentUri,
        publisherId: publisherId,
        keyFingerprint: fingerprint,
        publisherSignature: packSignature,
        contentSha256: digest,
        document: document,
        validation: validation,
        golden: golden,
        description: description,
        permissionSummary: List<String>.unmodifiable(permissionSummary.cast<String>()),
      ));
    }
    return List<VerifiedCommunityPack>.unmodifiable(results);
  }

  Future<InstalledPackRecord> install(VerifiedCommunityPack pack, ApprovalRef approval) async {
    final key = await trustStore.getTrusted(pack.publisherId);
    if (key == null || !key.enabled || key.fingerprint != pack.keyFingerprint ||
        calculationPackContentSha256(pack.document) != pack.contentSha256) {
      throw const FormatException('Community Pack trust or content changed before installation.');
    }
    final sourceProvenance = CalculationPackSourceProvenance(
      publisherId: pack.publisherId,
      keyFingerprint: pack.keyFingerprint,
      signature: pack.publisherSignature,
      sourceUrl: pack.documentUri.toString(),
      verifiedAtUtc: _clock().toUtc(),
    );
    return registry.approveAndInstall(
      pack.document,
      approval,
      validation: pack.validation,
      goldenReport: pack.golden,
      sourceProvenance: sourceProvenance,
    );
  }

  Future<bool> _verify(String payload, String encodedSignature, List<int> publicKeyBytes) async {
    try {
      final signatureBytes = base64.decode(base64.normalize(encodedSignature));
      if (signatureBytes.length != 64 || publicKeyBytes.length != 32) return false;
      return await _algorithm.verify(
        utf8.encode(payload),
        signature: Signature(
          signatureBytes,
          publicKey: SimplePublicKey(publicKeyBytes, type: KeyPairType.ed25519),
        ),
      );
    } on FormatException {
      return false;
    }
  }

  static void _validateHttps(Uri uri) {
    if (uri.scheme != 'https' || uri.host.isEmpty || uri.userInfo.isNotEmpty ||
        uri.hasQuery || uri.hasFragment) {
      throw const FormatException('Community catalog and package URLs must be HTTPS without credentials or query data.');
    }
  }
}
