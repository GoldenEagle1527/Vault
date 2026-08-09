import 'dart:convert';

import 'package:uuid/uuid.dart';
import 'package:vault/sandbox/sandbox_models.dart';
import 'package:vault/sandbox/workspace_guest_fs.dart';
import 'package:vault_agent_core/vault_agent_core.dart';

/// Empty / untitled conversation label shown in the UI.
const kNewConversationTitle = '新会话';

/// Metadata for one Agent conversation inside a workspace.
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

/// Index of conversations for one workspace.
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
  });

  final int conversationCount;
  final String? recentTitle;
  final DateTime? recentUpdatedAt;
}

/// Persists multi-conversation Agent state **inside** the workspace Linux at
/// [kGuestConversationsDir] (`/root/.vault/conversations/`).
///
/// Note: [AgentState.sessionId] (engine field) stores the **conversationId**,
/// not the workspace id. Workspace id lives in `metadata['workspaceId']`.
class ConversationStore {
  ConversationStore({required WorkspaceGuestFs fs}) : _fs = fs;

  final WorkspaceGuestFs _fs;

  static const _indexFileName = 'index.json';
  static const _metaWorkspaceId = 'workspaceId';

  String get _indexPath => '$kGuestConversationsDir/$_indexFileName';

  String _statePath(String conversationId) =>
      '$kGuestConversationsDir/$conversationId.json';

  Future<WorkspaceConversationIndex> _readIndex(String workspaceId) async {
    final raw = await _fs.readUtf8(workspaceId, _indexPath);
    if (raw == null || raw.trim().isEmpty) {
      return WorkspaceConversationIndex.empty;
    }
    try {
      final json = jsonDecode(raw);
      if (json is Map<String, dynamic>) {
        return WorkspaceConversationIndex.fromJson(json);
      }
      if (json is Map) {
        return WorkspaceConversationIndex.fromJson(json.cast<String, dynamic>());
      }
    } catch (_) {
      // Corrupt index — treat as empty; next save will rewrite.
    }
    return WorkspaceConversationIndex.empty;
  }

  Future<void> _writeIndex(
    String workspaceId,
    WorkspaceConversationIndex index,
  ) async {
    await _fs.writeUtf8(
      workspaceId,
      _indexPath,
      const JsonEncoder.withIndent('  ').convert(index.toJson()),
    );
  }

  Future<void> _writeStateFile(String workspaceId, AgentState state) async {
    await _fs.writeUtf8(
      workspaceId,
      _statePath(state.sessionId),
      jsonEncode(state.toJson()),
    );
  }

  Future<WorkspaceConversationIndex> list(String workspaceId) async {
    return _readIndex(workspaceId);
  }

  /// Ensures the workspace has an active conversation; creates one if needed.
  Future<({WorkspaceConversationIndex index, AgentState state})> ensureActive(
    String workspaceId,
  ) async {
    var index = await _readIndex(workspaceId);
    final activeId = index.activeConversationId;
    final known = activeId != null &&
        index.conversations.any((c) => c.id == activeId);

    if (!known) {
      return create(workspaceId);
    }

    final state = await load(workspaceId, activeId);
    return (index: index, state: state);
  }

  Future<({WorkspaceConversationIndex index, AgentState state})> create(
    String workspaceId,
  ) async {
    final index = await _readIndex(workspaceId);
    final now = DateTime.now().toUtc();
    final id = const Uuid().v4().replaceAll('-', '').substring(0, 12);
    final info = ConversationInfo(
      id: id,
      title: kNewConversationTitle,
      createdAt: now,
      updatedAt: now,
      messageCount: 0,
    );
    final next = WorkspaceConversationIndex(
      activeConversationId: id,
      conversations: [info, ...index.conversations],
    );
    final state = AgentState(
      sessionId: id,
      metadata: {_metaWorkspaceId: workspaceId},
    );
    await _writeStateFile(workspaceId, state);
    await _writeIndex(workspaceId, next);
    return (index: next, state: state);
  }

  Future<AgentState> load(String workspaceId, String conversationId) async {
    final raw = await _fs.readUtf8(workspaceId, _statePath(conversationId));
    if (raw == null) {
      return AgentState(
        sessionId: conversationId,
        metadata: {_metaWorkspaceId: workspaceId},
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
      state.metadata[_metaWorkspaceId] = workspaceId;
      return state;
    } catch (_) {
      return AgentState(
        sessionId: conversationId,
        metadata: {_metaWorkspaceId: workspaceId},
      );
    }
  }

  Future<void> save(String workspaceId, AgentState state) async {
    state.metadata[_metaWorkspaceId] = workspaceId;
    state.isRunning = false;
    await _writeStateFile(workspaceId, state);

    final index = await _readIndex(workspaceId);
    final title = titleFromMessages(state.history.messages);
    final now = DateTime.now().toUtc();
    final count = state.history.messages.length;
    final conversations = [...index.conversations];
    final i = conversations.indexWhere((c) => c.id == state.sessionId);
    if (i >= 0) {
      conversations[i] = conversations[i].copyWith(
        title: title,
        updatedAt: now,
        messageCount: count,
      );
    } else {
      conversations.insert(
        0,
        ConversationInfo(
          id: state.sessionId,
          title: title,
          createdAt: now,
          updatedAt: now,
          messageCount: count,
        ),
      );
    }
    conversations.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    await _writeIndex(
      workspaceId,
      WorkspaceConversationIndex(
        activeConversationId:
            index.activeConversationId ?? state.sessionId,
        conversations: conversations,
      ),
    );
  }

  Future<void> setActive(String workspaceId, String conversationId) async {
    final index = await _readIndex(workspaceId);
    if (!index.conversations.any((c) => c.id == conversationId)) {
      throw StateError('会话不存在：$conversationId');
    }
    await _writeIndex(
      workspaceId,
      WorkspaceConversationIndex(
        activeConversationId: conversationId,
        conversations: index.conversations,
      ),
    );
  }

  Future<WorkspaceConversationIndex> deleteConversation(
    String workspaceId,
    String conversationId,
  ) async {
    final index = await _readIndex(workspaceId);
    final remaining =
        index.conversations.where((c) => c.id != conversationId).toList();
    await _fs.deletePath(workspaceId, _statePath(conversationId));

    if (remaining.isEmpty) {
      await _writeIndex(workspaceId, WorkspaceConversationIndex.empty);
      final created = await create(workspaceId);
      return created.index;
    }

    String? active = index.activeConversationId;
    if (active == conversationId) {
      active = remaining.first.id;
    }

    final next = WorkspaceConversationIndex(
      activeConversationId: active,
      conversations: remaining,
    );
    await _writeIndex(workspaceId, next);
    return next;
  }

  /// Removes conversation files inside the guest. No-op if the workspace Linux
  /// is already gone (e.g. after [SandboxProvider.destroy]).
  Future<void> deleteWorkspace(String workspaceId) async {
    try {
      await _fs.deletePath(
        workspaceId,
        kGuestConversationsDir,
        recursive: true,
      );
    } catch (_) {
      // Distro / rootfs may already be destroyed.
    }
  }

  Future<WorkspaceConversationSummary> peekWorkspaceSummary(
    String workspaceId,
  ) async {
    final index = await _readIndex(workspaceId);
    if (index.conversations.isEmpty) {
      return const WorkspaceConversationSummary(conversationCount: 0);
    }
    final sorted = [...index.conversations]
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    final recent = sorted.first;
    return WorkspaceConversationSummary(
      conversationCount: index.conversations.length,
      recentTitle: recent.title,
      recentUpdatedAt: recent.updatedAt,
    );
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
