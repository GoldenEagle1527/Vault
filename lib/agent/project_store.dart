import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:vault/agent/conversation_store.dart';
import 'package:vault/agent/project_guest_operations.dart';
import 'package:vault/agent/project_models.dart';
import 'package:vault/agent/project_sqlite_repository.dart';
import 'package:vault/agent/site_port.dart';
import 'package:vault/agent/vault_meta_db.dart';
import 'package:vault/sandbox/sandbox_provider.dart';
import 'package:vault/sandbox/workspace_guest_fs.dart';

export 'package:vault/agent/project_models.dart';

/// Project lifecycle facade over host metadata and guest working trees.
class ProjectStore {
  ProjectStore({
    required VaultMetaDb metaDb,
    required WorkspaceGuestFs fs,
    required Future<CommandResult> Function(String workspaceId, String cmd)
    runGuest,
  }) : _metaDb = metaDb,
       _repository = ProjectSqliteRepository(metaDb),
       _guest = ProjectGuestOperations(fs: fs, runGuest: runGuest);

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
      runGuest:
          runGuest ??
          (workspaceId, cmd) async {
            final match = RegExp(r"git -C '([^']+)' init").firstMatch(cmd);
            if (match != null) {
              final hostGit = await resolve(
                workspaceId,
                '${match.group(1)!}/.git',
              );
              await Directory(hostGit).create(recursive: true);
            }
            return const CommandResult(exitCode: 0, stdout: '', stderr: '');
          },
    );
  }

  final VaultMetaDb _metaDb;
  final ProjectSqliteRepository _repository;
  final ProjectGuestOperations _guest;
  final Set<String> _bootstrapped = {};

  VaultMetaDb get metaDb => _metaDb;

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
    if (_bootstrapped.contains(workspaceId)) return;
    await _guest.bootstrap(workspaceId);
    await _repository.ensureSchema();
    await _migrateLegacyConversationsIfNeeded(workspaceId);
    _bootstrapped.add(workspaceId);
  }

  Future<List<ProjectInfo>> list(String workspaceId) async {
    await ensureBootstrapped(workspaceId);
    final loaded = await _repository.list(workspaceId);
    if (!_needsSlugBackfill(loaded)) return loaded;
    final taken = <String>{};
    for (final project in loaded) {
      final prepared = <ProjectUrlEntry>[];
      for (final entry in project.urls) {
        final existing = entry.slug?.trim();
        final slug = (existing != null && existing.isNotEmpty)
            ? existing
            : allocateSiteSlug(entry.name, taken);
        taken.add(slug);
        prepared.add(
          ProjectUrlEntry(
            name: entry.name,
            url: entry.url,
            startCommand: entry.startCommand,
            slug: slug,
          ),
        );
      }
      await _repository.replaceUrls(workspaceId, project.path, prepared);
    }
    return _repository.list(workspaceId);
  }

  bool _needsSlugBackfill(List<ProjectInfo> projects) {
    return projects.any(
      (project) => project.urls.any(
        (url) => url.slug == null || url.slug!.trim().isEmpty,
      ),
    );
  }

  Future<String?> activePath(String workspaceId) async {
    await ensureBootstrapped(workspaceId);
    return _repository.activePath(workspaceId);
  }

  Future<void> setActive(String workspaceId, String projectPath) =>
      _repository.setActive(workspaceId, projectPath);

  Future<ProjectInfo> createProject(
    String workspaceId, {
    String? name,
    List<ProjectUrlEntry> urls = const [],
    ConversationStore? conversationStore,
  }) async {
    await ensureBootstrapped(workspaceId);
    final existing = await list(workspaceId);
    final displayName = allocateDisplayName(
      existing.map((project) => project.name),
      base: (name == null || name.trim().isEmpty)
          ? kDefaultProjectName
          : name.trim(),
    );
    final now = DateTime.now().toUtc();
    var path = _timestampPath(now);
    final takenPaths = existing.map((project) => project.path).toSet();
    if (takenPaths.contains(path)) {
      for (var i = 2; ; i++) {
        final candidate = '${path}_$i';
        if (!takenPaths.contains(candidate)) {
          path = candidate;
          break;
        }
      }
    }

    await _guest.createProjectDirectory(workspaceId, path);
    final prepared = _prepareUrls(existing, path, urls);
    await _repository.insertProject(
      workspaceId: workspaceId,
      path: path,
      name: displayName,
      createdAt: now.toIso8601String(),
      urls: prepared,
    );
    final store = conversationStore ?? ConversationStore(metaDb: _metaDb);
    await store.ensureActive(workspaceId, path);
    return ProjectInfo(
      path: path,
      name: displayName,
      createdAt: now,
      updatedAt: now,
      urls: List.unmodifiable(prepared),
    );
  }

  Future<void> rename(String workspaceId, String projectPath, String newName) {
    final trimmed = newName.trim();
    if (trimmed.isEmpty) throw ArgumentError('项目名称不能为空');
    return _repository.rename(
      workspaceId,
      projectPath,
      trimmed,
      DateTime.now().toUtc().toIso8601String(),
    );
  }

  Future<void> updateUrls(
    String workspaceId,
    String projectPath,
    List<ProjectUrlEntry> urls,
  ) async {
    final all = await list(workspaceId);
    if (!all.any((project) => project.path == projectPath)) {
      throw StateError('项目不存在：$projectPath');
    }
    final prepared = _prepareUrls(all, projectPath, urls);
    await _repository.replaceUrls(
      workspaceId,
      projectPath,
      prepared,
      updatedAt: DateTime.now().toUtc().toIso8601String(),
    );
  }

  Future<List<SitePortClaim>> listPortClaims(String workspaceId) async =>
      portClaimsFromProjects(await list(workspaceId));

  Future<ProjectInfo?> getProject(
    String workspaceId,
    String projectPath,
  ) async {
    final all = await list(workspaceId);
    for (final project in all) {
      if (project.path == projectPath) return project;
    }
    return null;
  }

  Future<List<ProjectUrlEntry>> upsertUrl(
    String workspaceId,
    String projectPath,
    ProjectUrlEntry entry,
  ) async {
    final name = entry.name.trim();
    final url = entry.url.trim();
    if (name.isEmpty) throw ArgumentError('网址名称不能为空');
    if (url.isEmpty) throw ArgumentError('网址地址不能为空');
    final project = await getProject(workspaceId, projectPath);
    if (project == null) throw StateError('项目不存在：$projectPath');
    final previous = project.site;
    final keptSlug = entry.slug?.trim().isNotEmpty == true
        ? entry.slug!.trim()
        : previous?.slug;
    final normalized = ProjectUrlEntry(
      name: name,
      url: url,
      startCommand: entry.startCommand?.trim(),
      slug: keptSlug,
    );
    await updateUrls(workspaceId, projectPath, [normalized]);
    return (await getProject(workspaceId, projectPath))?.urls ?? [normalized];
  }

  Future<void> removeUrl(
    String workspaceId,
    String projectPath,
    String name,
  ) async {
    final project = await getProject(workspaceId, projectPath);
    if (project == null) throw StateError('项目不存在：$projectPath');
    await updateUrls(
      workspaceId,
      projectPath,
      project.urls
          .where((url) => url.name != name.trim())
          .toList(growable: false),
    );
  }

  Future<void> deleteProject(
    String workspaceId,
    String projectPath, {
    ConversationStore? conversationStore,
  }) async {
    await _repository.deleteProject(workspaceId, projectPath);
    await _guest.deleteProjectDirectory(workspaceId, projectPath);
    final remaining = await list(workspaceId);
    if (remaining.isNotEmpty) {
      await setActive(workspaceId, remaining.first.path);
      final store = conversationStore ?? ConversationStore(metaDb: _metaDb);
      await store.ensureActive(workspaceId, remaining.first.path);
    }
  }

  List<ProjectUrlEntry> _prepareUrls(
    List<ProjectInfo> all,
    String projectPath,
    List<ProjectUrlEntry> urls,
  ) {
    final takenSlugs = <String>{
      for (final project in all)
        if (project.path != projectPath)
          for (final entry in project.urls)
            if (entry.slug != null && entry.slug!.trim().isNotEmpty)
              entry.slug!.trim(),
    };
    final limited = urls.isEmpty ? urls : [urls.first];
    final prepared = <ProjectUrlEntry>[];
    for (final entry in limited) {
      final existing = entry.slug?.trim();
      final slug = (existing != null && existing.isNotEmpty)
          ? existing
          : allocateSiteSlug(entry.name, takenSlugs);
      takenSlugs.add(slug);
      prepared.add(
        ProjectUrlEntry(
          name: entry.name,
          url: entry.url,
          startCommand: entry.startCommand,
          slug: slug,
        ),
      );
    }
    _assertPortsUnique(all, projectPath, prepared);
    return prepared;
  }

  void _assertPortsUnique(
    List<ProjectInfo> all,
    String projectPath,
    List<ProjectUrlEntry> urls,
  ) {
    final seen = <int, String>{};
    final claims = portClaimsFromProjects(all);
    for (final entry in urls) {
      final port = portFromSiteUrl(entry.url);
      if (port == null) {
        throw ArgumentError('url 必须包含可解析的主机与端口：${entry.url}');
      }
      final prior = seen[port];
      if (prior != null) {
        throw SitePortConflictException(
          '同一项目内「$prior」与「${entry.name}」都使用端口 $port',
        );
      }
      seen[port] = entry.name;
      final conflict = findWorkspacePortConflict(
        claims: claims,
        port: port,
        ignoreProjectPath: projectPath,
      );
      if (conflict != null) {
        throw SitePortConflictException(
          '端口 $port 已被项目「${conflict.projectName}」的站点'
          '「${conflict.siteName}」占用，请换一个端口',
          claim: conflict,
        );
      }
    }
  }

  Future<void> _migrateLegacyConversationsIfNeeded(String workspaceId) async {
    final raw = await _guest.readLegacyIndex(workspaceId);
    if (raw == null || raw.trim().isEmpty) return;
    if (await _repository.hasProjects(workspaceId)) return;

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
    await _guest.createLegacyProjectDirectory(workspaceId, path);
    final createdAt = now.toIso8601String();
    await _repository.insertLegacyProject(
      workspaceId: workspaceId,
      path: path,
      createdAt: createdAt,
    );
    for (final conversation in index.conversations) {
      final stateRaw = await _guest.readLegacyConversation(
        workspaceId,
        conversation.id,
      );
      final stateJson =
          stateRaw ??
          jsonEncode({
            'sessionId': conversation.id,
            'metadata': {'workspaceId': workspaceId, 'projectPath': path},
          });
      await _repository.insertLegacyConversation(
        workspaceId: workspaceId,
        projectPath: path,
        id: conversation.id,
        title: conversation.title,
        createdAt: conversation.createdAt.toUtc().toIso8601String(),
        updatedAt: conversation.updatedAt.toUtc().toIso8601String(),
        messageCount: conversation.messageCount,
        stateJson: stateJson,
      );
    }
    final activeId = index.activeConversationId ?? index.conversations.first.id;
    await ConversationStore(
      metaDb: _metaDb,
    ).setActive(workspaceId, path, activeId);
    await _guest.deleteLegacyConversations(workspaceId);
  }
}
