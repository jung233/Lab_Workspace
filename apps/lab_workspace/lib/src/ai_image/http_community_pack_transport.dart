import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:lab_core/lab_core.dart';

/// Bounded HTTPS-only transport for signed community catalog manifests and
/// declarative Pack documents. It never downloads executables or archives.
final class HttpCommunityPackCatalogTransport implements CommunityPackCatalogTransport {
  HttpCommunityPackCatalogTransport({HttpClient? client}) : _client = client ?? HttpClient();

  final HttpClient _client;
  static const _maxBytes = 2 * 1024 * 1024;

  @override
  Future<Map<String, Object?>> getJson(Uri uri) async {
    if (uri.scheme != 'https' || uri.host.isEmpty || uri.userInfo.isNotEmpty || uri.hasFragment) {
      throw const FormatException('Community catalog requests require HTTPS and a credential-free URL.');
    }
    try {
      final request = await _client.getUrl(uri).timeout(const Duration(seconds: 30));
      request.followRedirects = false;
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final response = await request.close().timeout(const Duration(seconds: 30));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw const FormatException('Community catalog endpoint returned an unsuccessful status.');
      }
      final bytes = await response.fold<List<int>>(<int>[], (all, chunk) {
        if (all.length + chunk.length > _maxBytes) throw const FormatException('Community catalog document exceeds 2 MiB.');
        return all..addAll(chunk);
      }).timeout(const Duration(seconds: 30));
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map) throw const FormatException('Community catalog document must be a JSON object.');
      return Map<String, Object?>.unmodifiable(decoded.map((key, value) => MapEntry(key.toString(), value)));
    } on FormatException {
      rethrow;
    } on TimeoutException {
      throw const FormatException('Community catalog request timed out.');
    } on SocketException {
      throw const FormatException('Community catalog could not be reached.');
    } on Object {
      throw const FormatException('Community catalog request failed without retaining remote content.');
    }
  }

  void close() => _client.close(force: true);
}
