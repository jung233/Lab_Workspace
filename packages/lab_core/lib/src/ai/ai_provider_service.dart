import 'dart:convert';

import 'package:lab_core/src/domain/security.dart';

import 'models.dart';
import 'provider_adapters.dart';

abstract interface class AiProviderProfileRepository {
  Future<void> save(AiProviderProfile profile);
  Future<AiProviderProfile?> get(String providerId);
  Future<List<AiProviderProfile>> list();
}

abstract interface class ConsentReceiptRepository {
  Future<void> save(ConsentReceipt receipt);
  Future<ConsentReceipt?> get(String receiptId);
  Future<void> revoke(String receiptId, DateTime atUtc);
}

class AiProviderService {
  AiProviderService({
    required AiProviderProfileRepository profiles,
    required ConsentReceiptRepository consents,
    required AiSdkBridge bridge,
    required SecretStore secretStore,
    ToolArgumentsValidator validateArguments = validateJsonSchemaArguments,
    required ToolApprovalGate requestToolApproval,
    required ToolApprovalValidator validateToolApproval,
    required SafeAuditSink audit,
    Iterable<AiToolDefinition> tools = const [],
  })  : _profiles = profiles,
        _consents = consents,
        _bridge = bridge,
        _secretStore = secretStore,
        _validateArguments = validateArguments,
        _requestToolApproval = requestToolApproval,
        _validateToolApproval = validateToolApproval,
        _audit = audit,
        _tools = {for (final tool in tools) tool.name: tool};

  final AiProviderProfileRepository _profiles;
  final ConsentReceiptRepository _consents;
  final AiSdkBridge _bridge;
  final SecretStore _secretStore;
  final ToolArgumentsValidator _validateArguments;
  final ToolApprovalGate _requestToolApproval;
  final ToolApprovalValidator _validateToolApproval;
  final SafeAuditSink _audit;
  final Map<String, AiToolDefinition> _tools;

  Future<AiProviderProfile> configure(AiProviderProfile profile) async {
    _validateProfile(profile);
    await _profiles.save(profile);
    return profile;
  }

  Future<void> recordConsent(ConsentReceipt receipt) async {
    if (receipt.id.isEmpty || receipt.providerId.isEmpty || receipt.purpose.isEmpty ||
        receipt.totalBytes < 0 ||
        !receipt.expiresAt.isAfter(receipt.approvedAt)) {
      throw const AiProviderException('AI_CONSENT_INVALID', 'Consent receipt is incomplete.');
    }
    await _consents.save(receipt);
  }

  Future<void> revokeConsent(String receiptId) => _consents.revoke(receiptId, DateTime.now().toUtc());

  Future<AiCapabilities> probe(String providerId, {required ConsentReceipt consent}) async {
    final profile = await _requireProfile(providerId);
    final storedConsent = await _consents.get(consent.id);
    if (storedConsent == null || _canonicalConsent(storedConsent) != _canonicalConsent(consent) ||
        storedConsent.dataClass != 'synthetic' ||
        !storedConsent.covers(
          providerId: providerId,
          purpose: 'provider_capability_probe',
          assetIds: const [],
          scope: 'capability_probe',
        ) || storedConsent.totalBytes < 8192) {
      throw const AiProviderException('AI_PROBE_CONSENT_REQUIRED', 'Explicit consent for synthetic capability probes is required.');
    }
    final activeProfile = await _requireProfile(providerId);
    if (activeProfile.secretRef != profile.secretRef ||
        activeProfile.baseUrl != profile.baseUrl ||
        activeProfile.modelId != profile.modelId ||
        activeProfile.apiMode != profile.apiMode) {
      throw const AiProviderException('AI_PROVIDER_CHANGED', 'Provider configuration changed; restart the probe.');
    }
    final currentConsent = await _consents.get(consent.id);
    if (currentConsent == null || _canonicalConsent(currentConsent) != _canonicalConsent(consent)) {
      throw const AiProviderException('AI_PROBE_CONSENT_REQUIRED', 'Probe approval is no longer current.');
    }
    final key = await _requireSecret(activeProfile);
    final capabilities = await _bridge.probe(
      baseUrl: activeProfile.baseUrl,
      modelId: activeProfile.modelId,
      apiMode: activeProfile.apiMode,
      apiKey: key,
      timeoutSeconds: activeProfile.timeoutSeconds,
    );
    // Probes use only synthetic prompts and never receive user assets.
    final updated = AiProviderProfile(
      providerId: profile.providerId,
      name: profile.name,
      baseUrl: profile.baseUrl,
      modelId: profile.modelId,
      apiMode: profile.apiMode,
      secretRef: profile.secretRef,
      capabilities: capabilities,
      timeoutSeconds: profile.timeoutSeconds,
      maxToolRounds: profile.maxToolRounds,
      maxOutputTokens: profile.maxOutputTokens,
      dataPolicy: profile.dataPolicy,
    );
    await _profiles.save(updated);
    await _audit('ai.capability_probe', {'provider_id': providerId, 'capabilities': capabilities.toJson()});
    return capabilities;
  }

