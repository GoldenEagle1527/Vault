import 'dart:convert';

import 'package:logging/logging.dart';

import '../../core/llm_client.dart';
import '../../core/message.dart';
import '../../core/tool.dart';

class BedrockRequestBuilder {
  BedrockRequestBuilder({Logger? logger})
    : _logger = logger ?? Logger('BedrockClaudeClient');

  final Logger _logger;

  Map<String, dynamic> build(
    List<LLMMessage> messages, {
    List<Tool>? tools,
    ToolChoice? toolChoice,
    required ModelConfig modelConfig,
    bool? jsonOutput,
  }) {
    final body = <String, dynamic>{
      'anthropic_version': 'bedrock-2023-05-31',
      'max_tokens': modelConfig.maxTokens ?? 64000,
      'messages': messages
          .where((message) => message is! SystemMessage)
          .map(_buildMessage)
          .where((message) => message != null)
          .toList(),
    };

    final systemPrompt = messages
        .whereType<SystemMessage>()
        .map((message) => message.content)
        .join('\n');
    if (systemPrompt.isNotEmpty) body['system'] = systemPrompt;
    if (modelConfig.temperature != null) {
      body['temperature'] = modelConfig.temperature;
    }
    if (modelConfig.topP != null) body['top_p'] = modelConfig.topP;
    if (modelConfig.topK != null) body['top_k'] = modelConfig.topK!.toInt();

    if (tools != null && tools.isNotEmpty) {
      body['tools'] = tools
          .map(
            (tool) => {
              'name': tool.name,
              'description': tool.description,
              'input_schema': tool.parameters,
            },
          )
          .toList();
      if (toolChoice?.mode == ToolChoiceMode.auto) {
        body['tool_choice'] = {'type': 'auto'};
      } else if (toolChoice?.mode == ToolChoiceMode.required) {
        final allowedNames = toolChoice?.allowedFunctionNames;
        body['tool_choice'] = allowedNames != null && allowedNames.isNotEmpty
            ? {'type': 'tool', 'name': allowedNames.first}
            : {'type': 'any'};
      }
    }

    final extra = modelConfig.extra;
    if (extra?['thinking'] != null) body['thinking'] = extra!['thinking'];
    if (extra?['output_config'] != null) {
      body['output_config'] = extra!['output_config'];
    }
    if (jsonOutput == true && body['output_config'] == null) {
      _logger.warning(
        'jsonOutput is true but no output_config provided. '
        'Bedrock/Claude typically requires a JSON schema for structured output. '
        'Pass output_config in modelConfig.extra.',
      );
    }
    return body;
  }

  Map<String, dynamic>? _buildMessage(LLMMessage message) {
    if (message is UserMessage) {
      final content = message.contents
          .map(_buildContentPart)
          .where((part) => part != null)
          .toList();
      return {'role': 'user', 'content': content.isNotEmpty ? content : ''};
    }
    if (message is ModelMessage) {
      final content = message.contentBlocks.isNotEmpty
          ? _copyContentBlocks(message.contentBlocks)
          : _buildAssistantContent(message);
      return {
        'role': 'assistant',
        'content': content.isNotEmpty ? content : '',
      };
    }
    if (message is FunctionExecutionResultMessage) {
      final content = message.results.map((result) {
        final toolResult = <String, dynamic>{
          'type': 'tool_result',
          'tool_use_id': result.id,
          'content': result.content
              .map(_buildContentPart)
              .where((part) => part != null)
              .toList(),
        };
        if (result.isError) toolResult['is_error'] = true;
        return toolResult;
      }).toList();
      return {'role': 'user', 'content': content};
    }
    return null;
  }

  Map<String, dynamic>? _buildContentPart(UserContentPart part) {
    if (part is TextPart) return {'type': 'text', 'text': part.text};
    if (part is ImagePart) {
      return {
        'type': 'image',
        'source': {
          'type': 'base64',
          'media_type': part.mimeType,
          'data': part.base64Data,
        },
      };
    }
    return null;
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
    return content;
  }

  dynamic _decodeToolInput(String arguments) {
    if (arguments.isEmpty) return {};
    try {
      return jsonDecode(arguments);
    } catch (error) {
      _logger.warning('Error decoding tool input: $arguments - $error');
      return {};
    }
  }

  List<Map<String, dynamic>> _copyContentBlocks(
    List<Map<String, dynamic>> blocks,
  ) => blocks.map(_deepCopyMap).toList();

  Map<String, dynamic> _deepCopyMap(Map<String, dynamic> map) =>
      map.map((key, value) => MapEntry(key, _deepCopyValue(value)));

  dynamic _deepCopyValue(dynamic value) {
    if (value is Map) {
      return value.map(
        (key, child) => MapEntry(key.toString(), _deepCopyValue(child)),
      );
    }
    if (value is List) return value.map(_deepCopyValue).toList();
    return value;
  }
}
