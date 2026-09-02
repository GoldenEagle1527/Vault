import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault/agent/agent_chat_ui_scheduler.dart';

void main() {
  test('schedule coalesces multiple deltas into one flush', () {
    var flushes = 0;
    FrameCallback? pending;
    final scheduler = AgentChatUiScheduler(
      onFlush: () => flushes++,
      scheduleFrame: (callback) => pending = callback,
    );

    scheduler.schedule();
    scheduler.schedule();
    scheduler.schedule();
    expect(flushes, 0);
    expect(scheduler.isScheduled, isTrue);

    pending!(Duration.zero);
    expect(flushes, 1);
    expect(scheduler.isScheduled, isFalse);
  });

  test('flushNow cancels a pending frame callback', () {
    var flushes = 0;
    FrameCallback? pending;
    final scheduler = AgentChatUiScheduler(
      onFlush: () => flushes++,
      scheduleFrame: (callback) => pending = callback,
    );

    scheduler.schedule();
    scheduler.flushNow();
    expect(flushes, 1);

    pending!(Duration.zero);
    expect(flushes, 1);
  });

  test('cancel drops a pending flush', () {
    var flushes = 0;
    FrameCallback? pending;
    final scheduler = AgentChatUiScheduler(
      onFlush: () => flushes++,
      scheduleFrame: (callback) => pending = callback,
    );

    scheduler.schedule();
    scheduler.cancel();
    pending!(Duration.zero);
    expect(flushes, 0);
  });
}
