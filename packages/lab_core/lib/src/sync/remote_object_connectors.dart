import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'sync_models.dart';

/// Storage-neutral object API used by sync and backup. Object keys are
/// immutable: a repeated put succeeds only when the provider reports that the
/// key already exists; callers must compare its content before treating that
/// response as an idempotent success.
abstract interface class RemoteObjectConnector {
  Future<List<RemoteObject>> list(String prefix);
  Future<Uint8List> getBytes(String key, {int maximumBytes = 16 * 1024 * 1024});
  Future<void> downloadToFile(String key, String destination);
  Future<void> putBytes(String key, List<int> bytes);
  Future<void> putFile(String key, String sourcePath);
}

/// OneDrive Graph client for a pre-authorized delegated access token.
/// The credential/token lifecycle stays in the native SecretStore adapter.
/// Tokens are never persisted by this class or written to the Vault database.
final class OneDriveGraphConnector implements RemoteObjectConnector {
  OneDriveGraphConnector({
    String? accessToken,
    Future<String?> Function()? accessTokenProvider,
    this.driveId,
    HttpClient? client,
    this.graphBase = 'https://graph.microsoft.com/v1.0',
  })  : _accessToken = accessToken,
        _accessTokenProvider = accessTokenProvider,
        _client = client ?? HttpClient() {
    if ((accessToken == null || accessToken.isEmpty) && accessTokenProvider == null) {
      throw ArgumentError('A Microsoft access token or token provider is required.');
    }
    if (!Uri.parse(graphBase).isScheme('https')) {
      throw ArgumentError.value(graphBase, 'graphBase', 'HTTPS is required.');
    }
  }

  final String? _accessToken;
  final Future<String?> Function()? _accessTokenProvider;
  final String? driveId;
  final HttpClient _client;
  final String graphBase;

  @override
  Future<List<RemoteObject>> list(String prefix) async {
    final normalized = _normalizeKey(prefix);
    final output = <RemoteObject>[];
    final pending = <String>[normalized];
    while (pending.isNotEmpty) {
      final directory = pending.removeLast();
      Uri? next = _directoryUri(directory);
      while (next != null) {
        final response = await _send('GET', next);
        final body = await _body(response);
        if (response.statusCode != HttpStatus.ok) {
          throw _httpFailure('OneDrive list', response.statusCode, body);
        }
        final document = jsonDecode(body) as Map<String, Object?>;
        final values = document['value'];
        if (values is! List) throw const FormatException('Invalid Graph children response.');
        for (final value in values) {
          if (value is! Map<String, Object?>) continue;
          final name = value['name'] as String?;
          if (name == null || name.isEmpty) continue;
          final key = directory.isEmpty ? name : '$directory/$name';
          if (value['folder'] is Map) {
            pending.add(key);
          } else {
            final size = _asInt(value['size']);
            output.add(RemoteObject(key: key, byteSize: size, etag: value['eTag'] as String?));
          }
        }
        final nextLink = document['@odata.nextLink'] as String?;
        next = nextLink == null ? null : Uri.parse(nextLink);
      }
    }
    return output.where((item) => item.key.startsWith(normalized)).toList(growable: false);
  }

  @override
  Future<Uint8List> getBytes(String key, {int maximumBytes = 16 * 1024 * 1024}) async {
    final response = await _send('GET', _itemUri(key, content: true));
    if (response.statusCode != HttpStatus.ok) {
      final body = await _body(response);
      throw _httpFailure('OneDrive object read', response.statusCode, body);
    }
    final bytes = BytesBuilder(copy: false);
    var count = 0;
    await for (final part in response) {
      count += part.length;
      if (count > maximumBytes) {
        throw StateError('Remote object exceeds the bounded in-memory read limit.');
      }
      bytes.add(part);
    }
    return bytes.takeBytes();
  }

  @override
  Future<void> downloadToFile(String key, String destination) async {
    final response = await _send('GET', _itemUri(key, content: true));
    if (response.statusCode != HttpStatus.ok) {
      final body = await _body(response);
      throw _httpFailure('OneDrive object download', response.statusCode, body);
    }
    final output = File(destination);
    await output.parent.create(recursive: true);
    await output.create(exclusive: true);
    final sink = output.openWrite(mode: FileMode.writeOnly);
    try {
      await response.pipe(sink);
    } on Object {
      await sink.close();
      if (await output.exists()) await output.delete();
      rethrow;
    }
  }

  @override
  Future<void> putBytes(String key, List<int> bytes) async {
    final temp = File(p.join(Directory.systemTemp.path,
        'lw-graph-${DateTime.now().microsecondsSinceEpoch}.part'));
    await temp.writeAsBytes(bytes, flush: true);
    try {
      await _uploadLargeFile(key, temp, bytes.length);
    } finally {
      if (await temp.exists()) await temp.delete();
    }
  }

