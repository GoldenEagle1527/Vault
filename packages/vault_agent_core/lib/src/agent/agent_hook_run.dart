import 'package:dio/dio.dart';

import '../core/message.dart';
import 'agent_hook_context.dart';
import 'exception.dart';

class BeforeRunHookContext extends AgentHookContext {
  final List<LLMMessage> input;
  final bool stream;
  final CancelToken? cancelToken;

  const BeforeRunHookContext(
    super.agent, {
    required this.input,
    required this.stream,
    this.cancelToken,
  });

  BeforeRunHookContext copyWith({List<LLMMessage>? input}) {
    return BeforeRunHookContext(
      agent,
      input: input ?? this.input,
      stream: stream,
      cancelToken: cancelToken,
    );
  }
}

class TurnCompletionHookContext extends AgentHookContext {
  final ModelMessage finalMessage;
  final int continuationCount;
  final int maxContinuations;

  const TurnCompletionHookContext(
    super.agent, {
    required this.finalMessage,
    required this.continuationCount,
    required this.maxContinuations,
  });
}

class AfterRunHookContext extends AgentHookContext {
  final List<LLMMessage> input;
  final List<ModelMessage> modelMessages;
  final AgentException? error;

  const AfterRunHookContext(
    super.agent, {
    required this.input,
    required this.modelMessages,
    this.error,
  });
}

enum BeforeRunHookAction { proceed, abort }

class BeforeRunHookResult {
  final BeforeRunHookAction action;
  final List<LLMMessage>? input;
  final Exception? error;
  final String? reason;

  const BeforeRunHookResult.proceed([this.input])
    : action = BeforeRunHookAction.proceed,
      error = null,
      reason = null;

  const BeforeRunHookResult.abort({this.error, this.reason})
    : action = BeforeRunHookAction.abort,
      input = null;
}

enum TurnCompletionHookAction { accept, continueRun, abort }

class TurnCompletionHookResult {
  final TurnCompletionHookAction action;
  final List<LLMMessage> messages;
  final Exception? error;
  final String? reason;

  const TurnCompletionHookResult.accept()
    : action = TurnCompletionHookAction.accept,
      messages = const [],
      error = null,
      reason = null;

  const TurnCompletionHookResult.continueWith(
    List<LLMMessage> continuationMessages,
  ) : action = TurnCompletionHookAction.continueRun,
      messages = continuationMessages,
      error = null,
      reason = null;

  const TurnCompletionHookResult.abort({this.error, this.reason})
    : action = TurnCompletionHookAction.abort,
      messages = const [];
}
