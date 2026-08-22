import '../core/eval_suite.dart';
import '../core/trial_result.dart';

/// 当从持久化 store 加载历史 run 时返回的"快照"。
/// trials 完整保留，但 [suite] 字段是 [SuiteSnapshot]——历史 run 中的真实
/// EvalSuite 实例（含 grader / referenceSolution 等运行时对象）已经不可
/// 重建。跨 run 分析（saturation / graduation / diff）只读元数据，够用。
class PersistedRunReport {
  final String runName;
  final SuiteSnapshot suite;
  final List<TrialResult> trials;
  final DateTime startedAt;
  final DateTime endedAt;

  const PersistedRunReport({
    required this.runName,
    required this.suite,
    required this.trials,
    required this.startedAt,
    required this.endedAt,
  });

  Duration get duration => endedAt.difference(startedAt);

  Map<String, List<TrialResult>> trialsByTask() {
    final out = <String, List<TrialResult>>{};
    for (final t in trials) {
      out.putIfAbsent(t.trial.taskId, () => []).add(t);
    }
    return out;
  }
}

/// Suite 元数据的不可执行快照。只保留分析需要的字段。
class SuiteSnapshot {
  final String name;
  final SuiteKind kind;
  final List<String> taskIds;
  final double taskPassThreshold;
  final bool requireReferenceSolution;

  const SuiteSnapshot({
    required this.name,
    required this.kind,
    required this.taskIds,
    required this.taskPassThreshold,
    required this.requireReferenceSolution,
  });

  Map<String, dynamic> toJson() => {
    'name': name,
    'kind': kind.name,
    'taskIds': taskIds,
    'taskPassThreshold': taskPassThreshold,
    'requireReferenceSolution': requireReferenceSolution,
  };

  factory SuiteSnapshot.fromJson(Map<String, dynamic> json) {
    return SuiteSnapshot(
      name: json['name'] as String,
      kind: SuiteKind.values.firstWhere((k) => k.name == json['kind']),
      taskIds: ((json['taskIds'] as List?) ?? const []).cast<String>(),
      taskPassThreshold: (json['taskPassThreshold'] as num?)?.toDouble() ?? 1.0,
      requireReferenceSolution:
          json['requireReferenceSolution'] as bool? ?? false,
    );
  }

  factory SuiteSnapshot.from(EvalSuite suite) => SuiteSnapshot(
    name: suite.name,
    kind: suite.kind,
    taskIds: suite.tasks.map((t) => t.id).toList(),
    taskPassThreshold: suite.taskPassThreshold,
    requireReferenceSolution: suite.requireReferenceSolution,
  );
}

/// 索引文件中一行的轻量元数据。
class RunIndexEntry {
  final String runName;
  final String suiteName;
  final SuiteKind suiteKind;
  final DateTime startedAt;
  final DateTime endedAt;
  final double taskPassRate;
  final double trialPassRate;
  final int numTrials;

  const RunIndexEntry({
    required this.runName,
    required this.suiteName,
    required this.suiteKind,
    required this.startedAt,
    required this.endedAt,
    required this.taskPassRate,
    required this.trialPassRate,
    required this.numTrials,
  });

  Map<String, dynamic> toJson() => {
    'runName': runName,
    'suiteName': suiteName,
    'suiteKind': suiteKind.name,
    'startedAt': startedAt.toIso8601String(),
    'endedAt': endedAt.toIso8601String(),
    'taskPassRate': taskPassRate,
    'trialPassRate': trialPassRate,
    'numTrials': numTrials,
  };

  factory RunIndexEntry.fromJson(Map<String, dynamic> json) {
    return RunIndexEntry(
      runName: json['runName'] as String,
      suiteName: json['suiteName'] as String,
      suiteKind: SuiteKind.values.firstWhere(
        (k) => k.name == json['suiteKind'],
      ),
      startedAt: DateTime.parse(json['startedAt'] as String),
      endedAt: DateTime.parse(json['endedAt'] as String),
      taskPassRate: (json['taskPassRate'] as num).toDouble(),
      trialPassRate: (json['trialPassRate'] as num).toDouble(),
      numTrials: json['numTrials'] as int,
    );
  }
}