  @override
  Future<void> putFile(String key, String sourcePath) async {
    final file = File(sourcePath);
    final length = await file.length();
    await _uploadLargeFile(key, file, length);
  }

  Future<void> _uploadLargeFile(String key, File file, int length) async {
    await _ensureParentDirectories(key);
    final sessionRequest = await _sendRequest('POST', _itemUri(key, uploadSession: true));
    sessionRequest.headers.contentType = ContentType.json;
    sessionRequest.write(jsonEncode({'item': {'@microsoft.graph.conflictBehavior': 'fail'}}));
    final sessionResponse = await sessionRequest.close();
    final sessionBody = await _body(sessionResponse);
    if (sessionResponse.statusCode != HttpStatus.ok && sessionResponse.statusCode != HttpStatus.created) {
      if (sessionResponse.statusCode == HttpStatus.conflict ||
          sessionResponse.statusCode == HttpStatus.preconditionFailed) {
        final existing = File(p.join(Directory.systemTemp.path,
            'lw-graph-existing-${DateTime.now().microsecondsSinceEpoch}.part'));
        try {
          await downloadToFile(key, existing.path);
          final expected = (await sha256.bind(file.openRead()).first).toString();
          final actual = (await sha256.bind(existing.openRead()).first).toString();
          if (expected == actual) return;
          throw StateError('Immutable OneDrive key already contains different bytes: $key');
        } finally {
          if (await existing.exists()) await existing.delete();
        }
      }
      throw _httpFailure('OneDrive upload session', sessionResponse.statusCode, sessionBody);
    }
    final uploadUrl = (jsonDecode(sessionBody) as Map<String, Object?>)['uploadUrl'] as String?;
    if (uploadUrl == null) throw const FormatException('Graph did not return an uploadUrl.');
    final uri = Uri.parse(uploadUrl);
    if (!uri.isScheme('https')) throw const FormatException('Graph returned a non-HTTPS upload URL.');
    const chunkSize = 10 * 1024 * 1024; // 32 x 320 KiB, within Graph chunk rules.
    var start = 0;
    while (start < length) {
      final endExclusive = math.min(start + chunkSize, length).toInt();
      final request = await _client.putUrl(uri);
      request.contentLength = endExclusive - start;
      request.headers.set(HttpHeaders.contentRangeHeader, 'bytes $start-${endExclusive - 1}/$length');
      await request.addStream(file.openRead(start, endExclusive));
      final response = await request.close();
      final body = await _body(response);
      if (response.statusCode != HttpStatus.accepted &&
          response.statusCode != HttpStatus.created &&
          response.statusCode != HttpStatus.ok) {
        throw _httpFailure('OneDrive chunk upload', response.statusCode, body);
      }
      start = endExclusive;
    }
  }

  Future<void> _ensureParentDirectories(String key) async {
    final segments = _normalizeKey(key).split('/');
    if (segments.length < 2) return;
    var parent = '';
    for (final segment in segments.take(segments.length - 1)) {
      final request = await _sendRequest('POST', _directoryUri(parent));
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode({
        'name': segment,
        'folder': <String, Object?>{},
        '@microsoft.graph.conflictBehavior': 'fail',
      }));
      final response = await request.close();
      final body = await _body(response);
      if (response.statusCode != HttpStatus.created && response.statusCode != HttpStatus.conflict) {
        throw _httpFailure('OneDrive folder create', response.statusCode, body);
      }
      parent = parent.isEmpty ? segment : '$parent/$segment';
    }
  }

  Uri _directoryUri(String key) {
    final encoded = key.isEmpty ? '' : key.split('/').map(Uri.encodeComponent).join('/');
    final root = _rootPath();
    final path = encoded.isEmpty ? '$root/children' : '$root:/$encoded:/children';
    return Uri.parse('$graphBase$path?\$top=200');
  }

  Uri _itemUri(String key, {bool content = false, bool uploadSession = false, bool conflictFail = false}) {
    final encoded = _normalizeKey(key).split('/').map(Uri.encodeComponent).join('/');
    final root = _rootPath();
    final item = '$root:/$encoded:';
    if (content) return Uri.parse('$graphBase$item/content');
    if (uploadSession) return Uri.parse('$graphBase$item/createUploadSession');
    if (conflictFail) return Uri.parse('$graphBase$item');
    return Uri.parse('$graphBase$item');
  }

  String _rootPath() => driveId == null
      ? '/me/drive/root'
      : '/drives/${Uri.encodeComponent(driveId!)}/root';

  Future<HttpClientRequest> _sendRequest(String method, Uri uri) async {
    final token = _accessTokenProvider == null ? _accessToken : await _accessTokenProvider();
    if (token == null || token.trim().isEmpty) {
      throw const SyncCredentialRequiredException(SyncProvider.oneDrive);
    }
    final request = await _client.openUrl(method, uri);
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    return request;
  }

  Future<HttpClientResponse> _send(String method, Uri uri) async =>
      (await _sendRequest(method, uri)).close();

  static Future<String> _body(HttpClientResponse response) async {
    final builder = StringBuffer();
    var length = 0;
    await for (final bytes in response) {
      length += bytes.length;
      if (length > 1024 * 1024) break;
      builder.write(utf8.decode(bytes, allowMalformed: true));
    }
    return builder.toString();
  }
}

