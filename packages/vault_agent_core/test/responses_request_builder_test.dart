import 'package:test/test.dart';
import 'package:vault_agent_core/src/core/llm_client.dart';
import 'package:vault_agent_core/src/core/message.dart';
import 'package:vault_agent_core/src/core/tool.dart';
import 'package:vault_agent_core/src/llm/responses/request_builder.dart';

void main() {
  group('ResponsesRequestBuilder', () {
    test('serializes messages, tools, choices, and allowed config', () {
      final body = const ResponsesRequestBuilder().build(
        [
          SystemMessage('system'),
          UserMessage([
            TextPart('hello'),
            ImagePart('image-data', 'image/png', detail: 'high'),
            AudioPart('audio-data', 'audio/mpeg'),
          ]),
          ModelMessage(
            model: 'test-model',
            textOutput: 'working',
            functionCalls: [
              FunctionCall(id: 'call_1', name: 'lookup', arguments: '{"id":1}'),
            ],
          ),
          FunctionExecutionResultMessage(
            results: [
              FunctionExecutionResult(
                id: 'call_1',
                name: 'lookup',
                isError: false,
                arguments: '{"id":1}',
                content: [TextPart('first'), TextPart('second')],
              ),
            ],
          ),
        ],
        tools: [
          Tool(
            name: 'lookup',
            description: 'Look up an item',
            parameters: {'type': 'object', 'properties': <String, dynamic>{}},
          ),
        ],
        toolChoice: ToolChoice(
          mode: ToolChoiceMode.required,
          allowedFunctionNames: ['lookup'],
        ),
        modelConfig: ModelConfig(
          model: 'test-model',
          temperature: 0.2,
          maxTokens: 100,
          topP: 0.8,
          extra: {
            'reasoning': {'effort': 'medium'},
            'store': true,
            'ignored': 'value',
          },
        ),
        stream: true,
      );

      expect(body['model'], 'test-model');
      expect(body['stream'], isTrue);
      expect(body['temperature'], 0.2);
      expect(body['max_output_tokens'], 100);
      expect(body['top_p'], 0.8);
      expect(body['reasoning'], {'effort': 'medium'});
      expect(body['store'], isTrue);
      expect(body, isNot(contains('ignored')));
      expect(body['tool_choice'], {'type': 'function', 'name': 'lookup'});

      final input = body['input'] as List;
      expect(input[0]['role'], 'system');
      expect(input[1]['content'], [
        {'type': 'input_text', 'text': 'hello'},
        {
          'type': 'input_image',
          'image_url': 'data:image/png;base64,image-data',
          'detail': 'high',
        },
        {
          'type': 'input_audio',
          'input_audio': {'data': 'audio-data', 'format': 'mp3'},
        },
      ]);
      expect(input[2]['content'], [
        {'type': 'output_text', 'text': 'working'},
      ]);
      expect(input[3], {
        'type': 'function_call',
        'call_id': 'call_1',
        'name': 'lookup',
        'arguments': '{"id":1}',
      });
      expect(input[4], {
        'type': 'function_call_output',
        'call_id': 'call_1',
        'output': 'first\nsecond',
      });
    });

    test('uses previous response id and only sends pending messages', () {
      final body = const ResponsesRequestBuilder().build(
        [
          SystemMessage('system'),
          UserMessage.text('old'),
          ModelMessage(model: 'test-model', responseId: 'resp_1'),
          UserMessage.text('new'),
        ],
        tools: [Tool(name: 'tool', description: 'tool', parameters: const {})],
        modelConfig: ModelConfig(model: 'test-model'),
      );

      expect(body['previous_response_id'], 'resp_1');
      expect(body, isNot(contains('tools')));
      expect(body['input'], [
        {
          'type': 'message',
          'role': 'user',
          'content': [
            {'type': 'input_text', 'text': 'new'},
          ],
        },
      ]);
    });
  });
}
