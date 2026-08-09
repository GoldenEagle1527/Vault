import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vault/agent/conversation_store.dart';
import 'package:vault/sandbox/workspace_guest_fs.dart';
import 'package:vault_agent_core/vault_agent_core.dart';

void main() {
  late Directory temp;
  late ConversationStore store;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('vault_conv_');
    store = ConversationStore(fs: LocalDirWorkspaceGuestFs(temp.path));
  });

  tearDown(() async {
    if (await temp.exists()) {
      await temp.delete(recursive: true);
    }
  });

  test('ensureActive creates first conversation inside guest path', () async {
    final opened = await store.ensureActive('ws1');
    expect(opened.state.sessionId, isNotEmpty);
    expect(opened.state.metadata['workspaceId'], 'ws1');
    expect(opened.index.conversations, hasLength(1));
    expect(opened.index.activeConversationId, opened.state.sessionId);
    expect(opened.index.conversations.first.title, kNewConversationTitle);

    // LocalDir maps /root/.vault/... → {root}/ws1/root/.vault/...
    final expected = File(
      [
        temp.path,
        'ws1',
        'root',
        '.vault',
        'conversations',
        'index.json',
      ].join(Platform.pathSeparator),
    );
    expect(await expected.exists(), isTrue);
  });

  test('create adds second conversation and switches active', () async {
    final first = await store.ensureActive('ws1');
    final second = await store.create('ws1');
    expect(second.index.conversations, hasLength(2));
    expect(second.index.activeConversationId, second.state.sessionId);
    expect(second.state.sessionId, isNot(first.state.sessionId));
  });

  test('save updates title from first user message and reloads', () async {
    final opened = await store.ensureActive('ws1');
    final state = opened.state;
    state.history.messages.add(UserMessage.text('写个贪吃蛇游戏'));
    state.history.messages.add(
      ModelMessage(model: 'm', textOutput: '好的'),
    );
    await store.save('ws1', state);

    final index = await store.list('ws1');
    expect(index.conversations.first.title, '写个贪吃蛇游戏');
    expect(index.conversations.first.messageCount, 2);

    final loaded = await store.load('ws1', state.sessionId);
    expect(loaded.history.messages, hasLength(2));
    expect(loaded.isRunning, isFalse);
  });

  test('setActive and deleteConversation keep another conversation', () async {
    final a = await store.ensureActive('ws1');
    final b = await store.create('ws1');
    await store.setActive('ws1', a.state.sessionId);

    final after = await store.deleteConversation('ws1', b.state.sessionId);
    expect(after.conversations, hasLength(1));
    expect(after.conversations.single.id, a.state.sessionId);
    expect(after.activeConversationId, a.state.sessionId);
  });

  test('delete last conversation creates a fresh empty one', () async {
    final a = await store.ensureActive('ws1');
    final after = await store.deleteConversation('ws1', a.state.sessionId);
    expect(after.conversations, hasLength(1));
    expect(after.conversations.single.id, isNot(a.state.sessionId));
    expect(after.conversations.single.title, kNewConversationTitle);
  });

  test('deleteWorkspace removes conversation tree', () async {
    final opened = await store.ensureActive('ws1');
    await store.save(
      'ws1',
      opened.state..history.messages.add(UserMessage.text('hi')),
    );
    await store.deleteWorkspace('ws1');
    final summary = await store.peekWorkspaceSummary('ws1');
    expect(summary.conversationCount, 0);

    final again = await store.ensureActive('ws1');
    expect(again.index.conversations, hasLength(1));
    expect(again.state.history.messages, isEmpty);
  });

  test('peekWorkspaceSummary reports recent title and count', () async {
    final a = await store.ensureActive('ws1');
    a.state.history.messages.add(UserMessage.text('分析销售表'));
    await store.save('ws1', a.state);
    await store.create('ws1');

    final summary = await store.peekWorkspaceSummary('ws1');
    expect(summary.conversationCount, 2);
    expect(summary.recentTitle, isNotNull);
  });

  test('titleFromMessages truncates long text', () {
    final long = '一二三四五六七八九十一二三四五六七八九十一二三四五六七八九十';
    expect(long.length, greaterThan(24));
    final title = ConversationStore.titleFromMessages([
      UserMessage.text(long),
    ]);
    expect(title.endsWith('…'), isTrue);
    expect(title.length, lessThanOrEqualTo(25));
  });
}
