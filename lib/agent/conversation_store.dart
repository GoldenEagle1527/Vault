import 'dart:convert';

import 'package:uuid/uuid.dart';
import 'package:vault/agent/conversation_models.dart';
import 'package:vault/agent/conversation_sqlite_repository.dart';
import 'package:vault/agent/conversation_state.dart';
import 'package:vault/agent/vault_meta_db.dart';
import 'package:vault_agent_core/vault_agent_core.dart';

export 'package:vault/agent/conversation_models.dart';

/// Conversation lifecycle facade, scoped by workspace + project.
///
/// [AgentState.sessionId] stores the conversation id. Workspace and project
/// ids remain in metadata; SQLite details are isolated in the repository.
class ConversationStore {
  ConversationStore({required VaultMetaDb metaDb})
    : _repository = ConversationSqliteRepository(metaDb);

  final ConversationSqliteRepository _repository;

  static const _metaWorkspaceId = 'workspaceId';
  static const _metaProjectPath = 'projectPath';

  Map<String, dynamic> _meta(String workspaceId, String projectPath) => {
    _metaWorkspaceId: workspaceId,
    _metaProjectPath: projectPath,
  };

  Future<WorkspaceConversationIndex> list(
    String workspaceId,
    String projectPath,
  ) => _repository.readIndex(workspaceId, projectPath);

  Future<({WorkspaceConversationIndex index, AgentState state})> ensureActive(
    String workspaceId,
    String projectPath,
  ) async {
    final index = await _repository.readIndex(workspaceId, projectPath);
    final activeId = index.activeConversationId;
    final known =
        activeId != null && index.conversations.any((c) => c.id == activeId);
    if (!known) return create(workspaceId, projectPath);
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
    await _repository.insert(
      workspaceId: workspaceId,
      projectPath: projectPath,
      id: id,
      title: kNewConversationTitle,
      createdAt: now.toIso8601String(),
      messageCount: 0,
      stateJson: jsonEncode(state.toJson()),
    );
    return (
      index: await _repository.readIndex(workspaceId, projectPath),
      state: state,
    );
  }

  Future<AgentState> load(
    String workspaceId,
    String projectPath,
    String conversationId,
  ) async {
    final raw = await _repository.readStateJson(
      workspaceId,
      projectPath,
      conversationId,
    );
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
    final now = DateTime.now().toUtc().toIso8601String();
    await _repository.save(
      workspaceId: workspaceId,
      projectPath: projectPath,
      id: state.sessionId,
      title: titleFromMessages(state.history.messages),
      updatedAt: now,
      messageCount: state.history.messages.length,
      stateJson: jsonEncode(state.toJson()),
      headTreeSha: headTreeShaOf(state),
    );
  }

  Future<void> setActive(
    String workspaceId,
    String projectPath,
    String conversationId,
  ) => _repository.setActive(workspaceId, projectPath, conversationId);

  Future<WorkspaceConversationIndex> deleteConversation(
    String workspaceId,
    String projectPath,
    String conversationId,
  ) async {
    final index = await _repository.readIndex(workspaceId, projectPath);
    await _repository.delete(workspaceId, projectPath, conversationId);
    final remaining = index.conversations
        .where((c) => c.id != conversationId)
        .toList();
    if (remaining.isEmpty) {
      await _repository.deleteProjectState(workspaceId, projectPath);
      return (await create(workspaceId, projectPath)).index;
    }
    var active = index.activeConversationId;
    if (active == conversationId) active = remaining.first.id;
    await setActive(workspaceId, projectPath, active!);
    return _repository.readIndex(workspaceId, projectPath);
  }

  Future<({WorkspaceConversationIndex index, AgentState state})> fork({
    required String workspaceId,
    required String projectPath,
    required AgentState parentState,
    required int keepCount,
    required int forkedFromMessageIndex,
    void Function(AgentState forked)? mutate,
  }) async {
    final forked = truncateAgentState(parentState, keepCount);
    mutate?.call(forked);
    final now = DateTime.now().toUtc();
    final id = const Uuid().v4().replaceAll('-', '').substring(0, 12);
    forked.sessionId = id;
    forked.isRunning = false;
    forked.metadata.addAll(_meta(workspaceId, projectPath));
    await _repository.insert(
      workspaceId: workspaceId,
      projectPath: projectPath,
      id: id,
      title: titleFromMessages(forked.history.messages),
      createdAt: now.toIso8601String(),
      messageCount: forked.history.messages.length,
      stateJson: jsonEncode(forked.toJson()),
      parentId: parentState.sessionId,
      forkedFromMessageIndex: forkedFromMessageIndex,
      headTreeSha: headTreeShaOf(forked),
    );
    return (
      index: await _repository.readIndex(workspaceId, projectPath),
      state: forked,
    );
  }

  List<ConversationInfo> branchesAt({
    required List<ConversationInfo> conversations,
    required String currentId,
    required int messageIndex,
  }) => conversationBranchesAt(
    conversations: conversations,
    currentId: currentId,
    messageIndex: messageIndex,
  );

  static List<({ConversationInfo info, int depth})> treeOrder(
    List<ConversationInfo> conversations,
  ) => orderConversationTree(conversations);

  Future<void> deleteWorkspace(String workspaceId) =>
      _repository.deleteWorkspace(workspaceId);

  Future<WorkspaceConversationSummary> peekProjectsSummary(
    String workspaceId,
    List<String> projectPaths,
  ) => _repository.summary(workspaceId, projectPaths);

  static String titleFromMessages(List<LLMMessage> messages) =>
      conversationTitleFromMessages(messages);
}
