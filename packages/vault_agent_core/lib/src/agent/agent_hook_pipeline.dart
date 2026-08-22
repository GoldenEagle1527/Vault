import 'dart:async';

import '../core/message.dart';
import 'agent_hook_model.dart';
import 'agent_hook_persistence.dart';
import 'agent_hook_run.dart';
import 'agent_hook_tool.dart';

abstract class AgentHook {
  FutureOr<BeforeRunHookResult> beforeRun(BeforeRunHookContext context) {
    return BeforeRunHookResult.proceed(context.input);
  }

  FutureOr<ModelCallHookResult> beforeModelCall(ModelCallHookContext context) {
    return ModelCallHookResult.proceed(request: context.request);
  }

  FutureOr<ModelChunkHookResult> onModelChunk(ModelChunkHookContext context) {
    return ModelChunkHookResult.proceed(context.chunk);
  }

  FutureOr<ModelResponseHookResult> afterModelCall(
    ModelResponseHookContext context,
  ) {
    return ModelResponseHookResult.proceed(context.response);
  }

  FutureOr<ToolCallHookResult> beforeToolCall(ToolCallHookContext context) {
    return ToolCallHookResult.proceed(context.call);
  }

  FutureOr<ToolResultHookResult> afterToolCall(ToolResultHookContext context) {
    return ToolResultHookResult.proceed(result: context.result);
  }

  FutureOr<TurnCompletionHookResult> onTurnCompletion(
    TurnCompletionHookContext context,
  ) {
    return const TurnCompletionHookResult.accept();
  }

  FutureOr<StatePersistenceHookResult> beforePersistState(
    StatePersistenceHookContext context,
  ) {
    return const StatePersistenceHookResult.proceed();
  }

  FutureOr<void> afterPersistState(StatePersistenceHookContext context) {}

  FutureOr<void> afterRun(AfterRunHookContext context) {}
}

class AgentHookPipeline {
  final List<AgentHook> hooks;

  AgentHookPipeline(List<AgentHook> hooks) : hooks = List.unmodifiable(hooks);

  bool get isEmpty => hooks.isEmpty;

  Future<BeforeRunHookResult> beforeRun(BeforeRunHookContext context) async {
    var input = context.input;
    for (final hook in hooks) {
      final result = await hook.beforeRun(context.copyWith(input: input));
      if (result.action == BeforeRunHookAction.abort) {
        return result;
      }
      final nextInput = result.input ?? input;
      input = nextInput;
    }
    return BeforeRunHookResult.proceed(input);
  }

  Future<ModelCallHookResult> beforeModelCall(
    ModelCallHookContext context,
  ) async {
    var request = context.request;
    var changed = false;
    for (final hook in hooks) {
      final result = await hook.beforeModelCall(
        context.copyWith(request: request),
      );
      switch (result.action) {
        case ModelCallHookAction.abort:
          return result;
        case ModelCallHookAction.respond:
          return ModelCallHookResult.respond(
            result.response!,
            request: result.request ?? request,
            reason: result.reason,
          );
        case ModelCallHookAction.proceed:
          final nextRequest = result.request ?? request;
          if (!identical(nextRequest, request) || result.changed) {
            changed = true;
          }
          request = nextRequest;
      }
    }
    return ModelCallHookResult.proceed(request: request, changed: changed);
  }

  Future<ModelChunkHookResult> onModelChunk(
    ModelChunkHookContext context,
  ) async {
    var chunk = context.chunk;
    for (final hook in hooks) {
      final result = await hook.onModelChunk(context.copyWith(chunk: chunk));
      switch (result.action) {
        case ModelChunkHookAction.abort:
        case ModelChunkHookAction.drop:
          return result;
        case ModelChunkHookAction.proceed:
          final nextChunk = result.chunk ?? chunk;
          chunk = nextChunk;
      }
    }
    return ModelChunkHookResult.proceed(chunk);
  }

  Future<ModelResponseHookResult> afterModelCall(
    ModelResponseHookContext context,
  ) async {
    var response = context.response;
    for (final hook in hooks) {
      final result = await hook.afterModelCall(
        context.copyWith(response: response),
      );
      switch (result.action) {
        case ModelResponseHookAction.abort:
        case ModelResponseHookAction.retry:
          return result;
        case ModelResponseHookAction.proceed:
          final nextResponse = result.response ?? response;
          response = nextResponse;
      }
    }
    return ModelResponseHookResult.proceed(response);
  }

  Future<ToolCallHookResult> beforeToolCall(ToolCallHookContext context) async {
    var call = context.call;
    for (final hook in hooks) {
      final result = await hook.beforeToolCall(context.copyWith(call: call));
      switch (result.action) {
        case ToolCallHookAction.abort:
        case ToolCallHookAction.deny:
        case ToolCallHookAction.defer:
          return result;
        case ToolCallHookAction.proceed:
          final nextCall = result.call ?? call;
          call = _preserveToolCallId(context.call.id, nextCall);
      }
    }
    return ToolCallHookResult.proceed(call);
  }

  Future<ToolResultHookResult> afterToolCall(
    ToolResultHookContext context,
  ) async {
    var result = context.result;
    final injectedMessages = <LLMMessage>[];
    for (final hook in hooks) {
      final hookResult = await hook.afterToolCall(
        context.copyWith(result: result),
      );
      switch (hookResult.action) {
        case ToolResultHookAction.abort:
          return hookResult;
        case ToolResultHookAction.stop:
        case ToolResultHookAction.proceed:
          final nextResult = hookResult.result ?? result;
          result = nextResult;
          if (hookResult.injectedMessages.isNotEmpty) {
            injectedMessages.addAll(hookResult.injectedMessages);
          }
          if (hookResult.action == ToolResultHookAction.stop) {
            return ToolResultHookResult.stop(
              result: result,
              injectedMessages: injectedMessages,
              reason: hookResult.reason,
            );
          }
      }
    }
    return ToolResultHookResult.proceed(
      result: result,
      injectedMessages: injectedMessages,
    );
  }

  Future<TurnCompletionHookResult> onTurnCompletion(
    TurnCompletionHookContext context,
  ) async {
    for (final hook in hooks) {
      final result = await hook.onTurnCompletion(context);
      if (result.action == TurnCompletionHookAction.accept) {
        continue;
      }
      return result;
    }
    return const TurnCompletionHookResult.accept();
  }

  Future<StatePersistenceHookResult> beforePersistState(
    StatePersistenceHookContext context,
  ) async {
    for (final hook in hooks) {
      final result = await hook.beforePersistState(context);
      if (result.action == StatePersistenceHookAction.proceed) {
        continue;
      }
      return result;
    }
    return const StatePersistenceHookResult.proceed();
  }

  Future<void> afterPersistState(StatePersistenceHookContext context) async {
    for (final hook in hooks) {
      await hook.afterPersistState(context);
    }
  }

  Future<void> afterRun(AfterRunHookContext context) async {
    for (final hook in hooks) {
      await hook.afterRun(context);
    }
  }
}

FunctionCall _preserveToolCallId(String id, FunctionCall call) {
  if (call.id == id) return call;
  return FunctionCall(id: id, name: call.name, arguments: call.arguments);
}
