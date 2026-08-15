import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:vault/sandbox/proot_host.dart';

/// Host-side SQLite filename (outside guest Linux — Agent cannot touch it).
const kVaultMetaDbFileName = 'vault_meta.db';

/// Resolve the default host path for the app-wide Vault metadata database.
Future<String> defaultVaultMetaDbPath() async {
  try {
    if (Platform.isAndroid) {
      final files = await ProotHost.getFilesDir();
      return p.join(files, kVaultMetaDbFileName);
    }
    final base = await getApplicationSupportDirectory();
    return p.join(base.path, kVaultMetaDbFileName);
  } catch (_) {
    // Tests / hosts without path_provider plugins.
    return p.join(Directory.systemTemp.path, kVaultMetaDbFileName);
  }
}

/// Single host SQLite for projects + conversations, partitioned by workspace_id.
///
/// Lives on the host filesystem so the guest Agent cannot corrupt it via shell.
class VaultMetaDb {
  VaultMetaDb(this.filePath);

  final String filePath;

  static Future<VaultMetaDb> openDefault() async {
    return VaultMetaDb(await defaultVaultMetaDbPath());
  }

  /// Test / custom path helper.
  factory VaultMetaDb.at(String filePath) => VaultMetaDb(filePath);

  Future<T> withDb<T>(T Function(Database db) body) async {
    await File(filePath).parent.create(recursive: true);
    final db = sqlite3.open(filePath);
    try {
      db.execute('PRAGMA foreign_keys = ON');
      ensureSchema(db);
      return body(db);
    } finally {
      db.close();
    }
  }

  static void ensureSchema(Database db) {
    db.execute('''
CREATE TABLE IF NOT EXISTS workspace_state (
  workspace_id TEXT PRIMARY KEY,
  active_project_path TEXT
);
''');
    // Existing DBs created before `mode` was added.
    final workspaceStateCols = db.select('PRAGMA table_info(workspace_state)');
    final hasMode = workspaceStateCols.any((row) => row['name'] == 'mode');
    if (!hasMode) {
      db.execute('ALTER TABLE workspace_state ADD COLUMN mode TEXT');
    }
    final hasGatewayPort = workspaceStateCols.any(
      (row) => row['name'] == 'gateway_port',
    );
    if (!hasGatewayPort) {
      db.execute('ALTER TABLE workspace_state ADD COLUMN gateway_port INTEGER');
    }
    final hasName = workspaceStateCols.any((row) => row['name'] == 'name');
    if (!hasName) {
      db.execute('ALTER TABLE workspace_state ADD COLUMN name TEXT');
    }
    db.execute('''
CREATE TABLE IF NOT EXISTS projects (
  workspace_id TEXT NOT NULL,
  path TEXT NOT NULL,
  name TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (workspace_id, path)
);
''');
    db.execute('''
CREATE TABLE IF NOT EXISTS project_urls (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  workspace_id TEXT NOT NULL,
  project_path TEXT NOT NULL,
  sort_order INTEGER NOT NULL,
  name TEXT NOT NULL,
  url TEXT NOT NULL,
  start_command TEXT,
  slug TEXT,
  UNIQUE (workspace_id, project_path, sort_order),
  FOREIGN KEY (workspace_id, project_path)
    REFERENCES projects(workspace_id, path) ON DELETE CASCADE
);
''');
    final urlCols = db.select('PRAGMA table_info(project_urls)');
    final hasSlug = urlCols.any((row) => row['name'] == 'slug');
    if (!hasSlug) {
      db.execute('ALTER TABLE project_urls ADD COLUMN slug TEXT');
    }
    db.execute(
      'CREATE UNIQUE INDEX IF NOT EXISTS project_urls_workspace_slug '
      'ON project_urls (workspace_id, slug) '
      "WHERE slug IS NOT NULL AND slug != ''",
    );
    db.execute('''
CREATE TABLE IF NOT EXISTS project_state (
  workspace_id TEXT NOT NULL,
  project_path TEXT NOT NULL,
  active_conversation_id TEXT,
  PRIMARY KEY (workspace_id, project_path),
  FOREIGN KEY (workspace_id, project_path)
    REFERENCES projects(workspace_id, path) ON DELETE CASCADE
);
''');
    db.execute('''
CREATE TABLE IF NOT EXISTS conversations (
  workspace_id TEXT NOT NULL,
  project_path TEXT NOT NULL,
  id TEXT NOT NULL,
  title TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  message_count INTEGER NOT NULL DEFAULT 0,
  state_json TEXT NOT NULL,
  PRIMARY KEY (workspace_id, project_path, id),
  FOREIGN KEY (workspace_id, project_path)
    REFERENCES projects(workspace_id, path) ON DELETE CASCADE
);
''');
    final convCols = db.select('PRAGMA table_info(conversations)');
    if (!convCols.any((row) => row['name'] == 'parent_id')) {
      db.execute('ALTER TABLE conversations ADD COLUMN parent_id TEXT');
    }
    if (!convCols.any((row) => row['name'] == 'forked_from_message_index')) {
      db.execute(
        'ALTER TABLE conversations ADD COLUMN forked_from_message_index INTEGER',
      );
    }
    if (!convCols.any((row) => row['name'] == 'head_tree_sha')) {
      db.execute('ALTER TABLE conversations ADD COLUMN head_tree_sha TEXT');
    }
  }

  /// Delete all rows for [workspaceId] (projects cascade to urls/conversations).
  Future<void> deleteWorkspace(String workspaceId) async {
    await withDb((db) {
      db.execute('DELETE FROM conversations WHERE workspace_id = ?', [
        workspaceId,
      ]);
      db.execute('DELETE FROM project_state WHERE workspace_id = ?', [
        workspaceId,
      ]);
      db.execute('DELETE FROM project_urls WHERE workspace_id = ?', [
        workspaceId,
      ]);
      db.execute('DELETE FROM projects WHERE workspace_id = ?', [workspaceId]);
      db.execute('DELETE FROM workspace_state WHERE workspace_id = ?', [
        workspaceId,
      ]);
    });
  }
}
