import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:vault/agent/agent_service.dart';
import 'package:vault/agent/agent_settings.dart';
import 'package:vault/agent/conversation_state.dart';
import 'package:vault/agent/conversation_store.dart';
import 'package:vault/agent/project_store.dart';
import 'package:vault/agent/vault_meta_db.dart';
import 'package:vault/sandbox/sandbox_models.dart';
import 'package:vault_agent_core/vault_agent_core.dart';

class _RecordingWorkspace extends _FakeWorkspace {
  final List<String> commands = [];

  @override
  Future<CommandResult> run(
    String cmd, {
    Map<String, String>? environment,
    Duration? timeout,
  }) async {
    commands.add(cmd);
    return const CommandResult(exitCode: 0, stdout: '', stderr: '');
  }
}

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
  Future<CommandResult> run(
    String cmd, {
    Map<String, String>? environment,
    Duration? timeout,
  }) async => const CommandResult(exitCode: 0, stdout: '', stderr: '');

  @override
  Future<void> writeGuestFile(
    String guestAbsolutePath,
    List<int> bytes,
  ) async {}

  @override
  Future<Uint8List?> readGuestFile(String guestAbsolutePath) async => null;

  @override
  Future<void> dispose() async {}
}

void main() {
  late Directory temp;
  late ConversationStore store;
  late String projectPath;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('vault_switch_');
    final metaPath = p.join(temp.path, 'vault_meta.db');
    final metaDb = VaultMetaDb.at(metaPath);
    store = ConversationStore(metaDb: metaDb);
    final projects = ProjectStore.local(
      metaDbPath: metaPath,
      guestRoot: p.join(temp.path, 'guest'),
    );
    final created = await projects.createProject(
      'ws-switch',
      conversationStore: store,
    );
    projectPath = created.path;
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
    final a = await store.ensureActive('ws-switch', projectPath);
    a.state.history.messages.add(UserMessage.text('会话甲'));
    await store.save('ws-switch', projectPath, a.state);

    final b = await store.create('ws-switch', projectPath);
    b.state.history.messages.add(UserMessage.text('会话乙'));
    await store.save('ws-switch', projectPath, b.state);

    final service = AgentService(
      workspace: _FakeWorkspace(),
      settings: settings,
      conversationStore: store,
      projectPath: projectPath,
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

    final index = await store.list('ws-switch', projectPath);
    expect(index.conversations.length, greaterThanOrEqualTo(3));
  });

  test('switchConversation restores head_tree_sha via guest git', () async {
    final a = await store.ensureActive('ws-switch', projectPath);
    a.state.history.messages.add(UserMessage.text('会话甲'));
    a.state.metadata[kHeadTreeShaMeta] = 'a' * 40;
    await store.save('ws-switch', projectPath, a.state);

    final b = await store.create('ws-switch', projectPath);
    b.state.history.messages.add(UserMessage.text('会话乙'));
    await store.save('ws-switch', projectPath, b.state);

    final workspace = _RecordingWorkspace();
    final service = AgentService(
      workspace: workspace,
      settings: settings,
      conversationStore: store,
      projectPath: projectPath,
      conversationId: b.state.sessionId,
      initialState: b.state,
    );

    await service.switchConversation(a.state.sessionId);
    expect(service.conversationId, a.state.sessionId);
    expect(
      workspace.commands.any((cmd) => cmd.contains('git read-tree')),
      isTrue,
    );
    expect(workspace.commands.any((cmd) => cmd.contains('a' * 40)), isTrue);
  });
}
