import '../../core/llm_client.dart';
import '../../core/message.dart';
import '../../core/tool.dart';

class OpenAIRequestBuilder {
  const OpenAIRequestBuilder._();

  static Map<String, dynamic> build(
    List<LLMMessage> messages, {
    List<Tool>? tools,
    ToolChoice? toolChoice,
    required ModelConfig modelConfig,
    bool stream = false,
    bool? jsonOutput,
  }) {
    final finalMessages = <Map<String, dynamic>>[];
    for (final message in messages) {
      if (message is SystemMessage) {
        finalMessages.add({'role': 'system', 'content': message.content});
      } else if (message is UserMessage) {
        final content = message.contents.map((part) {
          if (part is TextPart) {
            return <String, dynamic>{'type': 'text', 'text': part.text};
          }
          if (part is ImagePart) {
            return <String, dynamic>{
              'type': 'image_url',
              'image_url': {
                'url': _convertBase64ToUrl(part.base64Data, part.mimeType),
                if (part.detail != null) 'detail': part.detail,
              },
            };
          }
          if (part is AudioPart) {
            var format = 'wav';
            if (part.mimeType.toLowerCase().contains('mp3') ||
                part.mimeType.toLowerCase().contains('mpeg')) {
              format = 'mp3';
            }
            return <String, dynamic>{
              'type': 'input_audio',
              'input_audio': {'data': part.base64Data, 'format': format},
            };
          }
          if (part is DocumentPart) {
            return <String, dynamic>{
              'type': 'file',
              'file': {'file_data': part.base64Data},
            };
          }
          throw Exception(
            'Unsupported content type for model ${modelConfig.model}: '
            '${part.runtimeType}',
          );
        }).toList();

        if (content.length == 1 && content.first['type'] == 'text') {
          finalMessages.add({'role': 'user', 'content': content.first['text']});
        } else {
          finalMessages.add({'role': 'user', 'content': content});
        }
      } else if (message is ModelMessage) {
        final mapped = <String, dynamic>{'role': 'assistant'};
        if (message.textOutput != null) {
          mapped['content'] = message.textOutput;
        }
        if (message.thought != null && message.thought!.isNotEmpty) {
          mapped['reasoning_content'] = message.thought;
        }
        if (message.functionCalls.isNotEmpty) {
          mapped['tool_calls'] = message.functionCalls
              .map(
                (call) => {
                  'id': call.id,
                  'type': 'function',
                  'function': {'name': call.name, 'arguments': call.arguments},
                },
              )
              .toList();
        }
        finalMessages.add(mapped);
      } else if (message is FunctionExecutionResultMessage) {
        for (final result in message.results) {
          final textParts = <String>[];
          final imageParts = <ImagePart>[];
          for (final part in result.content) {
            if (part is TextPart) {
              textParts.add(part.text);
            } else if (part is ImagePart) {
              imageParts.add(part);
            }
          }
          finalMessages.add({
            'role': 'tool',
            'tool_call_id': result.id,
            'content': textParts.join('\n'),
          });
          if (imageParts.isNotEmpty) {
            finalMessages.add({
              'role': 'user',
              'content': [
                {
                  'type': 'text',
                  'text': 'Image from tool ${result.name} (${result.id})',
                },
                ...imageParts.map(
                  (part) => {
                    'type': 'image_url',
                    'image_url': {
                      'url': _convertBase64ToUrl(
                        part.base64Data,
                        part.mimeType,
                      ),
                    },
                  },
                ),
              ],
            });
          }
        }
      }
    }

    final body = <String, dynamic>{
      'model': modelConfig.model,
      'messages': finalMessages,
      'stream': stream,
    };

    if (modelConfig.temperature != null) {
      body['temperature'] = modelConfig.temperature!;
    }
    if (modelConfig.maxTokens != null) {
      body['max_completion_tokens'] = modelConfig.maxTokens!;
    }
    if (modelConfig.topP != null) {
      body['top_p'] = modelConfig.topP!;
    }
    if (jsonOutput == true) {
      body['response_format'] = {'type': 'json_object'};
    }
    if (stream) {
      body['stream_options'] = {'include_usage': true};
    }

    if (tools != null && tools.isNotEmpty) {
      body['tools'] = tools
          .map(
            (tool) => {
              'type': 'function',
              'function': {
                'name': tool.name,
                'description': tool.description,
                'parameters': tool.parameters,
              },
            },
          )
          .toList();

      switch (toolChoice?.mode) {
        case ToolChoiceMode.none:
          body['tool_choice'] = 'none';
        case ToolChoiceMode.auto:
          body['tool_choice'] = 'auto';
        case ToolChoiceMode.required:
          if (toolChoice?.allowedFunctionNames != null &&
              toolChoice!.allowedFunctionNames!.isNotEmpty) {
            body['tool_choice'] = {
              'type': 'function',
              'function': {'name': toolChoice.allowedFunctionNames![0]},
            };
          } else {
            body['tool_choice'] = 'required';
          }
        case null:
          break;
      }
    }

    final extra = modelConfig.extra;
    if (extra != null) {
      if (extra.containsKey('reasoning_effort')) {
        body['reasoning_effort'] = extra['reasoning_effort'];
      }
      if (extra.containsKey('modalities')) {
        body['modalities'] = extra['modalities'];
      }
      if (extra.containsKey('audio')) {
        body['audio'] = extra['audio'];
      }
    }

    return body;
  }
}

String _convertBase64ToUrl(String base64Data, String mimeType) {
  if (base64Data.startsWith('data')) {
    return base64Data;
  }
  return 'data:$mimeType;base64,$base64Data';
}
