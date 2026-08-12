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

  test('uiEventsFromHistory maps usage onto assistant and prior user', () {
    const t0 = 1 * 1000 * 1000;
    const t1 = 3 * 1000 * 1000;
    final events = AgentService.uiEventsFromHistory([
      UserMessage([TextPart('问')], timestamp: t0),
      ModelMessage(
        model: 'm',
        textOutput: '答',
        timestamp: t1,
        usage: ModelUsage(
          promptTokens: 1200,
          completionTokens: 45,
          totalTokens: 1245,
          timestamp: t1,
        ),
      ),
    ]);

    expect(events, hasLength(2));
    final user = events[0] as AgentUiUserMessage;
    expect(user.promptTokens, 1200);
    expect(user.at, DateTime.fromMicrosecondsSinceEpoch(t0));

    final assistant = events[1] as AgentUiAssistantFinal;
    expect(assistant.promptTokens, 1200);
    expect(assistant.completionTokens, 45);
    expect(assistant.totalTokens, 1245);
    expect(assistant.duration, const Duration(seconds: 2));
  });

  test('uiEventsFromHistory maps background tool stub', () {
    final events = AgentService.uiEventsFromHistory([
      ModelMessage(
        model: 'm',
        functionCalls: [
          FunctionCall(id: 'c1', name: 'shell', arguments: '{"command":"sleep"}'),
        ],
      ),
      FunctionExecutionResultMessage(
        results: [
          FunctionExecutionResult(
            id: 'c1',
            name: 'shell',
            isError: false,
            arguments: '{"command":"sleep"}',
            content: [TextPart('已转后台')],
            metadata: {'background': true, 'jobId': 'job-1', 'callId': 'c1'},
          ),
        ],
      ),
    ]);

    expect(events, hasLength(2));
    expect(events[0], isA<AgentUiToolCall>());
    expect(events[1], isA<AgentUiToolBackgrounded>());
    final bg = events[1] as AgentUiToolBackgrounded;
    expect(bg.jobId, 'job-1');
    expect(bg.callId, 'c1');
    expect(bg.stubResult, '已转后台');
  });
}
