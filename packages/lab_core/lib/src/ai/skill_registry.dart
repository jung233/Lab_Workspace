import 'dart:convert';

abstract interface class ContentHasher {
  String sha256(String value);
}

enum SkillState { draft, validated, enabled, disabled }

class SkillDocument {
  const SkillDocument({
    required this.skillId,
    required this.version,
    required this.instructions,
    required this.contentSha256,
    this.capabilities = const {},
    this.state = SkillState.draft,
  });
  final String skillId;
  final String version;
  final String instructions;
  final String contentSha256;
  final Set<String> capabilities;
  final SkillState state;

  Map<String, Object?> toJson() => {
        'skill_id': skillId,
        'version': version,
        'instructions': instructions,
        'content_sha256': contentSha256,
        'capabilities': capabilities.toList()..sort(),
        'state': state.name,
        'permission_level': 'instruction_only',
      };
}

abstract interface class SkillRegistryRepository {
  Future<void> put(SkillDocument skill);
  Future<SkillDocument?> get(String skillId, String version);
  Future<List<SkillDocument>> list();
}

abstract interface class SkillInstructionValidator {
  Future<void> validate(String instructions);
}

/// Imports only plain instruction text. Scripts, binaries and declared tools
/// from an archive are never extracted or executed by this registry.
class SkillRegistryService {
  SkillRegistryService({
    required SkillRegistryRepository repository,
    required SkillInstructionValidator validator,
    required ContentHasher hasher,
    this.maxInstructionBytes = 256 * 1024,
  })  : _repository = repository,
        _validator = validator,
        _hasher = hasher;

  final SkillRegistryRepository _repository;
  final SkillInstructionValidator _validator;
  final ContentHasher _hasher;
  final int maxInstructionBytes;

  Future<SkillDocument> importInstructions({
    required String skillId,
    required String version,
    required String instructions,
    Set<String> declaredCapabilities = const {},
  }) async {
    if (!_validId(skillId) || !_validVersion(version)) {
      throw const SkillRegistryException('SKILL_ID_INVALID', 'Skill ID or version is invalid.');
    }
    if (utf8.encode(instructions).length > maxInstructionBytes) {
      throw const SkillRegistryException('SKILL_TOO_LARGE', 'Skill instructions exceed the import limit.');
    }
    await _validator.validate(instructions);
    // Skill text is prompt material only. Capabilities are informative and
    // cannot grant access to local files or registered tools.
    final document = SkillDocument(
      skillId: skillId,
      version: version,
      instructions: instructions,
      contentSha256: _hasher.sha256(instructions),
      capabilities: Set.unmodifiable(declaredCapabilities),
      state: SkillState.validated,
    );
    await _repository.put(document);
    return document;
  }

  Future<SkillDocument> enable(String skillId, String version) async {
    final old = await _repository.get(skillId, version);
    if (old == null || old.state == SkillState.draft) {
      throw const SkillRegistryException('SKILL_NOT_VALIDATED', 'Skill must validate before it can be enabled.');
    }
    final enabled = SkillDocument(
      skillId: old.skillId,
      version: old.version,
      instructions: old.instructions,
      contentSha256: old.contentSha256,
      capabilities: old.capabilities,
      state: SkillState.enabled,
    );
    await _repository.put(enabled);
    return enabled;
  }

  Future<String> getInstructions(String skillId, String version) async {
    final skill = await _repository.get(skillId, version);
    if (skill == null || skill.state != SkillState.enabled) {
      throw const SkillRegistryException('SKILL_DISABLED', 'Skill is not enabled.');
    }
    if (_hasher.sha256(skill.instructions) != skill.contentSha256) {
      throw const SkillRegistryException('SKILL_HASH_MISMATCH', 'Stored Skill instructions changed.');
    }
    return skill.instructions;
  }

  static bool _validId(String id) => RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9._-]{1,127}$').hasMatch(id);
  static bool _validVersion(String version) => RegExp(r'^\d+\.\d+\.\d+(?:[-+][A-Za-z0-9.-]+)?$').hasMatch(version);
}

class SkillRegistryException implements Exception {
  const SkillRegistryException(this.code, this.message);
  final String code;
  final String message;
  @override
  String toString() => '$code: $message';
}
