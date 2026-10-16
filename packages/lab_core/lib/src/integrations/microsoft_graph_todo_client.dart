import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'microsoft_todo_sync_service.dart';

/// Native sign-in owns delegated Microsoft identity and secure token refresh.
/// This port supplies only an access token for one outbound Graph operation.
abstract interface class MicrosoftGraphAccessTokenProvider {
  Future<String?> accessToken();
}

/// Microsoft Graph v1.0 client for a user-selected To Do list. Task correlation
/// uses an open extension so retries can reconcile a create that succeeded
/// remotely before the local SQLite link was committed.
final class HttpMicrosoftGraphTodoClient implements MicrosoftGraphTodoClient {
  HttpMicrosoftGraphTodoClient({
    required MicrosoftGraphAccessTokenProvider tokenProvider,
    HttpClient? httpClient,
    this.timeout = const Duration(seconds: 30),
  })  : _tokenProvider = tokenProvider,
        _http = httpClient ?? HttpClient();

  static const _graphRoot = 'https://graph.microsoft.com/v1.0';
  static const _extensionName = 'com.labworkspace.localTaskLink';
  static const _maxResponseBytes = 1024 * 1024;

  final MicrosoftGraphAccessTokenProvider _tokenProvider;
  final HttpClient _http;
  final Duration timeout;

  @override
  Future<List<MicrosoftTodoRemoteList>> listLists() async {
    var uri = Uri.parse('$_graphRoot/me/todo/lists').replace(queryParameters: {
      r'$select': 'id,displayName',
      r'$top': '100',
    });
    final lists = <MicrosoftTodoRemoteList>[];
    final seen = <String>{};
    while (true) {
      final body = await _send('GET', uri);
      final values = body['value'];
      if (values is List) {
        for (final value in values.whereType<Map>()) {
          final id = value['id'];
          final name = value['displayName'];
          if (id is String && id.isNotEmpty && name is String && name.isNotEmpty && seen.add(id)) {
            lists.add(MicrosoftTodoRemoteList(listId: id, displayName: name));
          }
        }
      }
      final next = body['@odata.nextLink'];
      if (next is! String || next.isEmpty) break;
      final nextUri = Uri.tryParse(next);
      if (!_isTrustedGraphUri(nextUri)) {
        throw const MicrosoftTodoException('TODO_GRAPH_PAGINATION_INVALID', 'Graph returned an invalid pagination link.');
      }
      uri = nextUri!;
      if (lists.length > 1000) {
        throw const MicrosoftTodoException('TODO_GRAPH_LIST_LIMIT', 'Microsoft To Do returned too many lists.');
      }
    }
    return List<MicrosoftTodoRemoteList>.unmodifiable(lists);
  }

  @override
  Future<MicrosoftTodoDeltaPage> listTaskDeltaPage({
    required String listId,
    String? requestUrl,
  }) async {
    final encodedList = Uri.encodeComponent(listId);
    final expectedPath = '/v1.0/me/todo/lists/$encodedList/tasks/delta';
    final uri = requestUrl == null
        ? Uri.parse('https://graph.microsoft.com$expectedPath').replace(queryParameters: {
            r'$select': 'id,title,status,dueDateTime,completedDateTime,extensions',
            r'$expand': "extensions(\$filter=id eq '$_extensionName')",
            r'$top': '100',
          })
        : Uri.tryParse(requestUrl);
    if (uri == null || uri.scheme != 'https' || uri.host != 'graph.microsoft.com' ||
        uri.userInfo.isNotEmpty || uri.port != 443 || uri.path != expectedPath) {
      throw const MicrosoftTodoException('TODO_GRAPH_DELTA_URL_INVALID', 'Delta cursor URL is not for the selected Microsoft To Do task list.');
    }
    final body = await _send('GET', uri);
    final value = body['value'];
    if (value is! List) {
      throw const MicrosoftTodoException('TODO_GRAPH_DELTA_RESPONSE_INVALID', 'Graph delta page did not contain a task collection.');
    }
    final changes = value.whereType<Map>().map((item) => _remote(item, listId)).toList(growable: false);
    final next = _validatedDeltaLink(body['@odata.nextLink'], expectedPath);
    final delta = _validatedDeltaLink(body['@odata.deltaLink'], expectedPath);
    if ((next == null) == (delta == null)) {
      throw const MicrosoftTodoException('TODO_GRAPH_DELTA_CURSOR_INVALID', 'Graph delta page must return exactly one continuation or completed cursor URL.');
    }
    return MicrosoftTodoDeltaPage(changes: changes, nextLink: next, deltaLink: delta);
  }

