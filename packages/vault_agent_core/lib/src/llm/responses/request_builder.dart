import '../../core/llm_client.dart';
import '../../core/message.dart';
import '../../core/tool.dart';

const _defaultExtraAllowedKeys = {
  'reasoning',
  'caching',
  'expire_at',
  'thinking',
  'store',
};

class ResponsesRequestBuilder {
  final bool autoPreviousResponseId;
  final Set<String>? extraAllowedKeys;

  const ResponsesRequestBuilder({
    this.autoPreviousResponseId = true,
    this.extraAllowedKeys,
  });

  Map<String, dynamic> build(
    List<LLMMessage> messages, {
    List<Tool>? tools,
    ToolChoice? toolChoice,
    required ModelConfig modelConfig,
    bool stream = false,
    bool? jsonOutput,
  }) {
    final allowedKeys = extraAllowedKeys ?? _defaultExtraAllowedKeys;
    String? previousResponseId =
        modelConfig.extra?['previous_response_id'] as String?;
    var cutoffIndex = -1;

    if (previousResponseId == null && autoPreviousResponseId) {
      for (var i = messages.length - 1; i >= 0; i--) {
        final message = messages[i];
        if (message is ModelMessage && message.responseId != null) {
          previousResponseId = message.responseId;
          cutoffIndex = i;
          break;
        }
      }
    } else if (previousResponseId != null) {
      for (var i = messages.length - 1; i >= 0; i--) {
        final message = messages[i];
        if (message is ModelMessage &&
            message.responseId == previousResponseId) {
          cutoffIndex = i;
          break;
        }
      }
    }

    final pendingMessages = cutoffIndex == -1
        ? messages
        : messages.sublist(cutoffIndex + 1);
    final input = <Map<String, dynamic>>[];

    for (final message in pendingMessages) {
      if (message is UserMessage) {
        input.add({
          'type': 'message',
          'role': 'user',
          'content': message.contents
              .map(_serializeUserContentPart)
              .whereType<Map<String, dynamic>>()
              .toList(),
        });
      } else if (message is SystemMessage) {
        if (previousResponseId == null) {
          input.add({
            'type': 'message',
            'role': 'system',
            'content': [
              {'type': 'input_text', 'text': message.content},
            ],
          });
        }
      } else if (message is ModelMessage) {
        if (message.textOutput != null && message.textOutput!.isNotEmpty) {
          input.add({
            'type': 'message',
            'role': 'assistant',
            'content': [
              {'type': 'output_text', 'text': message.textOutput},
            ],
            'status': 'completed',
          });
        }
        for (final call in message.functionCalls) {
          input.add({
            'type': 'function_call',
            'call_id': call.id,
            'name': call.name,
            'arguments': call.arguments,
          });
        }
      } else if (message is FunctionExecutionResultMessage) {
        for (final result in message.results) {
          input.add({
            'type': 'function_call_output',
            'call_id': result.id,
            'output': result.content
                .whereType<TextPart>()
                .map((part) => part.text)
                .join('\n'),
          });
        }
      }
    }

    final body = <String, dynamic>{
      'model': modelConfig.model,
      'stream': stream,
    };
    if (input.isNotEmpty) body['input'] = input;
    if (previousResponseId != null) {
      body['previous_response_id'] = previousResponseId;
    }
    if (tools != null && tools.isNotEmpty && previousResponseId == null) {
      body['tools'] = tools
          .map(
            (tool) => {
              'type': 'function',
              'name': tool.name,
              'description': tool.description,
              'parameters': tool.parameters,
            },
          )
          .toList();
      _addToolChoice(body, toolChoice);
    }
    if (modelConfig.temperature != null) {
      body['temperature'] = modelConfig.temperature;
    }
    if (modelConfig.maxTokens != null) {
      body['max_output_tokens'] = modelConfig.maxTokens;
    }
    if (modelConfig.topP != null) body['top_p'] = modelConfig.topP;
    for (final entry in modelConfig.extra?.entries ?? const Iterable.empty()) {
      if (allowedKeys.contains(entry.key)) body[entry.key] = entry.value;
    }
    return body;
  }

  Map<String, dynamic>? _serializeUserContentPart(UserContentPart part) {
    if (part is TextPart) {
      return {'type': 'input_text', 'text': part.text};
    }
    if (part is ImagePart) {
      return {
        'type': 'input_image',
        'image_url': _convertBase64ToUrl(part.base64Data, part.mimeType),
        if (part.detail != null) 'detail': part.detail,
      };
    }
    if (part is AudioPart) {
      final mimeType = part.mimeType.toLowerCase();
      final format = mimeType.contains('mp3') || mimeType.contains('mpeg')
          ? 'mp3'
          : 'wav';
      return {
        'type': 'input_audio',
        'input_audio': {'data': part.base64Data, 'format': format},
      };
    }
    return null;
  }

  void _addToolChoice(Map<String, dynamic> body, ToolChoice? toolChoice) {
    if (toolChoice == null) return;
    final names = toolChoice.allowedFunctionNames;
    if (names != null && names.isNotEmpty) {
      if (toolChoice.mode == ToolChoiceMode.required && names.length == 1) {
        body['tool_choice'] = {'type': 'function', 'name': names.first};
      } else {
        body['tool_choice'] = {
          'type': 'allowed_tools',
          'mode': toolChoice.mode == ToolChoiceMode.required
              ? 'required'
              : 'auto',
          'tools': names
              .map((name) => {'type': 'function', 'name': name})
              .toList(),
        };
      }
      return;
    }
    body['tool_choice'] = switch (toolChoice.mode) {
      ToolChoiceMode.none => 'none',
      ToolChoiceMode.auto => 'auto',
      ToolChoiceMode.required => 'required',
    };
  }
}

String _convertBase64ToUrl(String base64Data, String mimeType) {
  if (base64Data.startsWith('data')) return base64Data;
  return 'data:$mimeType;base64,$base64Data';
}
