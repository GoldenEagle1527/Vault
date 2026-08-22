import 'dart:convert';

import 'package:logging/logging.dart';

import '../../core/llm_client.dart';
import '../../core/message.dart';
import '../../core/tool.dart';

/// Serializes agent messages and options for the Anthropic Messages API.
class ClaudeRequestBuilder {
  final Logger _logger;

  ClaudeRequestBuilder({Logger? logger})
    : _logger = logger ?? Logger('ClaudeClient');

  Map<String, dynamic> build(
    List<LLMMessage> messages, {
    List<Tool>? tools,
    ToolChoice? toolChoice,
    required ModelConfig modelConfig,
    bool? jsonOutput,
  }) {
    final body = <String, dynamic>{
      'model': modelConfig.model,
      'max_tokens': modelConfig.maxTokens ?? 64000,
      'messages': messages
          .where((m) => m is! SystemMessage)
          .map((m) {
            if (m is UserMessage) {
              final content = m.contents
                  .map((c) {
                    if (c is TextPart) {
                      return {'type': 'text', 'text': c.text};
                    } else if (c is ImagePart) {
                      return {
                        'type': 'image',
                        'source': {
                          'type': 'base64',
                          'media_type': c.mimeType,
                          'data': c.base64Data,
                        },
                      };
                    } else if (c is DocumentPart) {
                      return {
                        'type': 'document',
                        'source': {
                          'type': 'base64',
                          'media_type': c.mimeType,
                          'data': c.base64Data,
                        },
                      };
                    }
                    return null;
                  })
                  .where((e) => e != null)
                  .toList();

              return {
                'role': 'user',
                'content': content.isNotEmpty ? content : '',
              };
            } else if (m is ModelMessage) {
              final content = m.contentBlocks.isNotEmpty
                  ? _copyContentBlocks(m.contentBlocks)
                  : _buildAssistantContent(m);
              return {
                'role': 'assistant',
                'content': content.isNotEmpty ? content : '',
              };
            } else if (m is FunctionExecutionResultMessage) {
              final content = m.results.map((r) {
                final result = {
                  'type': 'tool_result',
                  'tool_use_id': r.id,
                  'content': r.content
                      .map((p) {
                        if (p is TextPart) {
                          return {'type': 'text', 'text': p.text};
                        }
                        if (p is ImagePart) {
                          return {
                            'type': 'image',
                            'source': {
                              'type': 'base64',
                              'media_type': p.mimeType,
                              'data': p.base64Data,
                            },
                          };
                        }
                        return null;
                      })
                      .where((e) => e != null)
                      .toList(),
                };
                if (r.isError) {
                  result['is_error'] = true;
                }
                return result;
              }).toList();

              return {'role': 'user', 'content': content};
            }
            return null;
          })
          .where((e) => e != null)
          .toList(),
    };

    final systemPrompt = messages
        .whereType<SystemMessage>()
        .map((m) => m.content)
        .join('\n');
    if (systemPrompt.isNotEmpty) {
      body['system'] = systemPrompt;
    }

    if (modelConfig.temperature != null) {
      body['temperature'] = modelConfig.temperature;
    }
    if (modelConfig.topP != null) body['top_p'] = modelConfig.topP;
    if (modelConfig.topK != null) body['top_k'] = modelConfig.topK!.toInt();

    if (tools != null && tools.isNotEmpty) {
      body['tools'] = tools.map((t) {
        return {
          'name': t.name,
          'description': t.description,
          'input_schema': t.parameters,
        };
      }).toList();

      if (toolChoice != null) {
        if (toolChoice.mode == ToolChoiceMode.auto) {
          body['tool_choice'] = {'type': 'auto'};
        } else if (toolChoice.mode == ToolChoiceMode.required) {
          if (toolChoice.allowedFunctionNames != null &&
              toolChoice.allowedFunctionNames!.isNotEmpty) {
            body['tool_choice'] = {
              'type': 'tool',
              'name': toolChoice.allowedFunctionNames!.first,
            };
          } else {
            body['tool_choice'] = {'type': 'any'};
          }
        }
      }
    }

    if (modelConfig.extra != null) {
      if (modelConfig.extra!['thinking'] != null) {
        body['thinking'] = modelConfig.extra!['thinking'];
      }
      if (modelConfig.extra!['output_config'] != null) {
        body['output_config'] = modelConfig.extra!['output_config'];
      }
    }

    if (jsonOutput == true && body['output_config'] == null) {
      _logger.warning(
        'jsonOutput is true but no output_config provided. '
        'Claude typically requires a JSON schema for structured output. '
        'Pass output_config in modelConfig.extra.',
      );
    }

    return body;
  }

  List<Map<String, dynamic>> _buildAssistantContent(ModelMessage message) {
    final content = <Map<String, dynamic>>[];

    if (message.thought != null && message.thought!.isNotEmpty) {
      content.add({
        'type': 'thinking',
        'thinking': message.thought,
        if (message.thoughtSignature != null)
          'signature': message.thoughtSignature,
      });
    }

    if (message.textOutput != null) {
      content.add({'type': 'text', 'text': message.textOutput});
    }
    if (message.functionCalls.isNotEmpty) {
      final validCalls = <FunctionCall>[];
      for (final call in message.functionCalls) {
        if (call.id.isNotEmpty) {
          validCalls.add(call);
        } else if (validCalls.isNotEmpty) {
          final previous = validCalls.last;
          validCalls[validCalls.length - 1] = FunctionCall(
            id: previous.id,
            name: previous.name,
            arguments: previous.arguments + call.arguments,
          );
        }
      }

      for (final call in validCalls) {
        content.add({
          'type': 'tool_use',
          'id': call.id,
          'name': call.name,
          'input': _decodeToolInput(call.arguments),
        });
      }
    }

    return content;
  }

  dynamic _decodeToolInput(String arguments) {
    if (arguments.isEmpty) {
      return {};
    }
    try {
      return jsonDecode(arguments);
    } catch (e) {
      _logger.warning('Error decoding tool input: $arguments - $e');
      return {};
    }
  }

  List<Map<String, dynamic>> _copyContentBlocks(
    List<Map<String, dynamic>> blocks,
  ) {
    return blocks.map((block) => _deepCopyMap(block)).toList();
  }

  Map<String, dynamic> _deepCopyMap(Map<String, dynamic> map) {
    return map.map((key, value) => MapEntry(key, _deepCopyValue(value)));
  }

  dynamic _deepCopyValue(dynamic value) {
    if (value is Map) {
      return value.map(
        (key, child) => MapEntry(key.toString(), _deepCopyValue(child)),
      );
    }
    if (value is List) {
      return value.map(_deepCopyValue).toList();
    }
    return value;
  }
}
