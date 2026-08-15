/// Short chat label for system-injected user turns (model still sees the raw XML).
class SystemNotice {
  const SystemNotice(this.text, {this.isError = false});

  final String text;
  final bool isError;
}

/// Maps `<background-task-result>` / `<shell-notify>` payloads to a UI notice.
///
/// Returns null when [text] is a normal user message.
SystemNotice? systemNoticeForUserText(String text) {
  final t = text.trim();
  if (t.isEmpty) return null;
  if (_isShellNotify(t)) {
    return const SystemNotice('shell 输出已匹配，进程仍在运行');
  }
  if (_isBackgroundTaskResult(t)) {
    final failed = RegExp(r'status="failed"').allMatches(t).length;
    final done = RegExp(r'status="completed"').allMatches(t).length;
    final n = failed + done;
    if (failed > 0 && done == 0) {
      return SystemNotice(n > 1 ? '$n 个后台任务失败' : '后台任务失败', isError: true);
    }
    if (n > 1) return SystemNotice('$n 个后台任务已结束');
    return const SystemNotice('后台任务已结束');
  }
  return null;
}

bool _isBackgroundTaskResult(String t) =>
    t.contains('<background-task-result') || t.startsWith('以下后台工具任务已结束');

bool _isShellNotify(String t) =>
    t.contains('<shell-notify') ||
    t.startsWith('以下 shell 输出已匹配') ||
    t.startsWith('以下 shell 监控触发了');
