import 'package:flutter_test/flutter_test.dart';
import 'package:vault/agent/agent_chat_event_applier.dart';
import 'package:vault/agent/agent_chat_model.dart';
import 'package:vault/agent/agent_service.dart';
import 'package:vault/agent/chat_attachment.dart';
import 'package:vault/agent/present_file.dart';
import 'package:vault/sandbox/guest_media_kind.dart';

void main() {
  test('live deltas replace thinking placeholder and accumulate text', () {
    final applier = AgentChatEventApplier();

    applier.applyLive(const AgentUiStatus('正在思考…'));
    expect(applier.items.single.thinkingPlaceholder, isTrue);

    applier.applyLive(const AgentUiAssistantDelta('你好'));
    applier.applyLive(const AgentUiAssistantDelta('！'));

    expect(applier.items, hasLength(1));
    expect(applier.items.single.kind, AgentChatKind.assistant);
    expect(applier.items.single.text, '你好！');
    expect(applier.items.single.thinkingPlaceholder, isFalse);
  });

  test(
    'tool result is attached by call id and emits project refresh effect',
    () {
      var refreshCount = 0;
      final applier = AgentChatEventApplier(
        onProjectUrlRegistered: () => refreshCount++,
      );

      applier.applyLive(
        const AgentUiToolCall(
          name: 'register_project_url',
          arguments: '{"url":"http://localhost:3000"}',
          callId: 'call-1',
        ),
      );
      applier.applyLive(
        const AgentUiToolResult(
          name: 'register_project_url',
          result: 'ok',
          callId: 'call-1',
        ),
      );

      expect(applier.items, hasLength(1));
      expect(applier.items.single.toolResult, 'ok');
      expect(refreshCount, 1);
    },
  );

  test('present_file tool result fills chat item attachments', () {
    final applier = AgentChatEventApplier();
    const attachment = ChatAttachmentMeta(
      guestPath: '/root/out.csv',
      displayName: 'out.csv',
      kind: GuestMediaKind.text,
    );
    applier.applyLive(
      const AgentUiToolCall(
        name: kPresentFileToolName,
        arguments: '{"path":"/root/out.csv"}',
        callId: 'pf',
      ),
    );
    applier.applyLive(
      const AgentUiToolResult(
        name: kPresentFileToolName,
        result: 'ok',
        callId: 'pf',
        attachments: [attachment],
      ),
    );
    expect(applier.items, hasLength(1));
    expect(applier.items.single.attachments, hasLength(1));
    expect(applier.items.single.attachments.single.guestPath, '/root/out.csv');
  });

  test('restored user system notice is projected as status', () {
    final applier = AgentChatEventApplier();

    applier.applyRestored(
      const AgentUiUserMessage(
        '<background-task-result status="completed"></background-task-result>',
      ),
    );

    expect(applier.items.single.kind, AgentChatKind.status);
  });
}
