import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:lab_core/lab_core.dart';


final class MicrosoftDeviceAuthorization {
  const MicrosoftDeviceAuthorization({
    required this.deviceCode,
    required this.userCode,
    required this.verificationUri,
    required this.expiresIn,
    required this.interval,
  });

  final String deviceCode;
  final String userCode;
  final Uri verificationUri;
  final int expiresIn;
  final int interval;
}

/// OAuth 2.0 device-code flow and refresh-token storage. All token bytes remain
/// in platform secure storage; SQLite retains only the returned SecretRef.
final class MicrosoftIdentitySession implements MicrosoftGraphAccessTokenProvider {
  MicrosoftIdentitySession({
    required this.secrets,
    required this.repository,
    HttpClient? http,
  }) : _http = http ?? HttpClient();

  final SecretStore secrets;
  final SqliteMicrosoftTodoRepository repository;
  final HttpClient _http;
  static const _scopes = 'Tasks.ReadWrite offline_access';

  Future<MicrosoftDeviceAuthorization> beginDeviceAuthorization({
    required String clientId,
    required String tenantId,
  }) async {
    _validateOAuthSettings(clientId, tenantId);
    final response = await _postForm(
      Uri.https('login.microsoftonline.com', '/${Uri.encodeComponent(tenantId)}/oauth2/v2.0/devicecode'),
      {'client_id': clientId, 'scope': _scopes},
    );
    final code = response['device_code'];
    final userCode = response['user_code'];
    final verification = response['verification_uri'];
    final expiresIn = response['expires_in'];
    final interval = response['interval'];
    if (code is! String || userCode is! String || verification is! String ||
        expiresIn is! int || interval is! int) {
      throw const MicrosoftTodoException('TODO_AUTH_RESPONSE_INVALID', 'Microsoft authorization response was incomplete.');
    }
    final uri = Uri.tryParse(verification);
    if (uri == null || uri.scheme != 'https' || uri.host != 'microsoft.com' && !uri.host.endsWith('.microsoft.com')) {
      throw const MicrosoftTodoException('TODO_AUTH_RESPONSE_INVALID', 'Microsoft verification address was invalid.');
    }
    return MicrosoftDeviceAuthorization(
      deviceCode: code,
      userCode: userCode,
      verificationUri: uri,
      expiresIn: expiresIn,
      interval: interval.clamp(1, 30).toInt(),
    );
  }

  Future<void> finishDeviceAuthorization({
    required MicrosoftDeviceAuthorization authorization,
    required String clientId,
    required String tenantId,
    required MicrosoftTodoProfile profile,
    required bool Function() isCancelled,
  }) async {
    _validateOAuthSettings(clientId, tenantId);
    final authorityGeneration = repository.database.authorityGeneration;
    final deadline = DateTime.now().add(Duration(seconds: authorization.expiresIn));
    var delay = Duration(seconds: authorization.interval);
    while (DateTime.now().isBefore(deadline)) {
      if (isCancelled()) throw const MicrosoftTodoException('TODO_AUTH_CANCELLED', 'Microsoft sign-in was cancelled.');
      await Future<void>.delayed(delay);
      final response = await _postForm(
        Uri.https('login.microsoftonline.com', '/${Uri.encodeComponent(tenantId)}/oauth2/v2.0/token'),
        {
          'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
          'client_id': clientId,
          'device_code': authorization.deviceCode,
        },
        allowOAuthPending: true,
      );
      if (response['error'] == 'authorization_pending') continue;
      if (response['error'] == 'slow_down') {
        delay += const Duration(seconds: 5);
        continue;
      }
      final access = response['access_token'];
      final refresh = response['refresh_token'];
      final expires = response['expires_in'];
      if (access is! String || refresh is! String || expires is! int) {
        throw const MicrosoftTodoException('TODO_AUTH_FAILED', 'Microsoft sign-in did not return usable credentials.');
      }
      await _storeTokens(profile, {
        'access_token': access,
        'refresh_token': refresh,
        'expires_at_utc': DateTime.now().toUtc().add(Duration(seconds: expires)).toIso8601String(),
      }, authorityGeneration: authorityGeneration);
      return;
    }
    throw const MicrosoftTodoException('TODO_AUTH_EXPIRED', 'Microsoft device authorization expired.');
  }

