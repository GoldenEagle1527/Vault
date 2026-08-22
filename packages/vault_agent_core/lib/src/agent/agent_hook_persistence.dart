import 'agent_hook_context.dart';
import 'exception.dart';

class StatePersistenceHookContext extends AgentHookContext {
  final String reason;
  final AgentException? runError;

  const StatePersistenceHookContext(
    super.agent, {
    required this.reason,
    this.runError,
  });
}

enum StatePersistenceHookAction { proceed, skip, abort }

class StatePersistenceHookResult {
  final StatePersistenceHookAction action;
  final Exception? error;
  final String? reason;

  const StatePersistenceHookResult.proceed()
    : action = StatePersistenceHookAction.proceed,
      error = null,
      reason = null;

  const StatePersistenceHookResult.skip({this.reason})
    : action = StatePersistenceHookAction.skip,
      error = null;

  const StatePersistenceHookResult.abort({this.error, this.reason})
    : action = StatePersistenceHookAction.abort;
}
