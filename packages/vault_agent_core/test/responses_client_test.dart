import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:test/test.dart';
import 'package:vault_agent_core/src/core/llm_client.dart';
import 'package:vault_agent_core/src/core/message.dart';
import 'package:vault_agent_core/src/llm/responses_client.dart';

void main() {
  group('ResponsesClient compatibility facade', () {
    test('generate preserves request and response behavior', () async {
      final adapter = _CaptureAdapter([
        _jsonResponse({
          'id': 'resp_1',
          'status': 'completed',
          'output': [
            {
              'type': 'function_call',
              'call_id': 'call_1',
              'name': 'lookup',
              'arguments': '{"id":1}',
            },
          ],
          'usage': {'input_tokens': 2, 'output_tokens': 3, 'total_tokens': 5},
        }),
      ]);
      final client = ResponsesClient(
        apiKey: 'test-key',
        client: Dio()..httpClientAdapter = adapter,
      );

      final result = await client.generate([
        UserMessage.text('hello'),
      ], modelConfig: ModelConfig(model: 'test-model'));

      expect(adapter.requests.single['stream'], isFalse);
      expect(adapter.requests.single['input'], [
        {
          'type': 'message',
          'role': 'user',
          'content': [
            {'type': 'input_text', 'text': 'hello'},
          ],
        },
      ]);
      expect(result.responseId, 'resp_1');
      expect(result.functionCalls.single.id, 'call_1');
      expect(result.usage?.totalTokens, 5);
    });

    test('stream decodes SSE text and completion usage', () async {
      final adapter = _CaptureAdapter([
        _streamResponse([
          {'type': 'response.output_text.delta', 'delta': 'hello'},
          {
            'type': 'response.completed',
            'response': {
              'id': 'resp_2',
              'usage': {
                'input_tokens': 4,
                'output_tokens': 6,
                'total_tokens': 10,
              },
            },
          },
        ]),
      ]);
      final client = ResponsesClient(
        apiKey: 'test-key',
        client: Dio()..httpClientAdapter = adapter,
      );

      final stream = await client.stream([
        UserMessage.text('hello'),
      ], modelConfig: ModelConfig(model: 'test-model'));
      final chunks = await stream.map((event) => event.modelMessage).toList();

      expect(adapter.requests.single['stream'], isTrue);
      expect(chunks.whereType<ModelMessage>().first.textOutput, 'hello');
      final completed = chunks.whereType<ModelMessage>().singleWhere(
        (message) => message.usage != null,
      );
      expect(completed.responseId, 'resp_2');
      expect(completed.usage?.totalTokens, 10);
    });
  });
}

class _CaptureAdapter implements HttpClientAdapter {
  final List<ResponseBody> responses;
  final List<Map<String, dynamic>> requests = [];

  _CaptureAdapter(this.responses);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final bytes = <int>[];
    if (requestStream != null) {
      await for (final chunk in requestStream) {
        bytes.addAll(chunk);
      }
    }
    requests.add(jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>);
    return responses.removeAt(0);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _jsonResponse(Map<String, dynamic> body) {
  return ResponseBody.fromString(
    jsonEncode(body),
    200,
    headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    },
  );
}

ResponseBody _streamResponse(List<Map<String, dynamic>> events) {
  final data = events
      .map(
        (event) =>
            'event: ${event['type']}\n'
            'data: ${jsonEncode(event)}\n\n',
      )
      .join();
  return ResponseBody.fromString(
    data,
    200,
    headers: {
      Headers.contentTypeHeader: ['text/event-stream'],
    },
  );
}
