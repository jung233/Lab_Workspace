import 'dart:typed_data';

final class SecretRef {
  const SecretRef(this.value) : assert(value != '');

  final String value;

  @override
  String toString() => 'SecretRef([redacted])';

  @override
  bool operator ==(Object other) => other is SecretRef && other.value == value;

  @override
  int get hashCode => value.hashCode;
}

/// A durable reference to a user action. It never represents consent by
/// itself; command handlers must require a reference for gated actions.
final class ApprovalRef {
  const ApprovalRef(this.value) : assert(value != '');

  final String value;

  @override
  String toString() => 'ApprovalRef($value)';

  @override
  bool operator ==(Object other) =>
      other is ApprovalRef && other.value == value;

  @override
  int get hashCode => value.hashCode;
}

/// Implemented by the native application with DPAPI, Keychain, or Keystore.
/// Secret bytes must never be written to SQLite, logs, Packs, or backups.
abstract interface class SecretStore {
  Future<Uint8List?> read(SecretRef ref);

  Future<SecretRef> write(Uint8List secret);

  Future<void> delete(SecretRef ref);
}

/// Optional in-place rotation for credentials whose identity must remain
/// stable across refreshes (for example an OAuth refresh token reference).
abstract interface class MutableSecretStore implements SecretStore {
  Future<void> replace(SecretRef ref, Uint8List secret);
}
