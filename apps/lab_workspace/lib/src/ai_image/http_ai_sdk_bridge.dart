import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:lab_core/lab_core.dart';

/// Direct HTTPS transport for providers that implement the selected OpenAI API
/// wire format. It is used on native platforms without a trusted Python SDK
/// process; it never retries or logs request content or credentials.
final class HttpAiSdkBridge implements AiSdkBridge {
  HttpAiSdkBridge({HttpClient? client}) : _client = client ?? HttpClient();

  final HttpClient _client;
  static const _maxResponseBytes = 12 * 1024 * 1024;
  static const _probeImage =
      'data:image/png;base64,'
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/lfoAAAAASUVORK5CYII=';

  @override
  Future<AiSdkResponse> send(AiSdkRequest request) async {
    final uri = request.endpoint;
    _validateUri(uri);
    final requestBytes = utf8.encode(jsonEncode(request.body));
    if (requestBytes.length > _maxResponseBytes) {
      throw const AiProviderException(
        'AI_REQUEST_TOO_LARGE',
        'AI request exceeded the local size limit.',
      );
    }
    try {
      final outbound = await _client
          .postUrl(uri)
          .timeout(Duration(seconds: request.timeoutSeconds));
      outbound.followRedirects = false;
      for (final entry in request.headers.entries) {
        outbound.headers.set(entry.key, entry.value);
      }
      outbound.headers.contentType = ContentType.json;
      outbound.add(requestBytes);
      final response = await outbound.close().timeout(
        Duration(seconds: request.timeoutSeconds),
      );
      final bytes = await response
          .fold<List<int>>(<int>[], (all, chunk) {
            if (all.length + chunk.length > _maxResponseBytes) {
              throw const AiProviderException(
                'AI_RESPONSE_TOO_LARGE',
                'Provider response exceeded the local size limit.',
              );
            }
            return all..addAll(chunk);
          })
          .timeout(Duration(seconds: request.timeoutSeconds));
      if (bytes.isEmpty) {
        return AiSdkResponse(statusCode: response.statusCode, body: const {});
      }
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map) {
        throw const AiProviderException(
          'AI_RESPONSE_INVALID',
          'Provider response was not a JSON object.',
        );
      }
      return AiSdkResponse(
        statusCode: response.statusCode,
        body: decoded.map((key, value) => MapEntry(key.toString(), value)),
      );
    } on AiProviderException {
      rethrow;
    } on TimeoutException {
      throw const AiProviderException(
        'AI_NETWORK_TIMEOUT',
        'AI request timed out.',
        retryable: true,
      );
    } on SocketException {
      throw const AiProviderException(
        'AI_NETWORK_UNAVAILABLE',
        'AI provider could not be reached.',
        retryable: true,
      );
    } on FormatException {
      throw const AiProviderException(
        'AI_RESPONSE_INVALID',
        'Provider response could not be decoded.',
      );
    } on Object {
      throw const AiProviderException(
        'AI_TRANSPORT_FAILED',
        'AI request failed without retaining provider data.',
      );
    }
  }

  @override
  Future<AiCapabilities> probe({
    required Uri baseUrl,
    required String modelId,
    required AiApiMode apiMode,
    required String apiKey,
    required int timeoutSeconds,
  }) async {
    _validateUri(baseUrl);
    final responses = await _probeOne(
      baseUrl,
      modelId,
      apiKey,
      timeoutSeconds,
      AiApiMode.responses,
    );
    final chat = await _probeOne(
      baseUrl,
      modelId,
      apiKey,
      timeoutSeconds,
      AiApiMode.chatCompletions,
    );
    final selectedSupported = apiMode == AiApiMode.responses ? responses : chat;
    final tools = selectedSupported == CapabilityState.supported
        ? await _probeFeature(
            baseUrl,
            modelId,
            apiKey,
            timeoutSeconds,
            apiMode,
            'tools',
          )
        : CapabilityState.unknown;
    final schema = selectedSupported == CapabilityState.supported
        ? await _probeFeature(
            baseUrl,
            modelId,
            apiKey,
            timeoutSeconds,
            apiMode,
            'json_schema',
          )
        : CapabilityState.unknown;
    final vision = selectedSupported == CapabilityState.supported
        ? await _probeFeature(
            baseUrl,
            modelId,
            apiKey,
            timeoutSeconds,
            apiMode,
            'vision',
          )
        : CapabilityState.unknown;
    return AiCapabilities(
      responses: responses,
      chatCompletions: chat,
      functionTools: tools,
      jsonSchema: schema,
      vision: vision,
      imageEdit: CapabilityState.unknown,
      streaming: CapabilityState.unknown,
    );
  }

  Future<CapabilityState> _probeOne(
    Uri baseUrl,
    String model,
    String apiKey,
    int timeout,
    AiApiMode mode,
  ) async {
    final body = mode == AiApiMode.responses
        ? <String, Object?>{
            'model': model,
            'input': 'Reply OK.',
            'max_output_tokens': 8,
            'store': false,
          }
        : <String, Object?>{
            'model': model,
            'messages': [
              {'role': 'user', 'content': 'Reply OK.'},
            ],
            'max_tokens': 8,
          };
    return _probeRequest(baseUrl, apiKey, timeout, mode, body);
  }

  Future<CapabilityState> _probeFeature(
    Uri baseUrl,
    String model,
    String apiKey,
    int timeout,
    AiApiMode mode,
    String feature,
  ) async {
    final body = mode == AiApiMode.responses
        ? <String, Object?>{
            'model': model,
            'input': 'Use the synthetic probe if supported.',
            'max_output_tokens': 8,
            'store': false,
          }
        : <String, Object?>{
            'model': model,
            'messages': [
              {
                'role': 'user',
                'content': 'Use the synthetic probe if supported.',
              },
            ],
            'max_tokens': 8,
          };
    if (feature == 'tools') {
      body['tools'] = mode == AiApiMode.responses
          ? [
              {
                'type': 'function',
                'name': 'probe_echo',
                'description': 'Synthetic probe',
                'parameters': {
                  'type': 'object',
                  'properties': {
                    'ok': {'type': 'boolean'},
                  },
                  'required': ['ok'],
                  'additionalProperties': false,
                },
                'strict': true,
              },
            ]
          : [
              {
                'type': 'function',
                'function': {
                  'name': 'probe_echo',
                  'description': 'Synthetic probe',
                  'parameters': {
                    'type': 'object',
                    'properties': {
                      'ok': {'type': 'boolean'},
                    },
                    'required': ['ok'],
                    'additionalProperties': false,
                  },
                },
              },
            ];
    } else if (feature == 'json_schema') {
      body[mode == AiApiMode.responses
          ? 'text'
          : 'response_format'] = mode == AiApiMode.responses
          ? {
              'format': {
                'type': 'json_schema',
                'name': 'probe',
                'schema': {
                  'type': 'object',
                  'properties': {
                    'ok': {'type': 'boolean'},
                  },
                  'required': ['ok'],
                  'additionalProperties': false,
                },
                'strict': true,
              },
            }
          : {
              'type': 'json_schema',
              'json_schema': {
                'name': 'probe',
                'strict': true,
                'schema': {
                  'type': 'object',
                  'properties': {
                    'ok': {'type': 'boolean'},
                  },
                  'required': ['ok'],
                  'additionalProperties': false,
                },
              },
            };
    } else if (feature == 'vision') {
      body[mode == AiApiMode.responses
          ? 'input'
          : 'messages'] = mode == AiApiMode.responses
          ? [
              {
                'role': 'user',
                'content': [
                  {
                    'type': 'input_text',
                    'text': 'Describe this synthetic one pixel image.',
                  },
                  {'type': 'input_image', 'image_url': _probeImage},
                ],
              },
            ]
          : [
              {
                'role': 'user',
                'content': [
                  {
                    'type': 'text',
                    'text': 'Describe this synthetic one pixel image.',
                  },
                  {
                    'type': 'image_url',
                    'image_url': {'url': _probeImage},
                  },
                ],
              },
            ];
    }
    return _probeRequest(baseUrl, apiKey, timeout, mode, body);
  }

  Future<CapabilityState> _probeRequest(
    Uri baseUrl,
    String apiKey,
    int timeout,
    AiApiMode mode,
    Map<String, Object?> body,
  ) async {
    final endpoint = _endpoint(
      baseUrl,
      mode == AiApiMode.responses ? '/responses' : '/chat/completions',
    );
    try {
      final request = await _client
          .postUrl(endpoint)
          .timeout(Duration(seconds: timeout));
      request.followRedirects = false;
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $apiKey');
      request.headers.contentType = ContentType.json;
      request.add(utf8.encode(jsonEncode(body)));
      final response = await request.close().timeout(
        Duration(seconds: timeout),
      );
      await response.drain<void>().timeout(Duration(seconds: timeout));
      if (response.statusCode >= 200 && response.statusCode < 300) {
        return CapabilityState.supported;
      }
      if ({400, 404, 405, 415, 422}.contains(response.statusCode)) {
        return CapabilityState.unsupported;
      }
      throw AiProviderException(
        'AI_PROBE_HTTP_${response.statusCode}',
        'Synthetic capability probe failed.',
      );
    } on AiProviderException {
      rethrow;
    } on TimeoutException {
      throw const AiProviderException(
        'AI_NETWORK_TIMEOUT',
        'Synthetic capability probe timed out.',
      );
    } on SocketException {
      throw const AiProviderException(
        'AI_NETWORK_UNAVAILABLE',
        'Provider could not be reached for capability probe.',
      );
    } on Object {
      throw const AiProviderException(
        'AI_CAPABILITY_PROBE_FAILED',
        'Synthetic capability probe failed.',
      );
    }
  }

  static Uri _endpoint(Uri base, String suffix) {
    final path = base.path.endsWith('/')
        ? base.path.substring(0, base.path.length - 1)
        : base.path;
    return base.replace(
      path: path.endsWith('/v1') ? '$path$suffix' : '$path/v1$suffix',
      query: null,
      fragment: null,
    );
  }

  static void _validateUri(Uri uri) {
    final local = {'localhost', '127.0.0.1', '::1'}.contains(uri.host);
    if (uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.scheme != 'https' && !(local && uri.scheme == 'http'))) {
      throw const AiProviderException(
        'AI_ENDPOINT_UNSAFE',
        'AI transport requires HTTPS or a loopback HTTP endpoint.',
      );
    }
  }

  void close() => _client.close(force: true);
}
