import 'package:flutter_test/flutter_test.dart';
import 'package:vault/agent/agent_screen_policy.dart';
import 'package:vault/agent/agent_service.dart';
import 'package:vault/agent/agent_site_controller.dart';

void main() {
  test('AgentScreen event mapping keeps every service event category', () {
    const events = <AgentUiEvent>[
      AgentUiUserMessage('user'),
      AgentUiSystemNotice('notice'),
      AgentUiAssistantDelta('delta'),
      AgentUiAssistantFinal('final'),
      AgentUiModelUsage(promptTokens: 1, completionTokens: 2),
      AgentUiDiscardDraftAssistant(),
      AgentUiToolCall(name: 'tool', arguments: '{}'),
      AgentUiToolResult(name: 'tool', result: 'ok'),
      AgentUiConversationForked('fork'),
      AgentUiToolBackgrounded(
        name: 'tool',
        jobId: 'job',
        callId: 'call',
        stubResult: 'running',
      ),
      AgentUiToolBackgroundCompleted(
        name: 'tool',
        jobId: 'job',
        callId: 'call',
        result: 'done',
        isError: false,
      ),
      AgentUiShellNotify(
        jobId: 'job',
        callId: 'call',
        regex: 'ready',
        matchText: 'ready',
      ),
      AgentUiError('error'),
      AgentUiStatus('status'),
    ];

    expect(events.map(classifyAgentScreenEvent), AgentScreenEventKind.values);
    expect(
      coalesceAgentChatUiFlush(const AgentUiAssistantDelta('delta')),
      isTrue,
    );
    expect(
      coalesceAgentChatUiFlush(const AgentUiAssistantFinal('final')),
      isFalse,
    );
    expect(
      coalesceAgentChatUiFlush(
        const AgentUiToolCall(name: 't', arguments: '{}'),
      ),
      isFalse,
    );
  });

  test('AgentScreen status mapping preserves placeholder behavior', () {
    for (final message in [
      '正在思考…',
      '正在调用模型…',
      '运行中…',
      '后台任务结果已送达，正在继续…',
      'shell 匹配通知已送达，正在继续…',
      'shell 输出已匹配，准备唤醒模型…',
    ]) {
      expect(
        agentScreenStatusDisposition(message),
        AgentScreenStatusDisposition.thinking,
      );
    }
    expect(
      agentScreenStatusDisposition('已完成'),
      AgentScreenStatusDisposition.completed,
    );
    expect(
      agentScreenStatusDisposition('正在保存…'),
      AgentScreenStatusDisposition.visible,
    );
    expect(
      agentScreenStatusDisposition('正在执行工具：shell'),
      AgentScreenStatusDisposition.hidden,
    );
  });

  test('stale site probe cannot overwrite a newer probe', () {
    final guard = SiteProbeGenerationGuard();
    final stale = guard.tryBegin()!;

    guard.invalidate();
    final current = guard.tryBegin()!;

    expect(guard.canApply(stale), isFalse);
    expect(guard.canApply(current), isTrue);

    guard.finish(stale);
    expect(guard.inFlight, isTrue);
    expect(guard.tryBegin(), isNull);

    guard.finish(current);
    expect(guard.inFlight, isFalse);
  });
}
