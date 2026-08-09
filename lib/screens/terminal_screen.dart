import 'package:flutter/material.dart';
import 'package:vault/sandbox/sandbox_models.dart';
import 'package:vault/widgets/workspace_terminal.dart';

class TerminalScreen extends StatelessWidget {
  const TerminalScreen({
    super.key,
    required this.title,
    required this.workspace,
    this.disposeWorkspace = true,
  });

  final String title;
  final SandboxWorkspace workspace;

  /// When false, the PTY stays owned by the caller (e.g. [AgentScreen]).
  final bool disposeWorkspace;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Linux 终端'),
            Text(
              '$title · 高级调试',
              style: Theme.of(
                context,
              ).textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          Material(
            color: scheme.surfaceContainerHigh,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                children: [
                  Icon(Icons.info_outline, color: scheme.primary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '高级调试模式：命令会在当前工作区的独立 Linux 空间中执行。',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: WorkspaceTerminal(
              workspace: workspace,
              disposeWorkspace: disposeWorkspace,
            ),
          ),
        ],
      ),
    );
  }
}
