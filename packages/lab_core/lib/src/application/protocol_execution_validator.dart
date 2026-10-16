import '../domain/errors.dart';
import '../domain/protocol_document.dart';
import '../packs/workflow_calculation_binding.dart';
import 'protocol_semantic_validator.dart';

/// Application boundary for validating a Protocol before approval or execution.
/// Calculation references resolve only through the installed, approved Pack
/// registry; this class never executes a Protocol or Calculation Pack.
final class ProtocolExecutionValidator {
  const ProtocolExecutionValidator({this.calculationBinder});

  final WorkflowCalculationPackBinder? calculationBinder;

  Future<void> validate(
    Map<String, Object?> document, {
    required Map<String, Object?> provenance,
  }) async {
    ProtocolDocument.requireValid(document);
    final semantic = ProtocolSemanticValidator.validate(document);
    if (!semantic.isValid) {
      throw ValidationException(
        'PROTOCOL_SEMANTIC_INVALID',
        'Protocol contains unsupported operations or invalid semantic fields.',
        details: {
          'errors': semantic.errors,
          'unsupported_operations': semantic.unsupportedOperations,
        },
      );
    }
    _requireResolvedInputs(document, provenance);

    final steps = document['steps'];
    final containsCalculation =
        steps is List &&
        steps.any((value) {
          if (value is! Map) return false;
          final step = Map<String, Object?>.from(value);
          final toolPackRef = step['tool_pack_ref'];
          return step['kind'] == 'calculate' || toolPackRef != null;
        });
    final binder = calculationBinder;
    if (binder == null) {
      if (containsCalculation) {
        throw const ValidationException(
          'PROTOCOL_CALC_BINDER_UNAVAILABLE',
          'Calculation Pack bindings cannot be approved or run until the installed-pack verifier is configured.',
        );
      }
      return;
    }

    final report = await binder.validate(document);
    if (!report.isValid || report.requiresUserInput.isNotEmpty) {
      throw ValidationException(
        'PROTOCOL_WORKFLOW_BINDING_INVALID',
        'Protocol Calculation Pack bindings and required inputs must be valid before approval or execution.',
        details: {
          'errors': report.errors,
          'requires_user_input': report.requiresUserInput,
        },
      );
    }
  }

  void _requireResolvedInputs(
    Map<String, Object?> document,
    Map<String, Object?> provenance,
  ) {
    if (provenance['method'] == 'ai_protocol_generation') {
      final missing = provenance['requires_user_input'];
      if (missing is! List || missing.any((value) => value is! String)) {
        throw const ValidationException(
          'PROTOCOL_REQUIRES_USER_INPUT_INVALID',
          'AI Protocol provenance must contain a valid requires_user_input list.',
        );
      }
      if (missing.isNotEmpty) {
        throw ValidationException(
          'PROTOCOL_REQUIRES_USER_INPUT',
          'AI Protocol still has unresolved conditions and cannot be approved or run.',
          details: {'requires_user_input': missing},
        );
      }
    }

    final review = document['review'];
    if (review is Map && review['warnings'] is List) {
      final unresolvedWarnings = (review['warnings'] as List)
          .whereType<String>()
          .where((warning) => warning.startsWith('需要用户补充：'))
          .toList(growable: false);
      if (unresolvedWarnings.isNotEmpty) {
        throw ValidationException(
          'PROTOCOL_REQUIRES_USER_INPUT',
          'Protocol still has unresolved conditions and cannot be approved or run.',
          details: {'requires_user_input': unresolvedWarnings},
        );
      }
    }
  }
}
