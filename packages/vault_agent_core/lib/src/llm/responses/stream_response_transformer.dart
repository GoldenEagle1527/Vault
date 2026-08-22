import 'dart:async';

import '../../core/llm_client.dart';
import '../../core/message.dart';
import 'button_tool_call_buffer.dart';

class ResponsesAPIResponseTransformer
    extends StreamTransformerBase<Map<String, dynamic>, ModelMessage> {
  final ModelConfig modelConfig;

  ResponsesAPIResponseTransformer(this.modelConfig);

  @override
  Stream<ModelMessage> bind(Stream<Map<String, dynamic>> stream) async* {
    final toolBuffers = <String, ButtonToolCallBuffer>{};

    await for (final event in stream) {
      final type = event['type'] as String?;

      if (type == 'response.completed') {
        final response = event['response'];
        if (response != null && response['usage'] != null) {
          final usageData = response['usage'];
          yield ModelMessage(
            usage: ModelUsage(
              promptTokens: usageData['input_tokens'] ?? 0,
              completionTokens: usageData['output_tokens'] ?? 0,
              totalTokens: usageData['total_tokens'] ?? 0,
              cachedToken:
                  usageData['input_tokens_details']?['cached_tokens'] ?? 0,
              thoughtToken:
                  usageData['output_tokens_details']?['reasoning_tokens'] ?? 0,
              model: modelConfig.model,
            ),
            model: modelConfig.model,
            responseId: response['id'],
            stopReason: response['incomplete_details'] != null
                ? 'incomplete'
                : 'end_turn',
            metadata: {'status': 'completed'},
          );
        }
      }

      if (type == 'response.failed') {
        final error = event['error'];
        throw Exception(
          'Response generation failed: [${error?['code']}] '
          '${error?['message']}',
        );
      }

      if (type == 'response.incomplete') {
        yield ModelMessage(
          stopReason: 'incomplete',
          model: modelConfig.model,
          metadata: {'status': 'incomplete'},
        );
      }

      if (type == 'response.output_item.added') {
        final item = event['item'];
        final itemId = item['id'];
        if (item['type'] == 'function_call') {
          toolBuffers[itemId] = ButtonToolCallBuffer(
            id: item['call_id'] ?? item['id'] ?? '',
            name: item['name'] ?? item['function']?['name'] ?? '',
            arguments: '',
          );
          final started = toolBuffers[itemId]!;
          yield ModelMessage(
            functionCalls: [
              FunctionCall(id: started.id, name: started.name, arguments: ''),
            ],
            model: modelConfig.model,
          );
        }
      }

      if (type == 'response.output_item.done') {
        final item = event['item'];
        final itemId = item['id'];
        final buffer = toolBuffers.remove(itemId);
        if (buffer != null) {
          yield ModelMessage(
            functionCalls: [
              FunctionCall(
                id: buffer.id,
                name: buffer.name,
                arguments: buffer.arguments.isEmpty
                    ? (item['arguments'] ??
                          item['function']?['arguments'] ??
                          '')
                    : buffer.arguments,
              ),
            ],
            model: modelConfig.model,
          );
        }
      }

      if (type == 'response.output_text.delta') {
        final delta = event['delta'] as String?;
        if (delta != null) {
          yield ModelMessage(textOutput: delta, model: modelConfig.model);
        }
      }

      if (type == 'response.reasoning_summary_text.delta') {
        final delta = event['delta'] as String?;
        if (delta != null) {
          yield ModelMessage(thought: delta, model: modelConfig.model);
        }
      }

      if (type == 'response.function_call_arguments.delta') {
        final itemId = event['item_id'] as String;
        final buffer = toolBuffers[itemId];
        if (buffer != null) {
          buffer.arguments += event['delta'] as String? ?? '';
          yield ModelMessage(
            functionCalls: [
              FunctionCall(
                id: buffer.id,
                name: buffer.name,
                arguments: buffer.arguments,
              ),
            ],
            model: modelConfig.model,
          );
        }
      }

      if (type == 'response.refusal.delta') {
        final delta = event['delta'] as String?;
        if (delta != null) {
          yield ModelMessage(
            textOutput: delta,
            model: modelConfig.model,
            metadata: {'isRefusal': true},
          );
        }
      }

      if (type == 'error') {
        throw Exception(
          'OpenAI Responses Stream Error: '
          '[${event['code']}] ${event['message']}',
        );
      }

      if (type == 'response.audio.delta') {
        final delta = event['delta'] as String?;
        if (delta != null) {
          yield ModelMessage(
            audioOutputs: [
              ModelAudioPart(base64Data: delta, mimeType: 'audio/pcm'),
            ],
            model: modelConfig.model,
          );
        }
      }

      if (type == 'response.audio.transcript.delta') {
        final delta = event['delta'] as String?;
        if (delta != null) {
          yield ModelMessage(
            textOutput: delta,
            model: modelConfig.model,
            metadata: {'isTranscript': true},
          );
        }
      }
    }
  }
}
