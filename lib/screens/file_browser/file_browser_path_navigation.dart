import 'package:flutter/material.dart';

class FileBrowserPathNavigation extends StatelessWidget {
  const FileBrowserPathNavigation({
    super.key,
    required this.pathLabel,
    required this.canGoUp,
    required this.enabled,
    required this.dropEnabled,
    required this.onGoUp,
  });

  final String pathLabel;
  final bool canGoUp;
  final bool enabled;
  final bool dropEnabled;
  final VoidCallback onGoUp;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          children: [
            IconButton(
              tooltip: '上一级',
              onPressed: enabled && canGoUp ? onGoUp : null,
              icon: const Icon(Icons.arrow_upward),
            ),
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Text(
                  pathLabel,
                  style: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.copyWith(fontFamily: 'monospace'),
                ),
              ),
            ),
            if (dropEnabled)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Text(
                  '可拖拽导入',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