  Future<String> completeText({
    required String providerId,
    required String prompt,
    required ConsentReceipt consent,
    String purpose = 'text_assistance',
    Set<String> sourceAssetIds = const {},
    String dataClass = 'text',
    String scope = 'text',
  }) async {
    final response = await _run(
      providerId: providerId,
      content: sourceAssetIds.isEmpty
          ? AiContent.text(prompt)
          : AiContent.assets(prompt, sourceAssetIds, dataClass: dataClass),
      consent: consent,
      purpose: purpose,
      scope: scope,
      tools: const [],
    );
    return response.text;
  }

  Future<String> completeVision({
    required String providerId,
    required AiContent content,
    required ConsentReceipt consent,
    required String purpose,
  }) async {
    if (!content.includesAssets || content.imageDataUri == null || content.uploadBytes <= 0) {
      throw const AiProviderException('AI_IMAGE_INPUT_INVALID', 'Vision input must be a preview linked to an Asset.');
    }
    final profile = await _requireProfile(providerId);
    if (profile.capabilities.vision != CapabilityState.supported) {
      throw const AiProviderException('AI_VISION_UNSUPPORTED', 'Vision capability has not been verified.');
    }
    final response = await _run(
      providerId: providerId,
      content: content,
      consent: consent,
      purpose: purpose,
      scope: 'vision',
      tools: const [],
    );
    return response.text;
  }

  Future<AiTurn> completeVisionWithTools({
    required String providerId,
    required AiContent content,
    required ConsentReceipt consent,
    required String purpose,
    required Iterable<AiToolDefinition> tools,
  }) {
    if (!content.includesAssets || content.imageDataUri == null || content.uploadBytes <= 0) {
      throw const AiProviderException('AI_IMAGE_INPUT_INVALID', 'Vision input must be a preview linked to an Asset.');
    }
    return _completeVisionWithTools(
      providerId: providerId,
      content: content,
      consent: consent,
      purpose: purpose,
      tools: tools,
    );
  }

  Future<AiTurn> _completeVisionWithTools({
    required String providerId,
    required AiContent content,
    required ConsentReceipt consent,
    required String purpose,
    required Iterable<AiToolDefinition> tools,
  }) async {
    final profile = await _requireProfile(providerId);
    if (profile.capabilities.vision != CapabilityState.supported) {
      throw const AiProviderException('AI_VISION_UNSUPPORTED', 'Vision capability has not been verified.');
    }
    if (profile.capabilities.functionTools != CapabilityState.supported) {
      throw const AiProviderException('AI_TOOLS_UNSUPPORTED', 'Provider tool calling has not been verified.');
    }
    return _run(
      providerId: providerId,
      content: content,
      consent: consent,
      purpose: purpose,
      scope: 'vision',
      tools: tools.toList(growable: false),
    );
  }

  Future<AiTurn> runWithTools({
    required String providerId,
    required AiContent content,
    required String purpose,
    required ConsentReceipt consent,
    Iterable<String>? allowedToolNames,
  }) => _run(
        providerId: providerId,
        content: content,
        consent: consent,
        purpose: purpose,
        scope: 'tool_use',
        tools: allowedToolNames == null
            ? _tools.values.toList(growable: false)
            : allowedToolNames.map((name) {
                final tool = _tools[name];
                if (tool == null) throw AiProviderException('AI_TOOL_UNSUPPORTED', 'Tool $name is not registered.');
                return tool;
              }).toList(growable: false),
      );