/// S3-compatible client using AWS Signature Version 4 and conditional PUT.
/// It supports path-style endpoints so compatible local/private S3 services can
/// use the same connector without embedding provider SDKs in the core package.
final class S3ObjectConnector implements RemoteObjectConnector {
  S3ObjectConnector({
    required this.endpoint,
    required this.region,
    required this.bucket,
    required String accessKeyId,
    required String secretAccessKey,
    this.sessionToken,
    this.journalDirectory,
    HttpClient? client,
  })  : _accessKeyId = accessKeyId,
        _secretAccessKey = secretAccessKey,
        _client = client ?? HttpClient() {
    if (!endpoint.isScheme('https')) throw ArgumentError.value(endpoint, 'endpoint', 'HTTPS is required.');
    if (!endpoint.hasAuthority || region.trim().isEmpty || bucket.trim().isEmpty ||
        accessKeyId.isEmpty || secretAccessKey.isEmpty) {
      throw ArgumentError('S3 endpoint, region, bucket, and credentials are required.');
    }
  }

  final Uri endpoint;
  final String region;
  final String bucket;
  final String _accessKeyId;
  final String _secretAccessKey;
  final String? sessionToken;
  final String? journalDirectory;
  final HttpClient _client;

  static const int _singlePutLimitBytes = 5 * 1000 * 1000 * 1000;
  static const int _preferredMultipartPartBytes = 64 * 1024 * 1024;
  static const int _maximumMultipartPartBytes = 5 * 1024 * 1024 * 1024;
  static const int _maximumMultipartParts = 10000;
  static const int _maximumObjectBytes = _maximumMultipartPartBytes * _maximumMultipartParts;

  @override
  Future<List<RemoteObject>> list(String prefix) async {
    final objects = <RemoteObject>[];
    String? token;
    do {
      final query = <String, String>{'list-type': '2', 'prefix': _normalizeKey(prefix)};
      if (token != null) query['continuation-token'] = token;
      final uri = _objectUri('', query: query);
      final response = await (await _signedRequest(
        'GET',
        uri,
        payloadHash: sha256.convert(const <int>[]).toString(),
      )).close();
      final body = await _readString(response);
      if (response.statusCode != HttpStatus.ok) throw _httpFailure('S3 list', response.statusCode, body);
      for (final match in RegExp(r'<Contents>(.*?)</Contents>', dotAll: true).allMatches(body)) {
        final block = match.group(1)!;
        final keyValue = _xmlValue(block, 'Key');
        if (keyValue == null) continue;
        final size = int.tryParse(_xmlValue(block, 'Size') ?? '') ?? 0;
        final etag = _xmlValue(block, 'ETag');
        objects.add(RemoteObject(key: keyValue, byteSize: size, etag: etag));
      }
      token = _xmlValue(body, 'NextContinuationToken');
    } while (token != null && token.isNotEmpty);
    return objects;
  }

  @override
  Future<Uint8List> getBytes(String key, {int maximumBytes = 16 * 1024 * 1024}) async {
    final response = await (await _signedRequest(
      'GET',
      _objectUri(key),
      payloadHash: 'UNSIGNED-PAYLOAD',
    )).close();
    if (response.statusCode != HttpStatus.ok) {
      final body = await _readString(response);
      throw _httpFailure('S3 object read', response.statusCode, body);
    }
    final builder = BytesBuilder(copy: false);
    var count = 0;
    await for (final bytes in response) {
      count += bytes.length;
      if (count > maximumBytes) throw StateError('Remote object exceeds the bounded in-memory read limit.');
      builder.add(bytes);
    }
    return builder.takeBytes();
  }

