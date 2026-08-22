import 'package:sqlite3/sqlite3.dart';
import 'package:vault/agent/conversation_models.dart';
import 'package:vault/agent/vault_meta_db.dart';

/// SQLite persistence for conversations. It contains no Agent lifecycle logic.
class ConversationSqliteRepository {
  ConversationSqliteRepository(this._metaDb);

  final VaultMetaDb _metaDb;

  Future<WorkspaceConversationIndex> readIndex(
    String workspaceId,
    String projectPath,
  ) {
    return _metaDb.withDb((db) {
      final rows = db.select(
        'SELECT id, title, created_at, updated_at, message_count, '
        'parent_id, forked_from_message_index, head_tree_sha '
        'FROM conversations WHERE workspace_id = ? AND project_path = ? '
        'ORDER BY updated_at DESC',
        [workspaceId, projectPath],
      );
      final conversations = [
        for (final row in rows)
          ConversationInfo(
            id: row['id'] as String,
            title: row['title'] as String,
            createdAt: DateTime.parse(row['created_at'] as String),
            updatedAt: DateTime.parse(row['updated_at'] as String),
            messageCount: (row['message_count'] as num).toInt(),
            parentId: row['parent_id'] as String?,
            forkedFromMessageIndex: (row['forked_from_message_index'] as num?)
                ?.toInt(),
            headTreeSha: row['head_tree_sha'] as String?,
          ),
      ];
      final activeRows = db.select(
        'SELECT active_conversation_id FROM project_state '
        'WHERE workspace_id = ? AND project_path = ?',
        [workspaceId, projectPath],
      );
      String? active;
      if (activeRows.isNotEmpty) {
        active = activeRows.first['active_conversation_id'] as String?;
      }
      if (active != null && !conversations.any((c) => c.id == active)) {
        active = conversations.isEmpty ? null : conversations.first.id;
      }
      return WorkspaceConversationIndex(
        activeConversationId: active,
        conversations: conversations,
      );
    });
  }

  Future<String?> readStateJson(
    String workspaceId,
    String projectPath,
    String conversationId,
  ) {
    return _metaDb.withDb((db) {
      final rows = db.select(
        'SELECT state_json FROM conversations '
        'WHERE workspace_id = ? AND project_path = ? AND id = ?',
        [workspaceId, projectPath, conversationId],
      );
      return rows.isEmpty ? null : rows.first['state_json'] as String;
    });
  }

