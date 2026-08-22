import 'eval_task.dart';

/// Immutable work item describing one task attempt in an eval run.
///
/// This is an internal implementation detail of the eval runner and is not
/// exported from `eval.dart`.
class PlannedTrial {
  final EvalTask task;
  final int trialIndex;

  const PlannedTrial({required this.task, required this.trialIndex});
}

/// Expands tasks into the ordered trial work list consumed by the scheduler.
class TrialPlanner {
  const TrialPlanner();

  List<PlannedTrial> plan({
    required Iterable<EvalTask> tasks,
    int? trialsOverride,
  }) {
    return [
      for (final task in tasks)
        for (
          var trialIndex = 0;
          trialIndex < (trialsOverride ?? task.trialsPerRun);
          trialIndex++
        )
          PlannedTrial(task: task, trialIndex: trialIndex),
    ];
  }
}
