import 'dart:convert';

/// Makes JSON-compatible data immutable, including nested maps and lists.
Object? freezeJsonValue(Object? value) {
  if (value == null || value is String || value is bool || value is int) {
    return value;
  }
  if (value is double) {
    if (!value.isFinite) {
      throw const FormatException('JSON numbers must be finite.');
    }
    return value;
  }
  if (value is List) {
    return List<Object?>.unmodifiable(value.map(freezeJsonValue));
  }
  if (value is Map) {
    final result = <String, Object?>{};
    for (final entry in value.entries) {
      if (entry.key is! String) {
        throw const FormatException('JSON object keys must be strings.');
      }
      result[entry.key as String] = freezeJsonValue(entry.value);
    }
    return Map<String, Object?>.unmodifiable(result);
  }
  throw FormatException('Value of type ${value.runtimeType} is not JSON data.');
}

Map<String, Object?> freezeJsonObject(Map<String, Object?> value) =>
    freezeJsonValue(value)! as Map<String, Object?>;

/// Canonical JSON for stable SHA-256 identity. Object keys are sorted at every
/// depth; array order and JSON scalar representations are preserved.
String canonicalJson(Object? value) => jsonEncode(_canonicalValue(value));

Object? _canonicalValue(Object? value) {
  if (value == null || value is String || value is bool || value is num) {
    if (value is double && !value.isFinite) {
      throw const FormatException('JSON numbers must be finite.');
    }
    return value;
  }
  if (value is List) return value.map(_canonicalValue).toList(growable: false);
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return <String, Object?>{
      for (final key in keys) key: _canonicalValue(value[key]),
    };
  }
  throw FormatException('Value of type ${value.runtimeType} is not JSON data.');
}

Map<String, Object?> requireJsonObject(Object? value, String field) {
  if (value is! Map) throw FormatException('$field must be a JSON object.');
  final result = <String, Object?>{};
  for (final entry in value.entries) {
    if (entry.key is! String) {
      throw FormatException('$field must use string object keys.');
    }
    result[entry.key as String] = entry.value;
  }
  return result;
}
