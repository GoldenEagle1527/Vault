import 'agent_state.dart';

/// The minimal agent surface exposed to lifecycle hooks.
abstract interface class AgentHookHost {
  AgentState get state;
}

abstract class AgentHookContext {
  final AgentHookHost agent;

  const AgentHookContext(this.agent);

  AgentState get state => agent.state;
}