  @override
  Future<String?> accessToken() async {
    final authorityGeneration = repository.database.authorityGeneration;
    final profile = await repository.profile();
    final ref = profile?.secretRef;
    if (profile == null || ref == null || profile.clientId.isEmpty) return null;
    final bytes = await secrets.read(ref);
    if (bytes == null) return null;
    Map<String, Object?> bundle;
    try {
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map) return null;
      bundle = decoded.map((key, value) => MapEntry(key.toString(), value));
    } on Object {
      return null;
    } finally {
      bytes.fillRange(0, bytes.length, 0);
    }
    final token = bundle['access_token'];
    final expiry = DateTime.tryParse(bundle['expires_at_utc'] as String? ?? '');
    if (token is String && expiry != null && DateTime.now().toUtc().isBefore(expiry.toUtc().subtract(const Duration(minutes: 2)))) {
      final current = await repository.profile();
      if (repository.database.authorityGeneration != authorityGeneration || current?.secretRef != ref) return null;
      return token;
    }
    final refresh = bundle['refresh_token'];
    if (refresh is! String || refresh.isEmpty) return null;
    final response = await _postForm(
      Uri.https('login.microsoftonline.com', '/${Uri.encodeComponent(profile.tenantId)}/oauth2/v2.0/token'),
      {
        'grant_type': 'refresh_token',
        'client_id': profile.clientId,
        'refresh_token': refresh,
        'scope': _scopes,
      },
    );
    final newAccess = response['access_token'];
    final newRefresh = response['refresh_token'];
    final expiresIn = response['expires_in'];
    if (newAccess is! String || expiresIn is! int) return null;
    if (repository.database.authorityGeneration != authorityGeneration) return null;
    await _storeTokens(profile, {
      'access_token': newAccess,
      'refresh_token': newRefresh is String ? newRefresh : refresh,
      'expires_at_utc': DateTime.now().toUtc().add(Duration(seconds: expiresIn)).toIso8601String(),
    }, preserveReference: true, authorityGeneration: authorityGeneration);
    if (repository.database.authorityGeneration != authorityGeneration) return null;
    return newAccess;
  }

  Future<void> _storeTokens(
    MicrosoftTodoProfile profile,
    Map<String, Object?> tokenBundle, {
    bool preserveReference = false,
    required int authorityGeneration,
  }) async {
    final bytes = Uint8List.fromList(utf8.encode(jsonEncode(tokenBundle)));
    SecretRef? newRef;
    try {
      if (preserveReference && profile.secretRef != null && secrets is MutableSecretStore) {
        await (secrets as MutableSecretStore).replace(profile.secretRef!, bytes);
        newRef = profile.secretRef;
      } else {
        newRef = await secrets.write(bytes);
      }
      if (repository.database.authorityGeneration != authorityGeneration) {
        throw const MicrosoftTodoException('TODO_AUTHORITY_CHANGED', 'Local restore changed authorization; sign in again.');
      }
      await repository.saveProfile(MicrosoftTodoProfile(
        profileId: profile.profileId,
        listId: profile.listId,
        secretRef: newRef,
        enabled: profile.enabled,
        clientId: profile.clientId,
        tenantId: profile.tenantId,
        importRemoteTasks: profile.importRemoteTasks,
      ));
    } catch (_) {
      if (newRef != null && newRef != profile.secretRef) await secrets.delete(newRef);
      rethrow;
    } finally {
      bytes.fillRange(0, bytes.length, 0);
    }
    if (profile.secretRef != null && profile.secretRef != newRef) {
      await secrets.delete(profile.secretRef!);
    }
  }

  Future<Map<String, Object?>> _postForm(
    Uri uri,
    Map<String, String> fields, {
    bool allowOAuthPending = false,
  }) async {
    if (uri.scheme != 'https' || uri.host != 'login.microsoftonline.com') {
      throw const MicrosoftTodoException('TODO_AUTH_ENDPOINT_INVALID', 'Only Microsoft identity endpoints are allowed.');
    }
    try {
      final request = await _http.postUrl(uri).timeout(const Duration(seconds: 30));
      request.followRedirects = false;
      request.headers.contentType = ContentType('application', 'x-www-form-urlencoded', charset: 'utf-8');
      request.write(Uri(queryParameters: fields).query);
      final response = await request.close().timeout(const Duration(seconds: 30));
      final bytes = await response.fold<List<int>>(<int>[], (all, chunk) {
        if (all.length + chunk.length > 64 * 1024) {
          throw const MicrosoftTodoException('TODO_AUTH_RESPONSE_TOO_LARGE', 'Microsoft identity response exceeded the local limit.');
        }
        return all..addAll(chunk);
      });
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map) throw const MicrosoftTodoException('TODO_AUTH_RESPONSE_INVALID', 'Microsoft identity response was invalid.');
      final result = decoded.map((key, value) => MapEntry(key.toString(), value));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        if (allowOAuthPending && {'authorization_pending', 'slow_down'}.contains(result['error'])) return result;
        throw const MicrosoftTodoException('TODO_AUTH_FAILED', 'Microsoft identity request failed.');
      }
      return result;
    } on MicrosoftTodoException {
      rethrow;
    } on Object {
      throw const MicrosoftTodoException('TODO_AUTH_NETWORK_FAILED', 'Microsoft identity service could not be reached.');
    }
  }

  static void _validateOAuthSettings(String clientId, String tenantId) {
    if (clientId.trim().isEmpty || tenantId.trim().isEmpty ||
        !RegExp(r'^[A-Za-z0-9._-]{1,128}$').hasMatch(tenantId)) {
      throw const MicrosoftTodoException('TODO_AUTH_CONFIG_INVALID', 'A valid Microsoft application ID and tenant are required.');
    }
  }
}