  @override
  Future<void> downloadToFile(String key, String destination) async {
    final response = await (await _signedRequest(
      'GET',
      _objectUri(key),
      payloadHash: 'UNSIGNED-PAYLOAD',
    )).close();
    if (response.statusCode != HttpStatus.ok) {
      final body = await _readString(response);
      throw _httpFailure('S3 object download', response.statusCode, body);
    }
    final output = File(destination);
    await output.parent.create(recursive: true);
    await output.create(exclusive: true);
    final sink = output.openWrite(mode: FileMode.writeOnly);
    try {
      await response.pipe(sink);
    } on Object {
      await sink.close();
      if (await output.exists()) await output.delete();
      rethrow;
    }
  }

  @override
  Future<void> putBytes(String key, List<int> bytes) async {
    final digest = sha256.convert(bytes).toString();
    final response = await _putRequest(_objectUri(key), bytes.length, digest, Stream<List<int>>.value(bytes));
    if (response.statusCode == HttpStatus.ok || response.statusCode == HttpStatus.created) return;
    final body = await _readString(response);
    if (response.statusCode == HttpStatus.preconditionFailed) {
      final existing = await getBytes(key, maximumBytes: math.max(bytes.length, 1));
      if (sha256.convert(existing).toString() == digest) return;
      throw StateError('Immutable S3 key already contains different bytes: $key');
    }
    throw _httpFailure('S3 object upload', response.statusCode, body);
  }

  @override
  Future<void> putFile(String key, String sourcePath) async {
    final file = File(sourcePath);
    final length = await file.length();
    final digest = (await sha256.bind(file.openRead()).first).toString();
    if (length > _singlePutLimitBytes) {
      await _putMultipartFile(_normalizeKey(key), file, length, digest);
      return;
    }
    final response = await _putRequest(_objectUri(key), length, digest, file.openRead());
    if (response.statusCode == HttpStatus.ok || response.statusCode == HttpStatus.created) return;
    final body = await _readString(response);
    if (response.statusCode == HttpStatus.preconditionFailed) {
      final existing = File(p.join(Directory.systemTemp.path,
          'lw-s3-existing-${DateTime.now().microsecondsSinceEpoch}.part'));
      try {
        await downloadToFile(key, existing.path);
          final existingDigest = (await sha256.bind(existing.openRead()).first).toString();
          if (existingDigest == digest) return;
        throw StateError('Immutable S3 key already contains different bytes: $key');
      } finally {
        if (await existing.exists()) await existing.delete();
      }
    }
    throw _httpFailure('S3 file upload', response.statusCode, body);
  }

