import 'dart:convert';

import 'package:lab_core/src/ai/ai_provider_service.dart';
import 'package:lab_core/src/ai/models.dart';
import 'package:lab_core/src/domain/security.dart';
import 'package:lab_core/src/persistence/workspace_database.dart';

import 'provider_adapters.dart';

/// SQLite-backed repositories for provider settings and consent metadata.
/// Secret bytes remain exclusively in [SecretStore]; only opaque references
/// are persisted in the provider profile row.
final class SqliteAiProviderProfileRepository
    implements AiProviderProfileRepository {
  SqliteAiProviderProfileRepository(this.database);

  final WorkspaceDatabase database;

  @override
  Future<void> save(AiProviderProfile profile) async {
    final now = DateTime.now().toUtc().toIso8601String();
    database.execute(
      '''INSERT INTO ai_provider_profiles(
           provider_id,display_name,base_url,api_mode,model_id,secret_ref,
           capabilities_json,budgets_json,timeout_seconds,data_policy_json,
           enabled,revision,created_at_utc,updated_at_utc,authority_generation)
         VALUES(?,?,?,?,?,?,?,?,?,?,1,1,?,?,?)
         ON CONFLICT(provider_id) DO UPDATE SET
           display_name=excluded.display_name, base_url=excluded.base_url,
           api_mode=excluded.api_mode, model_id=excluded.model_id,
           secret_ref=excluded.secret_ref, capabilities_json=excluded.capabilities_json,
           budgets_json=excluded.budgets_json, timeout_seconds=excluded.timeout_seconds,
           data_policy_json=excluded.data_policy_json, enabled=1,
           revision=ai_provider_profiles.revision+1, updated_at_utc=excluded.updated_at_utc,
           authority_generation=excluded.authority_generation''',
      [
        profile.providerId,
        profile.name,
        profile.baseUrl.toString(),
        profile.apiMode == AiApiMode.responses ? 'responses' : 'chat_completions',
        profile.modelId,
        profile.secretRef?.value,
        jsonEncode(profile.capabilities.toJson()),
        jsonEncode({
          'max_tool_rounds': profile.maxToolRounds,
          'max_output_tokens': profile.maxOutputTokens,
        }),
        profile.timeoutSeconds,
        jsonEncode(profile.dataPolicy),
        now,
        now,
        database.authorityGeneration,
      ],
    );
  }

  @override
  Future<AiProviderProfile?> get(String providerId) async {
    final rows = database.query(
      'SELECT * FROM ai_provider_profiles WHERE provider_id=? AND enabled=1 AND authority_generation=?',
      [providerId, database.authorityGeneration],
    );
    return rows.isEmpty ? null : _profile(rows.single);
  }

  @override
  Future<List<AiProviderProfile>> list() async => database
      .query('SELECT * FROM ai_provider_profiles WHERE enabled=1 AND authority_generation=? ORDER BY display_name', [database.authorityGeneration])
      .map(_profile)
      .toList(growable: false);

  static AiProviderProfile _profile(DbRow row) {
    final budgets = _jsonMap(row['budgets_json'] as String);
    return AiProviderProfile(
      providerId: row['provider_id'] as String,
      name: row['display_name'] as String,
      baseUrl: Uri.parse(row['base_url'] as String),
      modelId: row['model_id'] as String,
      apiMode: row['api_mode'] == 'responses'
          ? AiApiMode.responses
          : AiApiMode.chatCompletions,
      secretRef: row['secret_ref'] is String
          ? SecretRef(row['secret_ref'] as String)
          : null,
      capabilities: AiCapabilities.fromJson(_jsonMap(row['capabilities_json'] as String)),
      timeoutSeconds: _asInt(row['timeout_seconds']),
      maxToolRounds: _asInt(budgets['max_tool_rounds'] ?? 8),
      maxOutputTokens: _asInt(budgets['max_output_tokens'] ?? 4096),
      dataPolicy: _jsonMap(row['data_policy_json'] as String),
    );
  }
}

final class SqliteConsentReceiptRepository implements ConsentReceiptRepository {
  SqliteConsentReceiptRepository(this.database);

  final WorkspaceDatabase database;

