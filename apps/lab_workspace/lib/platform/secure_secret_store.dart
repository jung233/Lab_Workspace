import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:lab_core/lab_core.dart';

/// Persists provider credentials only in the operating system's secure store.
/// SQLite and Vault backups receive only the opaque [SecretRef].
final class FlutterSecretStore implements MutableSecretStore {
  FlutterSecretStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;
  static const _prefix = 'lab_workspace.secret.';

  @override
  Future<Uint8List?> read(SecretRef ref) async {
    final encoded = await _storage.read(key: '$_prefix${ref.value}');
    if (encoded == null) return null;
    try {
      return Uint8List.fromList(base64Url.decode(encoded));
    } on FormatException {
      await _storage.delete(key: '$_prefix${ref.value}');
      return null;
    }
  }

  @override
  Future<SecretRef> write(Uint8List secret) async {
    if (secret.isEmpty) {
      throw ArgumentError.value(
        secret,
        'secret',
        'Credential cannot be empty.',
      );
    }
    final ref = SecretRef(_newOpaqueId());
    await _storage.write(
      key: '$_prefix${ref.value}',
      value: base64UrlEncode(secret),
    );
    return ref;
  }

  @override
  Future<void> replace(SecretRef ref, Uint8List secret) async {
    if (secret.isEmpty) {
      throw ArgumentError.value(
        secret,
        'secret',
        'Credential cannot be empty.',
      );
    }
    await _storage.write(
      key: '$_prefix${ref.value}',
      value: base64UrlEncode(secret),
    );
  }

  @override
  Future<void> delete(SecretRef ref) =>
      _storage.delete(key: '$_prefix${ref.value}');

  /// Imports an encryption recovery key under its original opaque reference so
  /// manifests remain resolvable on another device. Call only after the user
  /// confirms the recovery-key import.
  Future<void> importWithRef(SecretRef ref, Uint8List secret) async {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(ref.value)) {
      throw const FormatException('Unsupported recovery SecretRef format.');
    }
    if (secret.isEmpty) {
      throw ArgumentError.value(secret, 'secret', 'Recovery key cannot be empty.');
    }
    await _storage.write(
      key: '$_prefix${ref.value}',
      value: base64UrlEncode(secret),
    );
  }

  static String _newOpaqueId() {
    final random = Random.secure();
    return List<int>.generate(
      32,
      (_) => random.nextInt(256),
    ).map((value) => value.toRadixString(16).padLeft(2, '0')).join();
  }
}