  Future<void> _putMultipartFile(String key, File file, int length, String digest) async {
    if (length > _maximumObjectBytes) {
      throw StateError('S3 multipart upload exceeds the provider object-size limit.');
    }
    final requiredPartSize = (length + _maximumMultipartParts - 1) ~/ _maximumMultipartParts;
    final partSize = math.max(_preferredMultipartPartBytes, requiredPartSize).toInt();
    if (partSize > _maximumMultipartPartBytes) {
      throw StateError('S3 multipart upload exceeds the supported object size.');
    }
    final partCount = (length + partSize - 1) ~/ partSize;
    if (partCount > _maximumMultipartParts) {
      throw StateError('S3 multipart upload would exceed the 10,000 part limit.');
    }

    _S3MultipartJournal? journal = await _readMultipartJournal(key);
    if (journal != null &&
        (journal.key != key || journal.sha256 != digest ||
            journal.byteSize != length || journal.partSize != partSize)) {
      await _abortMultipart(key, journal.uploadId);
      await _deleteMultipartJournal(key);
      journal = null;
    }

    try {
      if (await _verifyExistingObject(key, digest, length)) {
        if (journal != null) await _abortMultipart(key, journal.uploadId);
        await _deleteMultipartJournal(key);
        return;
      }
    } on Object {
      if (journal != null) await _abortMultipart(key, journal.uploadId);
      await _deleteMultipartJournal(key);
      rethrow;
    }

    for (var restart = 0; restart < 3; restart++) {
      journal ??= await _startMultipart(key, digest, length, partSize);
      await _saveMultipartJournal(journal);
      try {
        final remoteParts = await _listMultipartParts(key, journal.uploadId);
        final completedParts = <_S3CompletedPart>[];
        for (var partNumber = 1; partNumber <= partCount; partNumber++) {
          final start = (partNumber - 1) * partSize;
          final end = math.min(start + partSize, length).toInt();
          final partLength = end - start;
          final checksum = await _sha256Base64Range(file, start, end);
          final saved = remoteParts[partNumber];
          if (saved != null && saved.byteSize == partLength && saved.checksumSha256 == checksum) {
            completedParts.add(_S3CompletedPart(
              partNumber: partNumber,
              etag: saved.etag,
              checksumSha256: checksum,
            ));
            continue;
          }
          final etag = await _uploadMultipartPart(
            key: key,
            uploadId: journal.uploadId,
            partNumber: partNumber,
            file: file,
            start: start,
            end: end,
            checksumSha256: checksum,
          );
          completedParts.add(_S3CompletedPart(
            partNumber: partNumber,
            etag: etag,
            checksumSha256: checksum,
          ));
        }

        final xml = StringBuffer('<CompleteMultipartUpload>');
        for (final part in completedParts) {
          xml
            ..write('<Part><PartNumber>${part.partNumber}</PartNumber>')
            ..write('<ETag>${_xmlEscape(part.etag)}</ETag>')
            ..write('<ChecksumSHA256>${part.checksumSha256}</ChecksumSHA256></Part>');
        }
        xml.write('</CompleteMultipartUpload>');
        final bytes = utf8.encode(xml.toString());
        final response = await _signedRequest(
          'POST',
          _objectUri(key, query: {'uploadId': journal.uploadId}),
          payloadHash: sha256.convert(bytes).toString(),
          extraHeaders: const {'if-none-match': '*'},
        );
        response.headers.contentType = ContentType('application', 'xml', charset: 'utf-8');
        response.contentLength = bytes.length;
        response.add(bytes);
        final completed = await response.close();
        final body = await _readString(completed);
        final errorCode = _xmlValue(body, 'Code');
        if (completed.statusCode == HttpStatus.conflict || errorCode == 'ConditionalRequestConflict' ||
            errorCode == 'NoSuchUpload') {
          throw const _S3RestartMultipart();
        }
        if (completed.statusCode == HttpStatus.preconditionFailed || errorCode == 'PreconditionFailed') {
          if (await _verifyExistingObject(key, digest, length)) {
            await _abortMultipart(key, journal.uploadId);
            await _deleteMultipartJournal(key);
            return;
          }
          throw StateError('Immutable S3 key already contains different bytes: $key');
        }
        if (completed.statusCode != HttpStatus.ok || body.contains('<Error>')) {
          throw _httpFailure('S3 multipart completion', completed.statusCode, body);
        }
        await _deleteMultipartJournal(key);
        return;
      } on _S3RestartMultipart {
        await _abortMultipart(key, journal.uploadId);
        await _deleteMultipartJournal(key);
        journal = null;
        if (restart == 2) rethrow;
      } on _S3TransientMultipart catch (error) {
        // Keep the upload ID. A later sync can list and verify completed parts,
        // then resume without retransmitting the whole object.
        Error.throwWithStackTrace(error.cause, error.stackTrace);
      } on Object {
        await _abortMultipart(key, journal.uploadId);
        await _deleteMultipartJournal(key);
        rethrow;
      }
    }
    throw StateError('S3 multipart upload could not complete after conditional retries.');
  }