  @override
  Future<void> save(ConsentReceipt receipt) async {
    database.transaction((tx) {
      tx.requireApproval(
        approvalRef: receipt.approvalRef,
        action: 'ai.upload_consent',
        subjectType: 'ai_provider',
        subjectId: receipt.providerId,
        atUtc: receipt.approvedAt,
        requiredScope: {
          'provider_id': receipt.providerId,
          'purpose': receipt.purpose,
          'data_class': receipt.dataClass,
          'asset_ids': receipt.assetIds.toList()..sort(),
          'total_bytes': receipt.totalBytes,
          'approved_scopes': receipt.approvedScopes.toList()..sort(),
          'expires_at_utc': receipt.expiresAt.toUtc().toIso8601String(),
        },
      );
      final approvalRows = tx.query(
        'SELECT scope_json,expires_at_utc,issuer_device_id,authority_generation FROM approval_receipts WHERE approval_ref=?',
        [receipt.approvalRef.value],
      );
      final approvedScope = approvalRows.isEmpty
          ? null
          : _jsonMap(approvalRows.single['scope_json'] as String);
      final expectedScope = <String, Object?>{
        'provider_id': receipt.providerId,
        'purpose': receipt.purpose,
        'data_class': receipt.dataClass,
        'asset_ids': receipt.assetIds.toList()..sort(),
        'total_bytes': receipt.totalBytes,
        'approved_scopes': receipt.approvedScopes.toList()..sort(),
        'expires_at_utc': receipt.expiresAt.toUtc().toIso8601String(),
      };
      if (approvedScope == null || _canonical(approvedScope) != _canonical(expectedScope)) {
        throw const AiProviderException(
          'AI_CONSENT_APPROVAL_SCOPE_MISMATCH',
          'Approval scope does not match the consent receipt being stored.',
        );
      }
      final approvalExpiry = approvalRows.single['expires_at_utc'] is String
          ? DateTime.tryParse(approvalRows.single['expires_at_utc'] as String)
          : null;
      if (approvalRows.single['expires_at_utc'] != null &&
          (approvalExpiry == null || approvalExpiry.toUtc().isBefore(receipt.expiresAt.toUtc()))) {
        throw const AiProviderException(
          'AI_CONSENT_APPROVAL_EXPIRY_MISMATCH',
          'Consent cannot outlive its approval receipt.',
        );
      }
      if (approvalRows.single['issuer_device_id'] != database.activeDeviceId ||
          approvalRows.single['authority_generation'] != database.authorityGeneration) {
        throw const AiProviderException(
          'AI_CONSENT_APPROVAL_STALE',
          'Consent must be approved by the current local installation.',
        );
      }
      tx.execute(
        '''INSERT INTO ai_consent_receipts(
             consent_id,provider_id,purpose,data_class,asset_ids_json,total_bytes,
             estimated_cost_text,approved_scopes_json,approved_at_utc,expires_at_utc,
             revoked_at_utc,approval_ref,authority_generation)
           VALUES(?,?,?,?,?,?,?,?,?,?,NULL,?,?)
           ON CONFLICT(consent_id) DO UPDATE SET
             provider_id=excluded.provider_id,purpose=excluded.purpose,
             data_class=excluded.data_class,asset_ids_json=excluded.asset_ids_json,
             total_bytes=excluded.total_bytes,estimated_cost_text=excluded.estimated_cost_text,
             approved_scopes_json=excluded.approved_scopes_json,
             approved_at_utc=excluded.approved_at_utc,expires_at_utc=excluded.expires_at_utc,
             approval_ref=excluded.approval_ref,revoked_at_utc=NULL,
             authority_generation=excluded.authority_generation''',
        [
          receipt.id,
          receipt.providerId,
          receipt.purpose,
          receipt.dataClass,
          jsonEncode(receipt.assetIds.toList()..sort()),
          receipt.totalBytes,
          receipt.estimatedCost,
          jsonEncode(receipt.approvedScopes.toList()..sort()),
          receipt.approvedAt.toUtc().toIso8601String(),
          receipt.expiresAt.toUtc().toIso8601String(),
          receipt.approvalRef.value,
          database.authorityGeneration,
        ],
      );
      return null;
    });
  }

