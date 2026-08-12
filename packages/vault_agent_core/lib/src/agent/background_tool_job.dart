import 'dart:async';

import 'package:vault_agent_core/src/core/message.dart';

/// Key used in [AgentState.systemReminders] for active background tool jobs.
const String kBackgroundJobsReminderKey = 'background_jobs';

/// Lifecycle of a tool call that outlived [StatefulAgent.toolBackgroundAfter].
enum BackgroundToolJobStatus { running, completed, failed }

/// Event kind emitted by [BackgroundToolJobRegistry].
enum BackgroundToolJobEventKind { backgrounded, completed, notified }

/// A tool invocation detached from the agent loop after the background threshold.
class BackgroundToolJob {
  BackgroundToolJob({
    required this.jobId,
    required this.callId,
    required this.toolName,
    required this.arguments,
    required this.startedAt,
    this.status = BackgroundToolJobStatus.running,
    this.result,
    this.error,
    this.notifyRegex,
  });

  final String jobId;
  final String callId;
  final String toolName;
  final String arguments;
  final DateTime startedAt;
  BackgroundToolJobStatus status;
  FunctionExecutionResult? result;
  Object? error;

  /// Optional shell output pattern that can wake the model without stopping the job.
  final String? notifyRegex;

  bool get isRunning => status == BackgroundToolJobStatus.running;

  String get argumentsSummary {
    final trimmed = arguments.trim();
    if (trimmed.length <= 160) return trimmed;
    return '${trimmed.substring(0, 160)}…';
  }

  String resultText() {
    final r = result;
    if (r == null) {
      if (error != null) return 'Error: $error';
      return '';
    }
    return r.content
        .whereType<TextPart>()
        .map((p) => p.text)
        .join('\n');
  }
}

/// Registry notification for UI / AgentService listeners.
class BackgroundToolJobEvent {
  const BackgroundToolJobEvent({
    required this.kind,
    required this.job,
    this.notifyText,
    this.notifyRegex,
  });

  final BackgroundToolJobEventKind kind;
  final BackgroundToolJob job;

  /// Matched excerpt when [kind] is [BackgroundToolJobEventKind.notified].
  final String? notifyText;
  final String? notifyRegex;
}

/// Tracks tool Futures that were released from the think-act loop.
class BackgroundToolJobRegistry {
  final Map<String, BackgroundToolJob> _jobs = {};
  final StreamController<BackgroundToolJobEvent> _controller =
      StreamController<BackgroundToolJobEvent>.broadcast();

  Stream<BackgroundToolJobEvent> get events => _controller.stream;

  List<BackgroundToolJob> get jobs => List.unmodifiable(_jobs.values);

  List<BackgroundToolJob> get runningJobs =>
      _jobs.values.where((j) => j.isRunning).toList(growable: false);

  BackgroundToolJob? operator [](String jobId) => _jobs[jobId];

  BackgroundToolJob register({
    required String jobId,
    required String callId,
    required String toolName,
    required String arguments,
    DateTime? startedAt,
    String? notifyRegex,
  }) {
    final job = BackgroundToolJob(
      jobId: jobId,
      callId: callId,
      toolName: toolName,
      arguments: arguments,
      startedAt: startedAt ?? DateTime.now(),
      notifyRegex: notifyRegex,
    );
    _jobs[jobId] = job;
    _controller.add(
      BackgroundToolJobEvent(
        kind: BackgroundToolJobEventKind.backgrounded,
        job: job,
      ),
    );
    return job;
  }

  /// Wake listeners because shell output matched a notify pattern.
  /// Does **not** change job status — the process keeps running.
  void notifyMatch(
    String jobId, {
    required String text,
    required String regex,
  }) {
    final job = _jobs[jobId];
    if (job == null || !job.isRunning) return;
    _controller.add(
      BackgroundToolJobEvent(
        kind: BackgroundToolJobEventKind.notified,
        job: job,
        notifyText: text,
        notifyRegex: regex,
      ),
    );
  }