  Future<bool> _verifyExistingObject(String key, String expectedSha, int expectedBytes) async {
    final response = await (await _signedRequest(
      'HEAD',
      _objectUri(key),
      payloadHash: sha256.convert(const <int>[]).toString(),
    )).close();
    if (response.statusCode == HttpStatus.notFound) {
      await response.drain<void>();
      return false;
    }
    if (response.statusCode != HttpStatus.ok) {
      final body = await _readString(response);
      throw _httpFailure('S3 object existence check', response.statusCode, body);
    }
    final contentLength = int.tryParse(response.headers.value(HttpHeaders.contentLengthHeader) ?? '');
    await response.drain<void>();
    if (contentLength != null && contentLength != expectedBytes) {
      throw StateError('Immutable S3 key already contains an object with a different size: $key');
    }
    final temporary = File(p.join(
      Directory.systemTemp.path,
      'lw-s3-existing-${DateTime.now().microsecondsSinceEpoch}.part',
    ));
    try {
      await downloadToFile(key, temporary.path);
      final actualBytes = await temporary.length();
      final actualSha = (await sha256.bind(temporary.openRead()).first).toString();
      if (actualBytes != expectedBytes || actualSha != expectedSha) {
        throw StateError('Immutable S3 key already contains different bytes: $key');
      }
      return true;
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  Future<_S3MultipartJournal> _startMultipart(
    String key,
    String digest,
    int length,
    int partSize,
  ) async {
    final request = await _signedRequest(
      'POST',
      _objectUri(key, query: const {'uploads': ''}),
      payloadHash: sha256.convert(const <int>[]).toString(),
      extraHeaders: const {'x-amz-checksum-algorithm': 'SHA256'},
    );
    request.contentLength = 0;
    final response = await request.close();
    final body = await _readString(response);
    if (response.statusCode != HttpStatus.ok && response.statusCode != HttpStatus.created) {
      throw _httpFailure('S3 multipart initiation', response.statusCode, body);
    }
    final uploadId = _xmlValue(body, 'UploadId');
    if (uploadId == null || uploadId.isEmpty) {
      throw const FormatException('S3 multipart initiation did not return an upload id.');
    }
    return _S3MultipartJournal(
      key: key,
      uploadId: uploadId,
      sha256: digest,
      byteSize: length,
      partSize: partSize,
    );
  }

  Future<Map<int, _S3RemotePart>> _listMultipartParts(String key, String uploadId) async {
    final parts = <int, _S3RemotePart>{};
    String? marker;
    while (true) {
      final query = <String, String>{'uploadId': uploadId};
      if (marker != null) query['part-number-marker'] = marker;
      final response = await (await _signedRequest(
        'GET',
        _objectUri(key, query: query),
        payloadHash: sha256.convert(const <int>[]).toString(),
      )).close();
      final body = await _readString(response);
      if (response.statusCode == HttpStatus.notFound || _xmlValue(body, 'Code') == 'NoSuchUpload') {
        throw const _S3RestartMultipart();
      }
      if (response.statusCode != HttpStatus.ok) {
        throw _httpFailure('S3 multipart part listing', response.statusCode, body);
      }
      for (final match in RegExp(r'<Part>(.*?)</Part>', dotAll: true).allMatches(body)) {
        final value = match.group(1)!;
        final partNumber = int.tryParse(_xmlValue(value, 'PartNumber') ?? '');
        final byteSize = int.tryParse(_xmlValue(value, 'Size') ?? '');
        final etag = _xmlValue(value, 'ETag');
        final checksum = _xmlValue(value, 'ChecksumSHA256');
        if (partNumber == null || byteSize == null || etag == null || checksum == null) continue;
        parts[partNumber] = _S3RemotePart(
          byteSize: byteSize,
          etag: etag,
          checksumSha256: checksum,
        );
      }
      if (_xmlValue(body, 'IsTruncated') != 'true') return parts;
      marker = _xmlValue(body, 'NextPartNumberMarker');
      if (marker == null || marker.isEmpty) throw const FormatException('S3 multipart listing has no next marker.');
    }
  }

  Future<String> _uploadMultipartPart({
    required String key,
    required String uploadId,
    required int partNumber,
    required File file,
    required int start,
    required int end,
    required String checksumSha256,
  }) async {
    final length = end - start;
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        final partDigest = (await sha256.bind(file.openRead(start, end)).first).toString();
        final request = await _signedRequest(
          'PUT',
          _objectUri(key, query: {'partNumber': '$partNumber', 'uploadId': uploadId}),
          payloadHash: partDigest,
          extraHeaders: {'x-amz-checksum-sha256': checksumSha256},
        );
        request.contentLength = length;
        await request.addStream(file.openRead(start, end));
        final response = await request.close();
        final etag = response.headers.value(HttpHeaders.etagHeader);
        if (response.statusCode == HttpStatus.ok && etag != null) {
          await response.drain<void>();
          return etag;
        }
        final body = await _readString(response);
        if (_isRetryableStatus(response.statusCode) && attempt < 2) {
          await Future<void>.delayed(Duration(milliseconds: 250 * (attempt + 1)));
          continue;
        }
        if (_isRetryableStatus(response.statusCode)) {
          throw _S3TransientMultipart(_httpFailure('S3 multipart part upload', response.statusCode, body));
        }
        throw _httpFailure('S3 multipart part upload', response.statusCode, body);
      } on SocketException catch (error, stackTrace) {
        if (attempt < 2) {
          await Future<void>.delayed(Duration(milliseconds: 250 * (attempt + 1)));
          continue;
        }
        throw _S3TransientMultipart(error, stackTrace);
      } on TimeoutException catch (error, stackTrace) {
        if (attempt < 2) {
          await Future<void>.delayed(Duration(milliseconds: 250 * (attempt + 1)));
          continue;
        }
        throw _S3TransientMultipart(error, stackTrace);
      } on _S3TransientMultipart {
        rethrow;
      } on Object {
        rethrow;
      }
    }
    throw StateError('S3 multipart part $partNumber failed after retries.');
  }

  Future<String> _sha256Base64Range(File file, int start, int end) async {
    final digest = await sha256.bind(file.openRead(start, end)).first;
    return base64.encode(digest.bytes);
  }

