import 'dart:convert';

import '../core/eval_suite.dart';
import '../core/trial_result.dart';
import '../graders/score.dart';

/// Command-line help shared by the native adapter and formatter tests.
const String transcriptViewerUsage = r'''
Usage: transcripts <command> [options]

Commands:
  list                          List recent runs.
    --suite NAME                Filter by suite.
    --limit N                   Max rows (default 20).

  show                          Show one trial.
    --trial RUN/TASK#INDEX      e.g. card_v3/card_001#0
    --format human|json         (default human)

  diff                          Compare same task across two runs.
    --task TASK_ID              Required.
    --runs RUN_A,RUN_B          Required.

  export                        Export run as one markdown blob.
    --run RUN_NAME              Required.
    --format markdown|json      (default markdown)

Common options:
  --store DIR                   Report store directory (default: ./reports)
''';

/// Parsed `RUN/TASK#INDEX` selector used by the viewer.
class TranscriptTrialSpec {
  final String runName;
  final String taskId;
  final int trialIndex;

  const TranscriptTrialSpec(this.runName, this.taskId, this.trialIndex);
}

/// Data needed to render one persisted run without depending on its storage.
class TranscriptRunView {
  final String runName;
  final String suiteName;
  final SuiteKind suiteKind;
  final Map<String, dynamic> suiteJson;
  final DateTime startedAt;
  final DateTime endedAt;
  final List<TrialResult> trials;

  const TranscriptRunView({
    required this.runName,
    required this.suiteName,
    required this.suiteKind,
    required this.suiteJson,
    required this.startedAt,
    required this.endedAt,
    required this.trials,
  });
}

/// Lightweight row used by the filtered `list` command.
class TranscriptRunSummary {
  final String runName;
  final String suiteName;
  final SuiteKind suiteKind;
  final DateTime startedAt;
  final double taskPassRate;
  final double trialPassRate;
  final int numTrials;

  const TranscriptRunSummary({
    required this.runName,
    required this.suiteName,
    required this.suiteKind,
    required this.startedAt,
    required this.taskPassRate,
    required this.trialPassRate,
    required this.numTrials,
  });
}

/// Pure parsing, querying, and formatting for transcript viewer front ends.
///
/// This class deliberately has no `dart:io` or report-store dependency.
class TranscriptViewer {
  const TranscriptViewer();

  Map<String, String> parseOptions(List<String> args) {
    final out = <String, String>{};
    for (var i = 0; i < args.length; i++) {
      final argument = args[i];
      if (argument.startsWith('--')) {
        final key = argument.substring(2);
        final value = (i + 1 < args.length && !args[i + 1].startsWith('--'))
            ? args[++i]
            : 'true';
        out[key] = value;
      }
    }
    return out;
  }

  TranscriptTrialSpec? parseTrialSpec(String value) {
    final hashIndex = value.lastIndexOf('#');
    final slashIndex = value.indexOf('/');
    if (hashIndex <= 0 || slashIndex <= 0 || hashIndex <= slashIndex) {
      return null;
    }
    final trialIndex = int.tryParse(value.substring(hashIndex + 1));
    if (trialIndex == null) return null;
    return TranscriptTrialSpec(
      value.substring(0, slashIndex),
      value.substring(slashIndex + 1, hashIndex),
      trialIndex,
    );
  }

  TrialResult findTrial(
    TranscriptRunView run,
    TranscriptTrialSpec specification,
  ) {
    return run.trials.firstWhere(
      (trial) =>
          trial.trial.taskId == specification.taskId &&
          trial.trial.trialIndex == specification.trialIndex,
      orElse: () => throw StateError('trial not found in run'),
    );
  }

  String formatRunNames(List<String> names) {
    if (names.isEmpty) return 'No runs found.\n';
    return '${names.join('\n')}\n';
  }

  String formatRunSummaries(
    List<TranscriptRunSummary> entries, {
    required String suiteName,
  }) {
    if (entries.isEmpty) {
      return 'No runs found for suite "$suiteName".\n';
    }
    final buffer = StringBuffer()
      ..writeln(
        [
          'Run',
          'Suite',
          'Kind',
          'Started',
          'Tasks pass',
          'Trials pass',
          '#trials',
        ].join('\t'),
      );
    for (final entry in entries) {
      buffer.writeln(
        [
          entry.runName,
          entry.suiteName,
          entry.suiteKind.name,
          entry.startedAt.toIso8601String(),
          '${(entry.taskPassRate * 100).toStringAsFixed(1)}%',
          '${(entry.trialPassRate * 100).toStringAsFixed(1)}%',
          entry.numTrials,
        ].join('\t'),
      );
    }
    return buffer.toString();
  }

  String formatTrialJson(TrialResult trial) => jsonEncode(trial.toJson());

