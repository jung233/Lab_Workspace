/// Semantic checks shared by Protocol editing, approval, and Run creation.
///
/// Protocol v2 keeps step params extensible, so structural validation alone
/// cannot rule out arbitrary operations or executable code hidden in a step.
abstract final class ProtocolSemanticValidator {
  static ProtocolSemanticValidationReport validate(
    Map<String, Object?> document,
  ) {
    final errors = <String>[];
    final unsupportedOperations = <String>[];
    _validateContractDetails(document, errors);
    _validateOperations(
      document,
      errors: errors,
      unsupportedOperations: unsupportedOperations,
    );
    return ProtocolSemanticValidationReport(
      errors: errors,
      unsupportedOperations: unsupportedOperations,
    );
  }

  static void _validateContractDetails(
    Map<String, Object?> document,
    List<String> errors,
  ) {
    final variables = document['variables'];
    final variableKeys = <String>{};
    if (variables is List) {
      for (final raw in variables) {
        if (raw is! Map) continue;
        final key = raw['key'];
        if (key is String) variableKeys.add(key);
      }
    }

    final steps = document['steps'];
    if (steps is! List) return;
    for (var index = 0; index < steps.length; index++) {
      final raw = steps[index];
      if (raw is! Map) continue;
      final step = raw.map((key, value) => MapEntry(key.toString(), value));
      final path = 'steps[$index]';
      if (step['instructions'] != null && step['instructions'] is! String) {
        errors.add('$path.instructions 必须是字符串。');
      }

      final rawCaptures = step['captures'];
      if (rawCaptures is List) {
        final captureKeys = <String>{};
        for (
          var captureIndex = 0;
          captureIndex < rawCaptures.length;
          captureIndex++
        ) {
          final capture = rawCaptures[captureIndex];
          if (capture is! Map) {
            errors.add('$path.captures[$captureIndex] 必须是对象。');
            continue;
          }
          final captureMap = capture.map(
            (key, value) => MapEntry(key.toString(), value),
          );
          final key = captureMap['key'];
          final kind = captureMap['kind'];
          if (key is! String || key.trim().isEmpty) {
            errors.add('$path.captures[$captureIndex].key 必须是非空字符串。');
          } else if (!captureKeys.add(key)) {
            errors.add('$path.captures[$captureIndex].key 重复：$key。');
          }
          if (kind is! String || kind.trim().isEmpty) {
            errors.add('$path.captures[$captureIndex].kind 必须是非空字符串。');
          }
          if (captureMap['required'] is! bool) {
            errors.add('$path.captures[$captureIndex].required 必须是布尔值。');
          }
          final unit = captureMap['unit'];
          if (unit != null && unit is! String) {
            errors.add('$path.captures[$captureIndex].unit 必须是字符串或 null。');
          }
          const allowedCaptureKeys = {'key', 'kind', 'unit', 'required'};
          for (final field in captureMap.keys) {
            if (!allowedCaptureKeys.contains(field)) {
              errors.add('$path.captures[$captureIndex] 包含不支持的字段：$field。');
            }
          }
        }
      }

      final packRef = step['tool_pack_ref'];
      if (packRef != null && packRef is! String) {
        errors.add('$path.tool_pack_ref 必须是字符串或 null。');
      } else if (packRef is String && packRef.trim().isEmpty) {
        errors.add('$path.tool_pack_ref 不能为空。');
      }
      if (packRef != null && step['kind'] != 'calculate') {
        errors.add('$path.tool_pack_ref 只能用于 calculate 步骤。');
      }

      final repeatMax = step['repeat_max'];
      if (repeatMax != null &&
          (repeatMax is! int || repeatMax < 1 || repeatMax > 1000)) {
        errors.add('$path.repeat_max 必须是 1 到 1000 的整数或 null。');
      }
      for (final field in ['params', 'output_bindings']) {
        final value = step[field];
        if (value != null && value is! Map) {
          errors.add('$path.$field 必须是 JSON object。');
        }
      }
      final duration = step['duration'];
      if (duration is Map &&
          duration['expected_seconds'] != null &&
          duration['source'] == 'unknown') {
        errors.add('$path.duration 使用 unknown 来源时，expected_seconds 必须为 null。');
      }
      _validateVariableReferences(step, variableKeys, path, errors);
    }
  }

  static void _validateVariableReferences(
    Object? value,
    Set<String> variableKeys,
    String path,
    List<String> errors,
  ) {
    if (value is Map) {
      for (final entry in value.entries) {
        final key = entry.key.toString();
        final nestedPath = '$path.$key';
        if (key == r'$ref' && entry.value is String) {
          final ref = entry.value as String;
          if (ref.startsWith('variables.') &&
              !variableKeys.contains(ref.substring('variables.'.length))) {
            errors.add('$nestedPath 引用了未声明变量：$ref。');
          }
        }
        _validateVariableReferences(
          entry.value,
          variableKeys,
          nestedPath,
          errors,
        );
      }
    } else if (value is List) {
      for (var index = 0; index < value.length; index++) {
        _validateVariableReferences(
          value[index],
          variableKeys,
          '$path[$index]',
          errors,
        );
      }
    } else if (value is String) {
      for (final match in RegExp(
        r'\$variables\.([A-Za-z_][A-Za-z0-9_]*)',
      ).allMatches(value)) {
        final key = match.group(1)!;
        if (!variableKeys.contains(key)) {
          errors.add('$path 引用了未声明变量：\$variables.$key。');
        }
      }
    }
  }

  static void _validateOperations(
    Object? value, {
    required List<String> errors,
    required List<String> unsupportedOperations,
    String path = 'document',
  }) {
    if (value is Map) {
      for (final entry in value.entries) {
        final key = entry.key.toString();
        final nestedPath = '$path.$key';
        final candidate = entry.value;
        if (const {
              'op',
              'operation',
              'operation_id',
              'primitive',
              'primitive_id',
            }.contains(key) &&
            candidate != null &&
            candidate != '') {
          final issue = '$nestedPath=$candidate';
          unsupportedOperations.add(issue);
          errors.add(
            '$issue 不能作为 Protocol 自由操作执行；请移除并使用本机已批准 Calculation Pack 引用。',
          );
        }
        if (const {
              'python',
              'python_code',
              'script',
              'shell',
              'shell_command',
              'source_code',
              'executable',
            }.contains(key) &&
            candidate != null &&
            candidate != '') {
          final issue = '$nestedPath 含有禁止的可执行代码字段。';
          unsupportedOperations.add(issue);
          errors.add(issue);
        }
        _validateOperations(
          candidate,
          errors: errors,
          unsupportedOperations: unsupportedOperations,
          path: nestedPath,
        );
      }
    } else if (value is List) {
      for (var index = 0; index < value.length; index++) {
        _validateOperations(
          value[index],
          errors: errors,
          unsupportedOperations: unsupportedOperations,
          path: '$path[$index]',
        );
      }
    }
  }
}

final class ProtocolSemanticValidationReport {
  ProtocolSemanticValidationReport({
    required Iterable<String> errors,
    required Iterable<String> unsupportedOperations,
  }) : errors = List<String>.unmodifiable(errors.toSet().toList()..sort()),
       unsupportedOperations = List<String>.unmodifiable(
         unsupportedOperations.toSet().toList()..sort(),
       );

  final List<String> errors;
  final List<String> unsupportedOperations;

  bool get isValid => errors.isEmpty;
}