/// Separate OneDrive OAuth profile. Its delegated token scopes intentionally do
/// not include Microsoft To Do, and no To Do SecretRef is accepted here.
final class MicrosoftOneDriveOAuthProfile {
  const MicrosoftOneDriveOAuthProfile({
    required this.targetId,
    required this.clientId,
    required this.tenantId,
    required this.authorityGeneration,
    this.driveId,
    this.credentialRef,
    this.tokenRef,
  });

  final String targetId;
  final String clientId;
  final String tenantId;
  final int authorityGeneration;
  final String? driveId;
  /// Stable reference stored on SyncTarget; it resolves through this local row.
  final SecretRef? credentialRef;
  /// Rotated token bundle ref, always backed by OS secure storage.
  final SecretRef? tokenRef;

  Map<String, Object?> toJson() => {
        'target_id': targetId,
        'client_id': clientId,
        'tenant_id': tenantId,
        'authority_generation': authorityGeneration,
        'drive_id': driveId,
        'credential_ref': credentialRef?.value,
        'token_ref': tokenRef?.value,
      };

  factory MicrosoftOneDriveOAuthProfile.fromJson(Map<String, Object?> json) => MicrosoftOneDriveOAuthProfile(
        targetId: json['target_id']! as String,
        clientId: json['client_id']! as String,
        tenantId: json['tenant_id']! as String,
        authorityGeneration: json['authority_generation'] is int ? json['authority_generation'] as int : 0,
        driveId: json['drive_id'] as String?,
        credentialRef: json['credential_ref'] is String ? SecretRef(json['credential_ref']! as String) : null,
        tokenRef: json['token_ref'] is String ? SecretRef(json['token_ref']! as String) : null,
      );
}

final class SqliteMicrosoftOneDriveOAuthRepository {
  const SqliteMicrosoftOneDriveOAuthRepository(this.database);

  final WorkspaceDatabase database;
  static const _prefix = 'sync.onedrive.oauth.';

  Future<void> save(MicrosoftOneDriveOAuthProfile profile) async {
    if (profile.authorityGeneration != database.authorityGeneration) {
      throw const MicrosoftOneDriveAuthException('ONEDRIVE_AUTHORITY_CHANGED', 'This OAuth profile belongs to an older local authorization generation.');
    }
    final key = '$_prefix${profile.targetId}';
    database.execute(
      '''INSERT INTO workspace_settings(setting_key,value_json,revision,updated_at_utc)
         VALUES(?,?,1,?) ON CONFLICT(setting_key) DO UPDATE SET
         value_json=excluded.value_json,revision=workspace_settings.revision+1,
         updated_at_utc=excluded.updated_at_utc''',
      [key, jsonEncode(profile.toJson()), DateTime.now().toUtc().toIso8601String()],
    );
  }

  Future<MicrosoftOneDriveOAuthProfile?> get(String targetId) async {
    final rows = database.query('SELECT value_json FROM workspace_settings WHERE setting_key=?', ['$_prefix$targetId']);
    if (rows.isEmpty) return null;
    final profile = _decode(rows.single['value_json'] as String);
    return profile.authorityGeneration == database.authorityGeneration ? profile : null;
  }