  Future<AiTurn> _run({
    required String providerId,
    required AiContent content,
    required ConsentReceipt? consent,
    required String purpose,
    required String scope,
    required List<AiToolDefinition> tools,
  }) async {
    final profile = await _requireProfile(providerId);
    await _requireConsent(profile, content, purpose, scope, consent);
    if (tools.isNotEmpty && profile.capabilities.functionTools != CapabilityState.supported) {
      throw const AiProviderException('AI_TOOLS_UNSUPPORTED', 'Provider tool calling has not been verified.');
    }
    final adapter = profile.apiMode == AiApiMode.responses
        ? const ResponsesAdapter()
        : const ChatCompletionsAdapter();
    final modeCapability = profile.apiMode == AiApiMode.responses
        ? profile.capabilities.responses
        : profile.capabilities.chatCompletions;
    if (modeCapability != CapabilityState.supported) {
      throw const AiProviderException('AI_API_MODE_UNVERIFIED', 'Probe the configured API mode successfully before use.');
    }
    final state = AiConversationState();
    var pendingResults = <AiToolResult>[];
    var combinedText = <String>[];
    final observedCalls = <AiToolCall>[];
    var outboundBytes = 0;
    final definitions = {for (final tool in tools) tool.name: tool};
    if (definitions.length != tools.length) {
      throw const AiProviderException('AI_TOOL_DUPLICATE', 'Tool names must be unique within a request.');
    }
    for (var round = 0; round <= profile.maxToolRounds; round++) {
      // Re-read both provider state and consent before every outbound call.
      // A revocation, profile disable, credential replacement, or authority
      // change during a tool round must stop the next request.
      final activeProfile = await _requireProfile(providerId);
      if (activeProfile.secretRef != profile.secretRef ||
          activeProfile.baseUrl != profile.baseUrl ||
          activeProfile.modelId != profile.modelId ||
          activeProfile.apiMode != profile.apiMode) {
        throw const AiProviderException(
          'AI_PROVIDER_CHANGED',
          'Provider configuration changed while the request was active; start again.',
        );
      }
      final callBytes = await _requireConsent(
        activeProfile,
        content,
        purpose,
        scope,
        consent,
        cumulativeBytes: outboundBytes,
        toolResults: pendingResults,
      );
      final apiKey = await _requireSecret(activeProfile);
      final result = await adapter.complete(
        bridge: _bridge,
        profile: activeProfile,
        apiKey: apiKey,
        content: content,
        state: state,
        tools: tools,
        toolResults: pendingResults,
      );
      outboundBytes += callBytes;
      state.responsesId = result.responsesId ?? state.responsesId;
      final calls = result.turn.toolCalls;
      combinedText.add(result.turn.text);
      if (calls.isEmpty) {
        await _audit('ai.request_completed', {'provider_id': providerId, 'rounds': round + 1});
        return AiTurn(
          items: [
            ...observedCalls.map(AiToolRequestItem.new),
            if (combinedText.any((text) => text.isNotEmpty)) AiTextItem(combinedText.where((text) => text.isNotEmpty).join('\n')),
          ],
          usage: result.turn.usage,
        );
      }
      if (round == profile.maxToolRounds) {
        throw const AiProviderException('AI_TOOL_ROUND_LIMIT', 'Provider exceeded the approved tool-call limit.');
      }
      pendingResults = [];
      for (final call in calls) {
        observedCalls.add(call);
        final definition = definitions[call.name];
        if (definition == null) {
          throw AiProviderException('AI_TOOL_UNSUPPORTED', 'Unregistered tool requested: ${call.name}.');
        }
        if (!_validateArguments(definition.parametersSchema, call.arguments)) {
          throw AiProviderException('AI_TOOL_ARGUMENTS_INVALID', 'Arguments failed validation for ${call.name}.');
        }
        final referencedAssets = {...content.assetIds, ..._assetReferences(call.arguments)};
        if (referencedAssets.isNotEmpty) {
          await _requireConsent(
            profile,
            AiContent.assets(content.text, referencedAssets, dataClass: content.dataClass),
            purpose,
            'tool_use',
            consent,
          );
        }
        ApprovalRef? approvalRef;
        if (definition.requiresApproval) {
          final decision = await _requestToolApproval(ToolApprovalRequest(
            call: call,
            assetIds: referencedAssets,
            scope: definition.scope,
            reason: 'The model requested a registered local tool.',
          ));
          if (!decision.approved || decision.approvalRef == null) {
            pendingResults.add(AiToolResult(callId: call.callId, name: call.name, output: {'error': 'user_denied'}));
            continue;
          }
          final confirmedApproval = decision.approvalRef!;
          approvalRef = confirmedApproval;
          await _validateToolApproval(confirmedApproval, ToolApprovalRequest(
            call: call,
            assetIds: referencedAssets,
            scope: definition.scope,
            reason: 'The user approved this exact registered tool call.',
          ));
        }
        final output = await definition.execute(call.arguments, approvalRef: approvalRef);
        pendingResults.add(AiToolResult(callId: call.callId, name: call.name, output: output));
        await _audit('ai.tool_executed', {'provider_id': providerId, 'tool_name': call.name});
      }
    }
    throw const AiProviderException('AI_REQUEST_INCOMPLETE', 'Provider did not finish within the tool-call limit.');
  }

