import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:lab_core/lab_core.dart';

/// Ed25519 signer for user-approved calculation Packs.
///
/// The private key is stored only in the operating system secure store. The
/// workspace settings row contains an opaque SecretRef so backups never carry
/// signing material. Losing the secure-store item fails closed rather than
/// silently creating a new signing identity.
final class SecureCalculationPackSignatures
    implements CalculationPackSignaturePort {
  SecureCalculationPackSignatures({
    required SecretStore secrets,
    required SettingsService settings,
  }) : _secrets = secrets,
       _settings = settings;

  static const _settingKey = 'calculation_pack_signing_secret_ref';
  final SecretStore _secrets;
  final SettingsService _settings;
  final Ed25519 _algorithm = Ed25519();

  Future<SecretRef>? _secretRefFuture;

  @override
  Future<String> sign(String canonicalPayload) async {
    final key = await _loadKeyPair();
    try {
      final signature = await _algorithm.sign(
        utf8.encode(canonicalPayload),
        keyPair: key,
      );
      return base64UrlEncode(signature.bytes).replaceAll('=', '');
    } finally {
      key.destroy();
    }
  }

  @override
  Future<bool> verify(String canonicalPayload, String signature) async {
    final key = await _loadKeyPair();
    try {
      final encoded = base64Url.decode(base64Url.normalize(signature));
      return await _algorithm.verify(
        utf8.encode(canonicalPayload),
        signature: Signature(encoded, publicKey: key.publicKey),
      );
    } on FormatException {
      return false;
    } finally {
      key.destroy();
    }
  }

  Future<SimpleKeyPairData> _loadKeyPair() async {
    final ref = await (_secretRefFuture ??= _getOrCreateSecretRef());
    final secret = await _secrets.read(ref);
    if (secret == null) {
      throw StateError(
        'Calculation Pack signing key is missing from secure storage.',
      );
    }
    try {
      final material = jsonDecode(utf8.decode(secret));
      if (material is! Map<String, dynamic> ||
          material['private_key'] is! String ||
          material['public_key'] is! String) {
        throw const FormatException('Malformed signing key material.');
      }
      final privateBytes = base64Url.decode(
        base64Url.normalize(material['private_key']! as String),
      );
      final publicBytes = base64Url.decode(
        base64Url.normalize(material['public_key']! as String),
      );
      return SimpleKeyPairData(
        privateBytes,
        publicKey: SimplePublicKey(publicBytes, type: KeyPairType.ed25519),
        type: KeyPairType.ed25519,
      );
    } finally {
      secret.fillRange(0, secret.length, 0);
    }
  }

  Future<SecretRef> _getOrCreateSecretRef() async {
    final saved = _settings.get(_settingKey)?.value['secret_ref'];
    if (saved is String && saved.isNotEmpty) return SecretRef(saved);
    if (saved != null) {
      throw StateError(
        'Calculation Pack signing SecretRef setting is malformed.',
      );
    }

    final pair = await _algorithm.newKeyPair();
    final keyData = await pair.extract();
    final privateBytes = Uint8List.fromList(
      await keyData.extractPrivateKeyBytes(),
    );
    final publicBytes = Uint8List.fromList(keyData.publicKey.bytes);
    Uint8List? serialized;
    try {
      serialized = Uint8List.fromList(
        utf8.encode(
          jsonEncode(<String, String>{
            'private_key': base64UrlEncode(privateBytes),
            'public_key': base64UrlEncode(publicBytes),
          }),
        ),
      );
      final ref = await _secrets.write(serialized);
      try {
        _settings.set(
          key: _settingKey,
          value: <String, Object?>{'secret_ref': ref.value},
        );
      } on Object {
        await _secrets.delete(ref);
        rethrow;
      }
      return ref;
    } finally {
      privateBytes.fillRange(0, privateBytes.length, 0);
      serialized?.fillRange(0, serialized.length, 0);
      keyData.destroy();
      if (pair is SimpleKeyPairData && !pair.hasBeenDestroyed) pair.destroy();
    }
  }
}
