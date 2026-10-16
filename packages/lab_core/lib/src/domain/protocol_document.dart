import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'errors.dart';
import 'json_value.dart';

final class ProtocolValidationReport {
  ProtocolValidationReport({required List<String> errors, required List<String> warnings})
      : errors = List.unmodifiable(errors),
        warnings = List.unmodifiable(warnings);

  final List<String> errors;
  final List<String> warnings;
  bool get isValid => errors.isEmpty;
}

/// Strict structural checks for protocol-v2 and its dependency DAG.
/// Approved ProtocolVersions remain plain JSON snapshots with a content hash.
abstract final class ProtocolDocument {
  static const _statuses = {'draft', 'approved', 'archived'};
  static const _stepKinds = {
    'action', 'wait', 'measure', 'calculate', 'image', 'record',
    'decision', 'repeat', 'sample', 'review',
  };
  static const _origins = {'sop', 'user', 'history', 'ai_suggestion', 'unknown'};

  static ProtocolValidationReport validate(Map<String, Object?> document) {
    final errors = <String>[];
    final warnings = <String>[];
    _requiredString(document, 'schema_version', errors, expected: '2.0');
    _requiredString(document, 'protocol_id', errors);
    _requiredString(document, 'version', errors);
    _requiredString(document, 'title', errors);
    final status = document['status'];
    if (status is! String || !_statuses.contains(status)) {
      errors.add('status must be draft, approved, or archived.');
    }

    final sources = document['sources'];
    if (sources is! List) {
      errors.add('sources must be an array.');
    } else {
      for (var index = 0; index < sources.length; index++) {
        final source = _object(sources[index], 'sources[$index]', errors);
        if (source == null) continue;
        _requiredString(source, 'asset_id', errors);
        final sha = source['sha256'];
        if (sha is! String || !_sha256.hasMatch(sha)) {
          errors.add('sources[$index].sha256 must be lowercase SHA-256.');
        }
        if (!_origins.contains(source['origin'])) {
          errors.add('sources[$index].origin is unsupported.');
        }
        _onlyKeys(source, const {'asset_id', 'sha256', 'page', 'quote', 'origin'},
            'sources[$index]', errors);
      }
    }

    final variables = document['variables'];
    if (variables is! List) {
      errors.add('variables must be an array.');
    } else {
      final keys = <String>{};
      for (var index = 0; index < variables.length; index++) {
        final variable = _object(variables[index], 'variables[$index]', errors);
        if (variable == null) continue;
        final key = _requiredString(variable, 'key', errors);
        if (key != null && !keys.add(key)) {
          errors.add('Variable key "$key" is duplicated.');
        }
        if (!_variableKinds.contains(variable['kind'])) {
          errors.add('variables[$index].kind is unsupported.');
        }
        if (variable['required'] is! bool) {
          errors.add('variables[$index].required must be boolean.');
        }
        _onlyKeys(variable, const {'key', 'kind', 'unit', 'required', 'default'},
            'variables[$index]', errors);
      }
    }

    final steps = document['steps'];
    final stepIds = <String>{};
    final stepObjects = <Map<String, Object?>>[];
    if (steps is! List || steps.isEmpty) {
      errors.add('steps must contain at least one step.');
    } else {
      for (var index = 0; index < steps.length; index++) {
        final step = _object(steps[index], 'steps[$index]', errors);
        if (step == null) continue;
        stepObjects.add(step);
        final id = _requiredString(step, 'step_id', errors);
        if (id != null && !stepIds.add(id)) errors.add('Step id "$id" is duplicated.');
        if (!_stepKinds.contains(step['kind'])) {
          errors.add('steps[$index].kind is unsupported.');
        }
        _requiredString(step, 'title', errors);
        if (step['human_gate'] is! bool) {
          errors.add('steps[$index].human_gate must be boolean.');
        }
        final dependencies = step['depends_on'];
        if (dependencies is! List || dependencies.any((value) => value is! String)) {
          errors.add('steps[$index].depends_on must be a string array.');
        } else {
          final dependencyIds = <String>{};
          for (final dependency in dependencies.cast<String>()) {
            if (!dependencyIds.add(dependency)) {
              errors.add('steps[$index].depends_on contains duplicate step "$dependency".');
            }
          }
        }
        final duration = _object(step['duration'], 'steps[$index].duration', errors);
        if (duration != null) {
          final expected = duration['expected_seconds'];
          if (expected != null && (expected is! int || expected < 0)) {
            errors.add('steps[$index].duration.expected_seconds must be null or >= 0.');
          }
          if (!_origins.contains(duration['source'])) {
            errors.add('steps[$index].duration.source is unsupported.');
          }
          _onlyKeys(duration, const {'expected_seconds', 'source', 'source_quote'},
              'steps[$index].duration', errors);
        }
        final captures = step['captures'];
        if (captures != null && captures is! List) {
          errors.add('steps[$index].captures must be an array when supplied.');
        }
        _onlyKeys(step, const {
          'step_id', 'kind', 'title', 'instructions', 'depends_on', 'duration',
          'captures', 'tool_pack_ref', 'human_gate', 'evidence', 'repeat_max',
          'params', 'output_bindings',
        }, 'steps[$index]', errors);
      }
    }

    for (var index = 0; index < stepObjects.length; index++) {
      final dependencies = stepObjects[index]['depends_on'];
      if (dependencies is! List) continue;
      for (final dependency in dependencies.whereType<String>()) {
        if (!stepIds.contains(dependency)) {
          errors.add('steps[$index] depends on unknown step "$dependency".');
        }
        if (stepObjects[index]['step_id'] == dependency) {
          errors.add('A step cannot depend on itself.');
        }
      }
    }
    if (stepObjects.length == stepIds.length && stepIds.isNotEmpty) {
      if (!_isAcyclic(stepObjects)) errors.add('Step dependencies contain a cycle.');
    }

    final review = _object(document['review'], 'review', errors);
    if (review != null) {
      final approvedByUser = review['approved_by_user'];
      if (approvedByUser is! bool) {
        errors.add('review.approved_by_user must be boolean.');
      } else if (status == 'approved' && !approvedByUser) {
        errors.add('An approved Protocol must record user approval.');
      }
      final reviewWarnings = review['warnings'];
      if (reviewWarnings is! List || reviewWarnings.any((value) => value is! String)) {
        errors.add('review.warnings must be a string array.');
      } else {
        warnings.addAll(reviewWarnings.cast<String>());
      }
      _onlyKeys(review, const {'approved_by_user', 'warnings'}, 'review', errors);
    }
    _onlyKeys(document, const {
      'schema_version', 'protocol_id', 'version', 'title', 'status', 'sources',
      'variables', 'steps', 'review',
    }, 'protocol', errors);
    return ProtocolValidationReport(errors: errors, warnings: warnings);
  }

