import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:vault/agent/conversation_store.dart';
import 'package:vault/agent/vault_meta_db.dart';
import 'package:vault/sandbox/sandbox_provider.dart';
import 'package:vault/sandbox/workspace_bootstrap.dart';
import 'package:vault/sandbox/workspace_guest_fs.dart';

/// Default display name for a newly created project.
const kDefaultProjectName = '新项目';

/// One URL/start entry for a project (order = startup sequence top → bottom).
class ProjectUrlEntry {
  const ProjectUrlEntry({
    required this.name,
    required this.url,
    this.startCommand,
  });

  final String name;
  final String url;
  final String? startCommand;

  Map<String, dynamic> toJson() => {
        'name': name,
        'url': url,
        if (startCommand != null && startCommand!.trim().isNotEmpty)
          'startCommand': startCommand,
      };

  factory ProjectUrlEntry.fromJson(Map<String, dynamic> json) {
    return ProjectUrlEntry(
      name: (json['name'] as String?)?.trim() ?? '',
      url: (json['url'] as String?)?.trim() ?? '',
      startCommand: (json['startCommand'] as String?)?.trim(),
    );
  }
}

/// Metadata for one project inside a workspace.
class ProjectInfo {
  const ProjectInfo({
    required this.path,
    required this.name,
    required this.createdAt,
    required this.updatedAt,
    this.urls = const [],
  });

  /// Timestamp folder name under [kGuestProjectsDir].
  final String path;
  final String name;
  final DateTime createdAt;
  final DateTime updatedAt;
  final List<ProjectUrlEntry> urls;

  String get guestDir => guestProjectDir(path);
}

/// Host SQLite project registry + guest timestamp dirs / git init.
///
/// Metadata lives in [VaultMetaDb] (outside Linux). Only the working tree
/// is created under `/root/projects/{path}/`.
class ProjectStore {
  ProjectStore({
    required VaultMetaDb metaDb,
    required WorkspaceGuestFs fs,
    required Future<CommandResult> Function(String workspaceId, String cmd)
        runGuest,
  })  : _metaDb = metaDb,
        _fs = fs,
        _runGuest = runGuest;

  factory ProjectStore.fromProvider(
    SandboxProvider provider, {
    required VaultMetaDb metaDb,
  }) {
    return ProjectStore(
      metaDb: metaDb,
      fs: SandboxWorkspaceGuestFs(provider),
      runGuest: provider.runGuestCommand,
    );
  }

  /// Test helper: host DB at [metaDbPath], guest files under [guestRoot].
  factory ProjectStore.local({
    required String metaDbPath,
    required String guestRoot,
    Future<CommandResult> Function(String workspaceId, String cmd)? runGuest,
  }) {
    Future<String> resolve(String workspaceId, String guestPath) async {
      final guest = assertGuestPathUnderHome(guestPath);
      return p.join(guestRoot, workspaceId, guest.substring(1));
    }

    return ProjectStore(
      metaDb: VaultMetaDb.at(metaDbPath),
      fs: LocalDirWorkspaceGuestFs(guestRoot),
      runGuest: runGuest ??
          (workspaceId, cmd) async {
            final match = RegExp(r"git -C '([^']+)' init").firstMatch(cmd);
            if (match != null) {
              final guestDir = match.group(1)!;
              final hostGit = await resolve(workspaceId, '$guestDir/.git');
              await Directory(hostGit).create(recursive: true);
            }
            return const CommandResult(exitCode: 0, stdout: '', stderr: '');
          },
    );
  }

  final VaultMetaDb _metaDb;
  final WorkspaceGuestFs _fs;
  final Future<CommandResult> Function(String workspaceId, String cmd)
      _runGuest;

  VaultMetaDb get metaDb => _metaDb;

  /// Allocate `新项目`, `新项目(1)`, … skipping names already in [existingNames].
  static String allocateDisplayName(
    Iterable<String> existingNames, {
    String base = kDefaultProjectName,
  }) {
    final taken = existingNames.toSet();
    if (!taken.contains(base)) return base;
    for (var i = 1; ; i++) {
      final candidate = '$base($i)';
      if (!taken.contains(candidate)) return candidate;
    }
  }