  Future<MicrosoftOneDriveOAuthProfile?> findByCredentialRef(SecretRef credentialRef) async {
    final rows = database.query('SELECT value_json FROM workspace_settings WHERE setting_key LIKE ?', ['$_prefix%']);
    for (final row in rows) {
      final profile = _decode(row['value_json'] as String);
      if (profile.authorityGeneration == database.authorityGeneration && profile.credentialRef == credentialRef) return profile;
    }
    return null;
  }

  Future<void> delete(String targetId) async {
    database.execute('DELETE FROM workspace_settings WHERE setting_key=?', ['$_prefix$targetId']);
  }

  static MicrosoftOneDriveOAuthProfile _decode(String json) {
    final value = jsonDecode(json);
    if (value is! Map) throw const MicrosoftOneDriveAuthException('ONEDRIVE_PROFILE_INVALID', 'OneDrive OAuth profile is malformed.');
    return MicrosoftOneDriveOAuthProfile.fromJson(value.map((key, value) => MapEntry(key.toString(), value)));
  }
}

/// Microsoft identity device-code and refresh-token adapter for OneDrive.
/// It implements the storage connector's token port by stable SecretRef and
/// rotates the actual encrypted token bundle only in the native SecretStore.
final class MicrosoftOneDriveIdentitySession implements OneDriveAccessTokenProvider {
  MicrosoftOneDriveIdentitySession({
    required this.secrets,
    required this.repository,
    HttpClient? http,
  }) : _http = http ?? HttpClient();

  final SecretStore secrets;
  final SqliteMicrosoftOneDriveOAuthRepository repository;
  final HttpClient _http;
  static const _scopes = 'Files.ReadWrite offline_access';

  Future<MicrosoftOneDriveOAuthProfile> saveConfiguration({
    required String targetId,
    required String clientId,
    required String tenantId,
    String? driveId,
  }) async {
    _validateSettings(clientId, tenantId);
    if (targetId.trim().isEmpty) throw const MicrosoftOneDriveAuthException('ONEDRIVE_PROFILE_INVALID', 'Sync target ID is required.');
    final previous = await repository.get(targetId);
    final sameApp = previous?.clientId == clientId.trim() && previous?.tenantId == tenantId.trim();
    final profile = MicrosoftOneDriveOAuthProfile(
      targetId: targetId,
      clientId: clientId.trim(),
      tenantId: tenantId.trim(),
      authorityGeneration: repository.database.authorityGeneration,
      driveId: driveId?.trim().isEmpty == true ? null : driveId?.trim(),
      credentialRef: sameApp ? previous?.credentialRef : null,
      tokenRef: sameApp ? previous?.tokenRef : null,
    );
    await repository.save(profile);
    if (!sameApp && previous?.tokenRef != null) await secrets.delete(previous!.tokenRef!);
    return profile;
  }

  Future<MicrosoftDeviceAuthorization> beginDeviceAuthorization({required String clientId, required String tenantId}) async {
    _validateSettings(clientId, tenantId);
    final response = await _postForm(
      Uri.https('login.microsoftonline.com', '/${Uri.encodeComponent(tenantId)}/oauth2/v2.0/devicecode'),
      {'client_id': clientId, 'scope': _scopes},
    );
    final code = response['device_code'];
    final userCode = response['user_code'];
    final verification = response['verification_uri'];
    final expiresIn = response['expires_in'];
    final interval = response['interval'];
    if (code is! String || userCode is! String || verification is! String || expiresIn is! int || interval is! int) {
      throw const MicrosoftOneDriveAuthException('ONEDRIVE_AUTH_RESPONSE_INVALID', 'Microsoft authorization response was incomplete.');
    }
    final uri = Uri.tryParse(verification);
    if (uri == null || uri.scheme != 'https' || (uri.host != 'microsoft.com' && !uri.host.endsWith('.microsoft.com'))) {
      throw const MicrosoftOneDriveAuthException('ONEDRIVE_AUTH_RESPONSE_INVALID', 'Microsoft verification address was invalid.');
    }
    return MicrosoftDeviceAuthorization(
      deviceCode: code,
      userCode: userCode,
      verificationUri: uri,
      expiresIn: expiresIn,
      interval: interval.clamp(1, 30).toInt(),
    );
  }

