import 'package:lab_core/src/domain/security.dart';
import 'package:lab_core/src/packs/calculation_pack.dart';
import 'package:lab_core/src/packs/calculation_pack_registry.dart';
import 'pack_draft_service.dart';

/// Adapts the shared Calculation Pack registry to the AI draft review boundary.
/// This adapter cannot execute drafts; install always re-enters registry gates.
final class CalculationPackReviewAdapter implements CalculationPackReviewPort {
  const CalculationPackReviewAdapter(this.registry);

  final CalculationPackRegistry registry;

  @override
  Future<PackDraftValidation> validate(Map<String, Object?> document) async {
    final report = registry.validate(document);
    return PackDraftValidation(
      valid: report.valid,
      errors: report.errors,
      warnings: report.warnings,
      unsupportedOperations: report.unsupportedOperations,
      requiresUserInput: report.requiresUserInput,
      contentSha256: report.contentSha256,
    );
  }

  @override
  Future<PackDraftGoldenReport> testPack(Map<String, Object?> document) async {
    final report = registry.testPack(document);
    return PackDraftGoldenReport(
      passed: report.passed,
      summary: report.passed ? 'All ${report.cases.length} golden cases passed.' : report.errors.join('; '),
      contentSha256: report.contentSha256,
      cases: report.cases,
      errors: report.errors,
    );
  }

  @override
  Future<InstalledCalculationPack> approveAndInstall(
    Map<String, Object?> document,
    ApprovalRef approvalRef, {
    required PackDraftValidation validation,
    required PackDraftGoldenReport goldenReport,
  }) async {
    final calculationValidation = PackValidationReport(
      valid: validation.valid,
      errors: validation.errors,
      warnings: validation.warnings,
      unsupportedOperations: validation.unsupportedOperations,
      requiresUserInput: validation.requiresUserInput,
      contentSha256: validation.contentSha256,
    );
    final calculationGolden = PackGoldenTestReport(
      passed: goldenReport.passed,
      cases: goldenReport.cases,
      errors: goldenReport.errors,
      contentSha256: goldenReport.contentSha256,
    );
    final installed = await registry.approveAndInstall(
      document,
      approvalRef,
      validation: calculationValidation,
      goldenReport: calculationGolden,
    );
    return InstalledCalculationPack(
      packId: installed.packId,
      version: installed.version,
      contentSha256: installed.contentSha256,
    );
  }
}