  static String _timestampPath(DateTime utc) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${utc.year}'
        '${two(utc.month)}'
        '${two(utc.day)}'
        '${two(utc.hour)}'
        '${two(utc.minute)}'
        '${two(utc.second)}';
  }

  Future<void> ensureBootstrapped(String workspaceId) async {
    final result = await _runGuest(
      workspaceId,
      workspaceGitAndDirsBootstrapScript(),
    );
    if (result.exitCode != 0) {
      // Tests / degraded: still ensure host schema exists.
      await _metaDb.withDb((_) {});
    } else {
      await _metaDb.withDb((_) {});
    }
    await _migrateLegacyConversationsIfNeeded(workspaceId);
  }

  Future<List<ProjectInfo>> list(String workspaceId) async {
    await ensureBootstrapped(workspaceId);
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

  Future<String?> activePath(String workspaceId) async {
    await ensureBootstrapped(workspaceId);
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

  Future<void> setActive(String workspaceId, String projectPath) async {
    final projects = await list(workspaceId);
    if (!projects.any((p) => p.path == projectPath)) {
      throw StateError('项目不存在：$projectPath');
    }
    await _metaDb.withDb((db) {
      db.execute(
        'INSERT INTO workspace_state (workspace_id, active_project_path) '
        'VALUES (?, ?) '
        'ON CONFLICT(workspace_id) DO UPDATE SET active_project_path = excluded.active_project_path',
        [workspaceId, projectPath],
      );
    });
  }

  /// Create a project folder (timestamp), register in host SQLite, `git init`,
  /// ensure one empty conversation, and set it active.
  Future<ProjectInfo> createProject(
    String workspaceId, {
    String? name,
    List<ProjectUrlEntry> urls = const [],
    ConversationStore? conversationStore,
  }) async {
    await ensureBootstrapped(workspaceId);
    final existing = await list(workspaceId);
    final displayName = allocateDisplayName(
      existing.map((e) => e.name),
      base: (name == null || name.trim().isEmpty)
          ? kDefaultProjectName
          : name.trim(),
    );

    final now = DateTime.now().toUtc();
    var path = _timestampPath(now);
    final takenPaths = existing.map((e) => e.path).toSet();
    if (takenPaths.contains(path)) {
      for (var i = 2; ; i++) {
        final candidate = '${path}_$i';
        if (!takenPaths.contains(candidate)) {
          path = candidate;
          break;
        }
      }
    }

    final guestDir = guestProjectDir(path);
    final init = await _runGuest(
      workspaceId,
      'mkdir -p ${shellSingleQuote(guestDir)} && '
      'git -C ${shellSingleQuote(guestDir)} init',
    );
    if (init.exitCode != 0) {
      throw StateError(
        '创建项目目录 / git init 失败（${init.exitCode}）：'
        '${init.stderr}\n${init.stdout}',
      );
    }

    final createdAt = now.toIso8601String();
    await _metaDb.withDb((db) {
      db.execute(
        'INSERT INTO projects (workspace_id, path, name, created_at, updated_at) '
        'VALUES (?, ?, ?, ?, ?)',
        [workspaceId, path, displayName, createdAt, createdAt],
      );
      _replaceUrls(db, workspaceId, path, urls);
      db.execute(
        'INSERT INTO workspace_state (workspace_id, active_project_path) '
        'VALUES (?, ?) '
        'ON CONFLICT(workspace_id) DO UPDATE SET active_project_path = excluded.active_project_path',
        [workspaceId, path],
      );
    });

    final store = conversationStore ?? ConversationStore(metaDb: _metaDb);
    await store.ensureActive(workspaceId, path);

    return ProjectInfo(
      path: path,
      name: displayName,
      createdAt: now,
      updatedAt: now,
      urls: List.unmodifiable(urls),
    );
  }

  Future<void> rename(
    String workspaceId,
    String projectPath,
    String newName,
  ) async {
    final trimmed = newName.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError('项目名称不能为空');
    }
    final now = DateTime.now().toUtc().toIso8601String();
    await _metaDb.withDb((db) {
      final row = db.select(
        'SELECT path FROM projects WHERE workspace_id = ? AND path = ?',
        [workspaceId, projectPath],
      );
      if (row.isEmpty) {
        throw StateError('项目不存在：$projectPath');
      }
      db.execute(
        'UPDATE projects SET name = ?, updated_at = ? '
        'WHERE workspace_id = ? AND path = ?',
        [trimmed, now, workspaceId, projectPath],
      );
    });
  }

  Future<void> updateUrls(
    String workspaceId,
    String projectPath,
    List<ProjectUrlEntry> urls,
  ) async {
    final now = DateTime.now().toUtc().toIso8601String();
    await _metaDb.withDb((db) {
      final row = db.select(
        'SELECT path FROM projects WHERE workspace_id = ? AND path = ?',
        [workspaceId, projectPath],
      );
      if (row.isEmpty) {
        throw StateError('项目不存在：$projectPath');
      }
      _replaceUrls(db, workspaceId, projectPath, urls);
      db.execute(
        'UPDATE projects SET updated_at = ? WHERE workspace_id = ? AND path = ?',
        [now, workspaceId, projectPath],
      );
    });
  }

  Future<ProjectInfo?> getProject(
    String workspaceId,
    String projectPath,
  ) async {
    final all = await list(workspaceId);
    for (final p in all) {
      if (p.path == projectPath) return p;
    }
    return null;
  }

  /// Insert or replace a URL entry by [entry.name] (keeps relative order).
  ///
  /// When [replaceAll] is true, the project's URL list becomes only [entry].
  Future<List<ProjectUrlEntry>> upsertUrl(
    String workspaceId,
    String projectPath,
    ProjectUrlEntry entry, {
    bool replaceAll = false,
  }) async {
    final name = entry.name.trim();
    final url = entry.url.trim();
    if (name.isEmpty) {
      throw ArgumentError('网址名称不能为空');
    }
    if (url.isEmpty) {
      throw ArgumentError('网址地址不能为空');
    }
    final normalized = ProjectUrlEntry(
      name: name,
      url: url,
      startCommand: entry.startCommand?.trim(),
    );

    if (replaceAll) {
      await updateUrls(workspaceId, projectPath, [normalized]);
      return [normalized];
    }

    final project = await getProject(workspaceId, projectPath);
    if (project == null) {
      throw StateError('项目不存在：$projectPath');
    }
    final urls = [...project.urls];
    final i = urls.indexWhere((u) => u.name == name);
    if (i >= 0) {
      urls[i] = normalized;
    } else {
      urls.add(normalized);
    }
    await updateUrls(workspaceId, projectPath, urls);
    return urls;
  }

  Future<void> removeUrl(
    String workspaceId,
    String projectPath,
    String name,
  ) async {
    final project = await getProject(workspaceId, projectPath);
    if (project == null) {
      throw StateError('项目不存在：$projectPath');
    }
    final next =
        project.urls.where((u) => u.name != name.trim()).toList(growable: false);
    await updateUrls(workspaceId, projectPath, next);
  }

  Future<void> deleteProject(
    String workspaceId,
    String projectPath, {
    ConversationStore? conversationStore,
  }) async {
    await _metaDb.withDb((db) {
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
      db.execute(
        'DELETE FROM projects WHERE workspace_id = ? AND path = ?',
        [workspaceId, projectPath],
      );
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

    try {
      await _fs.deletePath(
        workspaceId,
        guestProjectDir(projectPath),
        recursive: true,
      );
    } catch (_) {}

    final remaining = await list(workspaceId);
    if (remaining.isNotEmpty) {
      await setActive(workspaceId, remaining.first.path);
      final store = conversationStore ?? ConversationStore(metaDb: _metaDb);
      await store.ensureActive(workspaceId, remaining.first.path);
    }
  }

  List<ProjectUrlEntry> _loadUrls(
    Database db,
    String workspaceId,
    String projectPath,
  ) {
    final rows = db.select(
      'SELECT name, url, start_command FROM project_urls '
      'WHERE workspace_id = ? AND project_path = ? ORDER BY sort_order ASC',
      [workspaceId, projectPath],
    );
    return [
      for (final row in rows)
        ProjectUrlEntry(
          name: row['name'] as String,
          url: row['url'] as String,
          startCommand: row['start_command'] as String?,
        ),
    ];
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
      final u = urls[i];
      db.execute(
        'INSERT INTO project_urls '
        '(workspace_id, project_path, sort_order, name, url, start_command) '
        'VALUES (?, ?, ?, ?, ?, ?)',
        [
          workspaceId,
          projectPath,
          i,
          u.name,
          u.url,
          (u.startCommand == null || u.startCommand!.trim().isEmpty)
              ? null
              : u.startCommand!.trim(),
        ],
      );
    }
  }

  /// Move pre-project guest `/root/.vault/conversations` into host DB.
  Future<void> _migrateLegacyConversationsIfNeeded(String workspaceId) async {
    final legacyIndexPath = '$kGuestLegacyConversationsDir/index.json';
    final raw = await _fs.readUtf8(workspaceId, legacyIndexPath);
    if (raw == null || raw.trim().isEmpty) return;

    final existing = await _metaDb.withDb((db) {
      return db.select(
        'SELECT path FROM projects WHERE workspace_id = ?',
        [workspaceId],
      );
    });
    if (existing.isNotEmpty) return;

    WorkspaceConversationIndex index;
    try {
      final json = jsonDecode(raw);
      final map = json is Map<String, dynamic>
          ? json
          : (json as Map).cast<String, dynamic>();
      index = WorkspaceConversationIndex.fromJson(map);
    } catch (_) {
      return;
    }
    if (index.conversations.isEmpty) return;

    final now = DateTime.now().toUtc();
    final path = _timestampPath(now);
    final guestDir = guestProjectDir(path);
    await _runGuest(
      workspaceId,
      'mkdir -p ${shellSingleQuote(guestDir)} && '
      'git -C ${shellSingleQuote(guestDir)} init',
    );

    final createdAt = now.toIso8601String();
    final convStore = ConversationStore(metaDb: _metaDb);

    await _metaDb.withDb((db) {
      db.execute(
        'INSERT INTO projects (workspace_id, path, name, created_at, updated_at) '
        'VALUES (?, ?, ?, ?, ?)',
        [workspaceId, path, '已迁移', createdAt, createdAt],
      );
      db.execute(
        'INSERT INTO workspace_state (workspace_id, active_project_path) '
        'VALUES (?, ?) '
        'ON CONFLICT(workspace_id) DO UPDATE SET active_project_path = excluded.active_project_path',
        [workspaceId, path],
      );
    });

    for (final c in index.conversations) {
      final stateRaw = await _fs.readUtf8(
        workspaceId,
        '$kGuestLegacyConversationsDir/${c.id}.json',
      );
      final stateJson = stateRaw ??
          jsonEncode({
            'sessionId': c.id,
            'metadata': {
              'workspaceId': workspaceId,
              'projectPath': path,
            },
          });
      await _metaDb.withDb((db) {
        db.execute(
          'INSERT INTO conversations '
          '(workspace_id, project_path, id, title, created_at, updated_at, '
          'message_count, state_json) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
          [
            workspaceId,
            path,
            c.id,
            c.title,
            c.createdAt.toUtc().toIso8601String(),
            c.updatedAt.toUtc().toIso8601String(),
            c.messageCount,
            stateJson,
          ],
        );
      });
    }

    final activeId = index.activeConversationId ?? index.conversations.first.id;
    await convStore.setActive(workspaceId, path, activeId);

    try {
      await _fs.deletePath(
        workspaceId,
        kGuestLegacyConversationsDir,
        recursive: true,
      );
    } catch (_) {}
  }
}