  Future<MicrosoftOneDriveOAuthProfile> finishDeviceAuthorization({
    required MicrosoftDeviceAuthorization authorization,
    required MicrosoftOneDriveOAuthProfile profile,
    required bool Function() isCancelled,
  }) async {
    _validateSettings(profile.clientId, profile.tenantId);
    final deadline = DateTime.now().add(Duration(seconds: authorization.expiresIn));
    var delay = Duration(seconds: authorization.interval);
    while (DateTime.now().isBefore(deadline)) {
      if (isCancelled()) throw const MicrosoftOneDriveAuthException('ONEDRIVE_AUTH_CANCELLED', 'OneDrive sign-in was cancelled.');
      await Future<void>.delayed(delay);
      final response = await _postForm(
        Uri.https('login.microsoftonline.com', '/${Uri.encodeComponent(profile.tenantId)}/oauth2/v2.0/token'),
        {
          'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
          'client_id': profile.clientId,
          'device_code': authorization.deviceCode,
        },
        allowOAuthPending: true,
      );
      if (response['error'] == 'authorization_pending') continue;
      if (response['error'] == 'slow_down') {
        delay += const Duration(seconds: 5);
        continue;
      }
      final access = response['access_token'];
      final refresh = response['refresh_token'];
      final expires = response['expires_in'];
      if (access is! String || refresh is! String || expires is! int) {
        throw const MicrosoftOneDriveAuthException('ONEDRIVE_AUTH_FAILED', 'Microsoft sign-in did not return usable credentials.');
      }
      return _saveTokens(profile, {
        'access_token': access,
        'refresh_token': refresh,
        'expires_at_utc': DateTime.now().toUtc().add(Duration(seconds: expires)).toIso8601String(),
      });
    }
    throw const MicrosoftOneDriveAuthException('ONEDRIVE_AUTH_EXPIRED', 'Microsoft device authorization expired.');
  }

