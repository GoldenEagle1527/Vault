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
    expect(applier.items.single.streaming, isTrue);

    applier.applyLive(const AgentUiAssistantFinal('你好！'));
    expect(applier.items.single.streaming, isFalse);
    expect(applier.items.single.text, '你好！');
  });

  test('live thought deltas stay on the thinking item when tools start', () {
    final applier = AgentChatEventApplier();

    applier.applyLive(const AgentUiStatus('正在思考…'));
    applier.applyLive(const AgentUiAssistantDelta('', thought: '先看仓库'));
    applier.applyLive(const AgentUiAssistantDelta('', thought: '再提交'));
    applier.applyLive(
      const AgentUiToolCall(
        name: 'shell',
        arguments: '{"command":"git status"}',
        callId: 'c1',
      ),
    );

    expect(applier.items, hasLength(2));
    expect(applier.items.first.thinkingText, '先看仓库再提交');
    expect(applier.items.first.thinkingPlaceholder, isFalse);
    expect(applier.items.last.kind, AgentChatKind.tool);
  });

  test('restored assistant final keeps thought for collapsed display', () {
    final applier = AgentChatEventApplier();
    applier.applyRestored(
      const AgentUiAssistantFinal(
        '可以提交',
        thought: '先核对 diff',
        duration: Duration(seconds: 4),
      ),
    );
    expect(applier.items.single.thinkingText, '先核对 diff');
    expect(applier.items.single.text, '可以提交');
    expect(applier.items.single.duration, const Duration(seconds: 4));
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
          name: 'scaffold_site',
          arguments: '{"kind":"flask"}',
          callId: 'call-1',
        ),
      );
      applier.applyLive(
        const AgentUiToolResult(
          name: 'scaffold_site',
          result: 'ok',
          callId: 'call-1',
        ),
      );

      expect(applier.items, hasLength(1));
      expect(applier.items.single.toolResult, 'ok');
      expect(refreshCount, 1);
    },
  );

  test('manage_site tool result emits project refresh effect', () {
    var refreshCount = 0;
    final applier = AgentChatEventApplier(
      onProjectUrlRegistered: () => refreshCount++,
    );
    applier.applyLive(
      const AgentUiToolCall(
        name: 'manage_site',
        arguments: '{"action":"start"}',
        callId: 'ms-1',
      ),
    );
    applier.applyLive(
      const AgentUiToolResult(
        name: 'manage_site',
        result: 'ok',
        callId: 'ms-1',
      ),
    );
    expect(refreshCount, 1);
  });

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

  test('live tool-execution status is not shown as a banner', () {
    final applier = AgentChatEventApplier();
    applier.applyLive(const AgentUiStatus('正在执行工具：shell'));
    expect(applier.status, isNull);
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
