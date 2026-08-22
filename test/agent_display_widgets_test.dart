import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault/agent/agent_chat_model.dart';
import 'package:vault/agent/agent_navigation_coordinator.dart';
import 'package:vault/agent/project_store.dart';
import 'package:vault/screens/agent/widgets/agent_chat_widgets.dart';
import 'package:vault/screens/agent/widgets/agent_navigation.dart';

void main() {
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

    expect(find.text('Agent 正在思考…'), findsOneWidget);
    expect(find.text('Ran echo ok'), findsOneWidget);
    await tester.tap(find.text('Ran echo ok'));
    await tester.pump();
    expect(find.textContaining('ok'), findsWidgets);
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
}
