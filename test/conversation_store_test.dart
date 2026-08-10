import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
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
    state.history.messages.add(
      ModelMessage(model: 'm', textOutput: '好的'),
    );
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

    final after =
        await store.deleteConversation('ws1', projectPath, b.state.sessionId);
    expect(after.conversations, hasLength(1));
    expect(after.conversations.single.id, a.state.sessionId);
    expect(after.activeConversationId, a.state.sessionId);
  });

  test('delete last conversation creates a fresh empty one', () async {
    final a = await store.ensureActive('ws1', projectPath);
    final after =
        await store.deleteConversation('ws1', projectPath, a.state.sessionId);
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

    final summary =
        await store.peekProjectsSummary('ws1', [projectPath, other.path]);
    expect(summary.projectCount, 2);
    expect(summary.conversationCount, greaterThanOrEqualTo(3));
    expect(summary.recentTitle, '乙');
  });

  test('workspaces are isolated in the same DB file', () async {
    final ws2 = await projects.createProject(
      'ws2',
      conversationStore: store,
    );
    final list1 = await store.list('ws1', projectPath);
    final list2 = await store.list('ws2', ws2.path);
    expect(list1.conversations, isNotEmpty);
    expect(list2.conversations, hasLength(1));
    expect(list1.conversations.first.id, isNot(list2.conversations.first.id));
  });
}
