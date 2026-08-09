import 'package:flutter_test/flutter_test.dart';
import 'package:vault/agent/agent_service.dart';
import 'package:vault_agent_core/vault_agent_core.dart';

void main() {
  test('uiEventsFromHistory maps user assistant and tools', () {
    final events = AgentService.uiEventsFromHistory([
      UserMessage.text('你好'),
      ModelMessage(
        model: 'm',
        textOutput: '我来执行',
        functionCalls: [
          FunctionCall(id: '1', name: 'shell', arguments: '{"cmd":"ls"}'),
        ],
      ),
      FunctionExecutionResultMessage(
        results: [
          FunctionExecutionResult(
            id: '1',
            name: 'shell',
            isError: false,
            arguments: '{"cmd":"ls"}',
            content: [TextPart('ok')],
          ),
        ],
      ),
      ModelMessage(model: 'm', textOutput: '完成了'),
    ]);

    expect(events, hasLength(5));
    expect(events[0], isA<AgentUiUserMessage>());
    expect((events[0] as AgentUiUserMessage).text, '你好');
    expect(events[1], isA<AgentUiAssistantFinal>());
    expect((events[1] as AgentUiAssistantFinal).text, '我来执行');
    expect(events[2], isA<AgentUiToolCall>());
    expect((events[2] as AgentUiToolCall).name, 'shell');
    expect(events[3], isA<AgentUiToolResult>());
    expect((events[3] as AgentUiToolResult).result, 'ok');
    expect(events[4], isA<AgentUiAssistantFinal>());
    expect((events[4] as AgentUiAssistantFinal).text, '完成了');
  });
}
