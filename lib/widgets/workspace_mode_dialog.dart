import 'package:flutter/material.dart';
import 'package:vault/agent/workspace_mode.dart';

/// User-facing label for a [WorkspaceMode] (home list + picker).
String workspaceModeLabel(WorkspaceMode mode) => switch (mode) {
      WorkspaceMode.chat => '对话模式',
      WorkspaceMode.dev => '开发模式',
    };

/// Beginner-friendly chat vs dev picker. Cancel / dismiss returns null.
Future<WorkspaceMode?> showWorkspaceModeDialog(BuildContext context) {
  return showDialog<WorkspaceMode>(
    context: context,
    builder: (ctx) => const _WorkspaceModeDialog(),
  );
}

class _WorkspaceModeDialog extends StatelessWidget {
  const _WorkspaceModeDialog();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Text('这个工作区用来做什么？'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '以后可以按这个方式帮你。选错了也没关系，先选一个最接近的。',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
          ),
          const SizedBox(height: 16),
          _ModeOption(
            icon: Icons.chat_bubble_outline,
            title: '对话模式',
            subtitle: '跟我聊天、整理文件、看表格',
            onTap: () => Navigator.pop(context, WorkspaceMode.chat),
          ),
          const SizedBox(height: 10),
          _ModeOption(
            icon: Icons.web_outlined,
            title: '开发模式',
            subtitle: '把想法做成网页，刷新就能用',
            onTap: () => Navigator.pop(context, WorkspaceMode.dev),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
      ],
    );
  }
}

class _ModeOption extends StatelessWidget {
  const _ModeOption({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.65),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              CircleAvatar(
                backgroundColor: scheme.primaryContainer,
                foregroundColor: scheme.onPrimaryContainer,
                child: Icon(icon),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