  String formatTrialHuman(TrialResult result) {
    final trial = result.trial;
    final buffer = StringBuffer()
      ..writeln(
        'Trial: ${trial.runName} / ${trial.taskId} #${trial.trialIndex}',
      )
      ..writeln('Status: ${trial.status.name}')
      ..writeln('Duration: ${trial.duration}')
      ..writeln('All graders passed: ${result.allGradersPassed}');
    if (trial.failureReason != null) {
      buffer.writeln('Failure reason: ${trial.failureReason}');
    }
    buffer
      ..writeln()
      ..writeln('--- Scores ---');
    for (final score in result.scores) {
      buffer.writeln(formatScore(score));
    }
    buffer
      ..writeln()
      ..writeln('--- Outcome ---')
      ..writeln(
        const JsonEncoder.withIndent(
          '  ',
        ).convert(result.outcome.environmentState),
      )
      ..writeln()
      ..writeln('--- Transcript metrics ---');
    final metrics = result.transcript.metrics;
    buffer
      ..writeln(
        'turns=${metrics.nTurns} tools=${metrics.nToolCalls} '
        'tokens=${metrics.nTotalTokens}',
      )
      ..writeln()
      ..writeln('--- Messages ---');
    for (final message in result.transcript.messages) {
      final json = message.toJson();
      buffer.writeln('[${json['role']}] ${previewText(json)}');
    }
    buffer
      ..writeln()
      ..writeln('--- Tool calls ---');
    for (final call in result.transcript.toolCalls) {
      buffer.writeln(
        '${call.toolName}(${jsonEncode(call.arguments)})'
        '${call.isError ? " [ERROR]" : ""}',
      );
    }
    return buffer.toString();
  }

  String formatScore(Score score) {
    final pass = score.passed == null ? '?' : (score.passed! ? '✓' : '✗');
    final value = score.value?.toStringAsFixed(2) ?? '—';
    final tail = score.rationale == null ? '' : ' — ${score.rationale}';
    return '$pass ${score.graderName} ($value)$tail';
  }

  String previewText(Map<String, dynamic> messageJson) {
    final content = messageJson['content'];
    if (content is String) {
      return content.length > 200 ? '${content.substring(0, 200)}…' : content;
    }
    if (content is List) {
      final parts = content
          .map((part) {
            if (part is Map && part['type'] == 'text') {
              return part['text']?.toString() ?? '';
            }
            if (part is Map && part['text'] is String) return part['text'];
            return '<${(part as Map?)?['type'] ?? "?"}>';
          })
          .join(' ');
      return parts.length > 200 ? '${parts.substring(0, 200)}…' : parts;
    }
    return jsonEncode(content);
  }

  String formatTaskDiff(TranscriptRunView run, String taskId) {
    final buffer = StringBuffer()
      ..writeln('=== ${run.runName} (${run.startedAt.toIso8601String()}) ===');
    final trials = run.trials
        .where((trial) => trial.trial.taskId == taskId)
        .toList();
    if (trials.isEmpty) {
      buffer.writeln('  no trials for task $taskId');
      return buffer.toString();
    }
    for (final trial in trials) {
      buffer.writeln(
        '  trial #${trial.trial.trialIndex}: '
        '${trial.allGradersPassed ? "PASS" : "FAIL"} '
        '(scores=${trial.scores.map((score) => "${score.graderName}=${score.value?.toStringAsFixed(2) ?? '?'}").join(", ")})',
      );
    }
    return buffer.toString();
  }

  String formatRunJson(TranscriptRunView run) {
    return jsonEncode({
      'runName': run.runName,
      'suite': run.suiteJson,
      'startedAt': run.startedAt.toIso8601String(),
      'endedAt': run.endedAt.toIso8601String(),
      'trials': run.trials.map((trial) => trial.toJson()).toList(),
    });
  }

  String formatRunMarkdown(TranscriptRunView run) {
    final buffer = StringBuffer()
      ..writeln('# Run `${run.runName}`')
      ..writeln()
      ..writeln('- Suite: ${run.suiteName} (${run.suiteKind.name})')
      ..writeln('- Started: ${run.startedAt.toIso8601String()}')
      ..writeln('- Trials: ${run.trials.length}')
      ..writeln();
    for (final result in run.trials) {
      final trial = result.trial;
      buffer
        ..writeln('## ${trial.taskId} #${trial.trialIndex}')
        ..writeln(
          '- Status: ${trial.status.name}'
          '${trial.failureReason == null ? '' : ' (${trial.failureReason})'}',
        );
      for (final score in result.scores) {
        buffer.writeln('- ${formatScore(score)}');
      }
      final metrics = result.transcript.metrics;
      buffer
        ..writeln()
        ..writeln(
          'Metrics: turns=${metrics.nTurns} tools=${metrics.nToolCalls} '
          'tokens=${metrics.nTotalTokens}',
        )
        ..writeln();
    }
    return buffer.toString();
  }
}
