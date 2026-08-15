import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:vault/agent/conversation_state.dart';
import 'package:vault/agent/conversation_store.dart';
import 'package:vault/agent/project_store.dart';
import 'package:vault/agent/vault_meta_db.dart';
import 'package:vault_agent_core/vault_agent_core.dart';

void main() {
  late Directory temp;
  late VaultMetaDb metaDb;
  late ProjectStore projects;
  late ConversationStore store;
  late String projectPath;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('vault_conv_');
    metaDb = VaultMetaDb.at(p.join(temp.path, 'vault_meta.db'));
    projects = ProjectStore.local(
      metaDbPath: metaDb.filePath,
      guestRoot: p.join(temp.path, 'guest'),
    );
    store = ConversationStore(metaDb: metaDb);
    final created = await projects.createProject(
      'ws1',
      conversationStore: store,
    );
    projectPath = created.path;
  });

  tearDown(() async {
    if (await temp.exists()) {
      await temp.delete(recursive: true);
    }
  });

  test('ensureActive creates first conversation in host DB', () async {
    // createProject already ensured one conversation
    final opened = await store.ensureActive('ws1', projectPath);
    expect(opened.state.sessionId, isNotEmpty);
    expect(opened.state.metadata['workspaceId'], 'ws1');
    expect(opened.state.metadata['projectPath'], projectPath);
    expect(opened.index.conversations, hasLength(1));
    expect(opened.index.activeConversationId, opened.state.sessionId);
    expect(opened.index.conversations.first.title, kNewConversationTitle);
    expect(await File(metaDb.filePath).exists(), isTrue);
  });

  test('create adds second conversation and switches active', () async {
    final first = await store.ensureActive('ws1', projectPath);
    final second = await store.create('ws1', projectPath);
    expect(second.index.conversations, hasLength(2));
    expect(second.index.activeConversationId, second.state.sessionId);
    expect(second.state.sessionId, isNot(first.state.sessionId));
  });

  test('save updates title from first user message and reloads', () async {
    final opened = await store.ensureActive('ws1', projectPath);
    final state = opened.state;
    state.history.messages.add(UserMessage.text('写个贪吃蛇游戏'));
    state.history.messages.add(ModelMessage(model: 'm', textOutput: '好的'));
    await store.save('ws1', projectPath, state);

    final index = await store.list('ws1', projectPath);
    expect(index.conversations.first.title, '写个贪吃蛇游戏');
    expect(index.conversations.first.messageCount, 2);

    final loaded = await store.load('ws1', projectPath, state.sessionId);
    expect(loaded.history.messages, hasLength(2));
    expect(loaded.isRunning, isFalse);
  });

  test('setActive and deleteConversation keep another conversation', () async {
    final a = await store.ensureActive('ws1', projectPath);
    final b = await store.create('ws1', projectPath);
    await store.setActive('ws1', projectPath, a.state.sessionId);

    final after = await store.deleteConversation(
      'ws1',
      projectPath,
      b.state.sessionId,
    );
    expect(after.conversations, hasLength(1));
    expect(after.conversations.single.id, a.state.sessionId);
    expect(after.activeConversationId, a.state.sessionId);
  });

  test('delete last conversation creates a fresh empty one', () async {
    final a = await store.ensureActive('ws1', projectPath);
    final after = await store.deleteConversation(
      'ws1',
      projectPath,
      a.state.sessionId,
    );
    expect(after.conversations, hasLength(1));
    expect(after.conversations.single.id, isNot(a.state.sessionId));
    expect(after.conversations.single.title, kNewConversationTitle);
  });

  test('deleteWorkspace removes host rows for workspace', () async {
    final opened = await store.ensureActive('ws1', projectPath);
    await store.save(
      'ws1',
      projectPath,
      opened.state..history.messages.add(UserMessage.text('hi')),
    );
    await store.deleteWorkspace('ws1');
    final summary = await store.peekProjectsSummary('ws1', [projectPath]);
    expect(summary.conversationCount, 0);
  });

  test('peekProjectsSummary aggregates across projects', () async {
    final a = await store.ensureActive('ws1', projectPath);
    a.state.history.messages.add(UserMessage.text('甲'));
    await store.save('ws1', projectPath, a.state);
    await store.create('ws1', projectPath);

    final other = await projects.createProject(
      'ws1',
      name: '另一项目',
      conversationStore: store,
    );
    final b = await store.ensureActive('ws1', other.path);
    b.state.history.messages.add(UserMessage.text('乙'));
    await store.save('ws1', other.path, b.state);

    final summary = await store.peekProjectsSummary('ws1', [
      projectPath,
      other.path,
    ]);
    expect(summary.projectCount, 2);
    expect(summary.conversationCount, greaterThanOrEqualTo(3));
    expect(summary.recentTitle, '乙');
  });

  test('workspaces are isolated in the same DB file', () async {
    final ws2 = await projects.createProject('ws2', conversationStore: store);
    final list1 = await store.list('ws1', projectPath);
    final list2 = await store.list('ws2', ws2.path);
    expect(list1.conversations, isNotEmpty);
    expect(list2.conversations, hasLength(1));
    expect(list1.conversations.first.id, isNot(list2.conversations.first.id));
  });

  test(
    'fork truncates history, records parent, and treeOrder indents',
    () async {
      final opened = await store.ensureActive('ws1', projectPath);
      final parent = opened.state;
      parent.history.messages.addAll([
        UserMessage.text('第一问'),
        ModelMessage(model: 'm', textOutput: '答1'),
        UserMessage.text('第二问'),
        ModelMessage(model: 'm', textOutput: '答2'),
      ]);
      parent.systemPromptHistory = [
        SystemPromptHistoryItem(content: 'early', validFromMessageIndex: 0),
        SystemPromptHistoryItem(content: 'late', validFromMessageIndex: 3),
      ];
      parent.plan = PlanState(steps: [PlanStep(description: 'do')]);
      recordCheckpoint(
        parent,
        index: 0,
        sha: 'a' * 40,
        kind: kCheckpointUserTurn,
      );
      recordCheckpoint(
        parent,
        index: 2,
        sha: 'b' * 40,
        kind: kCheckpointUserTurn,
      );
      recordCheckpoint(
        parent,
        index: 4,
        sha: 'c' * 40,
        kind: kCheckpointTurnEnd,
      );
      await store.save('ws1', projectPath, parent);

      final forked = await store.fork(
        workspaceId: 'ws1',
        projectPath: projectPath,
        parentState: parent,
        keepCount: 2,
        forkedFromMessageIndex: 2,
      );

      expect(forked.state.sessionId, isNot(parent.sessionId));
      expect(forked.state.history.messages, hasLength(2));
      expect(forked.state.plan, isNull);
      expect(forked.state.systemPromptHistory, hasLength(1));
      expect(forked.state.systemPromptHistory.single.validFromMessageIndex, 0);
      expect(readCheckpoints(forked.state).every((c) => c.index < 2), isTrue);
      expect(forked.index.activeConversationId, forked.state.sessionId);

      final childInfo = forked.index.conversations.firstWhere(
        (c) => c.id == forked.state.sessionId,
      );
      expect(childInfo.parentId, parent.sessionId);
      expect(childInfo.forkedFromMessageIndex, 2);
      expect(childInfo.isBranch, isTrue);

      final tree = ConversationStore.treeOrder(forked.index.conversations);
      final childNode = tree.firstWhere(
        (n) => n.info.id == forked.state.sessionId,
      );
      expect(childNode.depth, 1);
      expect(tree.firstWhere((n) => n.info.id == parent.sessionId).depth, 0);
    },
  );

  test('delete child keeps parent; delete parent unlinks child', () async {
    final opened = await store.ensureActive('ws1', projectPath);
    final parent = opened.state;
    parent.history.messages.add(UserMessage.text('根会话'));
    await store.save('ws1', projectPath, parent);

    final child = await store.fork(
      workspaceId: 'ws1',
      projectPath: projectPath,
      parentState: parent,
      keepCount: 1,
      forkedFromMessageIndex: 0,
    );
    final grandchild = await store.fork(
      workspaceId: 'ws1',
      projectPath: projectPath,
      parentState: child.state,
      keepCount: 1,
      forkedFromMessageIndex: 0,
    );

    final afterChild = await store.deleteConversation(
      'ws1',
      projectPath,
      grandchild.state.sessionId,
    );
    expect(
      afterChild.conversations.any((c) => c.id == grandchild.state.sessionId),
      isFalse,
    );
    expect(
      afterChild.conversations.any((c) => c.id == parent.sessionId),
      isTrue,
    );
    expect(
      afterChild.conversations.any((c) => c.id == child.state.sessionId),
      isTrue,
    );

    final afterParent = await store.deleteConversation(
      'ws1',
      projectPath,
      parent.sessionId,
    );
    expect(
      afterParent.conversations.any((c) => c.id == parent.sessionId),
      isFalse,
    );
    final orphan = afterParent.conversations.firstWhere(
      (c) => c.id == child.state.sessionId,
    );
    expect(orphan.parentId, isNull);
    expect(orphan.isBranch, isFalse);
  });

  test('branchesAt lists siblings that share a fork point', () {
    final parent = ConversationInfo(
      id: 'p',
      title: '根',
      createdAt: DateTime.utc(2026, 1, 1),
      updatedAt: DateTime.utc(2026, 1, 2),
      messageCount: 2,
    );
    final a = ConversationInfo(
      id: 'a',
      title: '分支A',
      createdAt: DateTime.utc(2026, 1, 3),
      updatedAt: DateTime.utc(2026, 1, 3),
      messageCount: 1,
      parentId: 'p',
      forkedFromMessageIndex: 0,
    );
    final b = ConversationInfo(
      id: 'b',
      title: '分支B',
      createdAt: DateTime.utc(2026, 1, 4),
      updatedAt: DateTime.utc(2026, 1, 4),
      messageCount: 1,
      parentId: 'p',
      forkedFromMessageIndex: 0,
    );
    final other = ConversationInfo(
      id: 'c',
      title: '另一处',
      createdAt: DateTime.utc(2026, 1, 5),
      updatedAt: DateTime.utc(2026, 1, 5),
      messageCount: 1,
      parentId: 'p',
      forkedFromMessageIndex: 2,
    );
    final list = [parent, a, b, other];
    final fromParent = store.branchesAt(
      conversations: list,
      currentId: 'p',
      messageIndex: 0,
    );
    expect(fromParent.map((c) => c.id), containsAll(['a', 'b']));
    expect(fromParent.map((c) => c.id), isNot(contains('c')));

    final fromA = store.branchesAt(
      conversations: list,
      currentId: 'a',
      messageIndex: 0,
    );
    expect(fromA.map((c) => c.id), containsAll(['p', 'b']));
    expect(fromA.map((c) => c.id), isNot(contains('a')));
  });
}
