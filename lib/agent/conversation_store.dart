import 'dart:convert';

import 'package:uuid/uuid.dart';
import 'package:vault/agent/vault_meta_db.dart';
import 'package:vault_agent_core/vault_agent_core.dart';

/// Empty / untitled conversation label shown in the UI.
const kNewConversationTitle = '新会话';

/// Metadata for one Agent conversation inside a project.
class ConversationInfo {
  const ConversationInfo({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    required this.messageCount,
  });

  final String id;
  final String title;
  final DateTime createdAt;
  final DateTime updatedAt;
  final int messageCount;

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'updatedAt': updatedAt.toUtc().toIso8601String(),
        'messageCount': messageCount,
      };

  factory ConversationInfo.fromJson(Map<String, dynamic> json) {
    return ConversationInfo(
      id: json['id'] as String,
      title: (json['title'] as String?)?.trim().isNotEmpty == true
          ? (json['title'] as String).trim()
          : kNewConversationTitle,
      createdAt: DateTime.parse(json['createdAt'] as String),
      updatedAt: DateTime.parse(json['updatedAt'] as String),
      messageCount: (json['messageCount'] as num?)?.toInt() ?? 0,
    );
  }

  ConversationInfo copyWith({
    String? title,
    DateTime? updatedAt,
    int? messageCount,
  }) {
    return ConversationInfo(
      id: id,
      title: title ?? this.title,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      messageCount: messageCount ?? this.messageCount,
    );
  }
}

/// Index of conversations for one project.
class WorkspaceConversationIndex {
  const WorkspaceConversationIndex({
    required this.activeConversationId,
    required this.conversations,
  });

  final String? activeConversationId;
  final List<ConversationInfo> conversations;

  Map<String, dynamic> toJson() => {
        'activeConversationId': activeConversationId,
        'conversations': conversations.map((c) => c.toJson()).toList(),
      };

  factory WorkspaceConversationIndex.fromJson(Map<String, dynamic> json) {
    final list = (json['conversations'] as List? ?? const [])
        .map((e) => ConversationInfo.fromJson(e as Map<String, dynamic>))
        .toList();
    return WorkspaceConversationIndex(
      activeConversationId: json['activeConversationId'] as String?,
      conversations: list,
    );
  }

  static const empty = WorkspaceConversationIndex(
    activeConversationId: null,
    conversations: [],
  );
}

/// Lightweight summary for the home workspace list.
class WorkspaceConversationSummary {
  const WorkspaceConversationSummary({
    required this.conversationCount,
    this.recentTitle,
    this.recentUpdatedAt,
    this.projectCount = 0,
  });

  final int conversationCount;
  final String? recentTitle;
  final DateTime? recentUpdatedAt;
  final int projectCount;
}

/// Persists conversations in the host [VaultMetaDb], scoped by workspace + project.
///
/// Note: [AgentState.sessionId] stores the **conversationId**. Workspace /
/// project ids live in metadata. Agent shell cannot reach this database.
class ConversationStore {
  ConversationStore({required VaultMetaDb metaDb}) : _metaDb = metaDb;

  final VaultMetaDb _metaDb;

  static const _metaWorkspaceId = 'workspaceId';
  static const _metaProjectPath = 'projectPath';

  Map<String, dynamic> _meta(String workspaceId, String projectPath) => {
        _metaWorkspaceId: workspaceId,
        _metaProjectPath: projectPath,
      };

