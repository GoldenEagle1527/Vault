import 'package:vault/agent/vault_meta_db.dart';
import 'package:vault/agent/workspace_mode.dart';

/// Persists per-workspace [WorkspaceMode] in the host [VaultMetaDb].
///
/// Missing rows and null/unknown [mode] values are [WorkspaceMode.chat]
/// so existing workspaces stay in chat.
class WorkspaceStore {
  WorkspaceStore({required VaultMetaDb metaDb}) : _metaDb = metaDb;

  final VaultMetaDb _metaDb;

  Future<WorkspaceMode> getMode(String workspaceId) {
    return _metaDb.withDb((db) {
      final rows = db.select(
        'SELECT mode FROM workspace_state WHERE workspace_id = ?',
        [workspaceId],
      );
      if (rows.isEmpty) return WorkspaceMode.chat;
      return WorkspaceMode.parse(rows.first['mode'] as String?);
    });
  }

  Future<void> setMode(String workspaceId, WorkspaceMode mode) {
    return _metaDb.withDb((db) {
      db.execute(
        'INSERT INTO workspace_state (workspace_id, mode) VALUES (?, ?) '
        'ON CONFLICT(workspace_id) DO UPDATE SET mode = excluded.mode',
        [workspaceId, mode.id],
      );
    });
  }
}
