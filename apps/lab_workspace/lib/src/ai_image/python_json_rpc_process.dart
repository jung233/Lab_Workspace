import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:lab_core/lab_core.dart';

/// Starts one configured trusted Python worker for one JSON-RPC request.
/// It is intentionally unavailable outside Windows; mobile platforms must use
/// an embedded, signed runtime supplied by a native host integration.
final class PythonJsonRpcProcess implements AiJsonRpcClient {
  PythonJsonRpcProcess({
    required this.pythonExecutable,
    required this.scriptPath,
  });

  final String pythonExecutable;
  final String scriptPath;

  @override
  Future<Map<String, Object?>> call(
    String method,
    Map<String, Object?> params, {
    required int timeoutSeconds,
  }) async {
    if (!Platform.isWindows) {
      throw const AiProviderException(
        'AI_PYTHON_RUNTIME_UNAVAILABLE',
        'A trusted embedded Python SDK runtime is not configured for this platform.',
      );
    }
    final workerName = File(scriptPath).uri.pathSegments.last;
    final allowedMethods = switch (workerName) {
      'ai_provider_sdk_bridge.py' => const {'ai.request', 'ai.probe', 'ai.self_test'},
      'calculation_rpc.py' => const {'probe', 'execute', 'requestCancel', 'getLogs', 'quantifyRoi'},
      _ => const <String>{},
    };
    if (!allowedMethods.contains(method)) {
      throw const AiProviderException(
        'AI_WORKER_METHOD_NOT_ALLOWED',
        'Configured worker method is outside the local RPC allowlist.',
      );
    }
    final request = jsonEncode({
      'jsonrpc': '2.0',
      'id': 'lab-ai-1',
      'method': method,
      'params': params,
    });
    if (utf8.encode(request).length > 12 * 1024 * 1024) {
      throw const AiProviderException(
        'AI_REQUEST_TOO_LARGE',
        'AI worker request exceeded the local limit.',
      );
    }
    try {
      final process = await Process.start(
        pythonExecutable,
        ['-u', scriptPath],
        runInShell: false,
        mode: ProcessStartMode.normal,
      );
      final stdoutBuffer = <int>[];
      final stdoutDone = Completer<void>();
      final stdoutSubscription = process.stdout.listen(
        (chunk) {
          if (stdoutBuffer.length + chunk.length > 12 * 1024 * 1024) {
            process.kill(ProcessSignal.sigkill);
            if (!stdoutDone.isCompleted) {
              stdoutDone.completeError(
                const FormatException('AI worker response too large.'),
              );
            }
            return;
          }
          stdoutBuffer.addAll(chunk);
        },
        onError: (Object error, StackTrace stack) {
          if (!stdoutDone.isCompleted) stdoutDone.completeError(error, stack);
        },
        onDone: () {
          if (!stdoutDone.isCompleted) stdoutDone.complete();
        },
      );
      // Consume but never surface stderr; SDK diagnostics may contain user data.
      final stderrDone = process.stderr.drain<void>();
      process.stdin.writeln(request);
      await process.stdin.flush();
      await process.stdin.close();
      await Future.wait([
        stdoutDone.future.timeout(Duration(seconds: timeoutSeconds)),
        process.exitCode.timeout(Duration(seconds: timeoutSeconds)),
      ]);
      await stderrDone;
      await stdoutSubscription.cancel();
      final lines = LineSplitter().convert(utf8.decode(stdoutBuffer));
      if (lines.length != 1) {
        throw const FormatException(
          'Worker returned an invalid JSON-RPC envelope.',
        );
      }
      final envelope = jsonDecode(lines.single);
      if (envelope is! Map ||
          envelope['id'] != 'lab-ai-1' ||
          envelope['result'] is! Map) {
        throw const FormatException(
          'Worker returned an invalid JSON-RPC envelope.',
        );
      }
      return (envelope['result'] as Map).map(
        (key, value) => MapEntry(key.toString(), value),
      );
    } on AiProviderException {
      rethrow;
    } on TimeoutException {
      throw const AiProviderException(
        'AI_WORKER_TIMEOUT',
        'Trusted Python SDK worker timed out.',
      );
    } on ProcessException {
      throw const AiProviderException(
        'AI_WORKER_UNAVAILABLE',
        'Configured trusted Python worker could not be started.',
      );
    } on Object {
      throw const AiProviderException(
        'AI_WORKER_FAILED',
        'Trusted Python SDK worker failed without exposing request data.',
      );
    }
  }
}
