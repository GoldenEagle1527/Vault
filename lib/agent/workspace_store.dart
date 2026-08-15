import 'package:vault/agent/vault_meta_db.dart';
import 'package:vault/agent/workspace_mode.dart';

/// Default display name for a newly created workspace.
const kDefaultWorkspaceName = '新工作区';

/// Persists per-workspace [WorkspaceMode] and display name in the host
/// [VaultMetaDb].
///
/// Missing rows and null/unknown [mode] values are [WorkspaceMode.chat]
/// so existing workspaces stay in chat.
class WorkspaceStore {
  WorkspaceStore({required VaultMetaDb metaDb}) : _metaDb = metaDb;

  final VaultMetaDb _metaDb;

  /// Allocate `新工作区`, `新工作区(1)`, … skipping names already in [existingNames].
  static String allocateDisplayName(
    Iterable<String> existingNames, {
    String base = kDefaultWorkspaceName,
  }) {
    final taken = existingNames.toSet();
    if (!taken.contains(base)) return base;
    for (var i = 1; ; i++) {
      final candidate = '$base($i)';
      if (!taken.contains(candidate)) return candidate;
    }
  }

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

  /// Last successfully bound site-gateway port, if any.
  Future<int?> getGatewayPort(String workspaceId) {
    return _metaDb.withDb((db) {
      final rows = db.select(
        'SELECT gateway_port FROM workspace_state WHERE workspace_id = ?',
        [workspaceId],
      );
      if (rows.isEmpty) return null;
      final raw = rows.first['gateway_port'];
      if (raw is int && raw > 0) return raw;
      if (raw is num && raw.toInt() > 0) return raw.toInt();
      return null;
    });
  }

  Future<void> setGatewayPort(String workspaceId, int port) {
    return _metaDb.withDb((db) {
      db.execute(
        'INSERT INTO workspace_state (workspace_id, gateway_port) '
        'VALUES (?, ?) '
        'ON CONFLICT(workspace_id) DO UPDATE SET '
        'gateway_port = excluded.gateway_port',
        [workspaceId, port],
      );
    });
  }

  /// User-chosen display name, or null when unset (legacy workspaces).
  Future<String?> getName(String workspaceId) {
    return _metaDb.withDb((db) {
      final rows = db.select(
        'SELECT name FROM workspace_state WHERE workspace_id = ?',
        [workspaceId],
      );
      if (rows.isEmpty) return null;
      final name = (rows.first['name'] as String?)?.trim();
      if (name == null || name.isEmpty) return null;
      return name;
    });
  }

  Future<void> setName(String workspaceId, String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError.value(name, 'name', '工作区名称不能为空');
    }
    return _metaDb.withDb((db) {
      db.execute(
        'INSERT INTO workspace_state (workspace_id, name) VALUES (?, ?) '
        'ON CONFLICT(workspace_id) DO UPDATE SET name = excluded.name',
        [workspaceId, trimmed],
      );
    });
  }

  /// All stored workspace display names, keyed by workspace id.
  Future<Map<String, String>> listNames() {
    return _metaDb.withDb((db) {
      final rows = db.select('SELECT workspace_id, name FROM workspace_state');
      final out = <String, String>{};
      for (final row in rows) {
        final id = row['workspace_id'] as String?;
        final name = (row['name'] as String?)?.trim();
        if (id == null || id.isEmpty) continue;
        if (name == null || name.isEmpty) continue;
        out[id] = name;
      }
      return out;
    });
  }
}
