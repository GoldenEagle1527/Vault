import 'dart:convert';

import 'package:test/test.dart';
import 'package:vault_agent_core/eval.dart';

import '_helpers.dart';

void main() {
  const viewer = TranscriptViewer();

  group('TranscriptViewer formatter', () {
    test('parses options and trial selectors without IO', () {
      expect(viewer.parseOptions(['--limit', '5', '--verbose']), {
        'limit': '5',
        'verbose': 'true',
      });

      final specification = viewer.parseTrialSpec('run_a/task_x#2');
      expect(specification, isNotNull);
      expect(specification!.runName, 'run_a');
      expect(specification.taskId, 'task_x');
      expect(specification.trialIndex, 2);
      expect(viewer.parseTrialSpec('bad'), isNull);
    });

    test('formats a trial directly as human text and JSON', () {
      final trial = makeTrialResult(
        runName: 'run_a',
        suiteName: 'suite_a',
        taskId: 'task_x',
        trialIndex: 0,
        scores: [okScore('quality')],
      );

      final human = viewer.formatTrialHuman(trial);
      expect(human, contains('Trial: run_a / task_x #0'));
      expect(human, contains('✓ quality (1.00)'));
      expect(human, contains('--- Transcript metrics ---'));

      final json =
          jsonDecode(viewer.formatTrialJson(trial)) as Map<String, dynamic>;
      expect((json['trial'] as Map<String, dynamic>)['taskId'], 'task_x');
      expect(json['scores'], isA<List<dynamic>>());
    });

    test('queries and formats run diff and markdown directly', () {
      final passing = makeTrialResult(
        runName: 'run_a',
        suiteName: 'suite_a',
        taskId: 'task_x',
        trialIndex: 0,
        scores: [okScore('quality')],
      );
      final run = TranscriptRunView(
        runName: 'run_a',
        suiteName: 'suite_a',
        suiteKind: SuiteKind.mixed,
        suiteJson: const {'name': 'suite_a', 'kind': 'mixed'},
        startedAt: DateTime.utc(2026),
        endedAt: DateTime.utc(2026, 1, 1, 0, 0, 1),
        trials: [passing],
      );

      final specification = viewer.parseTrialSpec('run_a/task_x#0')!;
      expect(viewer.findTrial(run, specification), same(passing));
      expect(viewer.formatTaskDiff(run, 'task_x'), contains('PASS'));

      final markdown = viewer.formatRunMarkdown(run);
      expect(markdown, contains('# Run `run_a`'));
      expect(markdown, contains('## task_x #0'));
      expect(markdown, contains('Metrics: turns='));
    });
  });
}
