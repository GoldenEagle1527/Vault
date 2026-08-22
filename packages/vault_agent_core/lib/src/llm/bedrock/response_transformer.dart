import 'dart:convert';

import '../../core/llm_client.dart';
import '../../core/message.dart';

class BedrockResponseTransformer {
  ModelMessage transform(Map<String, dynamic> data, ModelConfig modelConfig) {
    if (data['type'] == 'error') {
      throw Exception('Bedrock Error: ${data['error']?['message']}');
    }

    final content = data['content'] as List?;
    var text = '';
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
          if (input is Map) input = jsonEncode(input);
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

    final usage = data['usage'];
    return ModelMessage(
      textOutput: text,
      contentBlocks: contentBlocks,
      functionCalls: functionCalls,
      model: modelConfig.model,
      stopReason: data['stop_reason'],
      thought: thought,
      thoughtSignature: thoughtSignature,
      usage: usage != null
          ? ModelUsage(
              promptTokens: usage['input_tokens'] ?? 0,
              completionTokens: usage['output_tokens'] ?? 0,
              totalTokens:
                  (usage['input_tokens'] ?? 0) + (usage['output_tokens'] ?? 0),
              cachedToken:
                  (usage['cache_read_input_tokens'] ?? 0) +
                  (usage['cache_creation_input_tokens'] ?? 0),
              model: modelConfig.model,
            )
          : null,
    );
  }
}
