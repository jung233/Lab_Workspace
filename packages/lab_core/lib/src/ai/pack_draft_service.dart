import 'dart:convert';

import 'package:lab_core/src/domain/security.dart';
import 'package:lab_core/src/domain/ids.dart';

import 'ai_provider_service.dart';
import 'models.dart';

class GeneratedCalculationPackDraft {
  const GeneratedCalculationPackDraft({
    required this.draftId,
    required this.document,
    required this.unsupportedOperations,
    required this.requiresUserInput,
    required this.source,
  });
  final String draftId;
  final Map<String, Object?> document;
  final List<String> unsupportedOperations;
  final List<String> requiresUserInput;
  final String? source;

  Map<String, Object?> toJson() => {
        'draft_id': draftId,
        'document': document,
        'unsupported_operations': unsupportedOperations,
        'requires_user_input': requiresUserInput,
        'source': source,
      };
}

class PackDraftValidation {
  const PackDraftValidation({
    required this.valid,
    required this.errors,
    required this.warnings,
    required this.unsupportedOperations,
    required this.requiresUserInput,
    this.contentSha256,
  });
  final bool valid;
  final List<String> errors;
  final List<String> warnings;
  final List<String> unsupportedOperations;
  final List<String> requiresUserInput;
  final String? contentSha256;
}

class PackDraftGoldenReport {
  const PackDraftGoldenReport({
    required this.passed,
    required this.summary,
    required this.contentSha256,
    this.cases = const [],
    this.errors = const [],
  });
  final bool passed;
  final String summary;
  final String contentSha256;
  final List<Map<String, Object?>> cases;
  final List<String> errors;
}

class InstalledCalculationPack {
  const InstalledCalculationPack({required this.packId, required this.version, required this.contentSha256});
  final String packId;
  final String version;
  final String contentSha256;
}

abstract interface class PackDraftRepository {
  Future<void> save(GeneratedCalculationPackDraft draft, {required String state});
  Future<GeneratedCalculationPackDraft?> get(String draftId);
  Future<void> updateState(String draftId, String state);
}

abstract interface class CalculationPackReviewPort {
  Future<PackDraftValidation> validate(Map<String, Object?> document);
  Future<PackDraftGoldenReport> testPack(Map<String, Object?> document);
  Future<InstalledCalculationPack> approveAndInstall(
    Map<String, Object?> document,
    ApprovalRef approvalRef, {
    required PackDraftValidation validation,
    required PackDraftGoldenReport goldenReport,
  });
}

/// Generates immutable, reviewable Pack drafts. It never executes a Pack or
/// performs installation until a separately validated user approval is passed
/// to the calculation registry.
class PackDraftService {
  PackDraftService({
    required AiProviderService ai,
    required PackDraftRepository drafts,
    required CalculationPackReviewPort calculationRegistry,
  })  : _ai = ai,
        _drafts = drafts,
        _registry = calculationRegistry;

  final AiProviderService _ai;
  final PackDraftRepository _drafts;
  final CalculationPackReviewPort _registry;

  Future<GeneratedCalculationPackDraft> generateDraft({
    required String providerId,
    required String request,
    required ConsentReceipt consent,
    required String skillInstructions,
    Set<String> sourceAssetIds = const {},
  }) async {
    final prompt = '''
Create a declarative Calculation Pack JSON draft using only the supplied Skill
instructions and the supported primitive registry. Do not emit or execute code.
The root object must follow schema_version 2.0, kind="calculation",
status="draft", and review.approved_by_user=false. For unknown conditions,
return them in requires_user_input. For unsupported operations, return them in
unsupported_operations; do not substitute another formula. Return one JSON
object with keys `document`, `unsupported_operations`, and `requires_user_input`.

Skill instructions:
$skillInstructions

User request:
$request
''';
    final response = await _ai.completeText(
      providerId: providerId,
      prompt: prompt,
      consent: consent,
      purpose: 'calculation_pack_generation',
      sourceAssetIds: sourceAssetIds,
      dataClass: 'research_protocol',
      scope: 'pack_generation',
    );
    final decoded = _decodeJsonObject(response);
    final rawDocument = decoded['document'];
    if (rawDocument is! Map) throw const PackDraftException('PACK_DRAFT_INVALID', 'Generated draft has no document object.');
    final document = rawDocument.map((key, value) => MapEntry(key.toString(), value));
    _forceDraft(document);
    final unsupported = _stringList(decoded['unsupported_operations']);
    final missing = _stringList(decoded['requires_user_input']);
    final draft = GeneratedCalculationPackDraft(
      draftId: newUuidV7(),
      document: document,
      unsupportedOperations: unsupported,
      requiresUserInput: missing,
      source: sourceAssetIds.isEmpty ? null : sourceAssetIds.join(','),
    );
    await _drafts.save(draft, state: 'draft');
    return draft;
  }

