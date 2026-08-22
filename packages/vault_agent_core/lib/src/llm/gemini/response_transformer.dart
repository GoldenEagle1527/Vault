import 'dart:convert';

import 'package:logging/logging.dart';

import '../../core/llm_client.dart';
import '../../core/message.dart';

final Logger _logger = Logger('GeminiClient');

ModelMessage? transformGeminiResponse(
  Map<String, dynamic> data,
  ModelConfig modelConfig,
) {
  try {
    final candidates = data['candidates'] as List? ?? [];
    if (candidates.isEmpty) {
      _logger.warning('Gemini returned no candidates, data: $data');
      return null;
    }

    final candidate = candidates[0];
    final contentParts = candidate['content']['parts'] as List? ?? [];
    String? textOutput;
    final functionCalls = <FunctionCall>[];
    String? thoughtSignature;
    String? thought;

    for (final part in contentParts) {
      if (part.containsKey('thought') && part['thought'] == true) {
        thought = (thought ?? '') + (part['text'] ?? '');
      } else if (part.containsKey('text')) {
        textOutput = (textOutput ?? '') + part['text'];
      }

      if (part.containsKey('functionCall')) {
        final functionCall = part['functionCall'];
        final name = functionCall['name']?.toString() ?? '';
        final id = functionCall['id']?.toString();
        functionCalls.add(
          FunctionCall(
            id: id == null || id.isEmpty ? name : id,
            name: name,
            arguments: jsonEncode(functionCall['args'] ?? {}),
          ),
        );
      }
      if (part.containsKey('thoughtSignature')) {
        thoughtSignature = part['thoughtSignature'];
      }
    }

    if (candidate.containsKey('thoughtSignature')) {
      thoughtSignature = candidate['thoughtSignature'];
    }

    ModelUsage? usage;
    if (data['usageMetadata'] != null) {
      final usageMetadata = data['usageMetadata'];
      usage = ModelUsage(
        promptTokens: usageMetadata['promptTokenCount'] ?? 0,
        completionTokens: usageMetadata['candidatesTokenCount'] ?? 0,
        totalTokens: usageMetadata['totalTokenCount'] ?? 0,
        cachedToken: usageMetadata['cachedContentTokenCount'] ?? 0,
        thoughtToken: usageMetadata['thoughtsTokenCount'] ?? 0,
        model: modelConfig.model,
        originalUsage: usageMetadata,
      );
    }

    final metadata = {
      'modelVersion': data['modelVersion'],
      'responseId': data['responseId'],
    };
    if (data['promptFeedback'] != null) {
      metadata['promptFeedback'] = data['promptFeedback'];
    }

    return ModelMessage(
      textOutput: textOutput,
      functionCalls: functionCalls,
      usage: usage,
      metadata: metadata,
      stopReason: candidate['finishReason'],
      thoughtSignature: thoughtSignature,
      thought: thought,
      model: modelConfig.model,
    );
  } catch (_) {
    throw Exception('Unexpected response format from Gemini: $data');
  }
}