  @override
  Future<String?> accessToken(SecretRef credentialRef) async {
    final authorityGeneration = repository.database.authorityGeneration;
    final profile = await repository.findByCredentialRef(credentialRef);
    final tokenRef = profile?.tokenRef;
    if (profile == null || tokenRef == null || profile.authorityGeneration != authorityGeneration) return null;
    final bytes = await secrets.read(tokenRef);
    if (bytes == null) return null;
    Map<String, Object?> bundle;
    try {
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map) return null;
      bundle = decoded.map((key, value) => MapEntry(key.toString(), value));
    } on Object {
      return null;
    } finally {
      bytes.fillRange(0, bytes.length, 0);
    }
    final token = bundle['access_token'];
    final expiry = DateTime.tryParse(bundle['expires_at_utc'] as String? ?? '');
    if (token is String && expiry != null && DateTime.now().toUtc().isBefore(expiry.toUtc().subtract(const Duration(minutes: 2)))) {
      if (repository.database.authorityGeneration != authorityGeneration) return null;
      return token;
    }
    final refresh = bundle['refresh_token'];
    if (refresh is! String || refresh.isEmpty) return null;
    final response = await _postForm(
      Uri.https('login.microsoftonline.com', '/${Uri.encodeComponent(profile.tenantId)}/oauth2/v2.0/token'),
      {
        'grant_type': 'refresh_token',
        'client_id': profile.clientId,
        'refresh_token': refresh,
        'scope': _scopes,
      },
    );
    final newAccess = response['access_token'];
    final newRefresh = response['refresh_token'];
    final expiresIn = response['expires_in'];
    if (newAccess is! String || expiresIn is! int || repository.database.authorityGeneration != authorityGeneration) return null;
    final rotated = await _saveTokens(profile, {
      'access_token': newAccess,
      'refresh_token': newRefresh is String ? newRefresh : refresh,
      'expires_at_utc': DateTime.now().toUtc().add(Duration(seconds: expiresIn)).toIso8601String(),
    });
    if (rotated.credentialRef != credentialRef) {
      throw const MicrosoftOneDriveAuthException('ONEDRIVE_CREDENTIAL_REF_CHANGED', 'Sync target credential reference changed during refresh.');
    }
    if (repository.database.authorityGeneration != authorityGeneration) return null;
    return newAccess;
  }

  Future<void> signOut(String targetId) async {
    final profile = await repository.get(targetId);
    if (profile == null) return;
    if (profile.tokenRef != null) await secrets.delete(profile.tokenRef!);
    await repository.delete(targetId);
  }

  Future<MicrosoftOneDriveOAuthProfile> _saveTokens(MicrosoftOneDriveOAuthProfile profile, Map<String, Object?> bundle) async {
    if (repository.database.authorityGeneration != profile.authorityGeneration) {
      throw const MicrosoftOneDriveAuthException('ONEDRIVE_AUTHORITY_CHANGED', 'Local restore changed authorization; reconnect OneDrive.');
    }
    final bytes = Uint8List.fromList(utf8.encode(jsonEncode(bundle)));
    SecretRef? newTokenRef;
    final previousTokenRef = profile.tokenRef;
    try {
      newTokenRef = await secrets.write(bytes);
      final updated = MicrosoftOneDriveOAuthProfile(
        targetId: profile.targetId,
        clientId: profile.clientId,
        tenantId: profile.tenantId,
        authorityGeneration: profile.authorityGeneration,
        driveId: profile.driveId,
        credentialRef: profile.credentialRef ?? newTokenRef,
        tokenRef: newTokenRef,
      );
      if (repository.database.authorityGeneration != profile.authorityGeneration) {
        throw const MicrosoftOneDriveAuthException('ONEDRIVE_AUTHORITY_CHANGED', 'Local restore changed authorization; reconnect OneDrive.');
      }
      await repository.save(updated);
    } catch (_) {
      if (newTokenRef != null) await secrets.delete(newTokenRef);
      rethrow;
    } finally {
      bytes.fillRange(0, bytes.length, 0);
    }
    if (previousTokenRef != null && previousTokenRef != newTokenRef) {
      try {
        await secrets.delete(previousTokenRef);
      } on Object {
        // The committed profile already points at the new token; a failed old
        // secret removal cannot invalidate the active refresh token.
      }
    }
    return MicrosoftOneDriveOAuthProfile(
      targetId: profile.targetId,
      clientId: profile.clientId,
      tenantId: profile.tenantId,
      authorityGeneration: profile.authorityGeneration,
      driveId: profile.driveId,
      credentialRef: profile.credentialRef ?? newTokenRef,
      tokenRef: newTokenRef,
    );
  }

  Future<Map<String, Object?>> _postForm(Uri uri, Map<String, String> fields, {bool allowOAuthPending = false}) async {
    if (uri.scheme != 'https' || uri.host != 'login.microsoftonline.com') {
      throw const MicrosoftOneDriveAuthException('ONEDRIVE_AUTH_ENDPOINT_INVALID', 'Only Microsoft identity endpoints are allowed.');
    }
    try {
      final request = await _http.postUrl(uri).timeout(const Duration(seconds: 30));
      request.followRedirects = false;
      request.headers.contentType = ContentType('application', 'x-www-form-urlencoded', charset: 'utf-8');
      request.write(Uri(queryParameters: fields).query);
      final response = await request.close().timeout(const Duration(seconds: 30));
      final bytes = await response.fold<List<int>>(<int>[], (all, chunk) {
        if (all.length + chunk.length > 64 * 1024) throw const MicrosoftOneDriveAuthException('ONEDRIVE_AUTH_RESPONSE_TOO_LARGE', 'Microsoft identity response exceeded the local limit.');
        return all..addAll(chunk);
      });
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map) throw const MicrosoftOneDriveAuthException('ONEDRIVE_AUTH_RESPONSE_INVALID', 'Microsoft identity response was invalid.');
      final result = decoded.map((key, value) => MapEntry(key.toString(), value));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        if (allowOAuthPending && {'authorization_pending', 'slow_down'}.contains(result['error'])) return result;
        throw const MicrosoftOneDriveAuthException('ONEDRIVE_AUTH_FAILED', 'Microsoft identity request failed.');
      }
      return result;
    } on MicrosoftOneDriveAuthException {
      rethrow;
    } on Object {
      throw const MicrosoftOneDriveAuthException('ONEDRIVE_AUTH_NETWORK_FAILED', 'Microsoft identity service could not be reached.');
    }
  }

  static void _validateSettings(String clientId, String tenantId) {
    if (clientId.trim().isEmpty || tenantId.trim().isEmpty || !RegExp(r'^[A-Za-z0-9._-]{1,128}$').hasMatch(tenantId)) {
      throw const MicrosoftOneDriveAuthException('ONEDRIVE_PROFILE_INVALID', 'A valid Microsoft application ID and tenant are required.');
    }
  }
}

final class MicrosoftOneDriveAuthException implements Exception {
  const MicrosoftOneDriveAuthException(this.code, this.message);
  final String code;
  final String message;
  @override
  String toString() => '$code: $message';
}
