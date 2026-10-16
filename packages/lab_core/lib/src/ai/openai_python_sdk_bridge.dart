import 'models.dart';
import 'provider_adapters.dart';

/// Minimal transport to the isolated Python JSON-RPC process. A native runner
/// owns process lifecycle and stdio; it must never log request params.
abstract interface class AiJsonRpcClient {
  Future<Map<String, Object?>> call(String method, Map<String, Object?> params, {required int timeoutSeconds});
}

class OpenAiPythonSdkBridge implements AiSdkBridge {
  const OpenAiPythonSdkBridge(this._rpc);
  final AiJsonRpcClient _rpc;

  @override
  Future<AiSdkResponse> send(AiSdkRequest request) async {
    final authorization = request.headers['Authorization'];
    if (authorization == null || !authorization.startsWith('Bearer ')) {
      throw const AiProviderException('AI_SECRET_MISSING', 'SDK bridge request has no bearer credential.');
    }
    final result = await _rpc.call('ai.request', {
      'api_mode': request.apiMode == AiApiMode.responses ? 'responses' : 'chat_completions',
      'base_url': _sdkBaseUrl(request.endpoint),
      'api_key': authorization.substring('Bearer '.length),
      'body': request.body,
      'timeout_seconds': request.timeoutSeconds,
    }, timeoutSeconds: request.timeoutSeconds + 5);
    if (result['ok'] != true) {
      final code = result['code'] is String ? result['code'] as String : 'AI_SDK_REQUEST_FAILED';
      final status = result['status_code'];
      final httpStatus = status is int ? status : 502;
      return AiSdkResponse(statusCode: httpStatus, body: {'error': {'code': code}});
    }
    final body = result['body'];
    if (body is! Map) throw const AiProviderException('AI_SDK_RESPONSE_INVALID', 'SDK runner returned a malformed response.');
    return AiSdkResponse(
      statusCode: 200,
      body: body.map((key, value) => MapEntry(key.toString(), value)),
    );
  }

  @override
  Future<AiCapabilities> probe({
    required Uri baseUrl,
    required String modelId,
    required AiApiMode apiMode,
    required String apiKey,
    required int timeoutSeconds,
  }) async {
    final result = await _rpc.call('ai.probe', {
      'base_url': baseUrl.toString(),
      'model_id': modelId,
      'api_key': apiKey,
      'api_mode': apiMode == AiApiMode.responses ? 'responses' : 'chat_completions',
      'timeout_seconds': timeoutSeconds,
    }, timeoutSeconds: timeoutSeconds * 8 + 10);
    if (result['ok'] != true || result['capabilities'] is! Map) {
      final code = result['code'] is String ? result['code'] as String : 'AI_CAPABILITY_PROBE_FAILED';
      throw AiProviderException(code, 'Synthetic capability probe failed.');
    }
    return AiCapabilities.fromJson((result['capabilities'] as Map).map((key, value) => MapEntry(key.toString(), value)));
  }

  static String _sdkBaseUrl(Uri endpoint) {
    final path = endpoint.path;
    final knownSuffix = path.endsWith('/chat/completions')
        ? '/chat/completions'
        : path.endsWith('/responses')
            ? '/responses'
            : '';
    final withoutEndpoint = knownSuffix.isEmpty ? path : path.substring(0, path.length - knownSuffix.length);
    return endpoint.replace(path: withoutEndpoint.isEmpty ? '/v1' : withoutEndpoint).toString();
  }
}
