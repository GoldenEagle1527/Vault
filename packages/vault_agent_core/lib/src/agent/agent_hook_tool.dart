import '../core/message.dart';
import '../core/tool.dart';
import 'agent_hook_context.dart';
import 'agent_tool_result.dart';

class ToolCallHookContext extends AgentHookContext {
  final FunctionCall call;
  final ModelMessage modelMessage;
  final List<Tool> availableTools;

  const ToolCallHookContext(
    super.agent, {
    required this.call,
    required this.modelMessage,
    required this.availableTools,
  });

  ToolCallHookContext copyWith({FunctionCall? call}) {
    return ToolCallHookContext(
      agent,
      call: call ?? this.call,
      modelMessage: modelMessage,
      availableTools: availableTools,
    );
  }
}

class ToolResultHookContext extends AgentHookContext {
  final FunctionExecutionResult result;
  final ModelMessage modelMessage;

  const ToolResultHookContext(
    super.agent, {
    required this.result,
    required this.modelMessage,
  });

  ToolResultHookContext copyWith({FunctionExecutionResult? result}) {
    return ToolResultHookContext(
      agent,
      result: result ?? this.result,
      modelMessage: modelMessage,
    );
  }
}

enum ToolCallHookAction { proceed, deny, defer, abort }

class ToolCallHookResult {
  final ToolCallHookAction action;
  final FunctionCall? call;
  final ExecutionToolResult? syntheticResult;
  final List<UserContentPart>? syntheticContent;
  final bool syntheticIsError;
  final Map<String, dynamic>? metadata;
  final Exception? error;
  final String? reason;

  const ToolCallHookResult.proceed([this.call])
    : action = ToolCallHookAction.proceed,
      syntheticResult = null,
      syntheticContent = null,
      syntheticIsError = false,
      metadata = null,
      error = null,
      reason = null;

  const ToolCallHookResult.denyWithResult(this.syntheticResult)
    : action = ToolCallHookAction.deny,
      call = null,
      syntheticContent = null,
      syntheticIsError = true,
      metadata = null,
      error = null,
      reason = null;

  const ToolCallHookResult.deny({
    List<UserContentPart>? content,
    bool isError = true,
    this.metadata,
    this.reason,
  }) : action = ToolCallHookAction.deny,
       call = null,
       syntheticResult = null,
       syntheticContent = content,
       syntheticIsError = isError,
       error = null;

  const ToolCallHookResult.defer({
    List<UserContentPart>? content,
    this.metadata,
    this.reason,
  }) : action = ToolCallHookAction.defer,
       call = null,
       syntheticResult = null,
       syntheticContent = content,
       syntheticIsError = false,
       error = null;

  const ToolCallHookResult.abort({this.error, this.reason})
    : action = ToolCallHookAction.abort,
      call = null,
      syntheticResult = null,
      syntheticContent = null,
      syntheticIsError = false,
      metadata = null;
}

enum ToolResultHookAction { proceed, stop, abort }

class ToolResultHookResult {
  final ToolResultHookAction action;
  final FunctionExecutionResult? result;
  final List<LLMMessage> injectedMessages;
  final Exception? error;
  final String? reason;

  const ToolResultHookResult.proceed({
    this.result,
    this.injectedMessages = const [],
  }) : action = ToolResultHookAction.proceed,
       error = null,
       reason = null;

  const ToolResultHookResult.stop({
    this.result,
    this.injectedMessages = const [],
    this.reason,
  }) : action = ToolResultHookAction.stop,
       error = null;

  const ToolResultHookResult.abort({this.error, this.reason})
    : action = ToolResultHookAction.abort,
      result = null,
      injectedMessages = const [];
}
