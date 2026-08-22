import 'dart:convert';
import 'dart:io';

import 'package:vault_agent_core/eval.dart';
import 'package:vault_agent_core/src/eval/reporting/file_report_store.dart'
    as file_store;
import 'package:vault_agent_core/src/eval/reporting/report_models.dart'
    as report_models;
import 'package:vault_agent_core/src/eval/reporting/report_store_interface.dart'
    as report_store_api;
import 'package:test/test.dart';

import '_helpers.dart';

class _StubTask implements EvalTask {
  @override
  final String id;
  @override
  final List<Grader> graders;
  @override
  final ReferenceSolution? referenceSolution = null;
  @override
  final int trialsPerRun = 1;
  @override
  final Map<String, String> metadata = const {};
  @override
  final Map<String, dynamic> input = const {};
  @override
  final String description = '';
  @override
  final Duration? timeout = null;
  _StubTask({required this.id, required this.graders});
}

class _NoopGrader extends CodeGrader {
  @override
  String get name => 'noop';
  @override
  Future<List<Assertion>> computeAssertions({
    required Trial trial,
    required Transcript transcript,
    required Outcome outcome,
    required EvalContext context,
    ReferenceSolution? referenceSolution,
  }) async => const [Assertion(description: 'always', passed: true)];
}

EvalRunReport _buildRun({
  required String name,
  required Map<String, double> taskPassRates,
  int trialsPerTask = 4,
}) {
  final taskIds = taskPassRates.keys.toList();
  final trials = <TrialResult>[];
  for (final id in taskIds) {
    final pr = taskPassRates[id]!;
    final passing = (pr * trialsPerTask).round();
    for (var i = 0; i < trialsPerTask; i++) {
      trials.add(
        makeTrialResult(
          runName: name,
          suiteName: 's',
          taskId: id,
          trialIndex: i,
          scores: [
            i < passing
                ? okScore('quality', value: 1.0)
                : failScore('quality', value: 0.0),
          ],
        ),
      );
    }
  }
  return EvalRunReport(
    runName: name,
    suite: EvalSuite(
      name: 's',
      agentName: 'agent_x',
      kind: SuiteKind.regression,
      tasks: [
        for (final id in taskIds) _StubTask(id: id, graders: [_NoopGrader()]),
      ],
    ),
    trials: trials,
    startedAt: DateTime(2025),
    endedAt: DateTime(2025),
  );
}