  Future<int> _requireConsent(
    AiProviderProfile profile,
    AiContent content,
    String purpose,
    String scope,
    ConsentReceipt? receipt, {
    int cumulativeBytes = 0,
    List<AiToolResult> toolResults = const [],
  }
  ) async {
    if (receipt == null) throw const AiProviderException('AI_UPLOAD_CONSENT_REQUIRED', 'Explicit upload consent is required.');
    final stored = await _consents.get(receipt.id);
    // The image is sent as a base64 data URI inside JSON, so its wire payload
    // is larger than the decoded preview bytes. Include prompt and bounded
    // envelope overhead when comparing with the user's approved estimate.
    final requestBytes = utf8.encode(content.text).length +
        (content.imageDataUri == null ? 0 : utf8.encode(content.imageDataUri!).length) +
        (toolResults.isEmpty ? 0 : utf8.encode(jsonEncode(toolResults.map((result) => {
          'call_id': result.callId,
          'name': result.name,
          'output': result.output,
        }).toList(growable: false))).length) +
        (content.includesAssets ? 512 : 0);
    if (stored == null || _canonicalConsent(stored) != _canonicalConsent(receipt) ||
        stored.dataClass != content.dataClass ||
        requestBytes > stored.totalBytes - cumulativeBytes ||
        !stored.covers(providerId: profile.providerId, purpose: purpose, assetIds: content.assetIds, scope: scope)) {
      throw const AiProviderException('AI_UPLOAD_CONSENT_INVALID', 'Consent does not cover this provider request.');
    }
    return requestBytes;
  }

  Future<AiProviderProfile> _requireProfile(String id) async =>
      await _profiles.get(id) ?? (throw AiProviderException('AI_PROVIDER_NOT_FOUND', 'Provider $id is not configured.'));

  static String _canonicalConsent(ConsentReceipt receipt) => jsonEncode({
        'id': receipt.id,
        'provider_id': receipt.providerId,
        'purpose': receipt.purpose,
        'data_class': receipt.dataClass,
        'asset_ids': receipt.assetIds.toList()..sort(),
        'total_bytes': receipt.totalBytes,
        'approved_scopes': receipt.approvedScopes.toList()..sort(),
        'approved_at': receipt.approvedAt.toUtc().toIso8601String(),
        'expires_at': receipt.expiresAt.toUtc().toIso8601String(),
        'approval_ref': receipt.approvalRef.value,
        'estimated_cost': receipt.estimatedCost,
      });

  Future<String> _requireSecret(AiProviderProfile profile) async {
    final ref = profile.secretRef;
    if (ref == null) throw const AiProviderException('AI_SECRET_MISSING', 'Provider has no secure credential reference.');
    final bytes = await _secretStore.read(ref);
    if (bytes == null || bytes.isEmpty) throw const AiProviderException('AI_SECRET_MISSING', 'Provider credential is unavailable.');
    try {
      return utf8.decode(bytes, allowMalformed: false);
    } on FormatException {
      throw const AiProviderException('AI_SECRET_INVALID', 'Provider credential encoding is invalid.');
    } finally {
      bytes.fillRange(0, bytes.length, 0);
    }
  }

