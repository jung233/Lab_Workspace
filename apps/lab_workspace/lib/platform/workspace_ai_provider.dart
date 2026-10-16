import 'dart:convert';
import 'dart:io';

import 'package:lab_core/lab_core.dart';

import '../src/ai_image/http_ai_sdk_bridge.dart';
import '../src/ai_image/python_json_rpc_process.dart';

/// Shared local composition for text-only AI workflows.
///
/// Protocol drafting and image analysis use the same durable provider profiles,
/// consent receipts, secure secret store, and SDK selection. Protocol drafting
/// has no registered tools, so an unexpected tool request is always denied.
final class WorkspaceAiProvider {
  WorkspaceAiProvider({required this.core, required SecretStore secretStore}) {
    profiles = SqliteAiProviderProfileRepository(core.database);
    consents = SqliteConsentReceiptRepository(core.database);
    final toolValidator = SqliteToolApprovalValidator(core.database);
    final worker = _readTrustedWorkerConfig(core.database);
    final python =
        worker['python_executable'] ??
        Platform.environment['LAB_WORKSPACE_PYTHON'];
    final bridgePath =
        worker['ai_sdk_script'] ??
        Platform.environment['LAB_WORKSPACE_AI_SDK_BRIDGE'];
    late final AiSdkBridge bridge;
    if (Platform.isWindows && python != null && bridgePath != null) {
      bridge = OpenAiPythonSdkBridge(
        PythonJsonRpcProcess(pythonExecutable: python, scriptPath: bridgePath),
      );
    } else {
      final httpBridge = HttpAiSdkBridge();
      _httpBridge = httpBridge;
      bridge = httpBridge;
    }
    ai = AiProviderService(
      profiles: profiles,
      consents: consents,
      bridge: bridge,
      secretStore: secretStore,
      requestToolApproval: (_) async =>
          const ToolApproval(approved: false, approvalRef: null),
      validateToolApproval: toolValidator.call,
      audit: (event, _) async {
        // Provider payloads, prompts, secrets, and model responses are never
        // stored in the local audit outbox.
        core.database.execute(
          "INSERT INTO outbox(outbox_id,event_type,payload_json,idempotency_key,next_attempt_at_utc,state,attempts,last_error) "
          "VALUES(?,?,?,?,?,'pending',0,NULL)",
          [
            newUuidV7(),
            'audit.$event',
            '{}',
            newUuidV7(),
            DateTime.now().toUtc().toIso8601String(),
          ],
        );
      },
    );
  }

  final LabCore core;
  late final SqliteAiProviderProfileRepository profiles;
  late final SqliteConsentReceiptRepository consents;
  late final AiProviderService ai;
  HttpAiSdkBridge? _httpBridge;

  void dispose() {
    _httpBridge?.close();
  }

  static Map<String, String> _readTrustedWorkerConfig(
    WorkspaceDatabase database,
  ) {
    final rows = database.query(
      'SELECT value_json FROM workspace_settings WHERE setting_key=?',
      ['trusted_python_workers'],
    );
    if (rows.isEmpty || rows.single['value_json'] is! String) {
      return const {};
    }
    try {
      final value = jsonDecode(rows.single['value_json'] as String);
      if (value is! Map) return const {};
      return value
          .map(
            (key, item) => MapEntry(key.toString(), item is String ? item : ''),
          )
          .cast<String, String>();
    } on Object {
      return const {};
    }
  }
}
