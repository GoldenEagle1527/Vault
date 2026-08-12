import 'dart:async';

import 'package:flutter/material.dart';
import 'package:vault/sandbox/sandbox_models.dart';

/// Runs [action] while showing a non-dismissible progress dialog.
///
/// [action] receives a reporter that updates the dialog. The dialog is closed
/// when [action] completes (success or failure).
Future<T> runWithWorkspaceInitDialog<T>({
  required BuildContext context,
  required Future<T> Function(WorkspaceInitProgressCallback report) action,
  String title = '正在初始化工作区',
}) async {
  final progress = ValueNotifier<WorkspaceInitProgress>(
    const WorkspaceInitProgress(
      step: 0,
      totalSteps: 1,
      label: '准备中…',
    ),
  );
  var dialogOpen = true;

  unawaited(
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      useRootNavigator: true,
      builder: (ctx) {
        return PopScope(
          canPop: false,
          child: AlertDialog(
            title: Text(title),
            content: ValueListenableBuilder<WorkspaceInitProgress>(
              valueListenable: progress,
              builder: (context, value, _) {
                final stepLabel = value.step <= 0
                    ? '准备中…'
                    : '${value.step} / ${value.totalSteps}';
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Center(child: CircularProgressIndicator()),
                    const SizedBox(height: 20),
                    Text(
                      stepLabel,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 12),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: value.step <= 0 ? null : value.fraction,
                        minHeight: 6,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      value.label.isEmpty ? '请稍候…' : value.label,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.wifi_outlined,
                          size: 18,
                          color: Theme.of(context).colorScheme.tertiary,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '请保证良好的网络环境。初始化需下载 git、python3 等软件包。',
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                                ),
                          ),
                        ),
                      ],
                    ),
                  ],
                );
              },
            ),
          ),
        );
      },
    ).whenComplete(() => dialogOpen = false),
  );

  // Let the dialog paint before heavy IO.
  await Future<void>.delayed(Duration.zero);

  try {
    return await action((p) {
      progress.value = p;
    });
  } finally {
    if (context.mounted && dialogOpen) {
      Navigator.of(context, rootNavigator: true).pop();
    }
    progress.dispose();
  }
}
