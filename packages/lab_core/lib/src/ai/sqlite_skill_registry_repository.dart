import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
import 'package:lab_core/src/ai/skill_registry.dart';
import 'package:lab_core/src/persistence/workspace_database.dart';

final class Sha256ContentHasher implements ContentHasher {
  const Sha256ContentHasher();
  @override
  String sha256(String value) => crypto.sha256.convert(utf8.encode(value)).toString();
}

final class SqliteSkillRegistryRepository implements SkillRegistryRepository {
  SqliteSkillRegistryRepository(this.database);

  final WorkspaceDatabase database;

  @override
  Future<void> put(SkillDocument skill) async {
    final old = database.query(
      'SELECT content_sha256,instructions_text,capabilities_json,permission_level,state FROM skill_registry_versions WHERE skill_id=? AND version=?',
      [skill.skillId, skill.version],
    );
    if (old.isNotEmpty) {
      final row = old.single;
      if (row['content_sha256'] != skill.contentSha256 || row['instructions_text'] != skill.instructions ||
          row['capabilities_json'] != jsonEncode(skill.capabilities.toList()..sort()) ||
          row['permission_level'] != 'instruction_only') {
        throw const SkillRegistryException('SKILL_VERSION_IMMUTABLE', 'An existing Skill version cannot change content.');
      }
      final oldState = row['state'] as String;
      if (oldState == 'enabled' && skill.state != SkillState.disabled && skill.state != SkillState.enabled) {
        throw const SkillRegistryException('SKILL_STATE_INVALID', 'An enabled Skill version cannot be downgraded.');
      }
    }
    database.execute(
      '''INSERT INTO skill_registry_versions(
           skill_id,version,content_sha256,instructions_text,capabilities_json,
           permission_level,state,created_at_utc)
         VALUES(?,?,?,?,?,'instruction_only',?,?)
         ON CONFLICT(skill_id,version) DO UPDATE SET state=excluded.state''',
      [
        skill.skillId,
        skill.version,
        skill.contentSha256,
        skill.instructions,
        jsonEncode(skill.capabilities.toList()..sort()),
        skill.state.name,
        DateTime.now().toUtc().toIso8601String(),
      ],
    );
  }

  @override
  Future<SkillDocument?> get(String skillId, String version) async {
    final rows = database.query(
      'SELECT * FROM skill_registry_versions WHERE skill_id=? AND version=?',
      [skillId, version],
    );
    return rows.isEmpty ? null : _document(rows.single);
  }

  @override
  Future<List<SkillDocument>> list() async => database
      .query('SELECT * FROM skill_registry_versions ORDER BY skill_id,version')
      .map(_document)
      .toList(growable: false);

  static SkillDocument _document(DbRow row) {
    final capabilities = jsonDecode(row['capabilities_json'] as String);
    if (capabilities is! List) throw const FormatException('Skill capabilities must be a JSON array.');
    return SkillDocument(
      skillId: row['skill_id'] as String,
      version: row['version'] as String,
      instructions: row['instructions_text'] as String,
      contentSha256: row['content_sha256'] as String,
      capabilities: capabilities.whereType<String>().toSet(),
      state: SkillState.values.byName(row['state'] as String),
    );
  }
}