  static String? _validatedDeltaLink(Object? value, String expectedPath) {
    if (value == null) return null;
    if (value is! String || value.isEmpty) {
      throw const MicrosoftTodoException('TODO_GRAPH_DELTA_CURSOR_INVALID', 'Graph returned an invalid delta cursor URL.');
    }
    final uri = Uri.tryParse(value);
    if (uri == null || uri.scheme != 'https' || uri.host != 'graph.microsoft.com' ||
        uri.userInfo.isNotEmpty || uri.port != 443 || uri.path != expectedPath ||
        !uri.hasQuery || uri.query.isEmpty) {
      throw const MicrosoftTodoException('TODO_GRAPH_DELTA_CURSOR_INVALID', 'Graph returned an unsafe delta cursor URL.');
    }
    return uri.toString();
  }

  @override
  Future<MicrosoftTodoRemoteTask> getTask({required String listId, required String taskId}) async {
    final uri = Uri.parse(
      '$_graphRoot/me/todo/lists/${Uri.encodeComponent(listId)}/tasks/${Uri.encodeComponent(taskId)}',
    ).replace(queryParameters: {
      r'$select': 'id,title,status,dueDateTime,completedDateTime,extensions',
      r'$expand': "extensions(\$filter=id eq '$_extensionName')",
    });
    return _remote(await _send('GET', uri), listId);
  }

  @override
  Future<List<MicrosoftTodoRemoteTask>> findByCorrelationId(String listId, String correlationId) async {
    final encodedList = Uri.encodeComponent(listId);
    var uri = Uri.parse('$_graphRoot/me/todo/lists/$encodedList/tasks').replace(queryParameters: {
      r'$expand': "extensions(\$filter=id eq '$_extensionName')",
      r'$select': 'id,title,status,dueDateTime,extensions',
      r'$top': '100',
    });
    final matches = <MicrosoftTodoRemoteTask>[];
    while (true) {
      final body = await _send('GET', uri);
      final values = body['value'];
      if (values is List) {
        for (final value in values.whereType<Map>()) {
          final task = _remote(value, listId);
          if (task.correlationId == correlationId) matches.add(task);
        }
      }
      final next = body['@odata.nextLink'];
      if (next is! String || next.isEmpty) break;
      final nextUri = Uri.tryParse(next);
      if (!_isTrustedGraphUri(nextUri)) {
        throw const MicrosoftTodoException('TODO_GRAPH_PAGINATION_INVALID', 'Graph returned an invalid pagination link.');
      }
      uri = nextUri!;
    }
    return matches;
  }

  @override
  Future<MicrosoftTodoRemoteTask> createTask({
    required String listId,
    required String title,
    required String correlationId,
    DateTime? dueAtUtc,
  }) async {
    final uri = Uri.parse('$_graphRoot/me/todo/lists/${Uri.encodeComponent(listId)}/tasks');
    final task = <String, Object?>{
      'title': title,
      'status': 'notStarted',
      if (dueAtUtc != null)
        'dueDateTime': {'dateTime': dueAtUtc.toUtc().toIso8601String(), 'timeZone': 'UTC'},
      'extensions': [
        {
          '@odata.type': 'microsoft.graph.openTypeExtension',
          'extensionName': _extensionName,
          'localTaskId': correlationId,
        }
      ],
    };
    final body = await _send('POST', uri, payload: task);
    return _remote(body, listId, fallbackCorrelationId: correlationId);
  }

  @override
  Future<MicrosoftTodoRemoteTask> updateTask({
    required String listId,
    required String taskId,
    required String ifMatchEtag,
    required String title,
    required bool completed,
    DateTime? dueAtUtc,
  }) async {
    final uri = Uri.parse('$_graphRoot/me/todo/lists/${Uri.encodeComponent(listId)}/tasks/${Uri.encodeComponent(taskId)}');
    final body = await _send('PATCH', uri, payload: {
      'title': title,
      'status': completed ? 'completed' : 'notStarted',
      'dueDateTime': dueAtUtc == null
          ? null
          : {'dateTime': dueAtUtc.toUtc().toIso8601String(), 'timeZone': 'UTC'},
    }, ifMatch: ifMatchEtag);
    return _remote(body, listId);
  }

