import 'package:vault/agent/conversation_store.dart';
import 'package:vault/agent/project_store.dart';

class AgentConversationNavItem {
  const AgentConversationNavItem({
    required this.info,
    required this.depth,
    required this.selected,
  });

  final ConversationInfo info;
  final int depth;
  final bool selected;
}

class AgentProjectNavItem {
  const AgentProjectNavItem({
    required this.project,
    required this.active,
    required this.siteUp,
    required this.siteBusy,
    required this.conversations,
  });

  final ProjectInfo project;
  final bool active;
  final bool siteUp;
  final bool siteBusy;
  final List<AgentConversationNavItem> conversations;
}

class AgentNavigationViewModel {
  const AgentNavigationViewModel({
    required this.projects,
    required this.booting,
  });

  final List<AgentProjectNavItem> projects;
  final bool booting;
}

/// Converts mutable screen selection/status into immutable navigation state.
class AgentNavigationCoordinator {
  const AgentNavigationCoordinator();

  AgentNavigationViewModel build({
    required List<ProjectInfo> projects,
    required List<ConversationInfo> conversations,
    required String? activeProjectPath,
    required String? activeConversationId,
    required Map<String, bool> siteUp,
    required Set<String> siteBusy,
    required bool booting,
  }) {
    return AgentNavigationViewModel(
      booting: booting,
      projects: [
        for (final project in projects)
          AgentProjectNavItem(
            project: project,
            active: project.path == activeProjectPath,
            siteUp: siteUp[project.path] == true,
            siteBusy: siteBusy.contains(project.path),
            conversations: project.path != activeProjectPath
                ? const []
                : [
                    for (final node in ConversationStore.treeOrder(
                      conversations,
                    ))
                      AgentConversationNavItem(
                        info: node.info,
                        depth: node.depth,
                        selected: node.info.id == activeConversationId,
                      ),
                  ],
          ),
      ],
    );
  }
}
