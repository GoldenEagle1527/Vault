import 'dart:async';
import 'dart:convert';

import 'package:logging/logging.dart';

import '../../core/llm_client.dart';
import '../../core/message.dart';

/// Decodes Anthropic SSE bytes into streaming package messages.
class ClaudeStreamDecoder {
  final Logger _logger;

  ClaudeStreamDecoder({Logger? logger})
    : _logger = logger ?? Logger('ClaudeClient');

  Stream<StreamingMessage> decode(
    Stream<List<int>> stream,
    ModelConfig modelConfig,
  ) {
    final controller = StreamController<StreamingMessage>();
    final parser = ClaudeStreamParser(modelConfig);
    String? eventType;

    stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) {
            if (line.isEmpty) {
              eventType = null;
            } else if (line.startsWith('data: ')) {
              final data = line.substring(6);
              if (data == '[DONE]') return;

              try {
                final json = jsonDecode(data) as Map<String, dynamic>;
                if (eventType == 'error' || json['type'] == 'error') {
                  controller.addError(createClaudeStreamError(json));
                  return;
                }

                final message = parser.parse(json);
                if (message != null) {
                  controller.add(StreamingMessage(modelMessage: message));
                }
              } catch (e) {
                _logger.warning('Error parsing SSE chunk: $e, data: $data');
              }
            } else if (line.startsWith('event: ')) {
              eventType = line.substring(7);
            } else if (line.startsWith('error: ')) {
              try {
                final errorData = jsonDecode(line.substring(7));
                controller.addError(createClaudeStreamError(errorData));
              } catch (_) {
                controller.addError(Exception('Claude Stream Error: $line'));
              }
            }
          },
          onError: controller.addError,
          onDone: controller.close,
        );

    return controller.stream;
  }
}

Exception createClaudeStreamError(Map<String, dynamic> payload) {
  final error = payload['error'];
  if (error is Map && error['message'] != null) {
    return Exception('Claude Stream Error: ${error['message']}');
  }
  if (payload['message'] != null) {
    return Exception('Claude Stream Error: ${payload['message']}');
  }
  return Exception('Claude Stream Error: $payload');
}

/// Stateful transformer for Anthropic streaming event payloads.
class ClaudeStreamParser {
  final ModelConfig modelConfig;
  String? _currentBlockType;
  Map<String, dynamic>? _currentRawBlock;
  String? _currentToolId;
  String? _currentToolName;
  final StringBuffer _currentToolJson = StringBuffer();
  final StringBuffer _currentText = StringBuffer();
  final StringBuffer _currentThinking = StringBuffer();
  String? _currentThinkingSignature;

  int _promptTokens = 0;
  int _completionTokens = 0;
  int _cachedTokens = 0;
  int _thoughtTokens = 0;

  ClaudeStreamParser(this.modelConfig);