  Future<WorkspaceConversationIndex> _readIndex(
    String workspaceId,
    String projectPath,
  ) {
    return _metaDb.withDb((db) {
      final rows = db.select(
        'SELECT id, title, created_at, updated_at, message_count '
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

  Future<WorkspaceConversationIndex> list(
    String workspaceId,
    String projectPath,
  ) =>
      _readIndex(workspaceId, projectPath);

  /// Ensures the project has an active conversation; creates one if needed.
  Future<({WorkspaceConversationIndex index, AgentState state})> ensureActive(
    String workspaceId,
    String projectPath,
  ) async {
    var index = await _readIndex(workspaceId, projectPath);
    final activeId = index.activeConversationId;
    final known =
        activeId != null && index.conversations.any((c) => c.id == activeId);

    if (!known) {
      return create(workspaceId, projectPath);
    }

    final state = await load(workspaceId, projectPath, activeId);
    return (index: index, state: state);
  }

  Future<({WorkspaceConversationIndex index, AgentState state})> create(
    String workspaceId,
    String projectPath,
  ) async {
    final now = DateTime.now().toUtc();
    final id = const Uuid().v4().replaceAll('-', '').substring(0, 12);
    final state = AgentState(
      sessionId: id,
      metadata: _meta(workspaceId, projectPath),
    );
    final stateJson = jsonEncode(state.toJson());
    final createdAt = now.toIso8601String();

    await _metaDb.withDb((db) {
      db.execute(
        'INSERT INTO conversations '
        '(workspace_id, project_path, id, title, created_at, updated_at, '
        'message_count, state_json) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
        [
          workspaceId,
          projectPath,
          id,
          kNewConversationTitle,
          createdAt,
          createdAt,
          0,
          stateJson,
        ],
      );
      db.execute(
        'INSERT INTO project_state '
        '(workspace_id, project_path, active_conversation_id) VALUES (?, ?, ?) '
        'ON CONFLICT(workspace_id, project_path) DO UPDATE SET '
        'active_conversation_id = excluded.active_conversation_id',
        [workspaceId, projectPath, id],
      );
    });

    final index = await _readIndex(workspaceId, projectPath);
    return (index: index, state: state);
  }

  Future<AgentState> load(
    String workspaceId,
    String projectPath,
    String conversationId,
  ) async {
    final raw = await _metaDb.withDb((db) {
      final rows = db.select(
        'SELECT state_json FROM conversations '
        'WHERE workspace_id = ? AND project_path = ? AND id = ?',
        [workspaceId, projectPath, conversationId],
      );
      if (rows.isEmpty) return null;
      return rows.first['state_json'] as String;
    });

    if (raw == null) {
      return AgentState(
        sessionId: conversationId,
        metadata: _meta(workspaceId, projectPath),
      );
    }
    try {
      final json = jsonDecode(raw);
      final map = json is Map<String, dynamic>
          ? json
          : (json as Map).cast<String, dynamic>();
      final state = AgentState.fromJson(map);
      state.sessionId = conversationId;
      state.isRunning = false;
      state.metadata.addAll(_meta(workspaceId, projectPath));
      return state;
    } catch (_) {
      return AgentState(
        sessionId: conversationId,
        metadata: _meta(workspaceId, projectPath),
      );
    }
  }

  Future<void> save(
    String workspaceId,
    String projectPath,
    AgentState state,
  ) async {
    state.metadata.addAll(_meta(workspaceId, projectPath));
    state.isRunning = false;
    final title = titleFromMessages(state.history.messages);
    final now = DateTime.now().toUtc();
    final count = state.history.messages.length;
    final stateJson = jsonEncode(state.toJson());

    await _metaDb.withDb((db) {
      final existing = db.select(
        'SELECT id, created_at FROM conversations '
        'WHERE workspace_id = ? AND project_path = ? AND id = ?',
        [workspaceId, projectPath, state.sessionId],
      );
      if (existing.isEmpty) {
        db.execute(
          'INSERT INTO conversations '
          '(workspace_id, project_path, id, title, created_at, updated_at, '
          'message_count, state_json) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
          [
            workspaceId,
            projectPath,
            state.sessionId,
            title,
            now.toIso8601String(),
            now.toIso8601String(),
            count,
            stateJson,
          ],
        );
      } else {
        db.execute(
          'UPDATE conversations SET title = ?, updated_at = ?, '
          'message_count = ?, state_json = ? '
          'WHERE workspace_id = ? AND project_path = ? AND id = ?',
          [
            title,
            now.toIso8601String(),
            count,
            stateJson,
            workspaceId,
            projectPath,
            state.sessionId,
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
          [workspaceId, projectPath, state.sessionId],
        );
      }
    });
  }

  Future<void> setActive(
    String workspaceId,
    String projectPath,
    String conversationId,
  ) async {
    await _metaDb.withDb((db) {
      final rows = db.select(
        'SELECT id FROM conversations '
        'WHERE workspace_id = ? AND project_path = ? AND id = ?',
        [workspaceId, projectPath, conversationId],
      );
      if (rows.isEmpty) {
        throw StateError('会话不存在：$conversationId');
      }
      db.execute(
        'INSERT INTO project_state '
        '(workspace_id, project_path, active_conversation_id) VALUES (?, ?, ?) '
        'ON CONFLICT(workspace_id, project_path) DO UPDATE SET '
        'active_conversation_id = excluded.active_conversation_id',
        [workspaceId, projectPath, conversationId],
      );
    });
  }

  Future<WorkspaceConversationIndex> deleteConversation(
    String workspaceId,
    String projectPath,
    String conversationId,
  ) async {
    final index = await _readIndex(workspaceId, projectPath);
    await _metaDb.withDb((db) {
      db.execute(
        'DELETE FROM conversations '
        'WHERE workspace_id = ? AND project_path = ? AND id = ?',
        [workspaceId, projectPath, conversationId],
      );
    });

    final remaining =
        index.conversations.where((c) => c.id != conversationId).toList();
    if (remaining.isEmpty) {
      await _metaDb.withDb((db) {
        db.execute(
          'DELETE FROM project_state WHERE workspace_id = ? AND project_path = ?',
          [workspaceId, projectPath],
        );
      });
      final created = await create(workspaceId, projectPath);
      return created.index;
    }

    String? active = index.activeConversationId;
    if (active == conversationId) {
      active = remaining.first.id;
    }
    await setActive(workspaceId, projectPath, active!);
    return _readIndex(workspaceId, projectPath);
  }

  /// Removes all host DB rows for [workspaceId].
  Future<void> deleteWorkspace(String workspaceId) async {
    await _metaDb.deleteWorkspace(workspaceId);
  }

  /// Aggregate conversation stats across [projectPaths].
  Future<WorkspaceConversationSummary> peekProjectsSummary(
    String workspaceId,
    List<String> projectPaths,
  ) async {
    if (projectPaths.isEmpty) {
      return const WorkspaceConversationSummary(
        conversationCount: 0,
        projectCount: 0,
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
          final c = ConversationInfo(
            id: row['id'] as String,
            title: row['title'] as String,
            createdAt: DateTime.parse(row['created_at'] as String),
            updatedAt: DateTime.parse(row['updated_at'] as String),
            messageCount: (row['message_count'] as num).toInt(),
          );
          if (recent == null || c.updatedAt.isAfter(recent.updatedAt)) {
            recent = c;
          }
        }
      }
      if (recent == null) {
        return WorkspaceConversationSummary(
          conversationCount: total,
          projectCount: projectPaths.length,
        );
      }
      return WorkspaceConversationSummary(
        conversationCount: total,
        recentTitle: recent.title,
        recentUpdatedAt: recent.updatedAt,
        projectCount: projectPaths.length,
      );
    });
  }

  /// Derive a short title from the first user message text.
  static String titleFromMessages(List<LLMMessage> messages) {
    for (final m in messages) {
      if (m is! UserMessage) continue;
      final text = m.contents
          .whereType<TextPart>()
          .map((p) => p.text)
          .join('\n')
          .trim();
      if (text.isEmpty) continue;
      final forTitle = text
          .split('\n')
          .where((line) => !line.trimLeft().startsWith('[Vault'))
          .join(' ')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      if (forTitle.isEmpty) continue;
      if (forTitle.length <= 24) return forTitle;
      return '${forTitle.substring(0, 24)}…';
    }
    return kNewConversationTitle;
  }
}
