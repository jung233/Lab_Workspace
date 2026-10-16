import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../domain/json_value.dart';

/// A declarative Pack draft. It is immutable and deliberately cannot execute.
final class CalculationPackDraft {
  CalculationPackDraft({required Map<String, Object?> document})
      : document = freezeJsonObject(document) {
    if (this.document['status'] != 'draft') {
      throw const FormatException('CalculationPackDraft status must be draft.');
    }
  }

  final Map<String, Object?> document;

  String get packId => document['pack_id']! as String;
  String get version => document['version']! as String;
  String get contentSha256 => calculationPackContentSha256(document);
  String get approvalSubjectId => '$packId@$version#$contentSha256';
}

/// Immutable approved content and its approval/signature envelope.
final class VersionedCalculationPack {
  VersionedCalculationPack({
    required Map<String, Object?> document,
    required this.contentSha256,
    required this.origin,
    required this.trustLevel,
    this.approvalRef,
    this.approvedAtUtc,
    this.signature,
    this.sourceProvenance,
  }) : document = freezeJsonObject(document) {
    if (this.document['status'] != 'approved' ||
        this.contentSha256 != calculationPackContentSha256(this.document) ||
        this.document['pack_id'] is! String ||
        this.document['version'] is! String) {
      throw const FormatException('VersionedCalculationPack identity or content hash is invalid.');
    }
  }

  final Map<String, Object?> document;
  final String contentSha256;
  final String origin;
  final String trustLevel;
  final String? approvalRef;
  final DateTime? approvedAtUtc;
  final String? signature;
  final CalculationPackSourceProvenance? sourceProvenance;

  String get packId => document['pack_id']! as String;
  String get version => document['version']! as String;
  String get ref => '$packId@$version';
}

/// Durable row returned after a Pack version is approved and installed.
final class InstalledPackRecord {
  const InstalledPackRecord({
    required this.packId,
    required this.version,
    required this.contentSha256,
    required this.origin,
    required this.trustLevel,
    required this.installedAtUtc,
    this.sourceProvenance,
  });

  final String packId;
  final String version;
  final String contentSha256;
  final String origin;
  final String trustLevel;
  final DateTime installedAtUtc;
  final CalculationPackSourceProvenance? sourceProvenance;

  String get ref => '$packId@$version';
}

/// Publisher provenance retained with a locally approved community Pack.
/// This metadata does not grant execution trust by itself.
final class CalculationPackSourceProvenance {
  CalculationPackSourceProvenance({
    required this.publisherId,
    required this.keyFingerprint,
    required this.signature,
    required this.sourceUrl,
    required this.verifiedAtUtc,
  }) {
    const shaPattern = r'^[a-f0-9]{64}$';
    if (publisherId.isEmpty || publisherId.length > 128 ||
        !RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(publisherId) ||
        !RegExp(shaPattern).hasMatch(keyFingerprint) ||
        signature.isEmpty || signature.length > 4096) {
      throw const FormatException('Calculation Pack publisher provenance is invalid.');
    }
    final uri = Uri.tryParse(sourceUrl);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty || uri.userInfo.isNotEmpty) {
      throw const FormatException('Calculation Pack provenance source URL must be an HTTPS URL.');
    }
  }

  final String publisherId;
  final String keyFingerprint;
  final String signature;
  final String sourceUrl;
  final DateTime verifiedAtUtc;

  Map<String, Object?> toJson() => {
        'publisher_id': publisherId,
        'key_fingerprint': keyFingerprint,
        'signature': signature,
        'source_url': sourceUrl,
        'verified_at_utc': verifiedAtUtc.toUtc().toIso8601String(),
      };

  static CalculationPackSourceProvenance fromJson(Map<String, Object?> json) {
    if (json.keys.toSet().difference(const {
          'publisher_id', 'key_fingerprint', 'signature', 'source_url', 'verified_at_utc',
        }).isNotEmpty ||
        json['publisher_id'] is! String ||
        json['key_fingerprint'] is! String ||
        json['signature'] is! String ||
        json['source_url'] is! String ||
        json['verified_at_utc'] is! String) {
      throw const FormatException('Calculation Pack publisher provenance fields are invalid.');
    }
    final verifiedAt = DateTime.tryParse(json['verified_at_utc']! as String);
    if (verifiedAt == null || verifiedAt.toUtc().toIso8601String() != json['verified_at_utc']) {
      throw const FormatException('Calculation Pack provenance verification time is invalid.');
    }
    return CalculationPackSourceProvenance(
      publisherId: json['publisher_id']! as String,
      keyFingerprint: json['key_fingerprint']! as String,
      signature: json['signature']! as String,
      sourceUrl: json['source_url']! as String,
      verifiedAtUtc: verifiedAt.toUtc(),
    );
  }
}

final class PackValidationReport {
  PackValidationReport({
    required this.valid,
    required Iterable<String> errors,
    required Iterable<String> warnings,
    required Iterable<String> unsupportedOperations,
    required Iterable<String> requiresUserInput,
    this.contentSha256,
  })  : errors = List<String>.unmodifiable(errors),
        warnings = List<String>.unmodifiable(warnings),
        unsupportedOperations = List<String>.unmodifiable(unsupportedOperations),
        requiresUserInput = List<String>.unmodifiable(requiresUserInput);

  final bool valid;
  final List<String> errors;
  final List<String> warnings;
  final List<String> unsupportedOperations;
  final List<String> requiresUserInput;
  final String? contentSha256;
}

final class PackGoldenTestReport {
  PackGoldenTestReport({
    required this.passed,
    required Iterable<Map<String, Object?>> cases,
    required Iterable<String> errors,
    required this.contentSha256,
  })  : cases = List<Map<String, Object?>>.unmodifiable(
          cases.map(freezeJsonObject),
        ),
        errors = List<String>.unmodifiable(errors);

  final bool passed;
  final List<Map<String, Object?>> cases;
  final List<String> errors;
  final String contentSha256;
}

/// Stable identity hash excludes state-only review fields. Draft -> approved
/// transitions therefore preserve the reviewed algorithm hash.
String calculationPackContentSha256(Map<String, Object?> document) {
  final canonicalDocument = jsonDecode(canonicalJson(document)) as Map<String, Object?>;
  canonicalDocument['status'] = 'draft';
  final review = canonicalDocument['review'];
  if (review is Map) review['approved_by_user'] = false;
  return sha256.convert(utf8.encode(canonicalJson(canonicalDocument))).toString();
}\n
