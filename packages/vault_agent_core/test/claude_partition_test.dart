import 'dart:convert';

import 'package:test/test.dart';
import 'package:vault_agent_core/src/core/llm_client.dart';
import 'package:vault_agent_core/src/core/message.dart';
import 'package:vault_agent_core/src/core/tool.dart';
import 'package:vault_agent_core/src/llm/claude/request_builder.dart';
import 'package:vault_agent_core/src/llm/claude/response_transformer.dart';
import 'package:vault_agent_core/src/llm/claude/stream_decoder.dart';

void main() {
  final modelConfig = ModelConfig(model: 'claude-test');

  group('ClaudeRequestBuilder', () {
    test('serializes system, media, tools, and provider options', () {
      final body = ClaudeRequestBuilder().build(
        [
          SystemMessage('first'),
          SystemMessage('second'),
          UserMessage([
            TextPart('hello'),
            ImagePart('image-data', 'image/png'),
            DocumentPart('document-data', 'application/pdf'),
          ]),
        ],
        tools: [
          Tool(
            name: 'lookup',
            description: 'Look up a value',
            parameters: {
              'type': 'object',
              'properties': {
                'key': {'type': 'string'},
              },
            },
          ),
        ],
        toolChoice: ToolChoice(
          mode: ToolChoiceMode.required,
          allowedFunctionNames: ['lookup'],
        ),
        modelConfig: ModelConfig(
          model: 'claude-test',
          maxTokens: 123,
          temperature: 0.2,
          topP: 0.8,
          topK: 10,
          extra: {
            'thinking': {'type': 'enabled', 'budget_tokens': 100},
            'output_config': {
              'format': {'type': 'json_schema'},
            },
          },
        ),
        jsonOutput: true,
      );

      expect(body['system'], 'first\nsecond');
      expect(body['max_tokens'], 123);
      expect(body['temperature'], 0.2);
      expect(body['top_p'], 0.8);
      expect(body['top_k'], 10);
      expect(body['tool_choice'], {'type': 'tool', 'name': 'lookup'});
      expect(body['tools'], [
        {
          'name': 'lookup',
          'description': 'Look up a value',
          'input_schema': {
            'type': 'object',
            'properties': {
              'key': {'type': 'string'},
            },
          },
        },
      ]);
      expect(body['messages'], [
        {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': 'hello'},
            {
              'type': 'image',
              'source': {
                'type': 'base64',
                'media_type': 'image/png',
                'data': 'image-data',
              },
            },
            {
              'type': 'document',
              'source': {
                'type': 'base64',
                'media_type': 'application/pdf',
                'data': 'document-data',
              },
            },
          ],
        },
      ]);
      expect(body['thinking'], {'type': 'enabled', 'budget_tokens': 100});
      expect(body['output_config'], {
        'format': {'type': 'json_schema'},
      });
    });

    test('reassembles split tool-call arguments', () {
      final body = ClaudeRequestBuilder().build([
        ModelMessage(
          model: 'claude-test',
          functionCalls: [
            FunctionCall(id: 'toolu_1', name: 'lookup', arguments: '{"key"'),
            FunctionCall(id: '', name: '', arguments: ':"value"}'),
          ],
        ),
      ], modelConfig: modelConfig);

      expect(body['messages'], [
        {
          'role': 'assistant',
          'content': [
            {
              'type': 'tool_use',
              'id': 'toolu_1',
              'name': 'lookup',
              'input': {'key': 'value'},
            },
          ],
        },
      ]);
    });
  });

  group('ClaudeResponseTransformer', () {
    test('preserves blocks, tool calls, thinking, usage, and stop reason', () {
      final message = ClaudeResponseTransformer().transform({
        'content': [
          {'type': 'thinking', 'thinking': 'reason', 'signature': 'sig'},
          {'type': 'text', 'text': 'answer'},
          {
            'type': 'tool_use',
            'id': 'toolu_1',
            'name': 'lookup',
            'input': {'key': 'value'},
          },
        ],
        'stop_reason': 'tool_use',
        'usage': {
          'input_tokens': 7,
          'output_tokens': 5,
          'cache_read_input_tokens': 2,
          'cache_creation_input_tokens': 3,
        },
      }, modelConfig);

      expect(message.textOutput, 'answer');
      expect(message.thought, 'reason');
      expect(message.thoughtSignature, 'sig');
      expect(message.stopReason, 'tool_use');
      expect(message.contentBlocks, hasLength(3));
      expect(message.functionCalls.single.id, 'toolu_1');
      expect(jsonDecode(message.functionCalls.single.arguments), {
        'key': 'value',
      });
      expect(message.usage?.promptTokens, 7);
      expect(message.usage?.completionTokens, 5);
      expect(message.usage?.totalTokens, 12);
      expect(message.usage?.cachedToken, 5);
    });

    test('keeps Claude payload error semantics', () {
      expect(
        () => ClaudeResponseTransformer().transform({
          'type': 'error',
          'error': {'message': 'invalid request'},
        }, modelConfig),
        throwsA(
          predicate(
            (error) =>
                error.toString() == 'Exception: Claude Error: invalid request',
          ),
        ),
      );
    });
  });

  group('ClaudeStreamDecoder', () {
    test(
      'decodes usage, tool calls, content blocks, and stop reason',
      () async {
        final events = [
          {
            'type': 'message_start',
            'message': {
              'usage': {
                'input_tokens': 4,
                'output_tokens': 0,
                'cache_read_input_tokens': 1,
                'cache_creation_input_tokens': 2,
              },
            },
          },
          {
            'type': 'content_block_start',
            'content_block': {
              'type': 'tool_use',
              'id': 'toolu_1',
              'name': 'lookup',
              'input': {},
            },
          },
          {
            'type': 'content_block_delta',
            'delta': {
              'type': 'input_json_delta',
              'partial_json': '{"key":"value"}',
            },
          },
          {'type': 'content_block_stop'},
          {
            'type': 'message_delta',
            'delta': {'stop_reason': 'tool_use'},
            'usage': {
              'output_tokens': 6,
              'output_tokens_details': {'reasoning_tokens': 2},
            },
          },
        ];
        final bytes = events
            .map(
              (event) =>
                  'event: ${event['type']}\n'
                  'data: ${jsonEncode(event)}\n\n',
            )
            .join();

        final chunks = await ClaudeStreamDecoder()
            .decode(Stream.value(utf8.encode(bytes)), modelConfig)
            .map((event) => event.modelMessage!)
            .toList();

        final finalBlock = chunks.firstWhere(
          (message) => message.contentBlocks.isNotEmpty,
        );
        expect(finalBlock.contentBlocks.single, {
          'type': 'tool_use',
          'id': 'toolu_1',
          'name': 'lookup',
          'input': {'key': 'value'},
        });
        expect(finalBlock.functionCalls.single.arguments, '{"key":"value"}');

        final terminal = chunks.last;
        expect(terminal.stopReason, 'tool_use');
        expect(terminal.usage?.promptTokens, 4);
        expect(terminal.usage?.completionTokens, 6);
        expect(terminal.usage?.cachedToken, 3);
        expect(terminal.usage?.thoughtToken, 2);
      },
    );

    test('surfaces SSE error events unchanged', () async {
      final bytes = utf8.encode(
        'event: error\n'
        'data: {"type":"error","error":{"message":"overloaded"}}\n\n',
      );

      await expectLater(
        ClaudeStreamDecoder().decode(Stream.value(bytes), modelConfig),
        emitsError(
          predicate(
            (error) =>
                error.toString() ==
                'Exception: Claude Stream Error: overloaded',
          ),
        ),
      );
    });
  });
}
