import 'package:flutter_test/flutter_test.dart';
import 'package:vault/agent/agent_service.dart';
import 'package:vault_agent_core/vault_agent_core.dart';

void main() {
  test('isVisibleAssistantText rejects blank model deltas', () {
    expect(AgentService.isVisibleAssistantText(null), isFalse);
    expect(AgentService.isVisibleAssistantText(''), isFalse);
    expect(AgentService.isVisibleAssistantText('   '), isFalse);
    expect(AgentService.isVisibleAssistantText('\n'), isFalse);
    expect(AgentService.isVisibleAssistantText('\n  \t'), isFalse);
    expect(AgentService.isVisibleAssistantText('好的'), isTrue);
  });

  test('stream mapper flushes assistant draft before tool calls', () async {
    final mapper = AgentStreamMapper(
      runningBackgroundJobs: () => const <BackgroundToolJob>[],
    );
    final buffer = StringBuffer('先检查');
    final events = await mapper
        .map(
          StreamingEvent(
            eventType: StreamingEventType.functionCallRequest,
            data: [
              FunctionCall(id: 'c1', name: 'shell', arguments: '{"cmd":"ls"}'),
            ],
          ),
          buffer,
        )
        .toList();

    expect(events, hasLength(3));
    expect(events[0], isA<AgentUiAssistantFinal>());
    expect((events[0] as AgentUiAssistantFinal).text, '先检查');
    expect(events[1], isA<AgentUiToolCall>());
    expect(events[2], isA<AgentUiStatus>());
    expect(buffer, isEmpty);
  });

  test('stream mapper maps completed background jobs', () {
    final mapper = AgentStreamMapper(
      runningBackgroundJobs: () => const <BackgroundToolJob>[],
    );
    final job = BackgroundToolJob(
      jobId: 'j1',
      callId: 'c1',
      toolName: 'shell',
      arguments: '{}',
      startedAt: DateTime.utc(2026),
      status: BackgroundToolJobStatus.completed,
      result: FunctionExecutionResult(
        id: 'c1',
        name: 'shell',
        isError: false,
        arguments: '{}',
        content: [TextPart('done')],
      ),
    );

    final events = mapper.mapBackgroundJobEvent(
      BackgroundToolJobEvent(
        kind: BackgroundToolJobEventKind.completed,
        job: job,
      ),
      runningJobCount: 0,
    );

    expect(events, hasLength(2));
    final completed = events.first as AgentUiToolBackgroundCompleted;
    expect(completed.result, 'done');
    expect(completed.isError, isFalse);
    expect((events.last as AgentUiStatus).message, '后台任务已完成');
  });
}