  Future<_S3MultipartJournal?> _readMultipartJournal(String key) async {
    final file = _journalFile(key);
    if (file == null || !await file.exists()) return null;
    try {
      final value = jsonDecode(await file.readAsString());
      if (value is! Map) throw const FormatException('S3 multipart journal is not an object.');
      final json = value.map((name, item) => MapEntry(name.toString(), item));
      return _S3MultipartJournal(
        key: json['key'] as String,
        uploadId: json['upload_id'] as String,
        sha256: json['sha256'] as String,
        byteSize: _asInt(json['byte_size']),
        partSize: _asInt(json['part_size']),
      );
    } on Object {
      await _deleteMultipartJournal(key);
      return null;
    }
  }

  Future<void> _saveMultipartJournal(_S3MultipartJournal journal) async {
    final file = _journalFile(journal.key);
    if (file == null) return;
    await file.parent.create(recursive: true);
    final encoded = jsonEncode(journal.toJson());
    if (await file.exists()) {
      if (await file.readAsString() == encoded) return;
      await file.delete();
    }
    final temporary = File('${file.path}.${DateTime.now().microsecondsSinceEpoch}.part');
    await temporary.writeAsString(encoded, flush: true);
    try {
      await temporary.rename(file.path);
    } on Object {
      if (await temporary.exists()) await temporary.delete();
      rethrow;
    }
  }

  File? _journalFile(String key) {
    final directory = journalDirectory;
    if (directory == null) return null;
    final name = sha256.convert(utf8.encode(key)).toString();
    return File(p.join(directory, '$name.json'));
  }

  Future<void> _deleteMultipartJournal(String key) async {
    final file = _journalFile(key);
    if (file != null && await file.exists()) await file.delete();
  }

  Future<void> _abortMultipart(String key, String uploadId) async {
    try {
      final response = await (await _signedRequest(
        'DELETE',
        _objectUri(key, query: {'uploadId': uploadId}),
        payloadHash: sha256.convert(const <int>[]).toString(),
      )).close();
      await response.drain<void>();
    } on Object {
      // Abort is best-effort. S3 lifecycle rules should also clean stale uploads.
    }
  }

  static bool _isRetryableStatus(int status) =>
      status == HttpStatus.requestTimeout || status == 429 ||
      status == HttpStatus.internalServerError || status == 502 ||
      status == 503 || status == 504;

  Future<HttpClientResponse> _putRequest(Uri uri, int length, String payloadHash, Stream<List<int>> body) async {
    final request = await _signedRequest('PUT', uri, payloadHash: payloadHash, extraHeaders: const {'if-none-match': '*'});
    request.contentLength = length;
    request.headers.contentType = ContentType.binary;
    await request.addStream(body);
    return request.close();
  }

  Future<HttpClientRequest> _signedRequest(
    String method,
    Uri uri, {
    required String payloadHash,
    Map<String, String> extraHeaders = const {},
  }) async {
    final now = DateTime.now().toUtc();
    final amzDate = _formatAmzDate(now);
    final date = amzDate.substring(0, 8);
    final host = uri.hasPort ? '${uri.host}:${uri.port}' : uri.host;
    final headers = <String, String>{
      'host': host,
      'x-amz-content-sha256': payloadHash,
      'x-amz-date': amzDate,
      ...extraHeaders.map((key, value) => MapEntry(key.toLowerCase(), value.trim())),
    };
    if (sessionToken != null) headers['x-amz-security-token'] = sessionToken!;
    final sortedNames = headers.keys.toList()..sort();
    final canonicalHeaders = sortedNames.map((name) => '$name:${headers[name]}\n').join();
    final signedHeaders = sortedNames.join(';');
    final canonicalRequest = <String>[
      method,
      _canonicalPath(uri.path),
      _canonicalQuery(uri.queryParametersAll),
      canonicalHeaders,
      signedHeaders,
      payloadHash,
    ].join('\n');
    final scope = '$date/$region/s3/aws4_request';
    final stringToSign = 'AWS4-HMAC-SHA256\n$amzDate\n$scope\n${sha256.convert(utf8.encode(canonicalRequest))}';
    final signingKey = _signingKey(date);
    final signature = Hmac(sha256, signingKey).convert(utf8.encode(stringToSign)).toString();
    final request = await _client.openUrl(method, uri);
    request.headers.set(HttpHeaders.authorizationHeader,
        'AWS4-HMAC-SHA256 Credential=$_accessKeyId/$scope, SignedHeaders=$signedHeaders, Signature=$signature');
    for (final entry in headers.entries) {
      if (entry.key != 'host') request.headers.set(entry.key, entry.value);
    }
    return request;
  }

