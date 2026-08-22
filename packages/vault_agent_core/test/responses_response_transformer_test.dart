import 'package:test/test.dart';
import 'package:vault_agent_core/src/core/llm_client.dart';
import 'package:vault_agent_core/src/llm/responses/response_transformer.dart';

void main() {
  test('transforms output, usage, reasoning, and tool calls', () {
    final source = <String, dynamic>{
      'id': 'resp_1',
      'status': 'completed',
      'output': [
        {
          'type': 'message',
          'content': [
            {'type': 'output_text', 'text': 'hello '},
            {'type': 'output_text', 'text': 'world'},
          ],
        },
        {
          'type': 'function_call',
          'call_id': 'call_1',
          'name': 'lookup',
          'arguments': '{"id":1}',
        },
        {
          'type': 'reasoning',
          'summary': [
            {'text': 'first '},
            {'text': 'second'},
          ],
        },
      ],
      'usage': {
        'input_tokens': 10,
        'output_tokens': 20,
        'total_tokens': 30,
        'input_tokens_details': {'cached_tokens': 4},
        'output_tokens_details': {'reasoning_tokens': 5},
      },
    };

    final result = ResponsesResponseTransformer(
      ModelConfig(model: 'test-model'),
    ).transform(source);

    expect(result.textOutput, 'hello world');
    expect(result.thought, 'first second');
    expect(result.responseId, 'resp_1');
    expect(result.stopReason, 'completed');
    expect(result.metadata, same(source));
    expect(result.functionCalls.single.id, 'call_1');
    expect(result.functionCalls.single.name, 'lookup');
    expect(result.functionCalls.single.arguments, '{"id":1}');
    expect(result.usage?.promptTokens, 10);
    expect(result.usage?.completionTokens, 20);
    expect(result.usage?.totalTokens, 30);
    expect(result.usage?.cachedToken, 4);
    expect(result.usage?.thoughtToken, 5);
  });
}
