import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vault/agent/agent_service.dart';
import 'package:vault/agent/agent_settings.dart';
import 'package:vault/agent/conversation_store.dart';
import 'package:vault/sandbox/sandbox_models.dart';
import 'package:vault/sandbox/workspace_guest_fs.dart';
import 'package:vault_agent_core/vault_agent_core.dart';

class _FakeWorkspace implements SandboxWorkspace {
  @override
  String get workspaceId => 'ws-switch';

  @override
  Stream<Uint8List> get output => const Stream.empty();

  @override
  void write(String data) {}

  @override
  void writeBytes(Uint8List data) {}

  @override
  void resize(int cols, int rows) {}

  @override
  Future<int> get exitCode => Future.value(0);

  @override
  Future<CommandResult> run(String cmd) async =>
      const CommandResult(exitCode: 0, stdout: '', stderr: '');

  @override
  Future<void> writeGuestFile(String guestAbsolutePath, List<int> bytes) async {}

  @override
  Future<void> dispose() async {}
}

void main() {
  late Directory temp;
  late ConversationStore store;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('vault_switch_');
    store = ConversationStore(fs: LocalDirWorkspaceGuestFs(temp.path));
  });

  tearDown(() async {
    if (await temp.exists()) {
      await temp.delete(recursive: true);
    }
  });

  const settings = AgentSettings(
    apiBaseUrl: 'https://example.com/v1',
    apiKey: 'k',
    model: 'm',
  );

  test('switchConversation isolates histories per conversation', () async {
    final a = await store.ensureActive('ws-switch');
    a.state.history.messages.add(UserMessage.text('会话甲'));
    await store.save('ws-switch', a.state);

    final b = await store.create('ws-switch');
    b.state.history.messages.add(UserMessage.text('会话乙'));
    await store.save('ws-switch', b.state);

    final service = AgentService(
      workspace: _FakeWorkspace(),
      settings: settings,
      conversationStore: store,
      conversationId: b.state.sessionId,
      initialState: b.state,
    );
    expect(service.conversationTitle, '会话乙');

    await service.switchConversation(a.state.sessionId);
    expect(service.conversationId, a.state.sessionId);
    expect(service.historyMessageCount, 1);
    expect(service.conversationTitle, '会话甲');

    await service.newConversation();
    expect(service.historyMessageCount, 0);
    expect(service.conversationTitle, kNewConversationTitle);

    final index = await store.list('ws-switch');
    expect(index.conversations.length, greaterThanOrEqualTo(3));
  });
}
