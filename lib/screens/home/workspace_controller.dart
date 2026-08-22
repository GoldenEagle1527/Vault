import 'package:flutter/foundation.dart';
import 'package:vault/agent/conversation_store.dart';
import 'package:vault/agent/project_store.dart';
import 'package:vault/agent/vault_meta_db.dart';
import 'package:vault/agent/workspace_mode.dart';
import 'package:vault/agent/workspace_store.dart';
import 'package:vault/sandbox/sandbox_provider.dart';

class WorkspaceController extends ChangeNotifier {
  WorkspaceController({
    required this.provider,
    required this.metaDb,
    required this.conversationStore,
    required this.projectStore,
    required this.workspaceStore,
  });

  final SandboxProvider provider;
  final VaultMetaDb metaDb;
  final ConversationStore conversationStore;
  final ProjectStore projectStore;
  final WorkspaceStore workspaceStore;

  SandboxCapabilities? capabilities;
  List<WorkspaceInfo> workspaces = const [];
  Map<String, WorkspaceConversationSummary> summaries = const {};
  Map<String, WorkspaceMode> modes = const {};
  Map<String, String> names = const {};
  String? error;
  bool busy = false;
  bool _disposed = false;
  int _generation = 0;

  Future<void> refresh() async {
    final generation = _beginOperation();
    if (generation == null) return;
    try {
      final nextCapabilities = await provider.probe();
      final nextWorkspaces = nextCapabilities.available
          ? await provider.list()
          : const <WorkspaceInfo>[];
      final nextSummaries = <String, WorkspaceConversationSummary>{};
      final nextModes = <String, WorkspaceMode>{};
      final nextNames = await workspaceStore.listNames();
      for (final workspace in nextWorkspaces) {
        try {
          final projects = await projectStore.list(workspace.workspaceId);
          nextSummaries[workspace.workspaceId] = await conversationStore
              .peekProjectsSummary(
                workspace.workspaceId,
                projects.map((project) => project.path).toList(),
              );
        } catch (_) {
          nextSummaries[workspace.workspaceId] =
              const WorkspaceConversationSummary(
                conversationCount: 0,
                projectCount: 0,
              );
        }
        try {
          nextModes[workspace.workspaceId] = await workspaceStore.getMode(
            workspace.workspaceId,
          );
        } catch (_) {
          nextModes[workspace.workspaceId] = WorkspaceMode.chat;
        }
      }
      if (_isCurrent(generation)) {
        capabilities = nextCapabilities;
        workspaces = nextWorkspaces;
        summaries = nextSummaries;
        modes = nextModes;
        names = nextNames;
      }
    } catch (e) {
      if (_isCurrent(generation)) error = e.toString();
    } finally {
      _finishOperation(generation);
    }
  }

  Future<SandboxWorkspace> create({
    required String id,
    required String displayName,
    required WorkspaceMode mode,
    WorkspaceInitProgressCallback? onProgress,
  }) async {
    final generation = _beginOperation();
    if (generation == null) {
      throw StateError('WorkspaceController is disposed');
    }
    try {
      final workspace = await provider.create(id, onProgress: onProgress);
      await workspaceStore.setName(id, displayName);
      await workspaceStore.setMode(id, mode);
      return workspace;
    } catch (e) {
      if (_isCurrent(generation)) error = e.toString();
      rethrow;
    } finally {
      _finishOperation(generation);
    }
  }

  Future<SandboxWorkspace> attach(WorkspaceInfo info) async {
    final generation = _beginOperation();
    if (generation == null) {
      throw StateError('WorkspaceController is disposed');
    }
    try {
      return await provider.attach(info.workspaceId);
    } catch (e) {
      if (_isCurrent(generation)) error = '打开工作区失败：$e';
      rethrow;
    } finally {
      _finishOperation(generation);
    }
  }

  Future<void> destroy(String workspaceId) async {
    final generation = _beginOperation();
    if (generation == null) return;
    try {
      await provider.destroy(workspaceId);
      await metaDb.deleteWorkspace(workspaceId);
      await refresh();
    } catch (e) {
      if (_isCurrent(generation)) error = e.toString();
    } finally {
      _finishOperation(generation);
    }
  }

  void dismissError() {
    if (_disposed) return;
    error = null;
    notifyListeners();
  }

  void setError(String message) {
    if (_disposed) return;
    error = message;
    notifyListeners();
  }

  int? _beginOperation() {
    if (_disposed) return null;
    final generation = _generation;
    busy = true;
    error = null;
    notifyListeners();
    return generation;
  }

  bool _isCurrent(int generation) => !_disposed && generation == _generation;

  void _finishOperation(int generation) {
    if (!_isCurrent(generation)) return;
    busy = false;
    notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    super.dispose();
  }
}
