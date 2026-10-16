import 'dart:convert';

import 'models.dart';

class AiSdkRequest {
  const AiSdkRequest({
    required this.apiMode,
    required this.endpoint,
    required this.headers,
    required this.body,
    required this.timeoutSeconds,
  });
  final AiApiMode apiMode;
  final Uri endpoint;
  final Map<String, String> headers;
  final Map<String, Object?> body;
  final int timeoutSeconds;

  /// Safe for diagnostics: intentionally excludes headers and request content.
  Map<String, Object?> toLogFields() => {
        'api_mode': apiMode.name,
        'endpoint_host': endpoint.host,
        'timeout_seconds': timeoutSeconds,
      };
}

class AiSdkResponse {
  const AiSdkResponse({required this.statusCode, required this.body});
  final int statusCode;
  final Map<String, Object?> body;
}

/// Platform-owned bridge. Windows should route through the trusted Python
/// OpenAI SDK runner; mobile may use a native HTTPS adapter with the same
/// contract. The bridge must not persist or log headers/body.
abstract interface class AiSdkBridge {
  Future<AiSdkResponse> send(AiSdkRequest request);

  /// Uses synthetic, non-sensitive inputs only. Providers must not be declared
  /// capable from their labels or from an unverified compatibility claim.
  Future<AiCapabilities> probe({
    required Uri baseUrl,
    required String modelId,
    required AiApiMode apiMode,
    required String apiKey,
    required int timeoutSeconds,
  });
}

class AiConversationState {
  AiConversationState({this.responsesId, List<Map<String, Object?>>? chatMessages})
      : chatMessages = chatMessages ?? <Map<String, Object?>>[],
        responsesInput = <Map<String, Object?>>[];
  String? responsesId;
  final List<Map<String, Object?>> chatMessages;
  /// Local conversation history sent back with `store:false`; no provider-side
  /// response retrieval or durable server-side conversation is required.
  final List<Map<String, Object?>> responsesInput;
}

class AdapterTurn {
  const AdapterTurn({required this.turn, this.responsesId});
  final AiTurn turn;
  final String? responsesId;
}

abstract interface class AiApiAdapter {
  AiApiMode get mode;

  Future<AdapterTurn> complete({
    required AiSdkBridge bridge,
    required AiProviderProfile profile,
    required String apiKey,
    required AiContent content,
    required AiConversationState state,
    required List<AiToolDefinition> tools,
    required List<AiToolResult> toolResults,
  });
}

class ResponsesAdapter implements AiApiAdapter {
  const ResponsesAdapter();
  @override
  AiApiMode get mode => AiApiMode.responses;

  @override
  Future<AdapterTurn> complete({
    required AiSdkBridge bridge,
    required AiProviderProfile profile,
    required String apiKey,
    required AiContent content,
    required AiConversationState state,
    required List<AiToolDefinition> tools,
    required List<AiToolResult> toolResults,
  }) async {
    if (state.responsesInput.isEmpty) {
      state.responsesInput.add({'role': 'user', 'content': _responsesContent(content)});
    }
    state.responsesInput.addAll(toolResults.map((item) => {
          'type': 'function_call_output',
          'call_id': item.callId,
          'output': jsonEncode(item.output),
        }));
    final body = <String, Object?>{
      'model': profile.modelId,
      'max_output_tokens': profile.maxOutputTokens,
      'store': false,
      'input': List<Map<String, Object?>>.unmodifiable(state.responsesInput),
      if (tools.isNotEmpty) 'tools': tools.map(_responsesTool).toList(growable: false),
    };
    final response = await bridge.send(_request(profile, apiKey, body, '/responses'));
    _checkStatus(response);
    final items = <AiTurnItem>[];
    for (final item in _asMapList(response.body['output'])) {
      state.responsesInput.add(Map<String, Object?>.from(item));
      if (item['type'] == 'function_call') {
        final arguments = _decodeArguments(item['arguments']);
        items.add(AiToolRequestItem(AiToolCall(
          callId: _requiredString(item['call_id'], 'call_id'),
          name: _requiredString(item['name'], 'name'),
          arguments: arguments,
        )));
      } else if (item['type'] == 'message') {
        for (final chunk in _asMapList(item['content'])) {
          final text = chunk['text'];
          if (text is String && text.isNotEmpty) items.add(AiTextItem(text));
        }
      }
    }
    return AdapterTurn(
      turn: AiTurn(items: items, usage: _asMap(response.body['usage'])),
      responsesId: response.body['id'] as String?,
    );
  }
}

class ChatCompletionsAdapter implements AiApiAdapter {
  const ChatCompletionsAdapter();
  @override
  AiApiMode get mode => AiApiMode.chatCompletions;

