import 'dart:async';
import 'dart:convert';

import '../../core/llm_client.dart';
import '../../core/message.dart';

class OpenAIChunkDecoder
    extends StreamTransformerBase<String, Map<String, dynamic>> {
  @override
  Stream<Map<String, dynamic>> bind(Stream<String> stream) async* {
    await for (final line in stream) {
      if (line.startsWith('data: ')) {
        final data = line.substring(6).trim();
        if (data == '[DONE]') return;
        try {
          yield jsonDecode(data);
        } catch (_) {
          // Preserve compatibility by ignoring malformed SSE data lines.
        }
      }
    }
  }
}

class OpenAIResponseTransformer
    extends StreamTransformerBase<Map<String, dynamic>, ModelMessage> {
  final ModelConfig modelConfig;

  OpenAIResponseTransformer(this.modelConfig);

  @override
  Stream<ModelMessage> bind(Stream<Map<String, dynamic>> stream) async* {
    final toolCallBuffer = <int, Map<String, dynamic>>{};
    String? pendingFinishReason;

    List<FunctionCall> snapshotToolCalls({bool finalize = false}) {
      final calls = <FunctionCall>[];
      if (toolCallBuffer.isEmpty) return calls;
      final sortedIndices = toolCallBuffer.keys.toList()..sort();
      for (final index in sortedIndices) {
        final buffer = toolCallBuffer[index]!;
        final id = buffer['id'] as String;
        final name = buffer['name'] as String;
        var arguments = buffer['arguments'] as String;
        if (id.isEmpty && name.isEmpty && arguments.isEmpty) continue;
        if (finalize && arguments.isEmpty) arguments = '{}';
        calls.add(FunctionCall(id: id, name: name, arguments: arguments));
      }
      if (finalize) toolCallBuffer.clear();
      return calls;
    }

    List<FunctionCall> finalizeToolCalls() => snapshotToolCalls(finalize: true);

    await for (final data in stream) {
      final metadata = {
        'model': data['model'],
        'object': data['object'],
        'created': data['created'],
        'usage': data['usage'],
        'prompt_filter_results': data['prompt_filter_results'],
        'system_fingerprint': data['system_fingerprint'],
      };

      if (data['usage'] != null) {
        final usage = data['usage'];
        final modelUsage = ModelUsage(
          promptTokens: usage['prompt_tokens'] ?? 0,
          completionTokens: usage['completion_tokens'] ?? 0,
          totalTokens: usage['total_tokens'] ?? 0,
          cachedToken: usage['prompt_tokens_details']?['cached_tokens'] ?? 0,
          thoughtToken:
              usage['completion_tokens_details']?['reasoning_tokens'] ?? 0,
          originalUsage: usage,
          model: modelConfig.model,
        );

        final usageChoices = data['choices'] as List? ?? [];
        if (usageChoices.isNotEmpty) {
          final usageChoice = usageChoices[0];
          final inlineFinishReason = usageChoice['finish_reason'];
          if (inlineFinishReason != null) {
            pendingFinishReason = inlineFinishReason;
          }
          final usageDelta = usageChoice['delta'];
          if (usageDelta != null && usageDelta['tool_calls'] != null) {
            _accumulateToolCalls(
              toolCallBuffer,
              usageDelta['tool_calls'] as List,
            );
          }
        }

        if (pendingFinishReason != null) {
          yield ModelMessage(
            stopReason: pendingFinishReason,
            functionCalls: finalizeToolCalls(),
            usage: modelUsage,
            metadata: metadata,
            model: modelConfig.model,
          );
          pendingFinishReason = null;
        } else {
          yield ModelMessage(
            usage: modelUsage,
            metadata: metadata,
            model: modelConfig.model,
          );
        }
        continue;
      }

      final choices = data['choices'] as List? ?? [];
      if (choices.isEmpty) continue;

      final choice = choices[0];
      final delta = choice['delta'];
      final finishReason = choice['finish_reason'];

      if (delta['content'] != null) {
        yield ModelMessage(
          textOutput: delta['content'],
          metadata: metadata,
          model: modelConfig.model,
        );
      }

      if (delta['reasoning_content'] != null) {
        yield ModelMessage(
          thought: delta['reasoning_content'],
          metadata: metadata,
          model: modelConfig.model,
        );
      }

      if (delta['audio'] != null) {
        final audio = delta['audio'];
        final audioContent = audio['data'] as String?;
        final audioTranscript = audio['transcript'] as String?;
        yield ModelMessage(
          audioOutputs: [
            ModelAudioPart(
              base64Data: audioContent,
              transcript: audioTranscript,
            ),
          ],
          metadata: metadata,
          model: modelConfig.model,
        );
      }

      if (delta['tool_calls'] != null) {
        _accumulateToolCalls(toolCallBuffer, delta['tool_calls'] as List);
        final snapshot = snapshotToolCalls();
        if (snapshot.isNotEmpty) {
          yield ModelMessage(
            functionCalls: snapshot,
            metadata: metadata,
            model: modelConfig.model,
          );
        }
      }

      if (finishReason != null) {
        pendingFinishReason = finishReason;
      }
    }

    if (pendingFinishReason != null) {
      yield ModelMessage(
        stopReason: pendingFinishReason,
        functionCalls: finalizeToolCalls(),
        model: modelConfig.model,
      );
    }
  }
}

void _accumulateToolCalls(
  Map<int, Map<String, dynamic>> buffer,
  List<dynamic> toolCalls,
) {
  for (final toolCall in toolCalls) {
    final index = toolCall['index'] as int;
    buffer.putIfAbsent(index, () => {'id': '', 'name': '', 'arguments': ''});
    final accumulated = buffer[index]!;
    if (toolCall['id'] != null) {
      accumulated['id'] = toolCall['id'];
    }
    final function = toolCall['function'];
    if (function != null) {
      if (function['name'] != null) {
        accumulated['name'] =
            (accumulated['name'] as String) + function['name'];
      }
      if (function['arguments'] != null) {
        accumulated['arguments'] =
            (accumulated['arguments'] as String) + function['arguments'];
      }
    }
  }
}
