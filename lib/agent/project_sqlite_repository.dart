import 'package:sqlite3/sqlite3.dart';
import 'package:vault/agent/project_models.dart';
import 'package:vault/agent/vault_meta_db.dart';

/// SQLite persistence for project metadata and URL registrations.
class ProjectSqliteRepository {
  ProjectSqliteRepository(this._metaDb);

  final VaultMetaDb _metaDb;

  Future<void> ensureSchema() => _metaDb.withDb((_) {});

  Future<List<ProjectInfo>> list(String workspaceId) {
    return _metaDb.withDb((db) {
      final rows = db.select(
        'SELECT path, name, created_at, updated_at FROM projects '
        'WHERE workspace_id = ? ORDER BY updated_at DESC',
        [workspaceId],
      );
      return [
        for (final row in rows)
          ProjectInfo(
            path: row['path'] as String,
            name: row['name'] as String,
            createdAt: DateTime.parse(row['created_at'] as String),
            updatedAt: DateTime.parse(row['updated_at'] as String),
            urls: _loadUrls(db, workspaceId, row['path'] as String),
          ),
      ];
    });
  }

  Future<String?> activePath(String workspaceId) {
    return _metaDb.withDb((db) {
      final rows = db.select(
        'SELECT active_project_path FROM workspace_state WHERE workspace_id = ?',
        [workspaceId],
      );
      if (rows.isEmpty) return null;
      final path = rows.first['active_project_path'] as String?;
      if (path == null || path.isEmpty) return null;
      final exists = db.select(
        'SELECT 1 FROM projects WHERE workspace_id = ? AND path = ?',
        [workspaceId, path],
      );
      return exists.isEmpty ? null : path;
    });
  }

  Future<void> setActive(String workspaceId, String projectPath) {
    return _metaDb.withDb((db) {
      final exists = db.select(
        'SELECT 1 FROM projects WHERE workspace_id = ? AND path = ?',
        [workspaceId, projectPath],
      );
      if (exists.isEmpty) throw StateError('项目不存在：$projectPath');
      _writeActiveProject(db, workspaceId, projectPath);
    });
  }

  Future<void> insertProject({
    required String workspaceId,
    required String path,
    required String name,
    required String createdAt,
    List<ProjectUrlEntry> urls = const [],
  }) {
    return _metaDb.withDb((db) {
      db.execute(
        'INSERT INTO projects (workspace_id, path, name, created_at, updated_at) '
        'VALUES (?, ?, ?, ?, ?)',
        [workspaceId, path, name, createdAt, createdAt],
      );
      _replaceUrls(db, workspaceId, path, urls);
      _writeActiveProject(db, workspaceId, path);
    });
  }

  Future<void> rename(
    String workspaceId,
    String projectPath,
    String name,
    String updatedAt,
  ) {
    return _metaDb.withDb((db) {
      final row = db.select(
        'SELECT path FROM projects WHERE workspace_id = ? AND path = ?',
        [workspaceId, projectPath],
      );
      if (row.isEmpty) throw StateError('项目不存在：$projectPath');
      db.execute(
        'UPDATE projects SET name = ?, updated_at = ? '
        'WHERE workspace_id = ? AND path = ?',
        [name, updatedAt, workspaceId, projectPath],
      );
    });
  }

  Future<void> replaceUrls(
    String workspaceId,
    String projectPath,
    List<ProjectUrlEntry> urls, {
    String? updatedAt,
  }) {
    return _metaDb.withDb((db) {
      _replaceUrls(db, workspaceId, projectPath, urls);
      if (updatedAt != null) {
        db.execute(
          'UPDATE projects SET updated_at = ? '
          'WHERE workspace_id = ? AND path = ?',
          [updatedAt, workspaceId, projectPath],
        );
      }
    });
  }

