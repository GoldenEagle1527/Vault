import '../llm/rate_limit_gate.dart';
import '../llm/recording_store.dart';
import '../observability/composite_trace_exporter.dart';
import '../observability/trace_exporter.dart';
import '../reporting/report_store.dart';
import 'agent_harness_factory.dart';
import 'eval_environment.dart';
import 'eval_run_report.dart';
import 'eval_suite.dart';
import 'eval_task.dart';
import 'trial_executor.dart';
import 'trial_planner.dart';
import 'trial_result.dart';
import 'trial_scheduler.dart';

/// Runs evaluation suites with bounded concurrency and optional rate
/// limiting. See RFC §6.8 and §6.15.
class EvalRunner {
  final EvalEnvironment environment;
  final AgentHarnessFactory harnessFactory;
  final TraceExporter exporter;

  /// Optional. If set, the runner exposes the store to the harness via
  /// the EvalContext (the harness chooses to wrap its LLMClient or not).
  final RecordingStore? recordingStore;

  /// Optional persistent store for run reports. When set, [runSuite]
  /// automatically saves the final [EvalRunReport] for cross-run analysis
  /// (saturation, graduation, diff).
  final ReportStore? reportStore;

  /// Optional. The harness can pull this from EvalContext too.
  final RateLimitGate rateLimitGate;

  /// Default per-trial timeout. Tasks may override via [EvalTask.timeout].
  final Duration defaultTimeout;

  EvalRunner({
    required this.environment,
    required this.harnessFactory,
    List<TraceExporter> exporters = const [],
    this.recordingStore,
    this.reportStore,
    RateLimitGate? rateLimitGate,
    this.defaultTimeout = const Duration(minutes: 5),
  }) : exporter = exporters.length == 1
           ? exporters.first
           : CompositeTraceExporter(exporters),
       rateLimitGate = rateLimitGate ?? const NoopRateLimitGate();
}

extension EvalRunnerOps on EvalRunner {
  /// Run all tasks in [suite], honoring [concurrency] and per-task
  /// trialsPerRun. Returns the aggregated report.
  Future<EvalRunReport> runSuite({
    required String runName,
    required EvalSuite suite,
    int concurrency = 8,
    int? trialsOverride,
    bool Function(EvalTask)? filter,
  }) async {
    final problems = suite.validate();
    if (problems.isNotEmpty) {
      throw StateError(
        'Invalid suite "${suite.name}":\n${problems.join('\n')}',
      );
    }

    final tasks = filter == null
        ? suite.tasks
        : suite.tasks.where(filter).toList();

    final plannedTrials = const TrialPlanner().plan(
      tasks: tasks,
      trialsOverride: trialsOverride,
    );
    final startedAt = DateTime.now();
    final executor = TrialExecutor(
      environment: environment,
      harnessFactory: harnessFactory,
      exporter: exporter,
      defaultTimeout: defaultTimeout,
    );
    final results = await TrialScheduler(concurrency: concurrency).run(
      trials: plannedTrials,
      execute: (planned) =>
          executor.run(planned: planned, suite: suite, runName: runName),
    );

    final endedAt = DateTime.now();

    // Run-level aggregate scores: report top-line metrics.
    final report = EvalRunReport(
      runName: runName,
      suite: suite,
      trials: results,
      startedAt: startedAt,
      endedAt: endedAt,
    );

    final aggregateScores = <String, double>{
      'task_pass_rate': report.taskPassRate,
      'trial_pass_rate': report.trialPassRate,
      ...report.graderMeans.map((k, v) => MapEntry('grader_mean.$k', v)),
    };

    await exporter.onRunEnd(
      runName: runName,
      suiteName: suite.name,
      aggregateScores: aggregateScores,
    );
    await exporter.dispose();
    if (recordingStore != null) await recordingStore!.flush();
    if (reportStore != null) await reportStore!.save(report);

    return report;
  }

  /// Convenience: run a single task. Useful for ad-hoc debugging or for
  /// rerunning a flaky task with extra trials.
  ///
  /// Internally wraps the task in a one-off [EvalSuite] of kind
  /// [SuiteKind.mixed]. The synthetic suite is **not** persisted to the
  /// report store (the run is for diagnosis, not for cross-run analysis).
  Future<List<TrialResult>> runTask({
    required String runName,
    required EvalTask task,
    required String agentName,
    int? trialsOverride,
  }) async {
    final tempSuite = EvalSuite(
      name: '_one_off/${task.id}',
      agentName: agentName,
      kind: SuiteKind.mixed,
      tasks: [task],
    );
    // Use a one-off runner that skips the persistent report store but
    // keeps every other behavior (exporters, recording, rate gate).
    final scopedRunner = EvalRunner(
      environment: environment,
      harnessFactory: harnessFactory,
      exporters: exporter is CompositeTraceExporter
          ? (exporter as CompositeTraceExporter).exporters
          : [exporter],
      recordingStore: recordingStore,
      // Intentionally null: this is a debug run, don't pollute history.
      // reportStore: null,
      rateLimitGate: rateLimitGate,
      defaultTimeout: defaultTimeout,
    );
    final report = await scopedRunner.runSuite(
      runName: runName,
      suite: tempSuite,
      concurrency: 1,
      trialsOverride: trialsOverride,
    );
    return report.trials;
  }
}
