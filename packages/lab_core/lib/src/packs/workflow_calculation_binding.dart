import '../calculation/unit_registry.dart';
import '../calculation/decimal_support.dart';
import '../domain/json_value.dart';
import '../domain/protocol_document.dart';
import 'calculation_pack.dart';
import 'calculation_pack_registry.dart';
import 'calculation_pack_validator.dart';

/// A checked link between one approved calculation Pack and a Protocol step.
/// The Pack itself remains immutable; only the input and capture bindings live
/// in the ProtocolVersion snapshot.
final class WorkflowCalculationBinding {
  WorkflowCalculationBinding({
    required this.stepId,
    required this.pack,
    required Map<String, Object?> inputBindings,
    required Map<String, String> outputBindings,
  })  : inputBindings = freezeJsonObject(inputBindings),
        outputBindings = Map<String, String>.unmodifiable(outputBindings);

  final String stepId;
  final VersionedCalculationPack pack;
  final Map<String, Object?> inputBindings;
  final Map<String, String> outputBindings;
}

final class WorkflowCalculationBindingReport {
  WorkflowCalculationBindingReport({
    required Iterable<String> errors,
    required Iterable<String> warnings,
    required Iterable<String> requiresUserInput,
    required Map<String, WorkflowCalculationBinding> bindingsByStepId,
  })  : errors = List<String>.unmodifiable(errors),
        warnings = List<String>.unmodifiable(warnings),
        requiresUserInput = List<String>.unmodifiable(requiresUserInput),
        bindingsByStepId = Map<String, WorkflowCalculationBinding>.unmodifiable(
          bindingsByStepId,
        );

  final List<String> errors;
  final List<String> warnings;
  final List<String> requiresUserInput;
  final Map<String, WorkflowCalculationBinding> bindingsByStepId;

  bool get isValid => errors.isEmpty;
}

/// Resolves declarative Protocol calculation steps only to installed Pack
/// versions. It validates input/capture types and units plus DAG ancestry; it
/// never executes a draft or evaluates arbitrary expressions.
final class WorkflowCalculationPackBinder {
  const WorkflowCalculationPackBinder(this.registry);

  final CalculationPackRegistry registry;