  @override
  Future<ConsentReceipt?> get(String receiptId) async {
    final rows = database.query(
      'SELECT * FROM ai_consent_receipts WHERE consent_id=? AND revoked_at_utc IS NULL AND authority_generation=?',
      [receiptId, database.authorityGeneration],
    );
    if (rows.isEmpty) return null;
    final row = rows.single;
    final expires = DateTime.tryParse(row['expires_at_utc'] as String? ?? '');
    if (expires == null || !DateTime.now().toUtc().isBefore(expires.toUtc())) return null;
    final receipt = ConsentReceipt(
      id: row['consent_id'] as String,
      providerId: row['provider_id'] as String,
      purpose: row['purpose'] as String,
      dataClass: row['data_class'] as String,
      assetIds: _stringSet(row['asset_ids_json'] as String),
      totalBytes: _asInt(row['total_bytes']),
      approvedScopes: _stringSet(row['approved_scopes_json'] as String),
      approvedAt: DateTime.parse(row['approved_at_utc'] as String).toUtc(),
      expiresAt: expires.toUtc(),
      approvalRef: ApprovalRef(row['approval_ref'] as String),
      estimatedCost: row['estimated_cost_text'] as String?,
    );
    final approvals = database.query(
      '''SELECT action,subject_type,subject_id,scope_json,approved_at_utc,
                expires_at_utc,revoked_at_utc,issuer_device_id,authority_generation
         FROM approval_receipts WHERE approval_ref=?''',
      [receipt.approvalRef.value],
    );
    if (approvals.isEmpty) return null;
    final approval = approvals.single;
    final approvalExpiry = DateTime.tryParse(approval['expires_at_utc'] as String? ?? '');
    final expectedScope = <String, Object?>{
      'provider_id': receipt.providerId,
      'purpose': receipt.purpose,
      'data_class': receipt.dataClass,
      'asset_ids': receipt.assetIds.toList()..sort(),
      'total_bytes': receipt.totalBytes,
      'approved_scopes': receipt.approvedScopes.toList()..sort(),
      'expires_at_utc': receipt.expiresAt.toUtc().toIso8601String(),
    };
    if (approval['action'] != 'ai.upload_consent' ||
        approval['subject_type'] != 'ai_provider' ||
        approval['subject_id'] != receipt.providerId ||
        approval['revoked_at_utc'] != null ||
        approval['issuer_device_id'] != database.activeDeviceId ||
        approval['authority_generation'] != database.authorityGeneration ||
        approval['approved_at_utc'] != receipt.approvedAt.toUtc().toIso8601String() ||
        (approval['expires_at_utc'] != null &&
            (approvalExpiry == null ||
                !DateTime.now().toUtc().isBefore(approvalExpiry.toUtc()) ||
                approvalExpiry.toUtc().isBefore(receipt.expiresAt.toUtc()))) ||
        _canonical(_jsonMap(approval['scope_json'] as String)) != _canonical(expectedScope)) {
      return null;
    }
    return receipt;
  }

  @override
  Future<void> revoke(String receiptId, DateTime atUtc) async {
    database.execute(
      'UPDATE ai_consent_receipts SET revoked_at_utc=? WHERE consent_id=? AND revoked_at_utc IS NULL',
      [atUtc.toUtc().toIso8601String(), receiptId],
    );
  }
}

Map<String, Object?> _jsonMap(String value) {
  final decoded = jsonDecode(value);
  if (decoded is! Map) throw const FormatException('Expected a JSON object in SQLite.');
  return decoded.map((key, item) => MapEntry(key.toString(), item));
}

String _canonical(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((key) => key.toString()).toList()..sort();
    return '{${keys.map((key) => '${jsonEncode(key)}:${_canonical(value[key])}').join(',')}}';
  }
  if (value is List) return '[${value.map(_canonical).join(',')}]';
  return jsonEncode(value);
}

Set<String> _stringSet(String value) =>
    ((jsonDecode(value) as List?) ?? const []).whereType<String>().toSet();

int _asInt(Object? value) => switch (value) {
      int number => number,
      BigInt number => number.toInt(),
      _ => int.parse(value.toString()),
    };

/// Validates that a tool approval is bound to the exact call presented to the
/// user, including parameters and every referenced Asset ID.
final class SqliteToolApprovalValidator {
  const SqliteToolApprovalValidator(this.database);

  final WorkspaceDatabase database;

  Future<void> call(ApprovalRef approvalRef, ToolApprovalRequest request) async {
    final rows = database.query(
      '''SELECT action,subject_type,subject_id,scope_json,expires_at_utc,revoked_at_utc
         FROM approval_receipts WHERE approval_ref=?''',
      [approvalRef.value],
    );
    if (rows.isEmpty) {
      throw const AiProviderException('APPROVAL_REQUIRED', 'A stored tool approval is required.');
    }
    final row = rows.single;
    final expiresAt = row['expires_at_utc'] is String
        ? DateTime.tryParse(row['expires_at_utc'] as String)
        : null;
    if (row['action'] != 'ai.tool.execute' || row['subject_type'] != 'ai_tool' ||
        row['subject_id'] != request.call.name || row['revoked_at_utc'] != null ||
        (row['expires_at_utc'] != null && expiresAt == null) ||
        (expiresAt != null && !DateTime.now().toUtc().isBefore(expiresAt.toUtc()))) {
      throw const AiProviderException('APPROVAL_SCOPE_MISMATCH', 'Tool approval is expired, revoked, or bound to another action.');
    }
    final expectedScope = <String, Object?>{
      'tool_name': request.call.name,
      'parameters': request.call.arguments,
      'asset_ids': request.assetIds.toList()..sort(),
      'scope': request.scope,
    };
    final storedScope = _jsonMap(row['scope_json'] as String);
    if (_canonical(storedScope) != _canonical(expectedScope)) {
      throw const AiProviderException('APPROVAL_SCOPE_MISMATCH', 'Tool approval does not match the exact parameters and Assets.');
    }
  }
}
