import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';

import '../core/eval_run_report.dart';
import '../core/outcome.dart';
import '../core/transcript.dart';
import '../core/trial.dart';
import '../core/trial_result.dart';
import '../graders/score.dart';
import 'report_models.dart';
import 'report_store_interface.dart';

final _logger = Logger('ReportStore');

/// 文件系统实现。
///
/// 布局：
/// ```
/// rootDir/
///   index.jsonl         # 每行一个 run 索引
///   reports/
///     {safe_runName}.json
/// ```
class FileReportStore implements ReportStore {
  final Directory rootDir;
  final File indexFile;
  final Directory reportsDir;

  FileReportStore(this.rootDir)
    : indexFile = File('${rootDir.path}/index.jsonl'),
      reportsDir = Directory('${rootDir.path}/reports') {
    rootDir.createSync(recursive: true);
    reportsDir.createSync(recursive: true);
    if (!indexFile.existsSync()) indexFile.createSync();
  }

  static String _safeName(String s) =>
      s.replaceAll(RegExp(r'[^A-Za-z0-9_.\-]'), '_');

  File _reportFile(String runName) =>
      File('${reportsDir.path}/${_safeName(runName)}.json');

  @override
  Future<void> save(EvalRunReport report) async {
    final entry = RunIndexEntry(
      runName: report.runName,
      suiteName: report.suite.name,
      suiteKind: report.suite.kind,
      startedAt: report.startedAt,
      endedAt: report.endedAt,
      taskPassRate: report.taskPassRate,
      trialPassRate: report.trialPassRate,
      numTrials: report.trials.length,
    );
    await indexFile.writeAsString(
      '${jsonEncode(entry.toJson())}\n',
      mode: FileMode.append,
      flush: true,
    );

    final body = {
      'runName': report.runName,
      'suite': SuiteSnapshot.from(report.suite).toJson(),
      'startedAt': report.startedAt.toIso8601String(),
      'endedAt': report.endedAt.toIso8601String(),
      'trials': report.trials.map((t) => t.toJson()).toList(),
    };
    await _reportFile(
      report.runName,
    ).writeAsString(jsonEncode(body), flush: true);
  }

  @override
  Future<PersistedRunReport?> load(String runName) async {
    final f = _reportFile(runName);
    if (!await f.exists()) return null;
    final body = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
    return _decode(body);
  }

  @override
  Future<List<RunIndexEntry>> listRecent({
    required String suiteName,
    int limit = 10,
  }) async {
    final entries = await _readIndex();
    final filtered = entries.where((e) => e.suiteName == suiteName).toList();
    filtered.sort((a, b) => b.startedAt.compareTo(a.startedAt));
    return filtered.take(limit).toList();
  }

  @override
  Future<List<PersistedRunReport>> loadRecent({
    required String suiteName,
    int limit = 10,
  }) async {
    final indices = await listRecent(suiteName: suiteName, limit: limit);
    final out = <PersistedRunReport>[];
    for (final idx in indices) {
      final r = await load(idx.runName);
      if (r != null) out.add(r);
    }
    return out;
  }

  @override
  Future<List<String>> listRunNames({String? suiteFilter, int? limit}) async {
    final entries = await _readIndex();
    var filtered = suiteFilter == null
        ? entries
        : entries.where((e) => e.suiteName == suiteFilter).toList();
    filtered.sort((a, b) => b.startedAt.compareTo(a.startedAt));
    if (limit != null) filtered = filtered.take(limit).toList();
    return filtered.map((e) => e.runName).toList();
  }

  TrialResult _trialResultFromJson(Map<String, dynamic> json) {
    return TrialResult(
      trial: Trial.fromJson(json['trial'] as Map<String, dynamic>),
      transcript: Transcript.fromJson(
        json['transcript'] as Map<String, dynamic>,
      ),
      outcome: Outcome.fromJson(json['outcome'] as Map<String, dynamic>),
      scores: ((json['scores'] as List?) ?? const [])
          .map((s) => Score.fromJson(s as Map<String, dynamic>))
          .toList(),
    );
  }

  PersistedRunReport _decode(Map<String, dynamic> body) {
    return PersistedRunReport(
      runName: body['runName'] as String,
      suite: SuiteSnapshot.fromJson(body['suite'] as Map<String, dynamic>),
      startedAt: DateTime.parse(body['startedAt'] as String),
      endedAt: DateTime.parse(body['endedAt'] as String),
      trials: (body['trials'] as List)
          .map((t) => _trialResultFromJson(t as Map<String, dynamic>))
          .toList(),
    );
  }

  Future<List<RunIndexEntry>> _readIndex() async {
    if (!await indexFile.exists()) return const [];
    final entries = <RunIndexEntry>[];
    final lines = await indexFile.readAsLines();
    for (final line in lines) {
      if (line.trim().isEmpty) continue;
      try {
        entries.add(
          RunIndexEntry.fromJson(jsonDecode(line) as Map<String, dynamic>),
        );
      } catch (e, st) {
        _logger.warning('skipping malformed index line', e, st);
      }
    }
    return entries;
  }
}
