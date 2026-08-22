import 'package:flutter/material.dart';
import 'package:vault/sandbox/sandbox_models.dart';

enum _InboxCollisionChoice { rename, autoRename, cancel }

Future<String?> resolveAgentInboxCollision(
  BuildContext context, {
  required String name,
  required Set<String> taken,
}) async {
  final choice = await showDialog<_InboxCollisionChoice>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('文件重名'),
      content: Text('当前项目 inbox 已有 `$name`'),
      actions: [
        TextButton(
          onPressed: () =>
              Navigator.pop(dialogContext, _InboxCollisionChoice.cancel),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: () =>
              Navigator.pop(dialogContext, _InboxCollisionChoice.rename),
          child: const Text('重命名'),
        ),
        FilledButton(
          onPressed: () =>
              Navigator.pop(dialogContext, _InboxCollisionChoice.autoRename),
          child: const Text('自动重命名'),
        ),
      ],
    ),
  );
  if (!context.mounted) return null;
  switch (choice) {
    case _InboxCollisionChoice.rename:
      final renamed = await _promptInboxFileName(context, name);
      if (renamed == null || !context.mounted) return null;
      final sanitized = sanitizeInboxFileName(renamed);
      if (taken.contains(sanitized)) {
        return resolveAgentInboxCollision(
          context,
          name: sanitized,
          taken: taken,
        );
      }
      return sanitized;
    case _InboxCollisionChoice.autoRename:
      return allocateInboxFileName(name, taken);
    case _InboxCollisionChoice.cancel:
    case null:
      return null;
  }
}

Future<String?> _promptInboxFileName(
  BuildContext context,
  String initial,
) async {
  final controller = TextEditingController(text: initial);
  final name = await showDialog<String>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('重命名附件'),
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: const InputDecoration(hintText: '新文件名'),
        onSubmitted: (value) => Navigator.pop(dialogContext, value),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, controller.text),
          child: const Text('确定'),
        ),
      ],
    ),
  );
  controller.dispose();
  final trimmed = name?.trim() ?? '';
  return trimmed.isEmpty ? null : trimmed;
}

Future<bool> confirmLeaveAgentWorkspace(
  BuildContext context, {
  required String message,
  required bool hasRunningSites,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('离开工作区？'),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: Text(hasRunningSites ? '停止站点并离开' : '离开并取消'),
        ),
      ],
    ),
  );
  return confirmed == true;
}

Future<bool> confirmSwitchRunningConversation(BuildContext context) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('切换会话？'),
      content: const Text('当前会话仍在运行，切换将取消正在进行的任务。'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('切换并取消'),
        ),
      ],
    ),
  );
  return confirmed == true;
}

Future<bool> confirmDeleteAgentConversation(BuildContext context) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('删除会话？'),
      content: const Text('将删除该会话的对话历史。工作区 Linux 文件不会因此删除。'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('删除'),
        ),
      ],
    ),
  );
  return confirmed == true;
}
