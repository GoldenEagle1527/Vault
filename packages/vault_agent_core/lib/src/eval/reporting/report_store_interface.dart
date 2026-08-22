import '../core/eval_run_report.dart';
import 'report_models.dart';

/// 持久化历史 run report。append-only。
abstract class ReportStore {
  Future<void> save(EvalRunReport report);

  Future<PersistedRunReport?> load(String runName);

  /// 列出某 suite 最近 N 次的索引条目（轻量），按时间倒序。
  Future<List<RunIndexEntry>> listRecent({
    required String suiteName,
    int limit = 10,
  });

  /// 加载某 suite 最近 N 次完整快照，按时间倒序。
  Future<List<PersistedRunReport>> loadRecent({
    required String suiteName,
    int limit = 10,
  });

  Future<List<String>> listRunNames({String? suiteFilter, int? limit});
}