  Future<WorkflowCalculationBindingReport> validate(
    Map<String, Object?> protocol,
  ) async {
    final errors = <String>[];
    final warnings = <String>[];
    final requiresUserInput = <String>[];
    final bindings = <String, WorkflowCalculationBinding>{};
    final structure = ProtocolDocument.validate(protocol);
    errors.addAll(structure.errors);
    warnings.addAll(structure.warnings);

    final rawVariables = protocol['variables'];
    final variables = <String, Map<String, Object?>>{};
    if (rawVariables is List) {
      for (var index = 0; index < rawVariables.length; index++) {
        final value = rawVariables[index];
        if (value is! Map) continue;
        final variable = _object(value);
        final key = variable['key'];
        if (key is String) variables[key] = variable;
      }
    }

    final rawSteps = protocol['steps'];
    if (rawSteps is! List) {
      return WorkflowCalculationBindingReport(
        errors: errors,
        warnings: warnings,
        requiresUserInput: requiresUserInput,
        bindingsByStepId: bindings,
      );
    }
    final steps = <String, Map<String, Object?>>{};
    final dependencies = <String, Set<String>>{};
    for (final rawStep in rawSteps) {
      if (rawStep is! Map) continue;
      final step = _object(rawStep);
      final id = step['step_id'];
      if (id is! String) continue;
      steps[id] = step;
      final rawDependencies = step['depends_on'];
      dependencies[id] = rawDependencies is List
          ? rawDependencies.whereType<String>().toSet()
          : <String>{};
    }

    for (final entry in steps.entries) {
      final stepId = entry.key;
      final step = entry.value;
      final kind = step['kind'];
      final rawPackRef = step['tool_pack_ref'];
      final packRef = rawPackRef is String ? rawPackRef : null;
      if (kind != 'calculate') {
        if (packRef != null && packRef.isNotEmpty) {
          errors.add('steps.$stepId: only calculate steps may reference a Calculation Pack.');
        }
        continue;
      }
      if (packRef == null || packRef.isEmpty) {
        errors.add('steps.$stepId: calculate steps require an installed tool_pack_ref.');
        continue;
      }
      if (step['human_gate'] != true) {
        errors.add('steps.$stepId: Calculation Pack execution requires human_gate=true.');
      }
      final identity = _parsePackRef(packRef);
      if (identity == null) {
        errors.add('steps.$stepId: tool_pack_ref must be an exact pack_id@version reference.');
        continue;
      }

      VersionedCalculationPack pack;
      try {
        pack = await registry.getInstalled(identity.$1, identity.$2);
      } on Object {
        errors.add('steps.$stepId: referenced Calculation Pack is not installed and approved ($packRef).');
        continue;
      }
      if (pack.ref != packRef) {
        errors.add('steps.$stepId: installed Pack identity does not match tool_pack_ref.');
        continue;
      }

      final rawParams = step['params'];
      if (rawParams != null && rawParams is! Map) {
        errors.add('steps.$stepId.params must be an object.');
      }
      final params = rawParams == null ? const <String, Object?>{} : _object(rawParams);
      final rawInputBindings = params['calculation_inputs'];
      if (rawInputBindings != null && rawInputBindings is! Map) {
        errors.add('steps.$stepId.params.calculation_inputs must be an object.');
      }
      final inputBindings = rawInputBindings == null
          ? <String, Object?>{}
          : _object(rawInputBindings);
      final definitions = _objectList(pack.document['inputs']);
      final declaredInputKeys = <String>{};
      for (final definition in definitions) {
        final key = definition['key'];
        if (key is! String || !declaredInputKeys.add(key)) continue;
        if (!inputBindings.containsKey(key)) {
          if (definition['required'] == true) {
            requiresUserInput.add('steps.$stepId.calculation_inputs.$key');
          }
          continue;
        }
        _validateInputBinding(
          binding: inputBindings[key],
          definition: definition,
          stepId: stepId,
          variables: variables,
          steps: steps,
          dependencies: dependencies,
          errors: errors,
        );
      }
      final extraInputs = inputBindings.keys.toSet().difference(declaredInputKeys);
      for (final key in extraInputs) {
        errors.add('steps.$stepId.calculation_inputs.$key is not declared by $packRef.');
      }

      final outputBindings = <String, String>{};
      final rawOutputBindings = step['output_bindings'];
      if (rawOutputBindings is! Map) {
        errors.add('steps.$stepId.output_bindings must map every Pack output to a declared capture.');
      } else {
        for (final binding in rawOutputBindings.entries) {
          if (binding.key is! String || binding.value is! String) {
            errors.add('steps.$stepId.output_bindings keys and values must be strings.');
            continue;
          }
          outputBindings[binding.key as String] = binding.value as String;
        }
      }
      _validateOutputBindings(
        stepId: stepId,
        pack: pack,
        outputBindings: outputBindings,
        step: step,
        errors: errors,
      );
      bindings[stepId] = WorkflowCalculationBinding(
        stepId: stepId,
        pack: pack,
        inputBindings: inputBindings,
        outputBindings: outputBindings,
      );
    }

    requiresUserInput.sort();
    return WorkflowCalculationBindingReport(
      errors: errors,
      warnings: warnings,
      requiresUserInput: requiresUserInput,
      bindingsByStepId: bindings,
    );
  }

  void _validateInputBinding({
    required Object? binding,
    required Map<String, Object?> definition,
    required String stepId,
    required Map<String, Map<String, Object?>> variables,
    required Map<String, Map<String, Object?>> steps,
    required Map<String, Set<String>> dependencies,
    required List<String> errors,
  }) {
    final key = definition['key'];
    if (key is! String) return;
    final path = 'steps.$stepId.calculation_inputs.$key';
    if (binding is String && binding.startsWith(r'$')) {
      final parts = binding.substring(1).split('.');
      if (parts.length == 2 && parts[0] == 'variables') {
        final variable = variables[parts[1]];
        if (variable == null) {
          errors.add('$path references an unknown Protocol variable: $binding');
          return;
        }
        _checkTypeAndUnit(
          path: path,
          packInput: definition,
          sourceKind: variable['kind'],
          sourceUnit: variable['unit'],
          errors: errors,
        );
        return;
      }
      if (parts.length == 4 && parts[0] == 'steps' && parts[2] == 'captures') {
        final sourceId = parts[1];
        final sourceStep = steps[sourceId];
        if (sourceStep == null || !_isAncestor(sourceId, stepId, dependencies)) {
          errors.add('$path references a capture that is not on a dependency path: $binding');
          return;
        }
        final rawCaptures = sourceStep['captures'];
        final captures = _objectList(rawCaptures);
        final capture = _firstWhereOrNull(
          captures,
          (candidate) => candidate['key'] == parts[3],
        );
        if (capture == null) {
          errors.add('$path references an undeclared capture: $binding');
          return;
        }
        _checkTypeAndUnit(
          path: path,
          packInput: definition,
          sourceKind: capture['kind'],
          sourceUnit: capture['unit'],
          errors: errors,
        );
        return;
      }
      errors.add('$path has an unsupported or malformed binding reference: $binding');
      return;
    }
    _validateLiteral(path, definition, binding, errors);
  }

