import 'dart:async';

import 'package:dio/dio.dart';

import '../core/llm_client.dart';
import '../core/message.dart';
import 'agent_state.dart';
import 'model_message_accumulator.dart';

typedef AgentModelChunkProcessor =
    FutureOr<ModelMessage?> Function(
      ModelMessage chunk, {
      required bool detectLoop,
    });

sealed class AgentModelCallEvent {
  const AgentModelCallEvent();
}

class AgentModelCallChunk extends AgentModelCallEvent {
  final ModelMessage message;

  const AgentModelCallChunk(this.message);
}

class AgentModelCallRetry extends AgentModelCallEvent {
  final Map<String, dynamic>? data;

  const AgentModelCallRetry(this.data);

  dynamic get reason => data?['retryReason'];
}

class AgentModelCallCompleted extends AgentModelCallEvent {
  final ModelMessage message;
  final bool isEmptyResponse;

  const AgentModelCallCompleted({
    required this.message,
    required this.isEmptyResponse,
  });
}

/// Executes and accumulates exactly one model request.
///
/// Agent policy remains outside this class. In particular, hooks and loop
/// detection can be injected through [processChunk], while request retries,
/// state changes, and phase ordering remain the caller's responsibility.
class AgentModelCallRunner {
  final LLMClient client;

  const AgentModelCallRunner({required this.client});

  Stream<AgentModelCallEvent> run({
    required CallLLMParams params,
    required AgentModelChunkProcessor processChunk,
    required String model,
    ModelMessage? syntheticResponse,
    CancelToken? cancelToken,
  }) async* {
    final aggregation = ModelMessageAccumulator();

    if (syntheticResponse != null) {
      final chunk = await processChunk(syntheticResponse, detectLoop: false);
      if (chunk != null) {
        aggregation.add(chunk);
        yield AgentModelCallChunk(chunk);
      }
    } else if (params.stream) {
      final stream = await client.stream(
        params.messages,
        tools: params.tools,
        toolChoice: params.toolChoice,
        modelConfig: params.modelConfig,
        cancelToken: cancelToken,
      );

      await for (final streamingMessage in stream) {
        final modelMessage = streamingMessage.modelMessage;
        if (modelMessage != null) {
          final chunk = await processChunk(modelMessage, detectLoop: true);
          if (chunk != null) {
            aggregation.add(chunk);
            yield AgentModelCallChunk(chunk);
          }
          continue;
        }

        final controlMessage = streamingMessage.controlMessage;
        if (controlMessage?.controlFlag == StreamingControlFlag.retry) {
          aggregation.reset();
          yield AgentModelCallRetry(controlMessage?.data);
        }
      }
    } else {
      var fullMessage = await client.generate(
        params.messages,
        tools: params.tools,
        toolChoice: params.toolChoice,
        modelConfig: params.modelConfig,
        cancelToken: cancelToken,
      );
      final chunk = await processChunk(fullMessage, detectLoop: true);
      fullMessage = chunk ?? ModelMessage(model: model);
      aggregation.add(fullMessage);
      yield AgentModelCallChunk(fullMessage);
    }

    yield AgentModelCallCompleted(
      message: aggregation.toModelMessage(model),
      isEmptyResponse: aggregation.isEmptyResponse,
    );
  }
}
