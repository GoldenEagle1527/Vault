import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vault/agent/agent_service.dart';
import 'package:vault/agent/agent_settings.dart';
import 'package:vault/sandbox/sandbox_models.dart';
import 'package:vault_agent_core/vault_agent_core.dart';

class _FakeWorkspace implements SandboxWorkspace {
  @override
  String get workspaceId => 'hist-test';

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
  }) async => const CommandResult(exitCode: 0, stdout: '', stderr: '');

  @override
  Future<void> writeGuestFile(
    String guestAbsolutePath,
    List<int> bytes,
  ) async {}

  @override
  Future<void> dispose() async {}
}

AgentState _stateWithMessages(List<LLMMessage> messages) {
  return AgentState(
    sessionId: 's1',
    history: AgentMessageHistory(messages: messages),
  );
}

void main() {
  const settingsA = AgentSettings(
    apiBaseUrl: 'https://example.com/v1',
    apiKey: 'key-a',
    model: 'model-a',
  );
  const settingsB = AgentSettings(
    apiBaseUrl: 'https://example.com/v1',
    apiKey: 'key-b',
    model: 'model-b',
  );

  test('applySettings keeps conversation history across client rebuild', () {
    final prior = _stateWithMessages([
      UserMessage.text('写个贪吃蛇'),
      ModelMessage(model: 'model-a', textOutput: '已写好 snake.html'),
    ]);

    final service = AgentService(
      workspace: _FakeWorkspace(),
      settings: settingsA,
      initialState: prior,
    );
    expect(service.historyMessageCount, 2);

    service.applySettings(settingsB);
    expect(service.historyMessageCount, 2);

    service.ensureAgentForTest();
    expect(service.historyMessageCount, 2);
  });

  test('dispose clears pending history', () async {
    final service = AgentService(
      workspace: _FakeWorkspace(),
      settings: settingsA,
      initialState: _stateWithMessages([UserMessage.text('hi')]),
    );
    expect(service.historyMessageCount, 1);
    await service.dispose();
    expect(service.historyMessageCount, 0);
  });

  test('restoredUiEvents mirrors persisted messages', () {
    final service = AgentService(
      workspace: _FakeWorkspace(),
      settings: settingsA,
      initialState: _stateWithMessages([
        UserMessage.text('写个贪吃蛇'),
        ModelMessage(model: 'model-a', textOutput: '已写好'),
      ]),
      conversationId: 's1',
    );
    final events = service.restoredUiEvents;
    expect(events, hasLength(2));
    expect(service.conversationTitle, '写个贪吃蛇');
  });
}
