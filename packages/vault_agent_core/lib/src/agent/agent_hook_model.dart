import 'package:dio/dio.dart';

import '../core/llm_client.dart';
import '../core/message.dart';
import '../core/tool.dart';
import 'agent_hook_context.dart';
import 'agent_state.dart';

class ModelCallRequest {
  final SystemMessage? systemMessage;
  final List<LLMMessage> requestMessages;
  final List<Tool> tools;
  final ToolChoice? toolChoice;
  final ModelConfig modelConfig;
  final bool stream;

  ModelCallRequest({
    required this.systemMessage,
    required List<LLMMessage> requestMessages,
    required List<Tool> tools,
    required this.toolChoice,
    required this.modelConfig,
    required this.stream,
  }) : requestMessages = List.unmodifiable(requestMessages),
       tools = List.unmodifiable(tools);

  ModelCallRequest copyWith({
    SystemMessage? systemMessage,
    bool clearSystemMessage = false,
    List<LLMMessage>? requestMessages,
    List<Tool>? tools,
    ToolChoice? toolChoice,
    bool clearToolChoice = false,
    ModelConfig? modelConfig,
    bool? stream,
  }) {
    return ModelCallRequest(
      systemMessage: clearSystemMessage
          ? null
          : systemMessage ?? this.systemMessage,
      requestMessages: requestMessages ?? this.requestMessages,
      tools: tools ?? this.tools,
      toolChoice: clearToolChoice ? null : toolChoice ?? this.toolChoice,
      modelConfig: modelConfig ?? this.modelConfig,
      stream: stream ?? this.stream,
    );
  }

  CallLLMParams toCallLLMParams() {
    final messages = List<LLMMessage>.from(requestMessages);
    if (systemMessage != null) {
      messages.insert(0, systemMessage!);
    }
    return CallLLMParams(
      messages: messages,
      tools: tools,
      toolChoice: toolChoice,
      modelConfig: modelConfig,
      stream: stream,
    );
  }
}

class ModelCallHookContext extends AgentHookContext {
  final ModelCallRequest request;
  final int turnIndex;
  final CancelToken? cancelToken;

  const ModelCallHookContext(
    super.agent, {
    required this.request,
    required this.turnIndex,
    this.cancelToken,
  });

  ModelCallHookContext copyWith({ModelCallRequest? request}) {
    return ModelCallHookContext(
      agent,
      request: request ?? this.request,
      turnIndex: turnIndex,
      cancelToken: cancelToken,
    );
  }
}

class ModelChunkHookContext extends AgentHookContext {
  final CallLLMParams params;
  final ModelMessage chunk;

  const ModelChunkHookContext(
    super.agent, {
    required this.params,
    required this.chunk,
  });

  ModelChunkHookContext copyWith({ModelMessage? chunk}) {
    return ModelChunkHookContext(
      agent,
      params: params,
      chunk: chunk ?? this.chunk,
    );
  }
}

class ModelResponseHookContext extends AgentHookContext {
  final CallLLMParams params;
  final ModelMessage response;

  const ModelResponseHookContext(
    super.agent, {
    required this.params,
    required this.response,
  });

  ModelResponseHookContext copyWith({ModelMessage? response}) {
    return ModelResponseHookContext(
      agent,
      params: params,
      response: response ?? this.response,
    );
  }
}

enum ModelCallHookAction { proceed, respond, abort }

class ModelCallHookResult {
  final ModelCallHookAction action;
  final ModelCallRequest? request;
  final ModelMessage? response;
  final bool changed;
  final Exception? error;
  final String? reason;

  const ModelCallHookResult.proceed({this.request, this.changed = false})
    : action = ModelCallHookAction.proceed,
      response = null,
      error = null,
      reason = null;

  const ModelCallHookResult.respond(this.response, {this.request, this.reason})
    : action = ModelCallHookAction.respond,
      changed = true,
      error = null;

  const ModelCallHookResult.abort({this.error, this.reason})
    : action = ModelCallHookAction.abort,
      request = null,
      response = null,
      changed = false;
}

enum ModelChunkHookAction { proceed, drop, abort }

class ModelChunkHookResult {
  final ModelChunkHookAction action;
  final ModelMessage? chunk;
  final Exception? error;
  final String? reason;

  const ModelChunkHookResult.proceed([this.chunk])
    : action = ModelChunkHookAction.proceed,
      error = null,
      reason = null;

  const ModelChunkHookResult.drop({this.reason})
    : action = ModelChunkHookAction.drop,
      chunk = null,
      error = null;

  const ModelChunkHookResult.abort({this.error, this.reason})
    : action = ModelChunkHookAction.abort,
      chunk = null;
}

enum ModelResponseHookAction { proceed, retry, abort }

class ModelResponseHookResult {
  final ModelResponseHookAction action;
  final ModelMessage? response;
  final String? retryReason;
  final Exception? error;
  final String? reason;

  const ModelResponseHookResult.proceed([this.response])
    : action = ModelResponseHookAction.proceed,
      retryReason = null,
      error = null,
      reason = null;

  const ModelResponseHookResult.retry(this.retryReason)
    : action = ModelResponseHookAction.retry,
      response = null,
      error = null,
      reason = null;

  const ModelResponseHookResult.abort({this.error, this.reason})
    : action = ModelResponseHookAction.abort,
      response = null,
      retryReason = null;
}
