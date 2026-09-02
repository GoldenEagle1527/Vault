import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault/agent/agent_chat_model.dart';
import 'package:vault/agent/agent_chat_transcript.dart';
import 'package:vault/agent/ask_user.dart';
import 'package:vault/agent/chat_attachment.dart';
import 'package:vault/agent/present_file.dart';
import 'package:vault/sandbox/guest_media_kind.dart';
import 'package:vault/agent/agent_navigation_coordinator.dart';
import 'package:vault/agent/project_store.dart';
import 'package:vault/agent/sub_agent_display.dart';
import 'package:vault/screens/agent/widgets/agent_chat_widgets.dart';
import 'package:vault/screens/agent/widgets/agent_navigation.dart';

void main() {
  test('sub-agent capsule label includes the running count', () {
    expect(subAgentBackgroundCapsuleLabel(1), '1个子Agent后台运行中...');
    expect(isSubAgentTool(kDelegateTaskToolName), isTrue);
    expect(isSubAgentTool('shell'), isFalse);
  });

  testWidgets('chat bubble renders thinking and expandable tool states', (
    tester,
  ) async {
    final tool = AgentChatItem.tool(
      name: 'shell',
      arguments: '{"command":"echo ok"}',
      result: '{"stdout":"ok\\n","exitCode":0}',
      callId: 'call',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              AgentChatBubble(item: AgentChatItem.thinking()),
              AgentChatBubble(item: tool),
            ],
          ),
        ),
      ),
    );

    expect(find.text('思考中'), findsOneWidget);
    expect(find.text('正在思考…'), findsNothing);
    await tester.tap(find.text('思考中'));
    await tester.pump();
    expect(find.text('正在思考…'), findsOneWidget);
    expect(find.text('Ran echo ok'), findsOneWidget);
    await tester.tap(find.text('Ran echo ok'));
    await tester.pump();
    expect(find.textContaining('ok'), findsWidgets);
  });

  test(
    'groupAgentTranscript folds consecutive tools and keeps ask_user out',
    () {
      final items = [
        AgentChatItem(kind: AgentChatKind.user, text: '做一下'),
        AgentChatItem.tool(name: 'shell', arguments: '{"command":"ls"}'),
        AgentChatItem.tool(name: 'read_file', arguments: '{"path":"a"}'),
        AgentChatItem.tool(name: 'shell', arguments: '{"command":"pwd"}'),
        AgentChatItem.tool(name: kAskUserToolName, arguments: '{}'),
        AgentChatItem(kind: AgentChatKind.assistant, text: '好了'),
      ];
      final spans = groupAgentTranscript(items);
      expect(spans, hasLength(4));
      expect(spans[0], isA<AgentTranscriptSingle>());
      expect((spans[1] as AgentTranscriptToolGroup).count, 3);
      expect((spans[2] as AgentTranscriptSingle).index, 4);
      expect((spans[3] as AgentTranscriptSingle).index, 5);
      expect(agentToolGroupLabel(count: 3, running: false), '执行了 3 个工具');
    },
  );

  testWidgets('tool group stays collapsed until opened', (tester) async {
    final tools = [
      AgentChatItem.tool(
        name: 'shell',
        arguments: '{"command":"git status"}',
        result: 'ok',
        callId: 'a',
      ),
      AgentChatItem.tool(
        name: 'shell',
        arguments: '{"command":"git diff"}',
        result: 'ok',
        callId: 'b',
      ),
      AgentChatItem.tool(
        name: 'shell',
        arguments: '{"command":"git log"}',
        result: 'ok',
        callId: 'c',
      ),
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: AgentToolCallGroup(items: tools)),
      ),
    );

    expect(find.text('执行了 3 个工具'), findsOneWidget);
    expect(find.text('Ran git status'), findsNothing);
    await tester.tap(find.text('执行了 3 个工具'));
    await tester.pumpAndSettle();
    expect(find.text('Ran git status'), findsOneWidget);
    expect(find.text('Ran git diff'), findsOneWidget);
    expect(find.text('Ran git log'), findsOneWidget);
  });

  testWidgets('thinking row stays collapsed and reveals detail on tap', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AgentChatBubble(
            item: AgentChatItem(
              kind: AgentChatKind.assistant,
              text: '结论',
              thinkingText: '先核对工作区再提交',
              duration: const Duration(seconds: 4),
            ),
          ),
        ),
      ),
    );

    expect(find.textContaining('思考'), findsOneWidget);
    expect(find.text('先核对工作区再提交'), findsNothing);
    await tester.tap(find.textContaining('思考'));
    await tester.pumpAndSettle();
    expect(find.text('先核对工作区再提交'), findsOneWidget);
    expect(find.text('结论'), findsOneWidget);
  });

  testWidgets('delegate_task bubble shows 启动子Agent instead of raw args', (
    tester,
  ) async {
    final tool = AgentChatItem.tool(
      name: kDelegateTaskToolName,
      arguments: '{"assignee":"clone","task_description":"请帮我写一个电影感黑洞壁纸网页"}',
      backgrounded: true,
      callId: 'sub-1',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: AgentChatBubble(item: tool)),
      ),
    );

    expect(find.text(kStartSubAgentSummary), findsOneWidget);
    expect(find.textContaining('assignee'), findsNothing);
    expect(find.textContaining('Ran'), findsNothing);
  });

  testWidgets('sub-agent capsule shows running count above conversation', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: SubAgentBackgroundCapsule(count: 2)),
      ),
    );

    expect(find.text(subAgentBackgroundCapsuleLabel(2)), findsOneWidget);
    expect(find.byIcon(Icons.hourglass_top_rounded), findsOneWidget);
  });

  testWidgets('present_file bubble shows preview and download actions', (
    tester,
  ) async {
    final item = AgentChatItem.tool(
      name: kPresentFileToolName,
      arguments: '{"path":"/root/out.csv"}',
      result: '已展示',
      attachments: const [
        ChatAttachmentMeta(
          guestPath: '/root/out.csv',
          displayName: 'out.csv',
          kind: GuestMediaKind.text,
        ),
      ],
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: AgentChatBubble(item: item)),
      ),
    );
    expect(find.text('out.csv'), findsOneWidget);
    expect(find.text('预览'), findsOneWidget);
    expect(find.text('下载'), findsOneWidget);
    expect(find.text('分享'), findsOneWidget);
    expect(find.text('Ran present_file'), findsNothing);
  });

  testWidgets('navigation panel emits project action ids', (tester) async {
    final now = DateTime.utc(2026);
    final project = ProjectInfo(
      path: 'project-id',
      name: '项目 A',
      createdAt: now,
      updatedAt: now,
    );
    String? selectedProject;
    String? openedTerminal;
    final model = AgentNavigationViewModel(
      booting: false,
      projects: [
        AgentProjectNavItem(
          project: project,
          active: true,
          siteUp: false,
          siteBusy: false,
          conversations: const [],
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AgentNavigationPanel(
            title: 'Vault',
            model: model,
            showClose: false,
            onCreateProject: () {},
            onClose: () {},
            onSelectProject: (id) => selectedProject = id,
            onOpenSite: (_) {},
            onOpenLogs: (_) {},
            onOpenTerminal: (id) => openedTerminal = id,
            onOpenFiles: (_) {},
            onToggleSite: (_) {},
            onNewConversation: (_) {},
            onSelectConversation: (_) {},
            onDeleteConversation: (_) {},
          ),
        ),
      ),
    );

    await tester.tap(find.text('项目 A'));
    await tester.tap(find.byTooltip('终端'));
    expect(selectedProject, 'project-id');
    expect(openedTerminal, 'project-id');
  });

  testWidgets('navigation panel opens site logs when registered', (
    tester,
  ) async {
    final now = DateTime.utc(2026);
    final project = ProjectInfo(
      path: 'project-id',
      name: '项目 A',
      createdAt: now,
      updatedAt: now,
      urls: const [
        ProjectUrlEntry(
          name: '网站',
          url: 'http://127.0.0.1:5000/',
          slug: 'site',
        ),
      ],
    );
    String? openedLogs;
    final model = AgentNavigationViewModel(
      booting: false,
      projects: [
        AgentProjectNavItem(
          project: project,
          active: true,
          siteUp: true,
          siteBusy: false,
          conversations: const [],
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AgentNavigationPanel(
            title: 'Vault',
            model: model,
            showClose: false,
            onCreateProject: () {},
            onClose: () {},
            onSelectProject: (_) {},
            onOpenSite: (_) {},
            onOpenLogs: (id) => openedLogs = id,
            onOpenTerminal: (_) {},
            onOpenFiles: (_) {},
            onToggleSite: (_) {},
            onNewConversation: (_) {},
            onSelectConversation: (_) {},
            onDeleteConversation: (_) {},
          ),
        ),
      ),
    );

    expect(find.byTooltip('打开站点（仅 HTTP）'), findsOneWidget);
    await tester.tap(find.byTooltip('站点日志'));
    expect(openedLogs, 'project-id');
  });
}
