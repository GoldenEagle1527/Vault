import 'dart:async';

import 'package:test/test.dart';
import 'package:vault_agent_core/src/core/llm_client.dart';
import 'package:vault_agent_core/src/llm/responses/stream_decoder.dart';
import 'package:vault_agent_core/src/llm/responses/stream_response_transformer.dart';

void main() {
  test(
    'decoder ignores non-data and malformed lines and stops at done',
    () async {
      final events = await Stream.fromIterable([
        'event: response.output_text.delta',
        'data: {"type":"response.output_text.delta","delta":"hello"}',
        'data: not-json',
        'data: [DONE]',
        'data: {"type":"response.output_text.delta","delta":"ignored"}',
      ]).transform(ResponsesChunkDecoder()).toList();

      expect(events, [
        {'type': 'response.output_text.delta', 'delta': 'hello'},
      ]);
    },
  );

  test(
    'stream transformer preserves deltas, tool buffers, and usage',
    () async {
      final chunks =
          await Stream<Map<String, dynamic>>.fromIterable([
                {
                  'type': 'response.output_item.added',
                  'item': {
                    'id': 'item_1',
                    'type': 'function_call',
                    'call_id': 'call_1',
                    'name': 'lookup',
                  },
                },
                {
                  'type': 'response.function_call_arguments.delta',
                  'item_id': 'item_1',
                  'delta': '{"id"',
                },
                {
                  'type': 'response.function_call_arguments.delta',
                  'item_id': 'item_1',
                  'delta': ':1}',
                },
                {
                  'type': 'response.output_item.done',
                  'item': {'id': 'item_1', 'type': 'function_call'},
                },
                {'type': 'response.output_text.delta', 'delta': 'hello'},
                {
                  'type': 'response.reasoning_summary_text.delta',
                  'delta': 'think',
                },
                {
                  'type': 'response.completed',
                  'response': {
                    'id': 'resp_1',
                    'usage': {
                      'input_tokens': 3,
                      'output_tokens': 4,
                      'total_tokens': 7,
                      'input_tokens_details': {'cached_tokens': 1},
                      'output_tokens_details': {'reasoning_tokens': 2},
                    },
                  },
                },
              ])
              .transform(
                ResponsesAPIResponseTransformer(
                  ModelConfig(model: 'test-model'),
                ),
              )
              .toList();

      final calls = chunks.expand((chunk) => chunk.functionCalls).toList();
      expect(calls.map((call) => call.arguments), [
        '',
        '{"id"',
        '{"id":1}',
        '{"id":1}',
      ]);
      expect(
        chunks.singleWhere((chunk) => chunk.textOutput != null).textOutput,
        'hello',
      );
      expect(
        chunks.singleWhere((chunk) => chunk.thought != null).thought,
        'think',
      );
      final completed = chunks.singleWhere((chunk) => chunk.usage != null);
      expect(completed.responseId, 'resp_1');
      expect(completed.stopReason, 'end_turn');
      expect(completed.usage?.promptTokens, 3);
      expect(completed.usage?.completionTokens, 4);
      expect(completed.usage?.totalTokens, 7);
      expect(completed.usage?.cachedToken, 1);
      expect(completed.usage?.thoughtToken, 2);
    },
  );
}