  void complete(String jobId, FunctionExecutionResult result) {
    final job = _jobs[jobId];
    if (job == null || !job.isRunning) return;
    job.status = result.isError
        ? BackgroundToolJobStatus.failed
        : BackgroundToolJobStatus.completed;
    job.result = result;
    _controller.add(
      BackgroundToolJobEvent(
        kind: BackgroundToolJobEventKind.completed,
        job: job,
      ),
    );
  }

  void fail(String jobId, Object error, {FunctionExecutionResult? result}) {
    final job = _jobs[jobId];
    if (job == null || !job.isRunning) return;
    job.status = BackgroundToolJobStatus.failed;
    job.error = error;
    job.result = result;
    _controller.add(
      BackgroundToolJobEvent(
        kind: BackgroundToolJobEventKind.completed,
        job: job,
      ),
    );
  }

  /// Drop finished jobs that have already been delivered to the model.
  void remove(String jobId) => _jobs.remove(jobId);

  void syncReminders(Map<String, String> systemReminders) {
    final running = runningJobs;
    if (running.isEmpty) {
      systemReminders.remove(kBackgroundJobsReminderKey);
      return;
    }
    final buffer = StringBuffer()
      ..writeln('The following tool calls are still running in the background:')
      ..writeln(
        'You will receive <background-task-result> when each finishes, '
        'or <shell-notify> when notify_regex matches (process keeps running).',
      );
    for (final job in running) {
      final notify = job.notifyRegex == null
          ? ''
          : ' notify_regex=${job.notifyRegex}';
      buffer.writeln(
        '- jobId=${job.jobId} tool=${job.toolName} callId=${job.callId} '
        'started=${job.startedAt.toIso8601String()}$notify '
        'args=${job.argumentsSummary}',
      );
    }
    systemReminders[kBackgroundJobsReminderKey] = buffer.toString().trim();
  }

  void dispose() {
    _jobs.clear();
    if (!_controller.isClosed) {
      _controller.close();
    }
  }
}

/// Builds the synthetic tool result shown to the model when a call is backgrounded.
String buildBackgroundToolStubText({
  required String toolName,
  required String jobId,
  required String callId,
  required Duration threshold,
  required List<BackgroundToolJob> runningJobs,
}) {
  final buffer = StringBuffer()
    ..writeln('工具 $toolName 已转入后台执行（超过 ${threshold.inSeconds} 秒）。')
    ..writeln('jobId: $jobId')
    ..writeln('callId: $callId')
    ..writeln('任务仍在运行；完成后会以 <background-task-result> 通知你。你可以继续其他工作。');
  if (runningJobs.isNotEmpty) {
    buffer.writeln('当前后台任务：');
    for (final job in runningJobs) {
      buffer.writeln('- ${job.jobId} (${job.toolName})');
    }
  }
  return buffer.toString().trim();
}

/// User-turn payload that reactivates the model after background jobs finish.
String buildBackgroundTaskResultMessage(List<BackgroundToolJob> jobs) {
  final buffer = StringBuffer()
    ..writeln('以下后台工具任务已结束，请根据结果继续：');
  for (final job in jobs) {
    final status = job.status == BackgroundToolJobStatus.failed
        ? 'failed'
        : 'completed';
    buffer.writeln(
      '<background-task-result job_id="${job.jobId}" tool="${job.toolName}" '
      'call_id="${job.callId}" status="$status">',
    );
    final body = job.resultText();
    if (body.isNotEmpty) {
      buffer.writeln(body);
    } else if (job.error != null) {
      buffer.writeln('Error: ${job.error}');
    }
    buffer.writeln('</background-task-result>');
  }
  return buffer.toString().trim();
}

/// User-turn payload when shell output matches notify_regex (process still alive).
String buildShellNotifyMessage({
  required String jobId,
  required String callId,
  required String toolName,
  required String regex,
  required String matchText,
}) {
  return '''
以下 shell 输出已匹配你设置的 notify_regex（进程仍在运行，未被终止），请查看并决定下一步：
<shell-notify job_id="$jobId" tool="$toolName" call_id="$callId" regex="${_xmlEscape(regex)}" still_running="true">
$matchText
</shell-notify>
'''.trim();
}

String _xmlEscape(String value) {
  return value
      .replaceAll('&', '&amp;')
      .replaceAll('"', '&quot;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');
}