void main() {
  group('diffRunReports', () {
    test('classifies regressed / improved / unchanged via threshold', () {
      final baseline = _buildRun(
        name: 'main',
        taskPassRates: const {
          'a': 1.0, // unchanged
          'b': 1.0, // regress
          'c': 0.0, // improve
        },
      );
      final current = _buildRun(
        name: 'pr',
        taskPassRates: const {'a': 1.0, 'b': 0.0, 'c': 1.0},
      );
      final diff = current.diffWith(baseline, significanceThreshold: 0.05);

      final regressed = diff.transitions
          .where((t) => t.regressed)
          .map((t) => t.taskId)
          .toList();
      final improved = diff.transitions
          .where((t) => t.improved)
          .map((t) => t.taskId)
          .toList();
      final unchanged = diff.transitions
          .where((t) => t.unchanged)
          .map((t) => t.taskId)
          .toList();

      expect(regressed, contains('b'));
      expect(improved, contains('c'));
      expect(unchanged, contains('a'));
    });

    test('reports added and removed task ids', () {
      final baseline = _buildRun(
        name: 'main',
        taskPassRates: const {'a': 1.0, 'old': 1.0},
      );
      final current = _buildRun(
        name: 'pr',
        taskPassRates: const {'a': 1.0, 'new': 0.5},
      );
      final diff = current.diffWith(baseline);
      expect(diff.addedTaskIds, ['new']);
      expect(diff.removedTaskIds, ['old']);
    });

    test('metricDeltas reflects task and trial pass-rate change', () {
      final baseline = _buildRun(name: 'main', taskPassRates: const {'a': 1.0});
      final current = _buildRun(name: 'pr', taskPassRates: const {'a': 0.0});
      final diff = current.diffWith(baseline);
      expect(diff.metricDeltas['task_pass_rate'], closeTo(-1.0, 1e-9));
      expect(diff.metricDeltas['trial_pass_rate'], closeTo(-1.0, 1e-9));
    });

    test('toMarkdown lists regressed tasks under a 🚨 header', () {
      final baseline = _buildRun(name: 'main', taskPassRates: const {'a': 1.0});
      final current = _buildRun(name: 'pr', taskPassRates: const {'a': 0.0});
      final md = current.diffWith(baseline).toMarkdown();
      expect(md, contains('Regressed tasks'));
      expect(md, contains('`a`'));
    });
  });

  group('FileReportStore round-trip', () {
    late Directory tmp;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('store_');
    });
    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test(
      'save → load round-trips the run and preserves trial results',
      () async {
        final store = FileReportStore(tmp);
        final r = _buildRun(
          name: 'r1',
          taskPassRates: const {'a': 1.0, 'b': 0.5},
        );
        await store.save(r);
        final loaded = await store.load('r1');
        expect(loaded, isNotNull);
        expect(loaded!.runName, 'r1');
        expect(loaded.suite.taskIds, containsAll(['a', 'b']));
        expect(loaded.trials.length, r.trials.length);
      },
    );

    test('listRunNames newest-first; listRecent filters by suite', () async {
      final store = FileReportStore(tmp);
      await store.save(
        EvalRunReport(
          runName: 'oldest',
          suite: EvalSuite(
            name: 'one',
            agentName: 'agent_x',
            kind: SuiteKind.mixed,
            tasks: [
              _StubTask(id: 'a', graders: [_NoopGrader()]),
            ],
          ),
          trials: [
            makeTrialResult(
              runName: 'oldest',
              suiteName: 'one',
              taskId: 'a',
              trialIndex: 0,
              scores: [okScore('noop')],
            ),
          ],
          startedAt: DateTime(2024),
          endedAt: DateTime(2024),
        ),
      );
      await store.save(
        EvalRunReport(
          runName: 'newest',
          suite: EvalSuite(
            name: 'two',
            agentName: 'agent_x',
            kind: SuiteKind.mixed,
            tasks: [
              _StubTask(id: 'a', graders: [_NoopGrader()]),
            ],
          ),
          trials: [
            makeTrialResult(
              runName: 'newest',
              suiteName: 'two',
              taskId: 'a',
              trialIndex: 0,
              scores: [okScore('noop')],
            ),
          ],
          startedAt: DateTime(2026),
          endedAt: DateTime(2026),
        ),
      );

      final all = await store.listRunNames();
      expect(all, ['newest', 'oldest']);

      final twoOnly = await store.listRecent(suiteName: 'two');
      expect(twoOnly.map((e) => e.runName), ['newest']);
    });

    test('partitioned libraries retain the facade type identities', () {
      final report_store_api.ReportStore directStore =
          file_store.FileReportStore(tmp);
      final ReportStore facadeStore = directStore;
      const directModel = report_models.SuiteSnapshot(
        name: 'suite',
        kind: SuiteKind.mixed,
        taskIds: ['task'],
        taskPassThreshold: 1,
        requireReferenceSolution: false,
      );
      const SuiteSnapshot facadeModel = directModel;

      expect(facadeStore, isA<FileReportStore>());
      expect(facadeModel.name, 'suite');
    });

    test('preserves index and report JSON shapes', () async {
      final store = FileReportStore(tmp);
      final run = _buildRun(
        name: 'json-shape',
        taskPassRates: const {'a': 1.0},
      );

      await store.save(run);

      final indexLines = await File('${tmp.path}/index.jsonl').readAsLines();
      expect(indexLines, hasLength(1));
      expect(jsonDecode(indexLines.single), {
        'runName': 'json-shape',
        'suiteName': 's',
        'suiteKind': 'regression',
        'startedAt': '2025-01-01T00:00:00.000',
        'endedAt': '2025-01-01T00:00:00.000',
        'taskPassRate': 1.0,
        'trialPassRate': 1.0,
        'numTrials': 4,
      });

      final reportJson =
          jsonDecode(
                await File(
                  '${tmp.path}/reports/json-shape.json',
                ).readAsString(),
              )
              as Map<String, dynamic>;
      expect(reportJson.keys, [
        'runName',
        'suite',
        'startedAt',
        'endedAt',
        'trials',
      ]);
      expect((reportJson['suite'] as Map<String, dynamic>).keys, [
        'name',
        'kind',
        'taskIds',
        'taskPassThreshold',
        'requireReferenceSolution',
      ]);
    });

    test('sanitizes report paths without changing indexed run names', () async {
      final store = FileReportStore(tmp);
      await store.save(
        _buildRun(
          name: r'folder/run:name\part',
          taskPassRates: const {'a': 1.0},
        ),
      );

      expect(
        await File('${tmp.path}/reports/folder_run_name_part.json').exists(),
        isTrue,
      );
      expect(await store.listRunNames(), [r'folder/run:name\part']);
      expect(await store.load(r'folder/run:name\part'), isNotNull);
    });

    test('skips malformed index lines and keeps newest-first limits', () async {
      final store = FileReportStore(tmp);
      await store.save(
        _buildRun(name: 'older', taskPassRates: const {'a': 1.0}),
      );
      final newer = _buildRun(name: 'newer', taskPassRates: const {'a': 1.0});
      await store.indexFile.writeAsString(
        'not-json\n${jsonEncode({'runName': newer.runName, 'suiteName': newer.suite.name, 'suiteKind': newer.suite.kind.name, 'startedAt': DateTime(2026).toIso8601String(), 'endedAt': DateTime(2026).toIso8601String(), 'taskPassRate': newer.taskPassRate, 'trialPassRate': newer.trialPassRate, 'numTrials': newer.trials.length})}\n',
        mode: FileMode.append,
      );

      expect(await store.listRunNames(limit: 1), ['newer']);
      expect(
        (await store.listRecent(
          suiteName: 's',
          limit: 2,
        )).map((entry) => entry.runName),
        ['newer', 'older'],
      );
    });

    test('propagates filesystem write errors', () async {
      final store = FileReportStore(tmp);
      await store.indexFile.delete();
      await Directory(store.indexFile.path).create();

      await expectLater(
        store.save(
          _buildRun(name: 'io-error', taskPassRates: const {'a': 1.0}),
        ),
        throwsA(isA<FileSystemException>()),
      );
    });
  });
}
