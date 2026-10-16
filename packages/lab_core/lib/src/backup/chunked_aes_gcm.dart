import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Bounded-memory authenticated file encryption shared by remote sync and
/// backup. The header is authenticated as additional data for every chunk;
/// each chunk has an independently derived nonce, so interrupted transfers do
/// not expose unauthenticated plaintext.
final class ChunkedAesGcm {
  ChunkedAesGcm({this.chunkSize = 1024 * 1024}) {
    if (chunkSize <= 0 || chunkSize > 64 * 1024 * 1024) {
      throw ArgumentError.value(chunkSize, 'chunkSize');
    }
  }

  static const List<int> _magic = [0x4c, 0x57, 0x41, 0x45]; // LWAE
  static const int _headerSize = 25;
  static const int _tagSize = 16;

  final int chunkSize;
  final AesGcm _algorithm = AesGcm.with256bits();

  Future<({int plaintextBytes, int ciphertextBytes})> encryptFile({
    required List<int> keyBytes,
    required String sourcePath,
    required String destinationPath,
  }) async {
    _requireKey(keyBytes);
    final source = File(sourcePath);
    final length = await source.length();
    final header = _makeHeader(length);
    final noncePrefix = header.sublist(17, 25);
    final output = File(destinationPath);
    await output.parent.create(recursive: true);
    final input = await source.open(mode: FileMode.read);
    await output.create(exclusive: true);
    final sink = output.openWrite(mode: FileMode.writeOnly);
    var total = 0;
    var counter = 0;
    try {
      sink.add(header);
      if (length == 0) {
        await _encryptChunk(const <int>[], keyBytes, header, noncePrefix, counter++, sink);
      }
      while (total < length) {
        final amount = min(chunkSize, length - total);
        final plain = await input.read(amount);
        if (plain.length != amount) throw const FileSystemException('Source changed during encryption.');
        await _encryptChunk(plain, keyBytes, header, noncePrefix, counter++, sink);
        total += plain.length;
      }
      await sink.flush();
      await sink.close();
      return (plaintextBytes: total, ciphertextBytes: await output.length());
    } on Object {
      await sink.close();
      if (await output.exists()) await output.delete();
      rethrow;
    } finally {
      await input.close();
    }
  }

  Future<void> decryptFile({
    required List<int> keyBytes,
    required String sourcePath,
    required String destinationPath,
  }) async {
    _requireKey(keyBytes);
    final source = File(sourcePath);
    final input = await source.open(mode: FileMode.read);
    final output = File(destinationPath);
    await output.parent.create(recursive: true);
    await output.create(exclusive: true);
    final sink = output.openWrite(mode: FileMode.writeOnly);
    try {
      final header = await _readExact(input, _headerSize);
      _validateHeader(header);
      final data = ByteData.sublistView(Uint8List.fromList(header));
      final expectedLength = data.getUint64(9, Endian.big);
      final chunkBytes = data.getUint32(5, Endian.big);
      final noncePrefix = header.sublist(17, 25);
      var written = 0;
      var index = 0;
      do {
        final lengthBytes = await _readExact(input, 4);
        final chunkLength = ByteData.sublistView(Uint8List.fromList(lengthBytes))
            .getUint32(0, Endian.big);
        final remaining = await input.length() - await input.position();
        if (chunkLength > chunkBytes ||
            (expectedLength > 0 && chunkLength == 0) ||
            written + chunkLength > expectedLength ||
            chunkLength + _tagSize > remaining) {
          throw const FormatException('Encrypted asset chunk length is invalid.');
        }
        final encrypted = await _readExact(input, chunkLength + _tagSize);
        final cipherText = encrypted.sublist(0, chunkLength);
        final mac = Mac(encrypted.sublist(chunkLength));
        final box = SecretBox(
          cipherText,
          nonce: _nonce(noncePrefix, index),
          mac: mac,
        );
        final plain = await _algorithm.decrypt(
          box,
          secretKey: SecretKey(keyBytes),
          aad: _aad(header, index, chunkLength),
        );
        sink.add(plain);
        written += plain.length;
        index++;
        if (expectedLength == 0) break;
      } while (written < expectedLength);
      if (written != expectedLength || await input.length() != await input.position()) {
        throw const FormatException('Encrypted asset length or trailing data is invalid.');
      }
      await sink.flush();
      await sink.close();
    } on Object {
      await sink.close();
      if (await output.exists()) await output.delete();
      rethrow;
    } finally {
      await input.close();
    }
  }

  Future<Uint8List> encryptBytes(List<int> plaintext, List<int> keyBytes) async {
    _requireKey(keyBytes);
    final header = _makeHeader(plaintext.length);
    final sink = BytesBuilder(copy: false)..add(header);
    final noncePrefix = header.sublist(17, 25);
    if (plaintext.isEmpty) {
      final box = await _algorithm.encrypt(
        const <int>[],
        secretKey: SecretKey(keyBytes),
        nonce: _nonce(noncePrefix, 0),
        aad: _aad(header, 0, 0),
      );
      _writeRecord(sink, const <int>[], box.mac.bytes);
    } else {
      var index = 0;
      for (var offset = 0; offset < plaintext.length; offset += chunkSize) {
        final end = min(offset + chunkSize, plaintext.length);
        final box = await _algorithm.encrypt(
          plaintext.sublist(offset, end),
          secretKey: SecretKey(keyBytes),
          nonce: _nonce(noncePrefix, index),
          aad: _aad(header, index, end - offset),
        );
        _writeRecord(sink, box.cipherText, box.mac.bytes);
        index++;
      }
    }
    return sink.takeBytes();
  }

