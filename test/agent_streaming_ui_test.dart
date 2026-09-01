import 'package:flutter_test/flutter_test.dart';
import 'package:vault/agent/agent_chat_event_applier.dart';
import 'package:vault/agent/agent_chat_model.dart';
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

  test('fullModelMessage does not replay text already flushed before tools', () async {
    final mapper = AgentStreamMapper(
      runningBackgroundJobs: () => const <BackgroundToolJob>[],
    );
    final buffer = StringBuffer();
    final applier = AgentChatEventApplier();

    Future<void> apply(StreamingEvent event) async {
      await for (final ui in mapper.map(event, buffer)) {
        applier.applyLive(ui);
      }
    }

    await apply(
      StreamingEvent(
        eventType: StreamingEventType.modelChunkMessage,
        data: ModelMessage(
          model: 'm',
          textOutput: '空项目，先建骨架。',
          functionCalls: [
            FunctionCall(
              id: 'c1',
              name: 'scaffold_site',
              arguments: '{"kind":"static"}',
            ),
          ],
        ),
      ),
    );
    await apply(
      StreamingEvent(
        eventType: StreamingEventType.fullModelMessage,
        data: ModelMessage(
          model: 'm',
          textOutput: '空项目，先建骨架。',
          timestamp: DateTime.utc(2026, 9, 1, 0, 40, 58)
              .microsecondsSinceEpoch,
          usage: ModelUsage(promptTokens: 100, completionTokens: 20),
          functionCalls: [
            FunctionCall(
              id: 'c1',
              name: 'scaffold_site',
              arguments: '{"kind":"static"}',
            ),
          ],
        ),
      ),
    );

    final assistants = applier.items
        .where((item) => item.kind == AgentChatKind.assistant)
        .toList();
    expect(assistants, hasLength(1));
    expect(assistants.single.text, '空项目，先建骨架。');
    expect(
      applier.items.where((item) => item.kind == AgentChatKind.tool),
      hasLength(1),
    );
  });

  test('fullModelMessage still shows text when nothing streamed this turn', () async {
    final mapper = AgentStreamMapper(
      runningBackgroundJobs: () => const <BackgroundToolJob>[],
    );
    final buffer = StringBuffer();
    final events = await mapper
        .map(
          StreamingEvent(
            eventType: StreamingEventType.fullModelMessage,
            data: ModelMessage(model: 'm', textOutput: '完成了'),
          ),
          buffer,
        )
        .toList();

    expect(
      events.whereType<AgentUiAssistantDelta>().single.text,
      '完成了',
    );
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