  void _validateLiteral(
    String path,
    Map<String, Object?> definition,
    Object? value,
    List<String> errors,
  ) {
    final kind = definition['kind'];
    final valid = switch (kind) {
      'decimal' => value is String || value is int && value is! bool,
      'integer' => value is int && value is! bool,
      'boolean' => value is bool,
      'text' || 'asset_ref' || 'sample_ref' => value is String && value.isNotEmpty,
      'table' => value is List && value.every((row) => row is Map),
      _ => false,
    };
    if (!valid || _containsFloat(value)) {
      errors.add('$path literal does not match Pack input kind "$kind" or contains a float.');
      return;
    }
    if (kind == 'decimal') {
      try {
        parseCalculationDecimal(value, field: path);
      } on FormatException {
        errors.add('$path must be a finite decimal string or integer.');
      }
      final unit = definition['unit'];
      if (unit is String) {
        try {
          UnitRegistry.parse(unit);
        } on FormatException {
          errors.add('$path uses an unregistered scientific unit.');
        }
      }
    }
  }

  void _checkTypeAndUnit({
    required String path,
    required Map<String, Object?> packInput,
    required Object? sourceKind,
    required Object? sourceUnit,
    required List<String> errors,
  }) {
    final targetKind = packInput['kind'];
    final sourceCompatible = switch (targetKind) {
      'decimal' => sourceKind == 'decimal' || sourceKind == 'integer',
      'integer' => sourceKind == 'integer',
      'boolean' => sourceKind == 'boolean',
      'text' => sourceKind == 'text' || sourceKind == 'choice' || sourceKind == 'date',
      'asset_ref' => sourceKind == 'asset_ref',
      'sample_ref' => sourceKind == 'sample_ref',
      'table' => sourceKind == 'table',
      _ => false,
    };
    if (!sourceCompatible) {
      errors.add('$path cannot bind Protocol kind "$sourceKind" to Pack kind "$targetKind".');
      return;
    }
    if (targetKind != 'decimal') return;
    final targetUnitValue = packInput['unit'];
    final targetUnit = targetUnitValue is String ? targetUnitValue : '1';
    if (sourceUnit == null) {
      if (targetUnit != '1') {
        errors.add('$path requires a source unit compatible with "$targetUnit".');
      }
      return;
    }
    if (sourceUnit is! String) {
      errors.add('$path source unit must be a registered unit string.');
      return;
    }
    try {
      final source = UnitRegistry.parse(sourceUnit);
      final target = UnitRegistry.parse(targetUnit);
      if (!source.compatibleWith(target)) {
        errors.add('$path unit "$sourceUnit" is incompatible with Pack unit "$targetUnit".');
      } else if (source.symbol != target.symbol) {
        errors.add('$path requires the same canonical unit as Pack unit "$targetUnit"; implicit conversion is not defined in Protocol bindings.');
      }
    } on FormatException {
      errors.add('$path uses an unregistered scientific unit.');
    }
  }

