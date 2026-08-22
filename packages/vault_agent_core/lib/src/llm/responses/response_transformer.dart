import '../../core/llm_client.dart';
import '../../core/message.dart';

class ResponsesResponseTransformer {
  final ModelConfig modelConfig;

  const ResponsesResponseTransformer(this.modelConfig);

  ModelMessage transform(Map<String, dynamic> data) {
    var textOutput = '';
    var reasoningOutput = '';
    final functionCalls = <FunctionCall>[];
    final audioOutputs = <ModelAudioPart>[];

    for (final item in data['output'] as List? ?? const []) {
      if (item['type'] == 'message') {
        for (final content in item['content'] as List? ?? const []) {
          if (content['type'] == 'output_text') {
            textOutput += content['text'] ?? '';
          } else if (content['type'] == 'audio') {
            // Retained for compatibility: non-streaming audio was not mapped.
          }
        }
      } else if (item['type'] == 'function_call') {
        functionCalls.add(
          FunctionCall(
            id: item['call_id'] ?? item['id'] ?? '',
            name: item['name'] ?? item['function']?['name'],
            arguments: item['arguments'] ?? item['function']?['arguments'],
          ),
        );
      } else if (item['type'] == 'reasoning') {
        for (final summary in item['summary'] as List? ?? const []) {
          reasoningOutput += summary['text'] ?? '';
        }
      }
    }

    return ModelMessage(
      textOutput: textOutput,
      functionCalls: functionCalls,
      audioOutputs: audioOutputs,
      usage: _parseUsage(data['usage']),
      model: modelConfig.model,
      responseId: data['id'] as String?,
      thought: reasoningOutput,
      metadata: data,
      stopReason: data['status'],
    );
  }

  ModelUsage? _parseUsage(dynamic usageData) {
    if (usageData == null) return null;
    return ModelUsage(
      promptTokens: usageData['input_tokens'] ?? 0,
      completionTokens: usageData['output_tokens'] ?? 0,
      totalTokens: usageData['total_tokens'] ?? 0,
      cachedToken: usageData['input_tokens_details']?['cached_tokens'] ?? 0,
      thoughtToken:
          usageData['output_tokens_details']?['reasoning_tokens'] ?? 0,
      model: modelConfig.model,
    );
  }
}