  Future<PackDraftValidation> validate(String draftId) async {
    final draft = await _requireDraft(draftId);
    _forceDraft(draft.document);
    if (draft.unsupportedOperations.isNotEmpty) {
      return PackDraftValidation(
        valid: false,
        errors: const ['Unsupported operations cannot be validated for installation.'],
        warnings: const [],
        unsupportedOperations: draft.unsupportedOperations,
        requiresUserInput: draft.requiresUserInput,
      );
    }
    final report = await _registry.validate(draft.document);
    if (draft.requiresUserInput.isNotEmpty) {
      return PackDraftValidation(
        valid: false,
        errors: [...report.errors, 'User input is required before this Pack can be considered.'],
        warnings: report.warnings,
        unsupportedOperations: report.unsupportedOperations,
        requiresUserInput: [...report.requiresUserInput, ...draft.requiresUserInput],
        contentSha256: report.contentSha256,
      );
    }
    await _drafts.updateState(draftId, report.valid ? 'validated' : 'draft');
    return report;
  }

  Future<PackDraftGoldenReport> testPack(String draftId) async {
    final draft = await _requireDraft(draftId);
    final validation = await validate(draftId);
    if (!validation.valid) throw PackDraftException('PACK_VALIDATION_FAILED', validation.errors.join('; '));
    final report = await _registry.testPack(draft.document);
    await _drafts.updateState(draftId, report.passed ? 'tested' : 'validated');
    return report;
  }

  Future<InstalledCalculationPack> approveAndInstall(String draftId, ApprovalRef approvalRef) async {
    final draft = await _requireDraft(draftId);
    final validation = await validate(draftId);
    if (!validation.valid) throw PackDraftException('PACK_VALIDATION_FAILED', validation.errors.join('; '));
    final golden = await _registry.testPack(draft.document);
    if (!golden.passed) throw PackDraftException('PACK_GOLDEN_FAILED', golden.summary);
    final installed = await _registry.approveAndInstall(
      draft.document,
      approvalRef,
      validation: validation,
      goldenReport: golden,
    );
    // The draft record remains an approved review artifact; the calculation
    // registry owns the separately installed immutable Pack version.
    await _drafts.updateState(draftId, 'approved');
    return installed;
  }

  Future<GeneratedCalculationPackDraft> _requireDraft(String id) async =>
      await _drafts.get(id) ?? (throw PackDraftException('PACK_DRAFT_NOT_FOUND', 'Draft $id does not exist.'));

  static void _forceDraft(Map<String, Object?> document) {
    if (document['schema_version'] != '2.0' || document['kind'] != 'calculation') {
      throw const PackDraftException('PACK_DRAFT_INVALID', 'Expected Calculation Pack schema version 2.0.');
    }
    document['status'] = 'draft';
    final review = document['review'];
    if (review is! Map) throw const PackDraftException('PACK_DRAFT_INVALID', 'Draft has no review object.');
    review['approved_by_user'] = false;
  }

  static Map<String, Object?> _decodeJsonObject(String value) {
    var text = value.trim();
    if (text.startsWith('```')) {
      text = text.replaceFirst(RegExp(r'^```(?:json)?\s*'), '').replaceFirst(RegExp(r'\s*```$'), '');
    }
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map) return decoded.map((key, value) => MapEntry(key.toString(), value));
    } on FormatException {
      // Convert malformed output into a typed failure without echoing model text.
    }
    throw const PackDraftException('PACK_DRAFT_INVALID', 'Model response was not a JSON object.');
  }

  static List<String> _stringList(Object? value) => value is List
      ? value.whereType<String>().toList(growable: false)
      : const [];
}

class PackDraftException implements Exception {
  const PackDraftException(this.code, this.message);
  final String code;
  final String message;
  @override
  String toString() => '$code: $message';
}