  void _validateOutputBindings({
    required String stepId,
    required VersionedCalculationPack pack,
    required Map<String, String> outputBindings,
    required Map<String, Object?> step,
    required List<String> errors,
  }) {
    final outputDefinitions = _objectList(pack.document['outputs']);
    final declaredOutputs = <String>{};
    final captures = <String, Map<String, Object?>>{};
    for (final capture in _objectList(step['captures'])) {
      final key = capture['key'];
      if (key is! String || captures.containsKey(key)) {
        errors.add('steps.$stepId has duplicate or invalid capture keys.');
      } else {
        captures[key] = capture;
      }
    }
    for (final output in outputDefinitions) {
      final key = output['key'];
      if (key is! String || !declaredOutputs.add(key)) continue;
      final captureKey = outputBindings[key];
      if (captureKey == null) {
        errors.add('steps.$stepId does not bind Pack output "$key" to a capture.');
        continue;
      }
      final capture = captures[captureKey];
      if (capture == null) {
        errors.add('steps.$stepId binds "$key" to undeclared capture "$captureKey".');
        continue;
      }
      final outputKind = _outputKind(pack.document, output);
      final captureKind = capture['kind'];
      if (!_compatibleOutputKind(outputKind, captureKind)) {
        errors.add('steps.$stepId capture "$captureKey" kind "$captureKind" cannot store Pack output "$key" kind "$outputKind".');
      }
      final outputUnit = output['unit'];
      final captureUnit = capture['unit'];
      if (outputKind == 'decimal') {
        final from = outputUnit is String ? outputUnit : '1';
        final to = captureUnit is String ? captureUnit : '1';
        try {
          final source = UnitRegistry.parse(from);
          final target = UnitRegistry.parse(to);
          if (!source.compatibleWith(target)) {
            errors.add('steps.$stepId capture "$captureKey" unit "$to" is incompatible with Pack output unit "$from".');
          } else if (source.symbol != target.symbol) {
            errors.add('steps.$stepId capture "$captureKey" must use Pack output unit "$from"; implicit conversion is not defined in Protocol bindings.');
          }
        } on FormatException {
          errors.add('steps.$stepId output or capture uses an unregistered scientific unit.');
        }
      }
    }
    final extra = outputBindings.keys.toSet().difference(declaredOutputs);
    for (final key in extra) {
      errors.add('steps.$stepId.output_bindings references undeclared Pack output "$key".');
    }
  }

  String _outputKind(
    Map<String, Object?> document,
    Map<String, Object?> output,
  ) {
    final reference = output['from_ref'];
    if (reference is! String) return 'unknown';
    final parts = reference.substring(1).split('.');
    if (parts.length != 3) return 'unknown';
    final pipeline = _objectList(document['pipeline']);
    final source = _firstWhereOrNull(
      pipeline,
      (step) => step['step_id'] == parts[1],
    );
    final op = source?['op'];
    final valueKey = parts[2];
    if (op == 'data.qc_range@1' || op == 'data.qc_limits@1') return 'boolean';
    if (op == 'csv.parse_table@1' || op == 'table.select@1' ||
        op == 'table.group_by@1') return 'table';
    if (op == 'data.export_table@1') return 'text';
    if (op is! String ||
        !CalculationPackValidator.outputKeysFor(op).contains(valueKey)) {
      return 'unknown';
    }
    return 'decimal';
  }

  bool _compatibleOutputKind(Object? source, Object? capture) => switch (source) {
        'decimal' => capture == 'decimal',
        'boolean' => capture == 'boolean',
        'text' => capture == 'text',
        'table' => capture == 'table',
        _ => false,
      };

  bool _isAncestor(
    String candidate,
    String stepId,
    Map<String, Set<String>> dependencies,
  ) {
    final visited = <String>{};
    final pending = <String>[...(dependencies[stepId] ?? const <String>{})];
    while (pending.isNotEmpty) {
      final current = pending.removeLast();
      if (current == candidate) return true;
      if (!visited.add(current)) continue;
      pending.addAll(dependencies[current] ?? const <String>{});
    }
    return false;
  }

  (String, String)? _parsePackRef(String reference) {
    final at = reference.lastIndexOf('@');
    if (at <= 0 || at == reference.length - 1) return null;
    final packId = reference.substring(0, at);
    final version = reference.substring(at + 1);
    if (!RegExp(r'^[a-z0-9][a-z0-9._-]*$').hasMatch(packId) ||
        !RegExp(r'^[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?$')
            .hasMatch(version)) {
      return null;
    }
    return (packId, version);
  }

  Map<String, Object?> _object(Object? value) {
    if (value is! Map) return const <String, Object?>{};
    try {
      return requireJsonObject(value, 'workflow binding object');
    } on FormatException {
      return const <String, Object?>{};
    }
  }

  List<Map<String, Object?>> _objectList(Object? value) {
    if (value is! List) return const <Map<String, Object?>>[];
    return value.whereType<Map>().map(_object).toList(growable: false);
  }

  bool _containsFloat(Object? value) {
    if (value is double) return true;
    if (value is List) return value.any(_containsFloat);
    if (value is Map) return value.values.any(_containsFloat);
    return false;
  }

  T? _firstWhereOrNull<T>(Iterable<T> values, bool Function(T) predicate) {
    for (final value in values) {
      if (predicate(value)) return value;
    }
    return null;
  }
}