  Future<Map<String, Object?>> _send(
    String method,
    Uri uri, {
    Map<String, Object?>? payload,
    String? ifMatch,
  }) async {
    if (!_isTrustedGraphUri(uri)) {
      throw const MicrosoftTodoException('TODO_GRAPH_URL_INVALID', 'Only the Microsoft Graph v1.0 host is allowed.');
    }
    final token = await _tokenProvider.accessToken();
    if (token == null || token.isEmpty) {
      throw const MicrosoftTodoException('TODO_AUTH_REQUIRED', 'Microsoft account authorization is required.');
    }
    try {
      final request = await _http.openUrl(method, uri).timeout(timeout);
      request.followRedirects = false;
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      if (payload != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(payload));
      }
      if (ifMatch != null) request.headers.set(HttpHeaders.ifMatchHeader, ifMatch);
      final response = await request.close().timeout(timeout);
      final bytes = await response.fold<List<int>>(<int>[], (all, chunk) {
        if (all.length + chunk.length > _maxResponseBytes) {
          throw const MicrosoftTodoException('TODO_GRAPH_RESPONSE_TOO_LARGE', 'Graph response exceeded the local size limit.');
        }
        return all..addAll(chunk);
      }).timeout(timeout);
      if (response.statusCode == HttpStatus.preconditionFailed) {
        throw const MicrosoftTodoPreconditionFailed();
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        // Never persist response bodies or exception text; Graph errors can
        // contain account and task details.
        var graphErrorCode = '';
        try {
          final errorBody = jsonDecode(utf8.decode(bytes));
          if (errorBody is Map && errorBody['error'] is Map) {
            final value = (errorBody['error'] as Map)['code'];
            if (value is String) graphErrorCode = value.toLowerCase();
          }
        } on FormatException {
          // The status-only mapping below remains authoritative.
        }
        final code = graphErrorCode == 'syncstatenotfound'
            ? 'TODO_GRAPH_DELTA_RESET_REQUIRED'
            : switch (response.statusCode) {
          401 => 'TODO_AUTH_EXPIRED',
          403 => 'TODO_ACCESS_DENIED',
          404 => 'TODO_REMOTE_NOT_FOUND',
          429 => 'TODO_RATE_LIMITED',
          410 => 'TODO_GRAPH_DELTA_RESET_REQUIRED',
          >= 500 => 'TODO_GRAPH_UNAVAILABLE',
              _ => 'TODO_GRAPH_REQUEST_FAILED',
            };
        throw MicrosoftTodoException(code, 'Microsoft Graph returned HTTP ${response.statusCode}.');
      }
      if (bytes.isEmpty) return const {};
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map) throw const MicrosoftTodoException('TODO_GRAPH_RESPONSE_INVALID', 'Graph response is not an object.');
      final result = decoded.map((key, value) => MapEntry(key.toString(), value));
      final etag = response.headers.value('ETag');
      if (etag != null) result['@odata.etag'] = etag;
      return result;
    } on MicrosoftTodoException {
      rethrow;
    } on TimeoutException {
      throw const MicrosoftTodoException('TODO_NETWORK_TIMEOUT', 'Microsoft Graph request timed out.');
    } on SocketException {
      throw const MicrosoftTodoException('TODO_NETWORK_UNAVAILABLE', 'Microsoft Graph could not be reached.');
    } on FormatException {
      throw const MicrosoftTodoException('TODO_GRAPH_RESPONSE_INVALID', 'Graph returned invalid JSON.');
    }
  }

  static bool _isTrustedGraphUri(Uri? uri) => uri != null &&
      uri.scheme == 'https' &&
      uri.host == 'graph.microsoft.com' &&
      uri.userInfo.isEmpty &&
      uri.port == 443 &&
      uri.path.startsWith('/v1.0/') &&
      uri.fragment.isEmpty;

  static MicrosoftTodoRemoteTask _remote(
    Map value,
    String listId, {
    String? fallbackCorrelationId,
  }) {
    final id = value['id'];
    if (id is! String || id.isEmpty) {
      throw const MicrosoftTodoException('TODO_GRAPH_RESPONSE_INVALID', 'Graph task response has no identifier.');
    }
    var correlation = fallbackCorrelationId;
    final extensions = value['extensions'];
    if (extensions is List) {
      for (final item in extensions.whereType<Map>()) {
        if (item['extensionName'] == _extensionName || item['id'] == _extensionName) {
          if (item['localTaskId'] is String) correlation = item['localTaskId'] as String;
        }
      }
    }
    final status = value['status'];
    final etag = value['@odata.etag'];
    final title = value['title'];
    final dueDate = value['dueDateTime'];
    final completedDate = value['completedDateTime'];
    final removed = value['@removed'];
    DateTime? parseDate(Object? date) {
      if (date == null) return null;
      if (date is! Map || date['dateTime'] is! String) {
        throw const MicrosoftTodoException('TODO_GRAPH_DATE_INVALID', 'Graph returned an invalid task date.');
      }
      final raw = (date['dateTime'] as String).trim();
      final zone = date['timeZone'] as String?;
      final hasOffset = raw.endsWith('Z') || RegExp(r'[+-]\d{2}:\d{2}$').hasMatch(raw);
      final normalized = hasOffset
          ? raw
          : const {'UTC', 'Etc/UTC', 'Coordinated Universal Time'}.contains(zone)
              ? '${raw}Z'
              : null;
      final parsed = normalized == null ? null : DateTime.tryParse(normalized);
      if (parsed == null) {
        throw const MicrosoftTodoException('TODO_GRAPH_DATE_UNSUPPORTED', 'Task dates in this time zone cannot be converted safely.');
      }
      return parsed.toUtc();
    }
    return MicrosoftTodoRemoteTask(
      taskId: id,
      listId: listId,
      title: title is String ? title : '',
      etag: etag is String ? etag : '',
      completed: status == 'completed',
      correlationId: correlation,
      dueAtUtc: parseDate(dueDate),
      completedAtUtc: parseDate(completedDate),
      deleted: removed is Map,
    );
  }
}
