import 'dart:async';

import 'package:test/test.dart';
import 'package:vault_agent_core/vault_agent_core.dart';

void main() {
  test('returns a foreground result without registering a job', () async {
    final registry = BackgroundToolJobRegistry();
    final racer = BackgroundToolRacer(
      registry: registry,
      createJobId: () => 'unused',
    );
    final expected = _result('foreground');

    final outcome = await racer.race(
      call: FunctionCall(id: 'call-1', name: 'fast', arguments: '{}'),
      work: Future.value(expected),
      threshold: const Duration(seconds: 1),
      systemReminders: {},
    );

    expect(outcome.result, same(expected));
    expect(outcome.backgroundedJob, isNull);
    expect(registry.jobs, isEmpty);
    registry.dispose();
  });

  test('registers timed out work then completes it and reminders', () async {
    final registry = BackgroundToolJobRegistry();
    final racer = BackgroundToolRacer(
      registry: registry,
      createJobId: () => 'job-1',
    );
    final reminders = <String, String>{};
    final work = Completer<ExecutionToolResult>();
    final events = <BackgroundToolJobEventKind>[];
    final subscription = registry.events.listen(
      (event) => events.add(event.kind),
    );

    final outcome = await racer.race(
      call: FunctionCall(id: 'call-1', name: 'slow', arguments: '{}'),
      work: work.future,
      threshold: const Duration(milliseconds: 5),
      systemReminders: reminders,
    );

    expect(outcome.backgroundedJob?.jobId, 'job-1');
    expect(outcome.result.metadata, {
      'background': true,
      'jobId': 'job-1',
      'callId': 'call-1',
    });
    expect(registry.runningJobs, hasLength(1));
    expect(reminders, contains(kBackgroundJobsReminderKey));

    work.complete(
      ExecutionToolResult(
        id: 'call-1',
        name: 'slow',
        arguments: '{}',
        content: [TextPart('done')],
        stopFlag: true,
        metadata: {'kept': true},
      ),
    );
    await Future<void>.delayed(Duration.zero);

    final job = registry['job-1']!;
    expect(job.status, BackgroundToolJobStatus.completed);
    expect(job.resultText(), 'done');
    expect(job.result?.metadata, {'kept': true});
    expect(reminders, isNot(contains(kBackgroundJobsReminderKey)));
    expect(events, [
      BackgroundToolJobEventKind.backgrounded,
      BackgroundToolJobEventKind.completed,
    ]);

    await subscription.cancel();
    registry.dispose();
  });

  test('normalizes foreground and background future failures', () async {
    final registry = BackgroundToolJobRegistry();
    var nextId = 0;
    final racer = BackgroundToolRacer(
      registry: registry,
      createJobId: () => 'job-${++nextId}',
    );

    final foreground = await racer.race(
      call: FunctionCall(id: 'call-fg', name: 'fail', arguments: '{}'),
      work: Future<ExecutionToolResult>.error(StateError('foreground')),
      threshold: const Duration(seconds: 1),
      systemReminders: {},
    );
    expect(foreground.result.isError, isTrue);
    expect(
      _text(foreground.result),
      'Error executing fail: Bad state: foreground',
    );

    final work = Completer<ExecutionToolResult>();
    final background = await racer.race(
      call: FunctionCall(id: 'call-bg', name: 'fail', arguments: '{}'),
      work: work.future,
      threshold: const Duration(milliseconds: 5),
      systemReminders: {},
    );
    work.completeError(StateError('background'));
    await Future<void>.delayed(Duration.zero);

    final job = registry[background.backgroundedJob!.jobId]!;
    expect(job.status, BackgroundToolJobStatus.failed);
    expect(job.error, isA<StateError>());
    expect(job.resultText(), 'Error executing fail: Bad state: background');
    registry.dispose();
  });
}

ExecutionToolResult _result(String text) {
  return ExecutionToolResult(
    id: 'call-1',
    name: 'fast',
    arguments: '{}',
    content: [TextPart(text)],
  );
}

String _text(ExecutionToolResult result) {
  return result.content.whereType<TextPart>().single.text;
}
