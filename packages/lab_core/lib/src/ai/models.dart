import 'package:lab_core/src/domain/security.dart';

enum AiApiMode { responses, chatCompletions }
enum CapabilityState { unknown, supported, unsupported }

class AiCapabilities {
  const AiCapabilities({
    this.responses = CapabilityState.unknown,
    this.chatCompletions = CapabilityState.unknown,
    this.vision = CapabilityState.unknown,
    this.functionTools = CapabilityState.unknown,
    this.jsonSchema = CapabilityState.unknown,
    this.imageEdit = CapabilityState.unknown,
    this.streaming = CapabilityState.unknown,
  });

  final CapabilityState responses;
  final CapabilityState chatCompletions;
  final CapabilityState vision;
  final CapabilityState functionTools;
  final CapabilityState jsonSchema;
  final CapabilityState imageEdit;
  final CapabilityState streaming;

  Map<String, Object?> toJson() => {
        'responses': responses.name,
        'chat_completions': chatCompletions.name,
        'vision': vision.name,
        'function_tools': functionTools.name,
        'json_schema': jsonSchema.name,
        'image_edit': imageEdit.name,
        'streaming': streaming.name,
      };

  factory AiCapabilities.fromJson(Map<String, Object?> json) => AiCapabilities(
        responses: _capability(json['responses']),
        chatCompletions: _capability(json['chat_completions']),
        vision: _capability(json['vision']),
        functionTools: _capability(json['function_tools']),
        jsonSchema: _capability(json['json_schema']),
        imageEdit: _capability(json['image_edit']),
        streaming: _capability(json['streaming']),
      );

  static CapabilityState _capability(Object? value) {
    for (final state in CapabilityState.values) {
      if (state.name == value) return state;
    }
    return CapabilityState.unknown;
  }
}

class AiProviderProfile {
  const AiProviderProfile({
    required this.providerId,
    required this.name,
    required this.baseUrl,
    required this.modelId,
    required this.apiMode,
    required this.secretRef,
    required this.capabilities,
    this.timeoutSeconds = 60,
    this.maxToolRounds = 8,
    this.maxOutputTokens = 4096,
    this.dataPolicy = const {},
  });

  final String providerId;
  final String name;
  final Uri baseUrl;
  final String modelId;
  final AiApiMode apiMode;
  final SecretRef? secretRef;
  final AiCapabilities capabilities;
  final int timeoutSeconds;
  final int maxToolRounds;
  final int maxOutputTokens;
  final Map<String, Object?> dataPolicy;

  Map<String, Object?> toJson() => {
        'provider_id': providerId,
        'name': name,
        'base_url': baseUrl.toString(),
        'model_id': modelId,
        'api_mode': apiMode == AiApiMode.responses ? 'responses' : 'chat_completions',
        'secret_ref': secretRef?.value,
        'capabilities': capabilities.toJson(),
        'timeout_seconds': timeoutSeconds,
        'max_tool_rounds': maxToolRounds,
        'max_output_tokens': maxOutputTokens,
        'data_policy': dataPolicy,
      };

  factory AiProviderProfile.fromJson(Map<String, Object?> json) => AiProviderProfile(
        providerId: json['provider_id'] as String,
        name: json['name'] as String,
        baseUrl: Uri.parse(json['base_url'] as String),
        modelId: json['model_id'] as String,
        apiMode: json['api_mode'] == 'responses' ? AiApiMode.responses : AiApiMode.chatCompletions,
        secretRef: json['secret_ref'] is String ? SecretRef(json['secret_ref'] as String) : null,
        capabilities: AiCapabilities.fromJson((json['capabilities'] as Map?)?.map(
              (key, value) => MapEntry(key.toString(), value),
            ) ?? const {}),
        timeoutSeconds: json['timeout_seconds'] as int? ?? 60,
        maxToolRounds: json['max_tool_rounds'] as int? ?? 8,
        maxOutputTokens: json['max_output_tokens'] as int? ?? 4096,
        dataPolicy: (json['data_policy'] as Map?)?.map((key, value) => MapEntry(key.toString(), value)) ?? const {},
      );
}

class ConsentReceipt {
  const ConsentReceipt({
    required this.id,
    required this.providerId,
    required this.purpose,
    required this.dataClass,
    required this.assetIds,
    required this.totalBytes,
    required this.approvedScopes,
    required this.approvedAt,
    required this.expiresAt,
    required this.approvalRef,
    this.estimatedCost,
  });

  final String id;
  final String providerId;
  final String purpose;
  final String dataClass;
  final Set<String> assetIds;
  final int totalBytes;
  final Set<String> approvedScopes;
  final DateTime approvedAt;
  final DateTime expiresAt;
  final ApprovalRef approvalRef;
  final String? estimatedCost;

