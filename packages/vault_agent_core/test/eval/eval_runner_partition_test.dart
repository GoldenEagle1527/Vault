import 'package:test/test.dart';
import 'package:vault_agent_core/eval.dart';
import 'package:vault_agent_core/src/eval/core/trial_executor.dart';
import 'package:vault_agent_core/src/eval/core/trial_planner.dart';
import 'package:vault_agent_core/src/eval/core/trial_scheduler.dart';
import 'package:vault_agent_core/vault_agent_core.dart';

import '_helpers.dart';

void main() {
  group('TrialPlanner', () {
    test('expands tasks in stable task and trial-index order', () {
      final first = _Task(id: 'first', trialsPerRun: 2);
      final second = _Task(id: 'second', trialsPerRun: 1);

      final planned = const TrialPlanner().plan(tasks: [first, second]);

      expect(
        planned.map((trial) => '${trial.task.id}#${trial.trialIndex}').toList(),
        ['first#0', 'first#1', 'second#0'],
      );
    });

    test('trialsOverride replaces every task trial count', () {
      final planned = const TrialPlanner().plan(
        tasks: [
          _Task(id: 'a', trialsPerRun: 1),
          _Task(id: 'b', trialsPerRun: 3),
        ],
        trialsOverride: 2,
      );

      expect(planned, hasLength(4));
      expect(planned.map((trial) => trial.trialIndex), [0, 1, 0, 1]);
    });
  });

  group('TrialScheduler', () {
    test('bounds concurrency and returns completion-ordered results', () async {
      final task = _Task(id: 'task', trialsPerRun: 3);
      final planned = const TrialPlanner().plan(tasks: [task]);
      var active = 0;
      var maxActive = 0;

      final results = await const TrialScheduler(concurrency: 2).run(
        trials: planned,
        execute: (trial) async {
          active++;
          if (active > maxActive) maxActive = active;
          await Future<void>.delayed(
            Duration(milliseconds: trial.trialIndex == 0 ? 40 : 5),
          );
          active--;
          return trial.trialIndex;
        },
      );

      expect(maxActive, 2);
      expect(results, [1, 2, 0]);
    });
  });

  group('TrialExecutor', () {
    test('owns one trial lifecycle and applies grader status', () async {
      final environment = _Environment();
      final exporter = _Exporter();
      final task = _Task(id: 'direct', graders: [_AlwaysFailGrader()]);
      final suite = EvalSuite(
        name: 'suite',
        agentName: 'agent',
        kind: SuiteKind.mixed,
        tasks: [task],
      );
      final executor = TrialExecutor(
        environment: environment,
        harnessFactory: _HarnessFactory(),
        exporter: exporter,
        defaultTimeout: const Duration(seconds: 1),
      );

      final result = await executor.run(
        planned: PlannedTrial(task: task, trialIndex: 0),
        suite: suite,
        runName: 'run',
      );

      expect(result.trial.status, TrialStatus.failed);
      expect(result.scores.single.passed, isFalse);
      expect(environment.prepares, 1);
      expect(environment.disposes, 1);
      expect(exporter.events, ['start', 'end']);
    });
  });
}

class _Task implements EvalTask {
  @override
  final String id;

  @override
  final int trialsPerRun;

  @override
  final List<Grader> graders;

  _Task({required this.id, this.trialsPerRun = 1, this.graders = const []});

  @override
  String get description => '';

  @override
  Map<String, dynamic> get input => const {};

  @override
  Map<String, String> get metadata => const {};

  @override
  ReferenceSolution? get referenceSolution => null;

  @override
  Duration? get timeout => null;
}

class _Environment implements EvalEnvironment {
  int prepares = 0;
  int disposes = 0;

  @override
  Future<EvalContext> prepare({
    required Trial trial,
    required EvalTask task,
  }) async {
    prepares++;
    return EvalContext(
      clock: const SystemEvalClock(),
      llmClient: FakeLLMClient([textReply('unused')]),
      controller: AgentController(),
    );
  }

  @override
  Future<void> dispose(EvalContext context) async {
    disposes++;
    context.controller.close();
  }
}

class _HarnessFactory implements AgentHarnessFactory {
  @override
  Future<AgentHarnessSession> create({
    required EvalTask task,
    required Trial trial,
    required EvalContext context,
  }) async {
    return _Session();
  }
}

class _Session implements AgentHarnessSession {
  @override
  Future<({Outcome outcome, Transcript transcript})> run() async {
    return (
      outcome: const Outcome(environmentState: {'value': 1}),
      transcript: emptyTranscript(),
    );
  }

  @override
  Future<void> dispose() async {}
}

class _AlwaysFailGrader implements Grader {
  @override
  String get name => 'always_fail';

  @override
  GraderKind get kind => GraderKind.code;

  @override
  double get passThreshold => 1.0;

  @override
  Future<Score> grade({
    required Trial trial,
    required Transcript transcript,
    required Outcome outcome,
    required EvalContext context,
    ReferenceSolution? referenceSolution,
  }) async {
    return failScore(name);
  }
}

class _Exporter implements TraceExporter {
  final List<String> events = [];

  @override
  Future<void> onTrialStart(Trial trial, EvalTask task) async {
    events.add('start');
  }

  @override
  Future<void> onTrialEnd({
    required Trial trial,
    required Transcript transcript,
    required Outcome outcome,
    required List<Score> scores,
  }) async {
    events.add('end');
  }

  @override
  Future<void> onLLMCall({
    required Trial trial,
    required List<LLMMessage> requestMessages,
    required ModelConfig modelConfig,
    required ModelMessage? response,
    required Duration duration,
    Object? error,
  }) async {}

  @override
  Future<void> onToolCall({
    required Trial trial,
    required ToolCallRecord record,
  }) async {}

  @override
  Future<void> onRunEnd({
    required String runName,
    required String suiteName,
    required Map<String, double> aggregateScores,
  }) async {}

  @override
  Future<void> dispose() async {}
}
