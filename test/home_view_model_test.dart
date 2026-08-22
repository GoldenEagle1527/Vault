import 'package:flutter_test/flutter_test.dart';
import 'package:vault/agent/conversation_models.dart';
import 'package:vault/agent/workspace_mode.dart';
import 'package:vault/sandbox/sandbox_models.dart';
import 'package:vault/screens/home/home_view_model.dart';

void main() {
  test('home view model resolves names and summary metadata', () {
    final now = DateTime(2026, 8, 21, 10);
    final info = WorkspaceInfo(
      workspaceId: 'workspace-1',
      displayName: 'workspace-1',
      createdAt: DateTime(2026, 8, 21, 9),
      approxDiskBytes: 2 * 1024 * 1024,
    );

    final model = buildHomeViewModel(
      capabilities: const SandboxCapabilities(
        available: true,
        backend: SandboxBackend.wsl,
        architecture: 'x64',
      ),
      busy: false,
      error: null,
      workspaces: [info],
      summaries: const {
        'workspace-1': WorkspaceConversationSummary(
          conversationCount: 3,
          projectCount: 2,
          recentTitle: '最近会话',
        ),
      },
      modes: const {'workspace-1': WorkspaceMode.dev},
      names: const {'workspace-1': '实验室'},
      now: now,
    );

    expect(model.greeting, '上午好');
    expect(model.canCreate, isTrue);
    expect(model.workspaces.single.title, '实验室');
    expect(model.workspaces.single.subtitle, contains('2 个项目'));
    expect(model.workspaces.single.subtitle, contains('3 个会话'));
  });

  test('recent conversation becomes title without a custom name', () {
    final info = WorkspaceInfo(
      workspaceId: 'workspace-2',
      displayName: 'workspace-2',
      createdAt: DateTime(2026),
    );
    final model = buildHomeViewModel(
      capabilities: null,
      busy: true,
      error: 'offline',
      workspaces: [info],
      summaries: const {
        'workspace-2': WorkspaceConversationSummary(
          conversationCount: 1,
          recentTitle: '分析报告',
        ),
      },
      modes: const {},
      names: const {},
      now: DateTime(2026, 8, 21, 20),
    );

    expect(model.canCreate, isFalse);
    expect(model.workspaces.single.title, '分析报告');
    expect(model.error, 'offline');
  });
}