  Future<Uint8List> decryptBytes(List<int> bytes, List<int> keyBytes) async {
    _requireKey(keyBytes);
    if (bytes.length < _headerSize) throw const FormatException('Encrypted object is truncated.');
    final header = bytes.sublist(0, _headerSize);
    _validateHeader(header);
    final view = ByteData.sublistView(Uint8List.fromList(header));
    final expectedLength = view.getUint64(9, Endian.big);
    final maxChunk = view.getUint32(5, Endian.big);
    final noncePrefix = header.sublist(17, 25);
    final output = BytesBuilder(copy: false);
    var offset = _headerSize;
    var written = 0;
    var index = 0;
    do {
      if (offset + 4 > bytes.length) throw const FormatException('Encrypted chunk header is truncated.');
      final size = ByteData.sublistView(Uint8List.fromList(bytes.sublist(offset, offset + 4)))
          .getUint32(0, Endian.big);
      offset += 4;
      if (size > maxChunk ||
          (expectedLength > 0 && size == 0) ||
          written + size > expectedLength ||
          offset + size + _tagSize > bytes.length) {
        throw const FormatException('Encrypted chunk length is invalid.');
      }
      final cipher = bytes.sublist(offset, offset + size);
      final mac = bytes.sublist(offset + size, offset + size + _tagSize);
      final plain = await _algorithm.decrypt(
        SecretBox(cipher, nonce: _nonce(noncePrefix, index), mac: Mac(mac)),
        secretKey: SecretKey(keyBytes),
        aad: _aad(header, index, size),
      );
      output.add(plain);
      written += plain.length;
      offset += size + _tagSize;
      index++;
      if (expectedLength == 0) break;
    } while (written < expectedLength);
    if (written != expectedLength || offset != bytes.length) {
      throw const FormatException('Encrypted object length or trailing data is invalid.');
    }
    return output.takeBytes();
  }

  Future<void> _encryptChunk(
    List<int> plaintext,
    List<int> key,
    List<int> header,
    List<int> noncePrefix,
    int index,
    IOSink sink,
  ) async {
    final box = await _algorithm.encrypt(
      plaintext,
      secretKey: SecretKey(key),
      nonce: _nonce(noncePrefix, index),
      aad: _aad(header, index, plaintext.length),
    );
    final size = ByteData(4)..setUint32(0, plaintext.length, Endian.big);
    sink.add(size.buffer.asUint8List());
    sink.add(box.cipherText);
    sink.add(box.mac.bytes);
  }

  Uint8List _makeHeader(int length) {
    final random = Random.secure();
    final bytes = Uint8List(_headerSize);
    bytes.setRange(0, 4, _magic);
    bytes[4] = 1;
    final view = ByteData.sublistView(bytes);
    view.setUint32(5, chunkSize, Endian.big);
    view.setUint64(9, length, Endian.big);
    for (var i = 17; i < 25; i++) {
      bytes[i] = random.nextInt(256);
    }
    return bytes;
  }

  static void _validateHeader(List<int> header) {
    if (header.length != _headerSize ||
        !_same(header.take(4), _magic) ||
        header[4] != 1) {
      throw const FormatException('Unsupported encrypted object header.');
    }
    final chunkSize = ByteData.sublistView(Uint8List.fromList(header)).getUint32(5, Endian.big);
    if (chunkSize == 0 || chunkSize > 64 * 1024 * 1024) {
      throw const FormatException('Encrypted object chunk size is outside the supported bound.');
    }
  }

  static List<int> _nonce(List<int> prefix, int index) {
    if (index < 0 || index > 0xffffffff) throw StateError('Encrypted object exceeds chunk nonce range.');
    final output = Uint8List(12)..setRange(0, 8, prefix);
    ByteData.sublistView(output).setUint32(8, index, Endian.big);
    return output;
  }

  static List<int> _aad(List<int> header, int index, int length) {
    final suffix = ByteData(8)
      ..setUint32(0, index, Endian.big)
      ..setUint32(4, length, Endian.big);
    return <int>[...header, ...suffix.buffer.asUint8List()];
  }

  static void _writeRecord(BytesBuilder output, List<int> cipher, List<int> mac) {
    final size = ByteData(4)..setUint32(0, cipher.length, Endian.big);
    output.add(size.buffer.asUint8List());
    output.add(cipher);
    output.add(mac);
  }

  static Future<Uint8List> _readExact(RandomAccessFile file, int length) async {
    final bytes = await file.read(length);
    if (bytes.length != length) throw const FormatException('Encrypted object is truncated.');
    return Uint8List.fromList(bytes);
  }

  static bool _same(Iterable<int> left, List<int> right) {
    final a = left.toList(growable: false);
    if (a.length != right.length) return false;
    for (var index = 0; index < a.length; index++) {
      if (a[index] != right[index]) return false;
    }
    return true;
  }

  static void _requireKey(List<int> key) {
    if (key.length != 32) throw const FormatException('AES-256-GCM key must contain 32 bytes.');
  }
}
