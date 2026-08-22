import 'dart:convert';

import '../../core/llm_client.dart';
import '../../core/message.dart';

/// Converts a completed Anthropic response into the package message model.
class ClaudeResponseTransformer {
  ModelMessage transform(Map<String, dynamic> data, ModelConfig modelConfig) {
    if (data['type'] == 'error') {
      throw Exception('Claude Error: ${data['error']?['message']}');
    }

    final content = data['content'] as List?;
    String text = '';
    final functionCalls = <FunctionCall>[];
    final contentBlocks = <Map<String, dynamic>>[];
    String? thought;
    String? thoughtSignature;

    if (content != null) {
      for (final part in content) {
        if (part is Map) {
          contentBlocks.add(Map<String, dynamic>.from(part));
        }
        if (part['type'] == 'text') {
          text += part['text'] ?? '';
        } else if (part['type'] == 'tool_use') {
          dynamic input = part['input'];
          if (input is Map) {
            input = jsonEncode(input);
          }
          input ??= '';

          functionCalls.add(
            FunctionCall(
              id: part['id'],
              name: part['name'],
              arguments: input.toString(),
            ),
          );
        } else if (part['type'] == 'thinking') {
          thought = part['thinking'];
          thoughtSignature = part['signature'];
        }
      }
    }

    return ModelMessage(
      textOutput: text,
      contentBlocks: contentBlocks,
      functionCalls: functionCalls,
      model: modelConfig.model,
      stopReason: data['stop_reason'],
      thought: thought,
      thoughtSignature: thoughtSignature,
      usage: data['usage'] != null
          ? ModelUsage(
              promptTokens: data['usage']['input_tokens'] ?? 0,
              completionTokens: data['usage']['output_tokens'] ?? 0,
              totalTokens:
                  (data['usage']['input_tokens'] ?? 0) +
                  (data['usage']['output_tokens'] ?? 0),
              cachedToken:
                  (data['usage']['cache_read_input_tokens'] ?? 0) +
                  (data['usage']['cache_creation_input_tokens'] ?? 0),
              model: modelConfig.model,
            )
          : null,
    );
  }
}
