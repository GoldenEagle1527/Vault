import 'package:flutter/material.dart';
import 'package:vault/agent/agent_navigation_coordinator.dart';
import 'package:vault/agent/workspace_mode.dart';

class AgentNavigationPanel extends StatelessWidget {
  const AgentNavigationPanel({
    super.key,
    required this.title,
    required this.model,
    this.mode = WorkspaceMode.chat,
    required this.showClose,
    required this.onCreateProject,
    required this.onClose,
    required this.onSelectProject,
    required this.onOpenSite,
    required this.onOpenTerminal,
    required this.onOpenFiles,
    required this.onToggleSite,
    required this.onNewConversation,
    required this.onSelectConversation,
    required this.onDeleteConversation,
  });

  final String title;
  final AgentNavigationViewModel model;
  final WorkspaceMode mode;
  final bool showClose;
  final VoidCallback onCreateProject;
  final VoidCallback onClose;
  final ValueChanged<String> onSelectProject;
  final ValueChanged<String> onOpenSite;
  final ValueChanged<String> onOpenTerminal;
  final ValueChanged<String> onOpenFiles;
  final ValueChanged<String> onToggleSite;
  final ValueChanged<String> onNewConversation;
  final ValueChanged<String> onSelectConversation;
  final ValueChanged<String> onDeleteConversation;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w600),
                      ),
                      Text(
                        '工作区导航',
                        style: Theme.of(context).textTheme.labelMedium
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: '新项目',
                  onPressed: model.booting ? null : onCreateProject,
                  icon: const Icon(Icons.create_new_folder_outlined),
                ),
                if (showClose)
                  IconButton(
                    tooltip: '关闭',
                    onPressed: onClose,
                    icon: const Icon(Icons.close),
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(child: _buildBody(context, scheme)),
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context, ColorScheme scheme) {
    return ListView(
      padding: const EdgeInsets.only(bottom: 8),
      children: [
        if (model.projects.isEmpty)
          ListTile(
            title: Text(
              '暂无项目',
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
            subtitle: const Text('点击右上角文件夹图标开始'),
          )
        else
          for (final item in model.projects) ...[
            AgentProjectHeader(
              item: item,
              mode: mode,
              booting: model.booting,
              onSelect: () => onSelectProject(item.project.path),
              onOpenSite: () => onOpenSite(item.project.path),
              onOpenTerminal: () => onOpenTerminal(item.project.path),
              onOpenFiles: () => onOpenFiles(item.project.path),
              onToggleSite: () => onToggleSite(item.project.path),
              onNewConversation: () => onNewConversation(item.project.path),
            ),
            if (item.active)
              if (item.conversations.isEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(36, 8, 16, 8),
                  child: Text(
                    '暂无会话',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                )
              else
                for (final conversation in item.conversations)
                  AgentConversationTile(
                    item: conversation,
                    onSelect: () => onSelectConversation(conversation.info.id),
                    onDelete: () => onDeleteConversation(conversation.info.id),
                  ),
          ],
      ],
    );
  }
}

class AgentProjectHeader extends StatelessWidget {
  const AgentProjectHeader({
    super.key,
    required this.item,
    this.mode = WorkspaceMode.chat,
    required this.booting,
    required this.onSelect,
    required this.onOpenSite,
    required this.onOpenTerminal,
    required this.onOpenFiles,
    required this.onToggleSite,
    required this.onNewConversation,
  });

  final AgentProjectNavItem item;
  final WorkspaceMode mode;
  final bool booting;
  final VoidCallback onSelect;
  final VoidCallback onOpenSite;
  final VoidCallback onOpenTerminal;
  final VoidCallback onOpenFiles;
  final VoidCallback onToggleSite;
  final VoidCallback onNewConversation;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final project = item.project;
    final site = project.site;
    final canAct = !booting && !item.siteBusy;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 0, 0),
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: booting ? null : onSelect,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 6, 4, 6),
                child: Row(
                  children: [
                    Icon(
                      item.active ? Icons.folder : Icons.folder_outlined,
                      size: 20,
                      color: item.active
                          ? scheme.primary
                          : scheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        project.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          _HeaderIconButton(
            tooltip: site == null
                ? '尚未登记前端入口'
                : (item.siteUp ? '打开站点' : '站点未启动'),
            icon: Icons.link,
            color: item.siteUp ? scheme.primary : scheme.onSurfaceVariant,
            onPressed: item.siteUp ? onOpenSite : null,
          ),
          _HeaderIconButton(
            tooltip: '终端',
            icon: Icons.terminal,
            onPressed: booting ? null : onOpenTerminal,
          ),
          _HeaderIconButton(
            tooltip: '文件管理器',
            icon: Icons.folder_open_outlined,
            onPressed: booting ? null : onOpenFiles,
          ),
          if (item.siteBusy)
            const SizedBox(
              width: 32,
              height: 32,
              child: Center(
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            )
          else
            _HeaderIconButton(
              tooltip: site == null
                  ? (mode == WorkspaceMode.dev
                        ? '还没有站点，让 Agent 调用 scaffold_site'
                        : '还没有站点')
                  : (item.siteUp ? '停止项目' : '启动项目'),
              icon: item.siteUp ? Icons.stop : Icons.play_arrow,
              color: site == null
                  ? scheme.onSurfaceVariant
                  : (item.siteUp ? scheme.error : scheme.primary),
              onPressed: canAct && site != null ? onToggleSite : null,
            ),
          _HeaderIconButton(
            tooltip: '新会话',
            icon: Icons.add,
            onPressed: booting ? null : onNewConversation,
          ),
        ],
      ),
    );
  }
}

class AgentConversationTile extends StatelessWidget {
  const AgentConversationTile({
    super.key,
    required this.item,
    required this.onSelect,
    required this.onDelete,
  });

  final AgentConversationNavItem item;
  final VoidCallback onSelect;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final conversation = item.info;
    return Padding(
      padding: EdgeInsets.fromLTRB(8.0 + item.depth * 16, 1, 8, 1),
      child: Material(
        color: item.selected
            ? scheme.surfaceContainerHighest
            : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onSelect,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
            child: Row(
              children: [
                if (conversation.isBranch) ...[
                  Icon(
                    Icons.call_split,
                    size: 14,
                    color: scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 6),
                ],
                Expanded(
                  child: Text(
                    conversation.isBranch
                        ? '分支 · ${conversation.title}'
                        : conversation.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontWeight: item.selected
                          ? FontWeight.w600
                          : FontWeight.w400,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  compactRelativeTime(conversation.updatedAt),
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                IconButton(
                  tooltip: '删除会话',
                  onPressed: onDelete,
                  icon: const Icon(Icons.delete_outline, size: 18),
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.all(4),
                  constraints: const BoxConstraints(
                    minWidth: 28,
                    minHeight: 28,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _HeaderIconButton extends StatelessWidget {
  const _HeaderIconButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.color,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Icon(icon, size: 20, color: color),
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.all(4),
      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
    );
  }
}

String compactRelativeTime(DateTime when, {DateTime? now}) {
  final local = when.toLocal();
  final current = now ?? DateTime.now();
  final diff = current.difference(local);
  if (diff.inSeconds < 60) return '${diff.inSeconds.clamp(1, 59)}s';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m';
  final today = DateTime(current.year, current.month, current.day);
  final day = DateTime(local.year, local.month, local.day);
  if (day == today) return '${diff.inHours.clamp(1, 23)}h';
  if (day == today.subtract(const Duration(days: 1))) return '昨天';
  if (local.year == current.year) return '${local.month}/${local.day}';
  return '${local.year}/${local.month}/${local.day}';
}
