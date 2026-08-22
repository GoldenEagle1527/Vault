import 'dart:io';

import '../reporting/report_store.dart';
import 'transcript_viewer.dart';

/// `dart:io` adapter for the pure [TranscriptViewer] formatting/query library.
class TranscriptViewerCli {
  final ReportStore store;
  final StringSink stdoutSink;
  final StringSink stderrSink;
  final TranscriptViewer viewer;

  const TranscriptViewerCli({
    required this.store,
    required this.stdoutSink,
    required this.stderrSink,
    this.viewer = const TranscriptViewer(),
  });

  Future<int> run(List<String> args) async {
    if (args.isEmpty) {
      stdoutSink.writeln(transcriptViewerUsage);
      return 0;
    }

    final command = args.first;
    final options = viewer.parseOptions(args.sublist(1));
    switch (command) {
      case 'list':
        return _list(options);
      case 'show':
        return _show(options);
      case 'diff':
        return _diff(options);
      case 'export':
        return _export(options);
      case '-h':
      case '--help':
        stdoutSink.writeln(transcriptViewerUsage);
        return 0;
      default:
        stderrSink.writeln('unknown command: $command');
        stdoutSink.writeln(transcriptViewerUsage);
        return 2;
    }
  }

  Future<int> _list(Map<String, String> options) async {
    final suite = options['suite'];
    final limit = int.tryParse(options['limit'] ?? '20') ?? 20;
    if (suite == null) {
      stdoutSink.write(
        viewer.formatRunNames(await store.listRunNames(limit: limit)),
      );
      return 0;
    }

    final entries = await store.listRecent(suiteName: suite, limit: limit);
    stdoutSink.write(
      viewer.formatRunSummaries([
        for (final entry in entries)
          TranscriptRunSummary(
            runName: entry.runName,
            suiteName: entry.suiteName,
            suiteKind: entry.suiteKind,
            startedAt: entry.startedAt,
            taskPassRate: entry.taskPassRate,
            trialPassRate: entry.trialPassRate,
            numTrials: entry.numTrials,
          ),
      ], suiteName: suite),
    );
    return 0;
  }

  Future<int> _show(Map<String, String> options) async {
    final value = options['trial'];
    if (value == null) {
      stderrSink.writeln('--trial RUN/TASK#INDEX is required');
      return 2;
    }
    final specification = viewer.parseTrialSpec(value);
    if (specification == null) {
      stderrSink.writeln('invalid --trial: $value (expected RUN/TASK#INDEX)');
      return 2;
    }

    final report = await store.load(specification.runName);
    if (report == null) {
      stderrSink.writeln('run not found: ${specification.runName}');
      return 1;
    }
    final trial = viewer.findTrial(_view(report), specification);
    if ((options['format'] ?? 'human') == 'json') {
      stdoutSink.writeln(viewer.formatTrialJson(trial));
    } else {
      stdoutSink.write(viewer.formatTrialHuman(trial));
    }
    return 0;
  }

  Future<int> _diff(Map<String, String> options) async {
    final taskId = options['task'];
    final runNames = (options['runs'] ?? '')
        .split(',')
        .where((name) => name.isNotEmpty)
        .toList();
    if (taskId == null || runNames.length != 2) {
      stderrSink.writeln('--task TASK_ID and --runs RUN_A,RUN_B are required');
      return 2;
    }

    final reports = <PersistedRunReport>[];
    for (final runName in runNames) {
      final report = await store.load(runName);
      if (report == null) {
        stderrSink.writeln('run not found: $runName');
        return 1;
      }
      reports.add(report);
    }
    for (final report in reports) {
      stdoutSink
        ..write(viewer.formatTaskDiff(_view(report), taskId))
        ..writeln();
    }
    return 0;
  }

  Future<int> _export(Map<String, String> options) async {
    final runName = options['run'];
    if (runName == null) {
      stderrSink.writeln('--run RUN_NAME is required');
      return 2;
    }
    final report = await store.load(runName);
    if (report == null) {
      stderrSink.writeln('run not found: $runName');
      return 1;
    }
    final run = _view(report);
    if ((options['format'] ?? 'markdown') == 'json') {
      stdoutSink.writeln(viewer.formatRunJson(run));
    } else {
      stdoutSink.writeln(viewer.formatRunMarkdown(run));
    }
    return 0;
  }

  TranscriptRunView _view(PersistedRunReport report) {
    return TranscriptRunView(
      runName: report.runName,
      suiteName: report.suite.name,
      suiteKind: report.suite.kind,
      suiteJson: report.suite.toJson(),
      startedAt: report.startedAt,
      endedAt: report.endedAt,
      trials: report.trials,
    );
  }
}

/// Backward-compatible command entry point used by `bin/transcripts.dart`.
Future<int> runTranscriptViewer(
  List<String> args, {
  StringSink? stdoutSink,
  StringSink? stderrSink,
}) {
  if (args.isEmpty) {
    (stdoutSink ?? stdout).writeln(transcriptViewerUsage);
    return Future.value(0);
  }
  final viewer = const TranscriptViewer();
  final options = viewer.parseOptions(args.sublist(1));
  final store = FileReportStore(Directory(options['store'] ?? './reports'));
  return TranscriptViewerCli(
    store: store,
    stdoutSink: stdoutSink ?? stdout,
    stderrSink: stderrSink ?? stderr,
    viewer: viewer,
  ).run(args);
}