  Future<void> deleteProject(String workspaceId, String projectPath) {
    return _metaDb.withDb((db) {
      db.execute(
        'DELETE FROM conversations WHERE workspace_id = ? AND project_path = ?',
        [workspaceId, projectPath],
      );
      db.execute(
        'DELETE FROM project_state WHERE workspace_id = ? AND project_path = ?',
        [workspaceId, projectPath],
      );
      db.execute(
        'DELETE FROM project_urls WHERE workspace_id = ? AND project_path = ?',
        [workspaceId, projectPath],
      );
      db.execute('DELETE FROM projects WHERE workspace_id = ? AND path = ?', [
        workspaceId,
        projectPath,
      ]);
      final active = db.select(
        'SELECT active_project_path FROM workspace_state WHERE workspace_id = ?',
        [workspaceId],
      );
      if (active.isNotEmpty &&
          active.first['active_project_path'] == projectPath) {
        db.execute(
          'UPDATE workspace_state SET active_project_path = NULL '
          'WHERE workspace_id = ?',
          [workspaceId],
        );
      }
    });
  }

  Future<bool> hasProjects(String workspaceId) {
    return _metaDb.withDb((db) {
      final rows = db.select(
        'SELECT path FROM projects WHERE workspace_id = ?',
        [workspaceId],
      );
      return rows.isNotEmpty;
    });
  }

  Future<void> insertLegacyProject({
    required String workspaceId,
    required String path,
    required String createdAt,
  }) {
    return _metaDb.withDb((db) {
      db.execute(
        'INSERT INTO projects (workspace_id, path, name, created_at, updated_at) '
        'VALUES (?, ?, ?, ?, ?)',
        [workspaceId, path, '已迁移', createdAt, createdAt],
      );
      _writeActiveProject(db, workspaceId, path);
    });
  }

  Future<void> insertLegacyConversation({
    required String workspaceId,
    required String projectPath,
    required String id,
    required String title,
    required String createdAt,
    required String updatedAt,
    required int messageCount,
    required String stateJson,
  }) {
    return _metaDb.withDb((db) {
      db.execute(
        'INSERT INTO conversations '
        '(workspace_id, project_path, id, title, created_at, updated_at, '
        'message_count, state_json) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
        [
          workspaceId,
          projectPath,
          id,
          title,
          createdAt,
          updatedAt,
          messageCount,
          stateJson,
        ],
      );
    });
  }

  List<ProjectUrlEntry> _loadUrls(
    Database db,
    String workspaceId,
    String projectPath,
  ) {
    final rows = db.select(
      'SELECT name, url, start_command, slug FROM project_urls '
      'WHERE workspace_id = ? AND project_path = ? ORDER BY sort_order ASC',
      [workspaceId, projectPath],
    );
    final loaded = [
      for (final row in rows)
        ProjectUrlEntry(
          name: row['name'] as String,
          url: row['url'] as String,
          startCommand: row['start_command'] as String?,
          slug: row['slug'] as String?,
        ),
    ];
    return loaded.isEmpty ? loaded : [loaded.first];
  }

  void _replaceUrls(
    Database db,
    String workspaceId,
    String projectPath,
    List<ProjectUrlEntry> urls,
  ) {
    db.execute(
      'DELETE FROM project_urls WHERE workspace_id = ? AND project_path = ?',
      [workspaceId, projectPath],
    );
    for (var i = 0; i < urls.length; i++) {
      final url = urls[i];
      final slug = url.slug?.trim();
      db.execute(
        'INSERT INTO project_urls '
        '(workspace_id, project_path, sort_order, name, url, start_command, slug) '
        'VALUES (?, ?, ?, ?, ?, ?, ?)',
        [
          workspaceId,
          projectPath,
          i,
          url.name,
          url.url,
          (url.startCommand == null || url.startCommand!.trim().isEmpty)
              ? null
              : url.startCommand!.trim(),
          (slug == null || slug.isEmpty) ? null : slug,
        ],
      );
    }
  }

  void _writeActiveProject(
    Database db,
    String workspaceId,
    String projectPath,
  ) {
    db.execute(
      'INSERT INTO workspace_state (workspace_id, active_project_path) '
      'VALUES (?, ?) '
      'ON CONFLICT(workspace_id) DO UPDATE SET '
      'active_project_path = excluded.active_project_path',
      [workspaceId, projectPath],
    );
  }
}