  @override
  Future<AdapterTurn> complete({
    required AiSdkBridge bridge,
    required AiProviderProfile profile,
    required String apiKey,
    required AiContent content,
    required AiConversationState state,
    required List<AiToolDefinition> tools,
    required List<AiToolResult> toolResults,
  }) async {
    if (state.chatMessages.isEmpty) {
      state.chatMessages.add({'role': 'user', 'content': _chatContent(content)});
    }
    for (final result in toolResults) {
      state.chatMessages.add({
        'role': 'tool',
        'tool_call_id': result.callId,
        'name': result.name,
        'content': jsonEncode(result.output),
      });
    }
    final body = <String, Object?>{
      'model': profile.modelId,
      'messages': List<Map<String, Object?>>.unmodifiable(state.chatMessages),
      'max_tokens': profile.maxOutputTokens,
      if (tools.isNotEmpty)
        'tools': tools
            .map((tool) => {
                  'type': 'function',
                  'function': {
                    'name': tool.name,
                    'description': tool.description,
                    'parameters': tool.parametersSchema,
                  }
                })
            .toList(growable: false),
    };
    final response = await bridge.send(_request(profile, apiKey, body, '/chat/completions'));
    _checkStatus(response);
    final choices = _asMapList(response.body['choices']);
    if (choices.isEmpty) throw const AiProviderException('AI_EMPTY_RESPONSE', 'Provider returned no choices.');
    final message = _asMap(choices.first['message']);
    final contentValue = message['content'];
    final items = <AiTurnItem>[];
    if (contentValue is String && contentValue.isNotEmpty) items.add(AiTextItem(contentValue));
    for (final call in _asMapList(message['tool_calls'])) {
      final function = _asMap(call['function']);
      items.add(AiToolRequestItem(AiToolCall(
        callId: _requiredString(call['id'], 'tool_call.id'),
        name: _requiredString(function['name'], 'function.name'),
        arguments: _decodeArguments(function['arguments']),
      )));
    }
    if (items.any((item) => item is AiToolRequestItem)) {
      state.chatMessages.add({
        'role': 'assistant',
        'tool_calls': _asMapList(message['tool_calls']),
        if (contentValue is String) 'content': contentValue,
      });
    } else if (contentValue is String) {
      state.chatMessages.add({'role': 'assistant', 'content': contentValue});
    }
    return AdapterTurn(
      turn: AiTurn(items: items, usage: _asMap(response.body['usage'])),
    );
  }
}

class AiProviderException implements Exception {
  const AiProviderException(this.code, this.message, {this.retryable = false});
  final String code;
  final String message;
  final bool retryable;
  @override
  String toString() => '$code: $message';
}

AiSdkRequest _request(
  AiProviderProfile profile,
  String apiKey,
  Map<String, Object?> body,
  String endpoint,
) {
  if (apiKey.trim().isEmpty) throw const AiProviderException('AI_SECRET_MISSING', 'Provider credential is empty.');
  return AiSdkRequest(
    apiMode: profile.apiMode,
    endpoint: _endpoint(profile.baseUrl, endpoint),
    headers: {'Authorization': 'Bearer $apiKey', 'Content-Type': 'application/json'},
    body: body,
    timeoutSeconds: profile.timeoutSeconds,
  );
}

Uri _endpoint(Uri base, String suffix) {
  final basePath = base.path.endsWith('/') ? base.path.substring(0, base.path.length - 1) : base.path;
  final path = basePath.endsWith('/v1') ? '$basePath$suffix' : '$basePath/v1$suffix';
  return base.replace(path: path, query: null, fragment: null);
}

Map<String, Object?> _responsesTool(AiToolDefinition tool) => {
      'type': 'function',
      'name': tool.name,
      'description': tool.description,
      'parameters': tool.parametersSchema,
      'strict': true,
    };

Object _responsesContent(AiContent content) {
  final image = content.imageDataUri;
  if (image == null) return content.text;
  return [
    {'type': 'input_text', 'text': content.text},
    {'type': 'input_image', 'image_url': image},
  ];
}

Object _chatContent(AiContent content) {
  final image = content.imageDataUri;
  if (image == null) return content.text;
  return [
    {'type': 'text', 'text': content.text},
    {'type': 'image_url', 'image_url': {'url': image}},
  ];
}

void _checkStatus(AiSdkResponse response) {
  if (response.statusCode >= 200 && response.statusCode < 300) return;
  // Provider bodies can contain prompts or user data; retain only a safe error code.
  final error = _asMap(response.body['error']);
  final code = error['code'] is String ? error['code'] as String : 'AI_PROVIDER_HTTP_${response.statusCode}';
  throw AiProviderException(code, 'Provider request failed with HTTP ${response.statusCode}.',
      retryable: response.statusCode == 429 || response.statusCode >= 500);
}

Map<String, Object?> _decodeArguments(Object? value) {
  if (value is Map<String, Object?>) return value;
  if (value is Map) return value.map((key, entry) => MapEntry(key.toString(), entry));
  if (value is String) {
    final decoded = jsonDecode(value);
    if (decoded is Map) return decoded.map((key, entry) => MapEntry(key.toString(), entry));
  }
  throw const AiProviderException('AI_TOOL_ARGUMENTS_INVALID', 'Tool arguments must be a JSON object.');
}

List<Map<String, Object?>> _asMapList(Object? value) => value is List
    ? value.whereType<Map>().map((item) => item.map((key, entry) => MapEntry(key.toString(), entry))).toList()
    : const [];

Map<String, Object?> _asMap(Object? value) => value is Map
    ? value.map((key, entry) => MapEntry(key.toString(), entry))
    : const {};

String _requiredString(Object? value, String field) {
  if (value is String && value.isNotEmpty) return value;
  throw AiProviderException('AI_RESPONSE_INVALID', 'Provider response is missing $field.');
}
