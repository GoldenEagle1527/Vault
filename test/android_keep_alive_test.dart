import 'package:flutter_test/flutter_test.dart';
import 'package:vault/sandbox/android_keep_alive.dart';
import 'package:vault/sandbox/proot_host.dart';

void main() {
  test('androidKeepAliveStatusLines describe each signal', () {
    const ready = AndroidKeepAliveStatus(
      notificationsEnabled: true,
      batteryOptimizationIgnored: true,
      foregroundServiceRunning: true,
    );
    expect(ready.ready, isTrue);
    final lines = androidKeepAliveStatusLines(ready);
    expect(lines, hasLength(3));
    expect(lines[0], contains('已允许'));
    expect(lines[1], contains('已关闭'));
    expect(lines[2], contains('运行中'));

    const blocked = AndroidKeepAliveStatus(
      notificationsEnabled: false,
      batteryOptimizationIgnored: false,
      foregroundServiceRunning: false,
    );
    expect(blocked.ready, isFalse);
    expect(
      androidKeepAliveStatusLines(blocked).join('\n'),
      contains('未允许'),
    );
  });

  test('shouldConfirmLeaveWorkspace when agent or site is live', () {
    expect(
      shouldConfirmLeaveWorkspace(agentRunning: false, runningSiteNames: const []),
      isFalse,
    );
    expect(
      shouldConfirmLeaveWorkspace(agentRunning: true, runningSiteNames: const []),
      isTrue,
    );
    expect(
      shouldConfirmLeaveWorkspace(
        agentRunning: false,
        runningSiteNames: const ['网站'],
      ),
      isTrue,
    );
  });

  test('leaveWorkspaceConfirmMessage mentions sites and agent', () {
    expect(
      leaveWorkspaceConfirmMessage(
        agentRunning: false,
        runningSiteNames: const ['网站'],
      ),
      contains('「网站」'),
    );
    expect(
      leaveWorkspaceConfirmMessage(
        agentRunning: true,
        runningSiteNames: const ['网站', 'API'],
      ),
      allOf(contains('「网站」'), contains('「API」'), contains('会话仍在运行')),
    );
  });
}
