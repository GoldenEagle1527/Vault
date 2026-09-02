import 'package:flutter/material.dart';
import 'package:vault/screens/home/home_view_model.dart';
import 'package:vault/widgets/glass.dart';

class HomeContent extends StatelessWidget {
  const HomeContent({
    super.key,
    required this.model,
    required this.onDismissError,
    required this.onCreate,
    required this.onOpen,
    required this.onDelete,
  });

  final HomeViewModel model;
  final VoidCallback onDismissError;
  final VoidCallback? onCreate;
  final ValueChanged<HomeWorkspaceItemViewModel>? onOpen;
  final ValueChanged<HomeWorkspaceItemViewModel>? onDelete;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
          children: [
            if (model.error != null) ...[
              MaterialBanner(
                content: Text(model.error!),
                actions: [
                  TextButton(
                    onPressed: onDismissError,
                    child: const Text('关闭'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
            ],
            if (model.capabilities case final caps?)
              if (!caps.available) ...[
                Card(
                  color: scheme.errorContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '环境不可用',
                          style: Theme.of(context).textTheme.titleSmall
                              ?.copyWith(color: scheme.onErrorContainer),
                        ),
                        if (caps.hint != null) ...[
                          const SizedBox(height: 8),
                          Text(
                            caps.hint!,
                            style: TextStyle(color: scheme.onErrorContainer),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
              ],
            FadeSlideIn(
              child: GlassPanel(
                borderRadius: 28,
                tone: GlassTone.tinted,
                tint: scheme.primaryContainer,
                padding: const EdgeInsets.all(24),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final intro = Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          model.greeting,
                          style: Theme.of(context).textTheme.labelLarge
                              ?.copyWith(color: scheme.onPrimaryContainer),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '一个工作区 = 一套独立 Linux 环境',
                          style: Theme.of(context).textTheme.headlineSmall
                              ?.copyWith(
                                color: scheme.onPrimaryContainer,
                                fontWeight: FontWeight.w600,
                                fontVariations: const [FontVariation.weight(600)],
                              ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '创建后即可在同一环境中开启多轮会话。',
                          style: TextStyle(color: scheme.onPrimaryContainer),
                        ),
                      ],
                    );
                    final button = FilledButton.icon(
                      onPressed: onCreate,
                      icon: const Icon(Icons.add),
                      label: const Text('新建工作区'),
                    );
                    if (constraints.maxWidth < 520) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [intro, const SizedBox(height: 20), button],
                      );
                    }
                    return Row(
                      children: [
                        Expanded(child: intro),
                        const SizedBox(width: 16),
                        button,
                      ],
                    );
                  },
                ),
              ),
            ),
            const SizedBox(height: 24),
            Text('全部工作区', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 10),
            if (model.workspaces.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Text(
                  model.busy ? '正在检查环境…' : '还没有工作区。点上方「新建工作区」开始。',
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              )
            else
              for (final (index, item) in model.workspaces.indexed)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: FadeSlideIn(
                    index: index,
                    child: WorkspaceRow(
                      model: item,
                      onOpen: onOpen == null ? null : () => onOpen!(item),
                      onDelete: onDelete == null ? null : () => onDelete!(item),
                    ),
                  ),
                ),
          ],
        ),
      ),
    );
  }
}

class WorkspaceRow extends StatelessWidget {
  const WorkspaceRow({
    super.key,
    required this.model,
    required this.onOpen,
    required this.onDelete,
  });

  final HomeWorkspaceItemViewModel model;
  final VoidCallback? onOpen;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final wide = MediaQuery.sizeOf(context).width >= 600;
    return PressableScale(
      onTap: onOpen,
      enabled: onOpen != null,
      child: GlassPanel(
        borderRadius: 20,
        tone: GlassTone.regular,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            CircleAvatar(
              backgroundColor: scheme.primaryContainer.withValues(alpha: 0.85),
              foregroundColor: scheme.onPrimaryContainer,
              child: Icon(model.icon),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    model.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      fontVariations: const [FontVariation.weight(600)],
                    ),
                  ),
                  Text(
                    model.subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            if (wide) ...[
              const SizedBox(width: 8),
              FilledButton.tonal(onPressed: onOpen, child: const Text('打开')),
            ],
            IconButton(
              tooltip: '删除',
              onPressed: onDelete,
              icon: const Icon(Icons.delete_outline),
            ),
          ],
        ),
      ),
    );
  }
}

class HomeEnvironmentChip extends StatelessWidget {
  const HomeEnvironmentChip({super.key, required this.model});

  final HomeViewModel model;

  @override
  Widget build(BuildContext context) {
    final caps = model.capabilities!;
    final scheme = Theme.of(context).colorScheme;
    return Chip(
      avatar: Icon(
        caps.available ? Icons.check_circle : Icons.error_outline,
        size: 18,
        color: caps.available ? scheme.primary : scheme.error,
      ),
      label: Text(caps.available ? '安全环境已就绪' : '环境不可用'),
      side: BorderSide.none,
      backgroundColor: caps.available
          ? scheme.primaryContainer
          : scheme.errorContainer,
      visualDensity: VisualDensity.compact,
    );
  }
}

class HomeRailButton extends StatelessWidget {
  const HomeRailButton({
    super.key,
    required this.selected,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final bool selected;
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 64,
      width: double.infinity,
      child: InkWell(
        onTap: onTap,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              color: selected
                  ? scheme.onSecondaryContainer
                  : scheme.onSurfaceVariant,
            ),
            const SizedBox(height: 4),
            Text(label, style: const TextStyle(fontSize: 12)),
          ],
        ),
      ),
    );
  }
}