  static String contentSha256(Map<String, Object?> document) =>
      sha256.convert(utf8.encode(canonicalJson(document))).toString();

  static void requireValid(Map<String, Object?> document) {
    final report = validate(document);
    if (!report.isValid) {
      throw ValidationException(
        'PROTOCOL_INVALID',
        'Protocol document failed v2 validation.',
        details: {'errors': report.errors},
      );
    }
  }

  /// Validates a frozen Run parameter snapshot against its approved Protocol.
  /// Unknown values are rejected so stale or misspelled fields never become
  /// hidden inputs to later execution or Calculation steps.
  static void requireValidParameterSnapshot(
    Map<String, Object?> document,
    Map<String, Object?> values,
  ) {
    final variablesValue = document['variables'];
    if (variablesValue is! List) {
      throw const ValidationException(
        'PROTOCOL_INVALID',
        'Approved Protocol variables are malformed.',
      );
    }
    final variables = <String, Map<String, Object?>>{};
    for (final raw in variablesValue) {
      if (raw is! Map) {
        throw const ValidationException(
          'PROTOCOL_INVALID',
          'Approved Protocol variables are malformed.',
        );
      }
      final variable = Map<String, Object?>.from(raw);
      final key = variable['key'];
      if (key is! String || key.trim().isEmpty || variables.containsKey(key)) {
        throw const ValidationException(
          'PROTOCOL_INVALID',
          'Approved Protocol variable identity is invalid.',
        );
      }
      variables[key] = variable;
    }
    for (final key in values.keys) {
      if (!variables.containsKey(key)) {
        throw ValidationException(
          'PROTOCOL_PARAMETER_UNKNOWN',
          'Parameter "$key" is not declared by the approved Protocol.',
          details: {'key': key},
        );
      }
    }
    for (final entry in variables.entries) {
      final variable = entry.value;
      final key = entry.key;
      final hasValue = values.containsKey(key);
      if (variable['required'] == true &&
          !hasValue &&
          !variable.containsKey('default')) {
        throw ValidationException(
          'PROTOCOL_PARAMETER_REQUIRED',
          'Required protocol value "$key" is missing.',
        );
      }
      if (!hasValue) continue;
      final value = values[key];
      final valid = switch (variable['kind']) {
        'decimal' => value is String &&
            RegExp(r'^[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?$')
                .hasMatch(value),
        'integer' => value is int,
        'text' || 'date' || 'choice' || 'sample_ref' || 'asset_ref' =>
          value is String,
        'boolean' => value is bool,
        _ => false,
      };
      if (!valid) {
        throw ValidationException(
          'PROTOCOL_PARAMETER_TYPE',
          'Protocol value "$key" does not match its declared kind.',
          details: {'key': key, 'kind': variable['kind']},
        );
      }
    }
  }

  static bool _isAcyclic(List<Map<String, Object?>> steps) {
    final dependencies = <String, List<String>>{
      for (final step in steps)
        step['step_id'] as String: (step['depends_on'] as List).cast<String>(),
    };
    final visiting = <String>{};
    final visited = <String>{};
    bool visit(String id) {
      if (visiting.contains(id)) return false;
      if (visited.contains(id)) return true;
      visiting.add(id);
      for (final dependency in dependencies[id] ?? const <String>[]) {
        if (dependencies.containsKey(dependency) && !visit(dependency)) return false;
      }
      visiting.remove(id);
      visited.add(id);
      return true;
    }
    return dependencies.keys.every(visit);
  }

  static Map<String, Object?>? _object(
    Object? value,
    String path,
    List<String> errors,
  ) {
    try {
      return requireJsonObject(value, path);
    } on FormatException {
      errors.add('$path must be an object.');
      return null;
    }
  }

  static String? _requiredString(
    Map<String, Object?> object,
    String key,
    List<String> errors, {
    String? expected,
  }) {
    final value = object[key];
    if (value is! String || value.isEmpty || (expected != null && value != expected)) {
      errors.add('$key must be a non-empty string${expected == null ? '' : ' equal to $expected'}.');
      return null;
    }
    return value;
  }

  static void _onlyKeys(
    Map<String, Object?> object,
    Set<String> allowed,
    String path,
    List<String> errors,
  ) {
    for (final key in object.keys) {
      if (!allowed.contains(key)) errors.add('$path contains unsupported property "$key".');
    }
  }

  static final _sha256 = RegExp(r'^[a-f0-9]{64}$');
  static const _variableKinds = {
    'decimal', 'integer', 'text', 'date', 'choice', 'sample_ref', 'asset_ref', 'boolean',
  };
}
