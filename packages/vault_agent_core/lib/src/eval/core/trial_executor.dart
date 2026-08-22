import 'dart:async';

import 'package:logging/logging.dart';

import '../graders/score.dart';
import '../observability/trace_exporter.dart';
import 'agent_harness_factory.dart';
import 'eval_environment.dart';
import 'eval_suite.dart';
import 'outcome.dart';
import 'transcript.dart';
import 'transcript_recorder.dart';
import 'trial.dart';
import 'trial_planner.dart';
import 'trial_result.dart';

final _logger = Logger('TrialExecutor');

/// Executes the complete lifecycle of one planned trial.
class TrialExecutor {
  final EvalEnvironment environment;
  final AgentHarnessFactory harnessFactory;
  final TraceExporter exporter;
  final Duration defaultTimeout;

  const TrialExecutor({
    required this.environment,
    required this.harnessFactory,
    required this.exporter,
    required this.defaultTimeout,
  });

  Future<TrialResult> run({
    required PlannedTrial planned,
    required EvalSuite suite,
    required String runName,
  }) async {
    final task = planned.task;
    final trialIndex = planned.trialIndex;

    final startedAt = DateTime.now();
    Trial trial = Trial(
      runName: runName,
      suiteName: suite.name,
      taskId: task.id,
      trialIndex: trialIndex,
      startedAt: startedAt,
      endedAt: startedAt,
      status: TrialStatus.errored,
    );

    try {
      await exporter.onTrialStart(trial, task);
    } catch (error, stackTrace) {
      _logger.warning('exporter.onTrialStart failed', error, stackTrace);
    }

    final timeout = task.timeout ?? defaultTimeout;
    Transcript? transcript;
    Outcome? outcome;
    var status = TrialStatus.errored;
    String? failureReason;

    final context = await environment.prepare(trial: trial, task: task);
    final recorder = EvalTranscriptRecorder(
      controller: context.controller,
      startedAt: startedAt,
      now: context.clock.now,
    );
    try {
      final session = await harnessFactory.create(
        task: task,
        trial: trial,
        context: context,
      );
      try {
        final result = await session.run().timeout(timeout);
        transcript = result.transcript;
        outcome = result.outcome;
        status = TrialStatus.passed;
      } on TimeoutException catch (error) {
        status = TrialStatus.timedOut;
        failureReason = 'Trial timed out after $timeout: $error';
      } catch (error, stackTrace) {
        status = TrialStatus.errored;
        failureReason = '$error';
        _logger.warning('trial run threw', error, stackTrace);
      } finally {
        await session.dispose();
      }
    } finally {
      await Future<void>.delayed(Duration.zero);
      final currentTranscript = transcript;
      if (currentTranscript == null || _isEmptyTranscript(currentTranscript)) {
        transcript = recorder.snapshot();
      }
      await recorder.dispose();
      await environment.dispose(context);
    }

    final endedAt = DateTime.now();
    final effectiveTranscript =
        transcript ??
        Transcript(
          messages: const [],
          toolCalls: const [],
          metrics: const TranscriptMetrics(
            nTurns: 0,
            nToolCalls: 0,
            nTotalTokens: 0,
          ),
        );
    outcome ??= const Outcome(environmentState: {});

    final scores = <Score>[];
    for (final grader in task.graders) {
      try {
        final score = await grader.grade(
          trial: trial,
          transcript: effectiveTranscript,
          outcome: outcome,
          context: context,
          referenceSolution: task.referenceSolution,
        );
        scores.add(score);
      } catch (error, stackTrace) {
        _logger.warning('grader ${grader.name} threw', error, stackTrace);
        scores.add(
          Score(
            graderName: grader.name,
            value: null,
            passed: null,
            rationale: 'grader exception: $error',
          ),
        );
      }
    }

    final passed = scores
        .where((score) => score.passed != null)
        .every((score) => score.passed == true);
    if (status == TrialStatus.passed && !passed) {
      status = TrialStatus.failed;
    }

    trial = Trial(
      runName: trial.runName,
      suiteName: trial.suiteName,
      taskId: trial.taskId,
      trialIndex: trial.trialIndex,
      startedAt: startedAt,
      endedAt: endedAt,
      status: status,
      failureReason: failureReason,
    );

    final result = TrialResult(
      trial: trial,
      transcript: effectiveTranscript,
      outcome: outcome,
      scores: scores,
    );

    try {
      await exporter.onTrialEnd(
        trial: trial,
        transcript: effectiveTranscript,
        outcome: outcome,
        scores: scores,
      );
    } catch (error, stackTrace) {
      _logger.warning('exporter.onTrialEnd failed', error, stackTrace);
    }

    return result;
  }

  bool _isEmptyTranscript(Transcript transcript) {
    final metrics = transcript.metrics;
    return transcript.messages.isEmpty &&
        transcript.toolCalls.isEmpty &&
        transcript.reasoningSteps.isEmpty &&
        transcript.events.isEmpty &&
        metrics.nTurns == 0 &&
        metrics.nToolCalls == 0 &&
        metrics.nTotalTokens == 0 &&
        metrics.timeToFirstToken == null &&
        metrics.timeToLastToken == null &&
        metrics.outputTokensPerSec == null;
  }
}
