import 'package:flutter_test/flutter_test.dart';
import 'package:vault/agent/agent_service.dart';
import 'package:vault/agent/agent_system_prompt.dart';
import 'package:vault/agent/ask_user.dart';
import 'package:vault/agent/chat_attachment.dart';
import 'package:vault/agent/present_file.dart';
import 'package:vault/sandbox/guest_media_kind.dart';
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

  test('uiEventsFromHistory maps model thought onto assistant final', () {
    final events = AgentService.uiEventsFromHistory([
      ModelMessage(model: 'm', thought: '先核对 diff', textOutput: '可以提交'),
    ]);

    expect(events, hasLength(1));
    final assistant = events.single as AgentUiAssistantFinal;
    expect(assistant.thought, '先核对 diff');
    expect(assistant.text, '可以提交');
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
          FunctionCall(
            id: 'c1',
            name: 'shell',
            arguments: '{"command":"sleep"}',
          ),
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

  test('uiEventsFromHistory maps background-task-result to system notice', () {
    final raw = buildBackgroundTaskResultMessage([
      BackgroundToolJob(
        jobId: 'j1',
        callId: 'c1',
        toolName: 'shell',
        arguments: '{}',
        startedAt: DateTime.utc(2026, 1, 1),
        status: BackgroundToolJobStatus.completed,
      ),
    ]);
    final events = AgentService.uiEventsFromHistory([UserMessage.text(raw)]);
    expect(events, hasLength(1));
    expect(events.single, isA<AgentUiSystemNotice>());
    final notice = events.single as AgentUiSystemNotice;
    expect(notice.text, '后台任务已结束');
    expect(notice.isError, isFalse);
  });

  test('uiEventsFromHistory maps ask_user call and result with indexes', () {
    const args = '{"questions":[{"id":"q","prompt":"？","options":["A"]}]}';
    final events = AgentService.uiEventsFromHistory([
      UserMessage.text('做个工具'),
      ModelMessage(
        model: 'm',
        functionCalls: [
          FunctionCall(id: 'a1', name: kAskUserToolName, arguments: args),
        ],
      ),
      FunctionExecutionResultMessage(
        results: [
          FunctionExecutionResult(
            id: 'a1',
            name: kAskUserToolName,
            isError: false,
            arguments: args,
            content: [TextPart('{"ok":true}')],
          ),
        ],
      ),
    ]);

    expect(events, hasLength(3));
    final user = events[0] as AgentUiUserMessage;
    expect(user.text, '做个工具');
    expect(user.historyIndex, 0);
    final call = events[1] as AgentUiToolCall;
    expect(call.name, kAskUserToolName);
    expect(call.historyIndex, 1);
    final result = events[2] as AgentUiToolResult;
    expect(result.name, kAskUserToolName);
    expect(result.result, '{"ok":true}');
    expect(result.historyIndex, 2);
  });

  test('uiEventsFromHistory strips Vault attachment prefix from user text', () {
    final stored = composeModelUserPrompt(
      userText: '看附件',
      attachmentContext: buildAttachmentContextMessage(['/root/inbox/a.png']),
    );
    final events = AgentService.uiEventsFromHistory([UserMessage.text(stored)]);
    expect(events, hasLength(1));
    expect(events.single, isA<AgentUiUserMessage>());
    expect((events.single as AgentUiUserMessage).text, '看附件');
    expect((events.single as AgentUiUserMessage).historyIndex, 0);
  });

  test('uiEventsFromHistory restores attachment metadata', () {
    final events = AgentService.uiEventsFromHistory([
      UserMessage(
        [TextPart('看图')],
        metadata: {
          'attachments': [
            const ChatAttachmentMeta(
              guestPath: '/root/projects/p1/inbox/shot.png',
              displayName: 'shot.png',
              kind: GuestMediaKind.image,
            ).toJson(),
          ],
        },
      ),
    ]);
    expect(events, hasLength(1));
    final user = events.single as AgentUiUserMessage;
    expect(user.text, '看图');
    expect(user.attachments, hasLength(1));
    expect(
      user.attachments.single.guestPath,
      '/root/projects/p1/inbox/shot.png',
    );
    expect(user.attachments.single.kind, GuestMediaKind.image);
  });

  test('uiEventsFromHistory restores present_file attachments', () {
    final payload = presentFilePayload(
      guestPath: '/root/projects/p1/out.csv',
      displayName: '表格.csv',
      kind: GuestMediaKind.text,
      size: 12,
    );
    final events = AgentService.uiEventsFromHistory([
      ModelMessage(
        model: 'm',
        functionCalls: [
          FunctionCall(
            id: 'pf1',
            name: kPresentFileToolName,
            arguments: '{"path":"/root/projects/p1/out.csv"}',
          ),
        ],
      ),
      FunctionExecutionResultMessage(
        results: [
          FunctionExecutionResult(
            id: 'pf1',
            name: kPresentFileToolName,
            isError: false,
            arguments: '{"path":"/root/projects/p1/out.csv"}',
            content: [TextPart('已展示文件\n${payload.toString()}')],
            metadata: payload,
          ),
        ],
      ),
    ]);

    expect(events, hasLength(2));
    final result = events[1] as AgentUiToolResult;
    expect(result.name, kPresentFileToolName);
    expect(result.attachments, hasLength(1));
    expect(result.attachments.single.guestPath, '/root/projects/p1/out.csv');
    expect(result.attachments.single.displayName, '表格.csv');
    expect(result.attachments.single.kind, GuestMediaKind.text);
  });

  test('uiEventsFromHistory parses present_file from result JSON only', () {
    const json =
        '{"present_file":true,"ok":true,"guestPath":"/root/shot.png",'
        '"displayName":"shot.png","kind":"image"}';
    final events = AgentService.uiEventsFromHistory([
      FunctionExecutionResultMessage(
        results: [
          FunctionExecutionResult(
            id: 'pf2',
            name: kPresentFileToolName,
            isError: false,
            arguments: '{}',
            content: [TextPart('已展示文件 /root/shot.png\n$json')],
          ),
        ],
      ),
    ]);
    final result = events.single as AgentUiToolResult;
    expect(result.attachments, hasLength(1));
    expect(result.attachments.single.guestPath, '/root/shot.png');
    expect(result.attachments.single.kind, GuestMediaKind.image);
  });
}