  void _validateProfile(AiProviderProfile profile) {
    if (profile.providerId.isEmpty || profile.name.isEmpty || profile.modelId.isEmpty ||
        !profile.baseUrl.isAbsolute || profile.timeoutSeconds <= 0 ||
        profile.maxToolRounds < 0 || profile.maxToolRounds > 16 || profile.maxOutputTokens <= 0) {
      throw const AiProviderException('AI_PROVIDER_PROFILE_INVALID', 'Provider profile is incomplete or outside policy limits.');
    }
    if (profile.baseUrl.userInfo.isNotEmpty || profile.baseUrl.hasQuery || profile.baseUrl.hasFragment) {
      throw const AiProviderException('AI_BASE_URL_INVALID', 'Provider base URL cannot contain credentials, query, or fragment data.');
    }
    if (profile.baseUrl.scheme != 'https' &&
        profile.baseUrl.host != 'localhost' &&
        profile.baseUrl.host != '127.0.0.1' &&
        profile.baseUrl.host != '::1') {
      throw const AiProviderException('AI_HTTPS_REQUIRED', 'Remote AI providers must use HTTPS.');
    }
  }

  static Set<String> _assetReferences(Object? value) {
    final result = <String>{};
    void visit(Object? item) {
      if (item is Map) {
        for (final entry in item.entries) {
          final key = entry.key.toString();
          if ((key == 'asset_id' || key == 'source_asset_id') && entry.value is String) {
            result.add(entry.value as String);
          } else if (key == 'asset_ids' && entry.value is List) {
            result.addAll((entry.value as List).whereType<String>());
          } else {
            visit(entry.value);
          }
        }
      } else if (item is List) {
        for (final nested in item) {
          visit(nested);
        }
      }
    }

    visit(value);
    return result;
  }
}

String canonicalToolArguments(Map<String, Object?> arguments) => jsonEncode(arguments);

/// Conservative JSON Schema subset for registered function tool arguments.
/// Unknown schema keywords fail closed instead of being silently ignored.
bool validateJsonSchemaArguments(Map<String, Object?> schema, Map<String, Object?> value) {
  bool valid(Map<String, Object?> definition, Object? candidate) {
    const supported = {
      'type', 'properties', 'required', 'additionalProperties', 'items', 'enum',
      'minimum', 'maximum', 'minLength', 'maxLength', 'minItems', 'maxItems',
      'description', 'title',
    };
    if (definition.keys.any((key) => !supported.contains(key))) return false;
    final enumValues = definition['enum'];
    if (enumValues is List && !enumValues.contains(candidate)) return false;
    switch (definition['type']) {
      case 'object':
        if (candidate is! Map) return false;
        final propertiesValue = definition['properties'];
        final properties = propertiesValue is Map
            ? propertiesValue.map((key, item) => MapEntry(key.toString(), item))
            : <String, Object?>{};
        final requiredFields = (definition['required'] as List? ?? const []).whereType<String>();
        if (requiredFields.any((key) => !candidate.containsKey(key))) return false;
        if (definition['additionalProperties'] == false && candidate.keys.any((key) => !properties.containsKey(key))) {
          return false;
        }
        for (final entry in candidate.entries) {
          final nested = properties[entry.key];
          if (nested == null) continue;
          if (nested is! Map || !valid(nested.map((key, item) => MapEntry(key.toString(), item)), entry.value)) return false;
        }
        return true;
      case 'array':
        if (candidate is! List) return false;
        final minItems = definition['minItems'];
        final maxItems = definition['maxItems'];
        if (minItems is int && candidate.length < minItems) return false;
        if (maxItems is int && candidate.length > maxItems) return false;
        final itemSchema = definition['items'];
        return itemSchema == null ||
            (itemSchema is Map && candidate.every((item) => valid(itemSchema.map((key, value) => MapEntry(key.toString(), value)), item)));
      case 'string':
        if (candidate is! String) return false;
        final minLength = definition['minLength'];
        final maxLength = definition['maxLength'];
        if (minLength is int && candidate.length < minLength) return false;
        if (maxLength is int && candidate.length > maxLength) return false;
        return true;
      case 'integer':
        return candidate is int && _withinRange(definition, candidate.toDouble());
      case 'number':
        return candidate is num && candidate.isFinite && _withinRange(definition, candidate.toDouble());
      case 'boolean':
        return candidate is bool;
      case null:
        return false;
      default:
        return false;
    }
  }

  return valid(schema, value);
}

bool _withinRange(Map<String, Object?> schema, double number) {
  final minimum = schema['minimum'];
  final maximum = schema['maximum'];
  return (minimum is! num || number >= minimum) && (maximum is! num || number <= maximum);
}
