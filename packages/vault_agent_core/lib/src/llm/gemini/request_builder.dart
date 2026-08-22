import 'dart:convert';

import '../../core/llm_client.dart';
import '../../core/message.dart';
import '../../core/tool.dart';

Map<String, dynamic> buildGeminiRequestBody(
  List<LLMMessage> messages, {
  List<Tool>? tools,
  ToolChoice? toolChoice,
  required ModelConfig modelConfig,
  bool? jsonOutput,
}) {
  final contents = messages.where((m) => m is! SystemMessage).map((m) {
    String role = 'user';
    if (m is ModelMessage) {
      role = 'model';
    } else if (m is FunctionExecutionResultMessage) {
      role = 'function';
    }

    final parts = <Map<String, dynamic>>[];

    if (m is UserMessage) {
      for (final part in m.contents) {
        if (part is TextPart) {
          parts.add({'text': part.text});
        } else if (part is ImagePart) {
          parts.add({
            'inlineData': {'mimeType': part.mimeType, 'data': part.base64Data},
          });
        } else if (part is AudioPart) {
          parts.add({
            'inlineData': {'mimeType': part.mimeType, 'data': part.base64Data},
          });
        } else if (part is VideoPart) {
          parts.add({
            'inlineData': {'mimeType': part.mimeType, 'data': part.base64Data},
          });
        } else if (part is DocumentPart) {
          parts.add({
            'inlineData': {'mimeType': part.mimeType, 'data': part.base64Data},
          });
        } else {
          throw Exception(
            'Unsupported content type for model ${modelConfig.model}: ${part.runtimeType}',
          );
        }
      }
    } else if (m is ModelMessage) {
      if (m.textOutput != null) parts.add({'text': m.textOutput});
      for (final functionCall in m.functionCalls) {
        parts.add({
          'functionCall': {
            if (functionCall.id.isNotEmpty) 'id': functionCall.id,
            'name': functionCall.name,
            'args': jsonDecode(functionCall.arguments),
          },
        });
      }
      if (m.thoughtSignature != null && parts.isNotEmpty) {
        final functionCallIndex = parts.indexWhere(
          (part) => part.containsKey('functionCall'),
        );
        if (functionCallIndex != -1) {
          parts[functionCallIndex]['thoughtSignature'] = m.thoughtSignature;
        } else {
          parts.last['thoughtSignature'] = m.thoughtSignature;
        }
      }
    } else if (m is FunctionExecutionResultMessage) {
      for (final result in m.results) {
        final mediaParts = <Map<String, dynamic>>[];
        for (final part in result.content) {
          if (part is TextPart) {
            continue;
          } else if (part is ImagePart) {
            mediaParts.add({
              'inlineData': {
                'mimeType': part.mimeType,
                'data': part.base64Data,
              },
            });
          } else if (part is AudioPart) {
            mediaParts.add({
              'inlineData': {
                'mimeType': part.mimeType,
                'data': part.base64Data,
              },
            });
          } else if (part is VideoPart) {
            mediaParts.add({
              'inlineData': {
                'mimeType': part.mimeType,
                'data': part.base64Data,
              },
            });
          } else if (part is DocumentPart) {
            mediaParts.add({
              'inlineData': {
                'mimeType': part.mimeType,
                'data': part.base64Data,
              },
            });
          } else {
            throw Exception(
              'Unsupported content type for model ${modelConfig.model}: ${part.runtimeType}',
            );
          }
        }

        final textContent = result.content
            .whereType<TextPart>()
            .map((part) => part.text)
            .join('\n');
        parts.add({
          'functionResponse': {
            if (result.id.isNotEmpty) 'id': result.id,
            'name': result.name,
            'response': {'content': textContent},
            if (mediaParts.isNotEmpty) 'parts': mediaParts,
          },
        });
      }
    }

    return {'role': role, 'parts': parts};
  }).toList();

  final generationConfig = <String, dynamic>{
    'temperature': modelConfig.temperature,
    'maxOutputTokens': modelConfig.maxTokens,
    'topP': modelConfig.topP,
    'topK': modelConfig.topK,
  };
  if (jsonOutput == true) {
    generationConfig['responseMimeType'] = 'application/json';
  }
  if (modelConfig.extra?['thinkingConfig'] != null) {
    generationConfig['thinkingConfig'] = modelConfig.extra!['thinkingConfig']!;
  }

  final body = <String, dynamic>{
    'contents': contents,
    'generationConfig': generationConfig,
  };
  final systemMessages = messages.whereType<SystemMessage>().toList();
  if (systemMessages.isNotEmpty) {
    body['systemInstruction'] = {
      'parts': [
        {'text': systemMessages.map((message) => message.content).join('\n')},
      ],
    };
  }

  if (tools != null && tools.isNotEmpty) {
    body['tools'] = [
      {
        'functionDeclarations': tools
            .map(
              (tool) => {
                'name': tool.name,
                'description': tool.description,
                'parameters': tool.parameters,
              },
            )
            .toList(),
      },
    ];

    switch (toolChoice?.mode) {
      case ToolChoiceMode.none:
        body['toolConfig'] = {
          'functionCallingConfig': {'mode': 'NONE'},
        };
      case ToolChoiceMode.auto:
        body['toolConfig'] = {
          'functionCallingConfig': {'mode': 'AUTO'},
        };
      case ToolChoiceMode.required:
        final toolConfig = <String, dynamic>{'mode': 'ANY'};
        if (toolChoice?.allowedFunctionNames != null) {
          toolConfig['allowedFunctionNames'] = toolChoice!.allowedFunctionNames;
        }
        body['toolConfig'] = toolConfig;
      case null:
        break;
    }
  }
  return body;
}
