import 'trial_planner.dart';

typedef TrialWork<T> = Future<T> Function(PlannedTrial planned);

/// Runs planned trials with bounded concurrency.
///
/// LLM request rate limiting remains the responsibility of the configured
/// LLM client and its `RateLimitGate`; admitting a trial here must not consume
/// an LLM request permit.
class TrialScheduler {
  final int concurrency;

  const TrialScheduler({required this.concurrency});

  Future<List<T>> run<T>({
    required Iterable<PlannedTrial> trials,
    required TrialWork<T> execute,
  }) async {
    final iterator = trials.iterator;
    final results = <T>[];
    final workers = List<Future<void>>.generate(
      concurrency,
      (_) => _worker(iterator: iterator, results: results, execute: execute),
    );
    await Future.wait(workers);
    return results;
  }

  Future<void> _worker<T>({
    required Iterator<PlannedTrial> iterator,
    required List<T> results,
    required TrialWork<T> execute,
  }) async {
    while (iterator.moveNext()) {
      final result = await execute(iterator.current);
      results.add(result);
    }
  }
}