  Future<void> insert({
    required String workspaceId,
    required String projectPath,
    required String id,
    required String title,
    required String createdAt,
    required int messageCount,
    required String stateJson,
    String? parentId,
    int? forkedFromMessageIndex,
    String? headTreeSha,
  }) {
    return _metaDb.withDb((db) {
      db.execute(
        'INSERT INTO conversations '
        '(workspace_id, project_path, id, title, created_at, updated_at, '
        'message_count, state_json, parent_id, forked_from_message_index, '
        'head_tree_sha) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        [
          workspaceId,
          projectPath,
          id,
          title,
          createdAt,
          createdAt,
          messageCount,
          stateJson,
          parentId,
          forkedFromMessageIndex,
          headTreeSha,
        ],
      );
      _writeActive(db, workspaceId, projectPath, id);
    });
  }

  Future<void> save({
    required String workspaceId,
    required String projectPath,
    required String id,
    required String title,
    required String updatedAt,
    required int messageCount,
    required String stateJson,
    required String? headTreeSha,
  }) {
    return _metaDb.withDb((db) {
      final existing = db.select(
        'SELECT id, created_at FROM conversations '
        'WHERE workspace_id = ? AND project_path = ? AND id = ?',
        [workspaceId, projectPath, id],
      );
      if (existing.isEmpty) {
        db.execute(
          'INSERT INTO conversations '
          '(workspace_id, project_path, id, title, created_at, updated_at, '
          'message_count, state_json, head_tree_sha) '
          'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
          [
            workspaceId,
            projectPath,
            id,
            title,
            updatedAt,
            updatedAt,
            messageCount,
            stateJson,
            headTreeSha,
          ],
        );
      } else {
        db.execute(
          'UPDATE conversations SET title = ?, updated_at = ?, '
          'message_count = ?, state_json = ?, head_tree_sha = ? '
          'WHERE workspace_id = ? AND project_path = ? AND id = ?',
          [
            title,
            updatedAt,
            messageCount,
            stateJson,
            headTreeSha,
            workspaceId,
            projectPath,
            id,
          ],
        );
      }
      final active = db.select(
        'SELECT active_conversation_id FROM project_state '
        'WHERE workspace_id = ? AND project_path = ?',
        [workspaceId, projectPath],
      );
      if (active.isEmpty) {
        db.execute(
          'INSERT INTO project_state '
          '(workspace_id, project_path, active_conversation_id) VALUES (?, ?, ?)',
          [workspaceId, projectPath, id],
        );
      }
    });
  }

  Future<void> setActive(
    String workspaceId,
    String projectPath,
    String conversationId,
  ) {
    return _metaDb.withDb((db) {
      final rows = db.select(
        'SELECT id FROM conversations '
        'WHERE workspace_id = ? AND project_path = ? AND id = ?',
        [workspaceId, projectPath, conversationId],
      );
      if (rows.isEmpty) {
        throw StateError('会话不存在：$conversationId');
      }
      _writeActive(db, workspaceId, projectPath, conversationId);
    });
  }

  Future<void> delete(
    String workspaceId,
    String projectPath,
    String conversationId,
  ) {
    return _metaDb.withDb((db) {
      db.execute(
        'UPDATE conversations SET parent_id = NULL, '
        'forked_from_message_index = NULL '
        'WHERE workspace_id = ? AND project_path = ? AND parent_id = ?',
        [workspaceId, projectPath, conversationId],
      );
      db.execute(
        'DELETE FROM conversations '
        'WHERE workspace_id = ? AND project_path = ? AND id = ?',
        [workspaceId, projectPath, conversationId],
      );
    });
  }

  Future<void> deleteProjectState(String workspaceId, String projectPath) {
    return _metaDb.withDb((db) {
      db.execute(
        'DELETE FROM project_state WHERE workspace_id = ? AND project_path = ?',
        [workspaceId, projectPath],
      );
    });
  }

  Future<void> deleteWorkspace(String workspaceId) =>
      _metaDb.deleteWorkspace(workspaceId);

  Future<WorkspaceConversationSummary> summary(
    String workspaceId,
    List<String> projectPaths,
  ) {
    if (projectPaths.isEmpty) {
      return Future.value(
        const WorkspaceConversationSummary(
          conversationCount: 0,
          projectCount: 0,
        ),
      );
    }
    return _metaDb.withDb((db) {
      var total = 0;
      ConversationInfo? recent;
      for (final path in projectPaths) {
        final rows = db.select(
          'SELECT id, title, created_at, updated_at, message_count '
          'FROM conversations WHERE workspace_id = ? AND project_path = ?',
          [workspaceId, path],
        );
        total += rows.length;
        for (final row in rows) {
          final conversation = ConversationInfo(
            id: row['id'] as String,
            title: row['title'] as String,
            createdAt: DateTime.parse(row['created_at'] as String),
            updatedAt: DateTime.parse(row['updated_at'] as String),
            messageCount: (row['message_count'] as num).toInt(),
          );
          if (recent == null ||
              conversation.updatedAt.isAfter(recent.updatedAt)) {
            recent = conversation;
          }
        }
      }
      return WorkspaceConversationSummary(
        conversationCount: total,
        recentTitle: recent?.title,
        recentUpdatedAt: recent?.updatedAt,
        projectCount: projectPaths.length,
      );
    });
  }

  void _writeActive(
    Database db,
    String workspaceId,
    String projectPath,
    String conversationId,
  ) {
    db.execute(
      'INSERT INTO project_state '
      '(workspace_id, project_path, active_conversation_id) VALUES (?, ?, ?) '
      'ON CONFLICT(workspace_id, project_path) DO UPDATE SET '
      'active_conversation_id = excluded.active_conversation_id',
      [workspaceId, projectPath, conversationId],
    );
  }
}
