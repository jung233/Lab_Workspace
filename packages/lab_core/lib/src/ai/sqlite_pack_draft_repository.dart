import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:lab_core/src/ai/pack_draft_service.dart';
import 'package:lab_core/src/persistence/workspace_database.dart';

final class SqlitePackDraftRepository implements PackDraftRepository {
  SqlitePackDraftRepository(this.database);

  final WorkspaceDatabase database;

  @override
  Future<void> save(GeneratedCalculationPackDraft draft, {required String state}) async {
    final canonical = jsonEncode(draft.document);
    final digest = sha256.convert(utf8.encode(canonical)).toString();
    final now = DateTime.now().toUtc().toIso8601String();
    database.execute(
      '''INSERT INTO ai_pack_drafts(
           draft_id,pack_id,version,document_json,validation_json,
           unsupported_operations_json,requires_user_input_json,state,
           content_sha256,created_at_utc)
         VALUES(?,?,?,?,'{}',?,?,?,?,?)
         ON CONFLICT(draft_id) DO UPDATE SET
           document_json=excluded.document_json,
           unsupported_operations_json=excluded.unsupported_operations_json,
           requires_user_input_json=excluded.requires_user_input_json,
           state=excluded.state,content_sha256=excluded.content_sha256''',
      [
        draft.draftId,
        draft.document['pack_id'] as String,
        draft.document['version'] as String,
        canonical,
        jsonEncode(draft.unsupportedOperations),
        jsonEncode(draft.requiresUserInput),
        state,
        digest,
        now,
      ],
    );
  }

  @override
  Future<GeneratedCalculationPackDraft?> get(String draftId) async {
    final rows = database.query('SELECT * FROM ai_pack_drafts WHERE draft_id=?', [draftId]);
    if (rows.isEmpty) return null;
    final row = rows.single;
    final documentValue = jsonDecode(row['document_json'] as String);
    if (documentValue is! Map) return null;
    return GeneratedCalculationPackDraft(
      draftId: row['draft_id'] as String,
      document: documentValue.map((key, value) => MapEntry(key.toString(), value)),
      unsupportedOperations: _stringList(row['unsupported_operations_json'] as String),
      requiresUserInput: _stringList(row['requires_user_input_json'] as String),
      source: null,
    );
  }

  @override
  Future<void> updateState(String draftId, String state) async {
    const allowed = {'draft', 'validated', 'review_required', 'approved', 'rejected'};
    if (!allowed.contains(state)) throw ArgumentError.value(state, 'state');
    database.execute('UPDATE ai_pack_drafts SET state=? WHERE draft_id=?', [state, draftId]);
  }

  static List<String> _stringList(String value) =>
      ((jsonDecode(value) as List?) ?? const []).whereType<String>().toList(growable: false);
}