  List<int> _signingKey(String date) {
    final kDate = Hmac(sha256, utf8.encode('AWS4$_secretAccessKey')).convert(utf8.encode(date)).bytes;
    final kRegion = Hmac(sha256, kDate).convert(utf8.encode(region)).bytes;
    final kService = Hmac(sha256, kRegion).convert(utf8.encode('s3')).bytes;
    return Hmac(sha256, kService).convert(utf8.encode('aws4_request')).bytes;
  }

  Uri _objectUri(String key, {Map<String, String> query = const {}}) {
    final pathSegments = <String>[
      ...endpoint.pathSegments.where((segment) => segment.isNotEmpty),
      bucket,
      if (key.isNotEmpty) ..._normalizeKey(key).split('/'),
    ];
    return endpoint.replace(
      pathSegments: pathSegments,
      queryParameters: query.isEmpty ? null : query,
    );
  }
}

final class _S3MultipartJournal {
  const _S3MultipartJournal({
    required this.key,
    required this.uploadId,
    required this.sha256,
    required this.byteSize,
    required this.partSize,
  });

  final String key;
  final String uploadId;
  final String sha256;
  final int byteSize;
  final int partSize;

  Map<String, Object?> toJson() => {
        'key': key,
        'upload_id': uploadId,
        'sha256': sha256,
        'byte_size': byteSize,
        'part_size': partSize,
      };
}

final class _S3RemotePart {
  const _S3RemotePart({
    required this.byteSize,
    required this.etag,
    required this.checksumSha256,
  });

  final int byteSize;
  final String etag;
  final String checksumSha256;
}

final class _S3CompletedPart {
  const _S3CompletedPart({
    required this.partNumber,
    required this.etag,
    required this.checksumSha256,
  });

  final int partNumber;
  final String etag;
  final String checksumSha256;
}

final class _S3RestartMultipart implements Exception {
  const _S3RestartMultipart();
}

final class _S3TransientMultipart implements Exception {
  _S3TransientMultipart(this.cause, [StackTrace? stackTrace])
      : stackTrace = stackTrace ?? StackTrace.current;

  final Object cause;
  final StackTrace stackTrace;
}

String _normalizeKey(String key) {
  final value = key.replaceAll('\\', '/').replaceAll(RegExp(r'^/+|/+$'), '');
  if (value.split('/').any((segment) => segment == '.' || segment == '..') || value.contains('\u0000')) {
    throw ArgumentError.value(key, 'key', 'Object keys cannot traverse paths.');
  }
  return value;
}

int _asInt(Object? value) => switch (value) {
      int number => number,
      num number => number.toInt(),
      _ => 0,
    };

String _formatAmzDate(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}${value.month.toString().padLeft(2, '0')}${value.day.toString().padLeft(2, '0')}T'
    '${value.hour.toString().padLeft(2, '0')}${value.minute.toString().padLeft(2, '0')}${value.second.toString().padLeft(2, '0')}Z';

String _awsEncode(String value) {
  final output = StringBuffer();
  for (final byte in utf8.encode(value)) {
    final allowed = (byte >= 0x41 && byte <= 0x5a) ||
        (byte >= 0x61 && byte <= 0x7a) ||
        (byte >= 0x30 && byte <= 0x39) ||
        '-_.~'.codeUnits.contains(byte);
    if (allowed) {
      output.writeCharCode(byte);
    } else {
      output.write('%${byte.toRadixString(16).toUpperCase().padLeft(2, '0')}');
    }
  }
  return output.toString();
}

String _canonicalPath(String path) =>
    path.split('/').map((segment) => _awsEncode(Uri.decodeComponent(segment))).join('/');

String _canonicalQuery(Map<String, List<String>> query) {
  final pairs = <String>[];
  for (final entry in query.entries) {
    for (final value in entry.value) {
      pairs.add('${_awsEncode(entry.key)}=${_awsEncode(value)}');
    }
  }
  pairs.sort();
  return pairs.join('&');
}

Future<String> _readString(HttpClientResponse response) async {
  final bytes = BytesBuilder(copy: false);
  var count = 0;
  await for (final chunk in response) {
    count += chunk.length;
    if (count > 1024 * 1024) break;
    bytes.add(chunk);
  }
  return utf8.decode(bytes.takeBytes(), allowMalformed: true);
}

String? _xmlValue(String xml, String name) {
  final match = RegExp('<$name>(.*?)</$name>', dotAll: true).firstMatch(xml);
  if (match == null) return null;
  return match.group(1)!
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'");
}

String _xmlEscape(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');

Exception _httpFailure(String operation, int statusCode, String body) =>
    HttpException('$operation failed with HTTP $statusCode: ${body.trim()}', uri: null);
