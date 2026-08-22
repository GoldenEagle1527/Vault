import 'package:test/test.dart';
import 'package:vault_agent_core/src/core/llm_client.dart';
import 'package:vault_agent_core/src/core/message.dart';
import 'package:vault_agent_core/src/core/tool.dart';
import 'package:vault_agent_core/src/llm/openai/request_builder.dart';
import 'package:vault_agent_core/src/llm/openai/stream_decoder.dart';

void main() {
  group('OpenAIRequestBuilder', () {
    test('maps messages, tools, generation options, and stream usage', () {
      final body = OpenAIRequestBuilder.build(
        [
          SystemMessage('system'),
          UserMessage.text('hello'),
          ModelMessage(
            model: 'openai-test',
            thought: 'reasoning',
            functionCalls: [
              FunctionCall(
                id: 'call_1',
                name: 'lookup',
                arguments: '{"query":"dart"}',
              ),
            ],
          ),
        ],
        tools: [
          Tool(
            name: 'lookup',
            description: 'Lookup a value',
            parameters: {
              'type': 'object',
              'properties': {
                'query': {'type': 'string'},
              },
            },
          ),
        ],
        toolChoice: ToolChoice(
          mode: ToolChoiceMode.required,
          allowedFunctionNames: ['lookup'],
        ),
        modelConfig: ModelConfig(
          model: 'openai-test',
          temperature: 0.2,
          maxTokens: 128,
          topP: 0.9,
          extra: {
            'reasoning_effort': 'high',
            'modalities': ['text'],
            'audio': {'voice': 'alloy'},
            'ignored': true,
          },
        ),
        stream: true,
        jsonOutput: true,
      );

      expect(body['model'], 'openai-test');
      expect(body['stream'], isTrue);
      expect(body['stream_options'], {'include_usage': true});
      expect(body['temperature'], 0.2);
      expect(body['max_completion_tokens'], 128);
      expect(body['top_p'], 0.9);
      expect(body['response_format'], {'type': 'json_object'});
      expect(body['reasoning_effort'], 'high');
      expect(body['modalities'], ['text']);
      expect(body['audio'], {'voice': 'alloy'});
      expect(body, isNot(contains('ignored')));

      final messages = body['messages'] as List;
      expect(messages[0], {'role': 'system', 'content': 'system'});
      expect(messages[1], {'role': 'user', 'content': 'hello'});
      expect(messages[2], {
        'role': 'assistant',
        'reasoning_content': 'reasoning',
        'tool_calls': [
          {
            'id': 'call_1',
            'type': 'function',
            'function': {'name': 'lookup', 'arguments': '{"query":"dart"}'},
          },
        ],
      });
      expect(body['tool_choice'], {
        'type': 'function',
        'function': {'name': 'lookup'},
      });
    });
  });

  group('OpenAIChunkDecoder', () {
    test('decodes data lines and stops at DONE', () async {
      final chunks = await Stream.fromIterable([
        'event: message',
        'data: not-json',
        'data: {"choices":[]}',
        'data: [DONE]',
        'data: {"ignored":true}',
      ]).transform(OpenAIChunkDecoder()).toList();

      expect(chunks, [
        {'choices': []},
      ]);
    });
  });

  group('OpenAIResponseTransformer', () {
    test(
      'accumulates tool calls and combines finish reason with usage',
      () async {
        final chunks =
            await Stream<Map<String, dynamic>>.fromIterable([
                  {
                    'model': 'remote-model',
                    'choices': [
                      {
                        'delta': {
                          'tool_calls': [
                            {
                              'index': 0,
                              'id': 'call_1',
                              'function': {
                                'name': 'lookup',
                                'arguments': '{"query"',
                              },
                            },
                          ],
                        },
                        'finish_reason': null,
                      },
                    ],
                  },
                  {
                    'model': 'remote-model',
                    'choices': [
                      {
                        'delta': {
                          'tool_calls': [
                            {
                              'index': 0,
                              'function': {'arguments': ':"dart"}'},
                            },
                          ],
                        },
                        'finish_reason': 'tool_calls',
                      },
                    ],
                  },
                  {
                    'model': 'remote-model',
                    'choices': <dynamic>[],
                    'usage': {
                      'prompt_tokens': 3,
                      'completion_tokens': 4,
                      'total_tokens': 7,
                    },
                  },
                ])
                .transform(
                  OpenAIResponseTransformer(ModelConfig(model: 'openai-test')),
                )
                .toList();

        expect(chunks, hasLength(3));
        expect(chunks[0].functionCalls.single.arguments, '{"query"');
        expect(chunks[1].functionCalls.single.arguments, '{"query":"dart"}');

        final completed = chunks[2];
        expect(completed.stopReason, 'tool_calls');
        expect(completed.functionCalls.single.id, 'call_1');
        expect(completed.functionCalls.single.name, 'lookup');
        expect(completed.functionCalls.single.arguments, '{"query":"dart"}');
        expect(completed.usage?.promptTokens, 3);
        expect(completed.usage?.completionTokens, 4);
        expect(completed.usage?.totalTokens, 7);
        expect(completed.model, 'openai-test');
      },
    );

    test('emits text and reasoning deltas unchanged', () async {
      final chunks =
          await Stream<Map<String, dynamic>>.fromIterable([
                {
                  'choices': [
                    {
                      'delta': {
                        'content': 'answer',
                        'reasoning_content': 'thought',
                      },
                      'finish_reason': 'stop',
                    },
                  ],
                },
              ])
              .transform(
                OpenAIResponseTransformer(ModelConfig(model: 'openai-test')),
              )
              .toList();

      expect(chunks.map((chunk) => chunk.textOutput), ['answer', null, null]);
      expect(chunks.map((chunk) => chunk.thought), [null, 'thought', null]);
      expect(chunks.last.stopReason, 'stop');
    });
  });
}
