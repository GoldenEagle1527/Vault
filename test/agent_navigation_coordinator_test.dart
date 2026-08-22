import 'package:flutter_test/flutter_test.dart';
import 'package:vault/agent/agent_navigation_coordinator.dart';
import 'package:vault/agent/conversation_store.dart';
import 'package:vault/agent/project_store.dart';

void main() {
  test('build marks active selections and preserves branch depth', () {
    final now = DateTime.utc(2026, 8, 21);
    final root = ConversationInfo(
      id: 'root',
      title: '主会话',
      createdAt: now,
      updatedAt: now,
      messageCount: 1,
    );
    final branch = ConversationInfo(
      id: 'branch',
      title: '分支',
      createdAt: now,
      updatedAt: now,
      messageCount: 1,
      parentId: 'root',
      forkedFromMessageIndex: 0,
    );
    final project = ProjectInfo(
      path: 'project',
      name: '项目',
      createdAt: now,
      updatedAt: now,
    );

    final model = const AgentNavigationCoordinator().build(
      projects: [project],
      conversations: [branch, root],
      activeProjectPath: 'project',
      activeConversationId: 'branch',
      siteUp: const {'project': true},
      siteBusy: const {},
      booting: false,
    );

    expect(model.projects.single.active, isTrue);
    expect(model.projects.single.siteUp, isTrue);
    expect(model.projects.single.conversations, hasLength(2));
    final branchItem = model.projects.single.conversations.firstWhere(
      (item) => item.info.id == 'branch',
    );
    expect(branchItem.selected, isTrue);
    expect(branchItem.depth, 1);
  });

  test('inactive projects do not receive active conversation rows', () {
    final now = DateTime.utc(2026);
    final projects = [
      for (final path in ['active', 'other'])
        ProjectInfo(path: path, name: path, createdAt: now, updatedAt: now),
    ];

    final model = const AgentNavigationCoordinator().build(
      projects: projects,
      conversations: const [],
      activeProjectPath: 'active',
      activeConversationId: null,
      siteUp: const {},
      siteBusy: const {},
      booting: false,
    );

    expect(model.projects.last.active, isFalse);
    expect(model.projects.last.conversations, isEmpty);
  });
}