  Map<String, Object?> toJson() => {
        'id': id,
        'provider_id': providerId,
        'purpose': purpose,
        'data_class': dataClass,
        'asset_ids': assetIds.toList()..sort(),
        'total_bytes': totalBytes,
        'approved_scopes': approvedScopes.toList()..sort(),
        'approved_at': approvedAt.toUtc().toIso8601String(),
        'expires_at': expiresAt.toUtc().toIso8601String(),
        'approval_ref': approvalRef.value,
        'estimated_cost': estimatedCost,
      };

  factory ConsentReceipt.fromJson(Map<String, Object?> json) => ConsentReceipt(
        id: json['id'] as String,
        providerId: json['provider_id'] as String,
        purpose: json['purpose'] as String,
        dataClass: json['data_class'] as String,
        assetIds: ((json['asset_ids'] as List?) ?? const []).whereType<String>().toSet(),
        totalBytes: json['total_bytes'] as int,
        approvedScopes: ((json['approved_scopes'] as List?) ?? const []).whereType<String>().toSet(),
        approvedAt: DateTime.parse(json['approved_at'] as String).toUtc(),
        expiresAt: DateTime.parse(json['expires_at'] as String).toUtc(),
        approvalRef: ApprovalRef(json['approval_ref'] as String),
        estimatedCost: json['estimated_cost'] as String?,
      );

  bool covers({
    required String providerId,
    required String purpose,
    required Iterable<String> assetIds,
    required String scope,
    DateTime? now,
  }) {
    final instant = now ?? DateTime.now().toUtc();
    final requested = assetIds.toSet();
    return this.providerId == providerId &&
        this.purpose == purpose &&
        approvedScopes.contains(scope) &&
        this.assetIds.containsAll(requested) &&
        requested.containsAll(this.assetIds) &&
        !instant.isBefore(approvedAt) &&
        instant.isBefore(expiresAt);
  }
}

class AiContent {
  const AiContent.text(this.text)
      : assetIds = const {},
        dataClass = 'text',
        imageDataUri = null,
        uploadBytes = 0;
  const AiContent.assets(this.text, this.assetIds,
      {this.dataClass = 'research_data', this.imageDataUri, this.uploadBytes = 0});

  final String text;
  final Set<String> assetIds;
  final String dataClass;
  /// A short-lived, user-approved preview only; never serialize into a log or DB.
  final String? imageDataUri;
  final int uploadBytes;
  bool get includesAssets => assetIds.isNotEmpty;
}

class AiToolCall {
  const AiToolCall({required this.callId, required this.name, required this.arguments});
  final String callId;
  final String name;
  final Map<String, Object?> arguments;
}

class AiToolResult {
  const AiToolResult({required this.callId, required this.name, required this.output});
  final String callId;
  final String name;
  final Map<String, Object?> output;
}

sealed class AiTurnItem {
  const AiTurnItem();
}

class AiTextItem extends AiTurnItem {
  const AiTextItem(this.text);
  final String text;
}

class AiToolRequestItem extends AiTurnItem {
  const AiToolRequestItem(this.call);
  final AiToolCall call;
}

class AiTurn {
  const AiTurn({required this.items, this.usage = const {}});
  final List<AiTurnItem> items;
  final Map<String, Object?> usage;
  String get text => items.whereType<AiTextItem>().map((item) => item.text).join('\n');
  List<AiToolCall> get toolCalls =>
      items.whereType<AiToolRequestItem>().map((item) => item.call).toList(growable: false);
}

class ToolApprovalRequest {
  const ToolApprovalRequest({
    required this.call,
    required this.assetIds,
    required this.scope,
    required this.reason,
  });
  final AiToolCall call;
  final Set<String> assetIds;
  final String scope;
  final String reason;
}

class ToolApproval {
  const ToolApproval({required this.approvalRef, required this.approved});
  final ApprovalRef? approvalRef;
  final bool approved;
}

class AiToolDefinition {
  const AiToolDefinition({
    required this.name,
    required this.description,
    required this.parametersSchema,
    required this.scope,
    required this.requiresApproval,
    required this.execute,
  });
  final String name;
  final String description;
  final Map<String, Object?> parametersSchema;
  final String scope;
  final bool requiresApproval;
  final Future<Map<String, Object?>> Function(Map<String, Object?> arguments, {ApprovalRef? approvalRef}) execute;
}

typedef ToolArgumentsValidator = bool Function(
  Map<String, Object?> schema,
  Map<String, Object?> value,
);

typedef ToolApprovalGate = Future<ToolApproval> Function(ToolApprovalRequest request);
typedef ToolApprovalValidator = Future<void> Function(
  ApprovalRef approvalRef,
  ToolApprovalRequest request,
);
typedef SafeAuditSink = Future<void> Function(String event, Map<String, Object?> fields);