  ModelMessage? parse(Map<String, dynamic> chunk) {
    final type = chunk['type'];

    if (type == 'content_block_start') {
      final start = chunk['content_block'];
      _currentBlockType = start['type'] as String?;
      _currentRawBlock = Map<String, dynamic>.from(start as Map);
      _currentText.clear();
      _currentThinking.clear();
      _currentThinkingSignature = null;
      if (start['type'] == 'tool_use') {
        _currentToolId = start['id'];
        _currentToolName = start['name'];
        _currentToolJson.clear();
        return ModelMessage(
          functionCalls: [
            FunctionCall(
              id: _currentToolId ?? '',
              name: _currentToolName ?? '',
              arguments: '',
            ),
          ],
          model: modelConfig.model,
          usage: _currentUsage(),
        );
      } else if (start['type'] == 'thinking') {
        return ModelMessage(
          thought: '',
          model: modelConfig.model,
          usage: _currentUsage(),
        );
      }
    } else if (type == 'content_block_delta') {
      final delta = chunk['delta'];
      if (delta['type'] == 'text_delta') {
        _currentText.write(delta['text'] ?? '');
        return ModelMessage(
          textOutput: delta['text'],
          model: modelConfig.model,
          usage: _currentUsage(),
        );
      } else if (delta['type'] == 'thinking_delta') {
        _currentThinking.write(delta['thinking'] ?? '');
        return ModelMessage(
          thought: delta['thinking'],
          model: modelConfig.model,
          usage: _currentUsage(),
        );
      } else if (delta['type'] == 'signature_delta') {
        _currentThinkingSignature = delta['signature'];
        return ModelMessage(
          thoughtSignature: delta['signature'],
          model: modelConfig.model,
          usage: _currentUsage(),
        );
      } else if (delta['type'] == 'input_json_delta') {
        _currentToolJson.write(delta['partial_json']);
        if (_currentToolId != null) {
          return ModelMessage(
            functionCalls: [
              FunctionCall(
                id: _currentToolId!,
                name: _currentToolName ?? '',
                arguments: _currentToolJson.toString(),
              ),
            ],
            model: modelConfig.model,
            usage: _currentUsage(),
          );
        }
      }
    } else if (type == 'content_block_stop') {
      return _finishCurrentBlock();
    } else if (type == 'message_start') {
      final message = chunk['message'];
      if (message != null && message['usage'] != null) {
        final usage = message['usage'];
        _promptTokens = usage['input_tokens'] ?? 0;
        _cachedTokens =
            (usage['cache_read_input_tokens'] ?? 0) +
            (usage['cache_creation_input_tokens'] ?? 0);
        _completionTokens += (usage['output_tokens'] as int? ?? 0);
        return ModelMessage(usage: _currentUsage(), model: modelConfig.model);
      }
    } else if (type == 'message_delta') {
      final delta = chunk['delta'];
      String? stopReason;

      if (delta != null && delta['stop_reason'] != null) {
        stopReason = delta['stop_reason'];
      }

      if (chunk['usage'] != null) {
        final u = chunk['usage'];
        _completionTokens = (u['output_tokens'] as int? ?? 0);
        _thoughtTokens = u['output_tokens_details']?['reasoning_tokens'] ?? 0;
      }

      if (stopReason != null || chunk['usage'] != null) {
        return ModelMessage(
          stopReason: stopReason,
          usage: _currentUsage(),
          model: modelConfig.model,
        );
      }
    }

    return null;
  }

  ModelUsage _currentUsage() {
    return ModelUsage(
      promptTokens: _promptTokens,
      completionTokens: _completionTokens,
      totalTokens: _promptTokens + _completionTokens,
      cachedToken: _cachedTokens,
      thoughtToken: _thoughtTokens,
      model: modelConfig.model,
    );
  }

  ModelMessage? _finishCurrentBlock() {
    final blockType = _currentBlockType;
    if (blockType == null) {
      return null;
    }

    final block = Map<String, dynamic>.from(_currentRawBlock ?? {});
    FunctionCall? toolCall;

    if (blockType == 'text') {
      block['text'] = _currentText.toString();
    } else if (blockType == 'thinking') {
      block['thinking'] = _currentThinking.toString();
      if (_currentThinkingSignature != null) {
        block['signature'] = _currentThinkingSignature;
      }
    } else if (blockType == 'tool_use') {
      final arguments = _currentToolJson.toString();
      toolCall = FunctionCall(
        id: _currentToolId!,
        name: _currentToolName!,
        arguments: arguments,
      );
      block['input'] = _parseToolInput(arguments);
    }

    _clearCurrentBlock();
    return ModelMessage(
      contentBlocks: [block],
      functionCalls: toolCall == null ? const [] : [toolCall],
      model: modelConfig.model,
      usage: _currentUsage(),
    );
  }

  void _clearCurrentBlock() {
    _currentBlockType = null;
    _currentRawBlock = null;
    _currentToolId = null;
    _currentToolName = null;
    _currentToolJson.clear();
    _currentText.clear();
    _currentThinking.clear();
    _currentThinkingSignature = null;
  }

  dynamic _parseToolInput(String input) {
    if (input.isEmpty) {
      return {};
    }
    try {
      return jsonDecode(input);
    } catch (_) {
      return {};
    }
  }
}
