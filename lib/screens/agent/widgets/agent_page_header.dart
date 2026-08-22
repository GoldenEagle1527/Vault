import 'package:flutter/material.dart';

class AgentPageHeader extends StatelessWidget implements PreferredSizeWidget {
  const AgentPageHeader({
    super.key,
    required this.hasProject,
    required this.conversationTitle,
    required this.projectName,
    required this.workspaceTitle,
    required this.wide,
    required this.running,
    required this.backgroundJobCount,
    required this.onOpenNavigation,
    required this.onOpenSettings,
  });

  final bool hasProject;
  final String conversationTitle;
  final String projectName;
  final String workspaceTitle;
  final bool wide;
  final bool running;
  final int backgroundJobCount;
  final VoidCallback onOpenNavigation;
  final VoidCallback onOpenSettings;

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AppBar(
      centerTitle: true,
      titleSpacing: 8,
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(
            hasProject ? conversationTitle : '新建项目以开始',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
          Text(
            hasProject
                ? '$projectName · $workspaceTitle'
                : '$workspaceTitle · 工作区',
            style: Theme.of(
              context,
            ).textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
      actions: [
        if (!wide)
          IconButton(
            tooltip: '工作区导航',
            onPressed: onOpenNavigation,
            icon: const Icon(Icons.menu_open),
          ),
        if (wide)
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: Chip(
              label: Text(
                running
                    ? '运行中'
                    : backgroundJobCount > 0
                    ? '后台 $backgroundJobCount'
                    : '已连接',
              ),
              avatar: Icon(
                running
                    ? Icons.sync
                    : backgroundJobCount > 0
                    ? Icons.hourglass_top_rounded
                    : Icons.check_circle,
                size: 16,
                color: scheme.primary,
              ),
              visualDensity: VisualDensity.compact,
              side: BorderSide.none,
              backgroundColor: scheme.primaryContainer.withValues(alpha: 0.75),
              labelStyle: TextStyle(color: scheme.onPrimaryContainer),
            ),
          ),
        IconButton(
          tooltip: '设置',
          onPressed: onOpenSettings,
          icon: const Icon(Icons.settings_outlined),
        ),
      ],
    );
  }
}
