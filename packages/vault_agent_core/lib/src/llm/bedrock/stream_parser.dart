import 'dart:convert';

import '../../core/llm_client.dart';
import '../../core/message.dart';

class BedrockStreamParser {
  BedrockStreamParser(this.modelConfig);

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
      }
      if (start['type'] == 'thinking') {
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
      }
      if (delta['type'] == 'thinking_delta') {
        _currentThinking.write(delta['thinking'] ?? '');
        return ModelMessage(
          thought: delta['thinking'],
          model: modelConfig.model,
          usage: _currentUsage(),
        );
      }
      if (delta['type'] == 'signature_delta') {
        _currentThinkingSignature = delta['signature'];
        return ModelMessage(
          thoughtSignature: delta['signature'],
          model: modelConfig.model,
          usage: _currentUsage(),
        );
      }
      if (delta['type'] == 'input_json_delta') {
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
      if (message['usage'] != null) {
        final usage = message['usage'];
        _promptTokens = usage['input_tokens'] ?? 0;
        _cachedTokens =
            (usage['cache_read_input_tokens'] ?? 0) +
            (usage['cache_creation_input_tokens'] ?? 0);
        _completionTokens += usage['output_tokens'] as int? ?? 0;
        return ModelMessage(usage: _currentUsage(), model: modelConfig.model);
      }
    } else if (type == 'message_delta') {
      final delta = chunk['delta'];
      final stopReason = delta['stop_reason'] as String?;
      if (chunk['usage'] != null) {
        final usage = chunk['usage'];
        _completionTokens = usage['output_tokens'] as int? ?? 0;
        _thoughtTokens =
            usage['output_tokens_details']?['reasoning_tokens'] ?? 0;
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

  ModelMessage? _finishCurrentBlock() {
    final blockType = _currentBlockType;
    if (blockType == null) return null;

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
    if (input.isEmpty) return {};
    try {
      return jsonDecode(input);
    } catch (_) {
      return {};
    }
  }

  ModelUsage _currentUsage() => ModelUsage(
    promptTokens: _promptTokens,
    completionTokens: _completionTokens,
    totalTokens: _promptTokens + _completionTokens,
    cachedToken: _cachedTokens,
    thoughtToken: _thoughtTokens,
    model: modelConfig.model,
  );
}
