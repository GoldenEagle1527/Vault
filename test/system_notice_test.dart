import 'package:flutter_test/flutter_test.dart';
import 'package:vault/agent/system_notice.dart';
import 'package:vault_agent_core/vault_agent_core.dart';

void main() {
  test('normal user text is not a system notice', () {
    expect(systemNoticeForUserText('帮我启动网站'), isNull);
    expect(systemNoticeForUserText(''), isNull);
  });

  test('background-task-result becomes a short centered notice', () {
    final raw = buildBackgroundTaskResultMessage([
      BackgroundToolJob(
        jobId: 'j1',
        callId: 'c1',
        toolName: 'shell',
        arguments: '{}',
        startedAt: DateTime.utc(2026, 1, 1),
        status: BackgroundToolJobStatus.completed,
      ),
    ]);
    final notice = systemNoticeForUserText(raw);
    expect(notice, isNotNull);
    expect(notice!.text, '后台任务已结束');
    expect(notice.isError, isFalse);
  });

  test('failed background-task-result is an error notice', () {
    final raw = buildBackgroundTaskResultMessage([
      BackgroundToolJob(
        jobId: 'j1',
        callId: 'c1',
        toolName: 'shell',
        arguments: '{}',
        startedAt: DateTime.utc(2026, 1, 1),
        status: BackgroundToolJobStatus.failed,
        error: 'boom',
      ),
    ]);
    final notice = systemNoticeForUserText(raw);
    expect(notice, isNotNull);
    expect(notice!.text, '后台任务失败');
    expect(notice.isError, isTrue);
  });

  test('shell-notify becomes a short notice', () {
    final raw = buildShellNotifyMessage(
      jobId: 'j1',
      callId: 'c1',
      toolName: 'shell',
      regex: 'ready',
      matchText: 'Listening on 8080',
    );
    final notice = systemNoticeForUserText(raw);
    expect(notice, isNotNull);
    expect(notice!.text, 'shell 输出已匹配，进程仍在运行');
    expect(notice.isError, isFalse);
  });
}
