import 'dart:convert';

import 'package:vault_agent_core/vault_agent_core.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

void main() {
  group('GeminiClient', () {
    test('generate 保留 Gemini functionCall 返回的 id', () async {
      final adapter = _CaptureAdapter([
        (_) => _jsonResponse({
          'candidates': [
            {
              'content': {
                'parts': [
                  {
                    'functionCall': {
                      'id': 'call_abc123',
                      'name': 'Glob',
                      'args': {'pattern': '*.dart'},
                    },
                  },
                ],
              },
              'finishReason': 'STOP',
            },
          ],
        }),
      ]);
      final client = GeminiClient(
        apiKey: 'test-key',
        client: Dio()..httpClientAdapter = adapter,
      );

      final result = await client.generate([
        UserMessage.text('find files'),
      ], modelConfig: ModelConfig(model: 'gemini-test'));

      expect(result.functionCalls, hasLength(1));
      expect(result.functionCalls.single.id, 'call_abc123');
      expect(result.functionCalls.single.name, 'Glob');
      expect(jsonDecode(result.functionCalls.single.arguments), {
        'pattern': '*.dart',
      });
    });

    test('request body maps functionCall and functionResponse ids', () async {
      final adapter = _CaptureAdapter([
        (_) => _jsonResponse({
          'candidates': [
            {
              'content': {
                'parts': [
                  {'text': 'ok'},
                ],
              },
              'finishReason': 'STOP',
            },
          ],
        }),
      ]);
      final client = GeminiClient(
        apiKey: 'test-key',
        client: Dio()..httpClientAdapter = adapter,
      );

      await client.generate([
        ModelMessage(
          model: 'gemini-test',
          functionCalls: [
            FunctionCall(
              id: 'call_abc123',
              name: 'Glob',
              arguments: '{"pattern":"*.dart"}',
            ),
          ],
        ),
        FunctionExecutionResultMessage(
          results: [
            FunctionExecutionResult(
              id: 'call_abc123',
              name: 'Glob',
              isError: false,
              arguments: '{"pattern":"*.dart"}',
              content: [TextPart('["lib/main.dart"]')],
            ),
          ],
        ),
      ], modelConfig: ModelConfig(model: 'gemini-test'));

      final body = adapter.bodies.single as Map<String, dynamic>;
      final contents = body['contents'] as List;
      final functionCall =
          (contents[0]['parts'] as List).single['functionCall']
              as Map<String, dynamic>;
      final functionResponse =
          (contents[1]['parts'] as List).single['functionResponse']
              as Map<String, dynamic>;

      expect(functionCall['id'], 'call_abc123');
      expect(functionCall['name'], 'Glob');
      expect(functionCall['args'], {'pattern': '*.dart'});
      expect(functionResponse['id'], 'call_abc123');
      expect(functionResponse['name'], 'Glob');
      expect(functionResponse['response'], {'content': '["lib/main.dart"]'});
    });

    test('stream preserves chunks, usage, and function calls', () async {
      final adapter = _CaptureAdapter([
        (_) => _jsonResponse({
          'candidates': [
            {
              'content': {
                'parts': [
                  {'text': 'hello'},
                  {
                    'functionCall': {
                      'id': 'call_stream',
                      'name': 'Glob',
                      'args': {'pattern': '*.dart'},
                    },
                  },
                ],
              },
              'finishReason': 'STOP',
            },
          ],
          'usageMetadata': {
            'promptTokenCount': 2,
            'candidatesTokenCount': 3,
            'totalTokenCount': 5,
          },
        }),
      ]);
      final client = GeminiClient(
        apiKey: 'test-key',
        client: Dio()..httpClientAdapter = adapter,
      );

      final stream = await client.stream([
        UserMessage.text('find files'),
      ], modelConfig: ModelConfig(model: 'gemini-test'));
      final events = await stream.toList();

      expect(events, hasLength(1));
      final message = events.single.modelMessage!;
      expect(message.textOutput, 'hello');
      expect(message.functionCalls.single.id, 'call_stream');
      expect(message.usage!.promptTokens, 2);
      expect(message.usage!.completionTokens, 3);
      expect(message.usage!.totalTokens, 5);
    });

    test('generate preserves HTTP and stop-reason error semantics', () async {
      final httpErrorAdapter = _CaptureAdapter([
        (_) => ResponseBody.fromString('bad request', 400),
      ]);
      final httpErrorClient = GeminiClient(
        apiKey: 'test-key',
        client: Dio()..httpClientAdapter = httpErrorAdapter,
        maxRetries: 0,
      );

      await expectLater(
        httpErrorClient.generate([
          UserMessage.text('hello'),
        ], modelConfig: ModelConfig(model: 'gemini-test')),
        throwsA(
          predicate(
            (error) => error.toString().contains(
              'Failed to generate from Gemini: 400',
            ),
          ),
        ),
      );

      final stopReasonAdapter = _CaptureAdapter([
        (_) => _jsonResponse({
          'candidates': [
            {
              'content': {
                'parts': [
                  {'text': 'bad call'},
                ],
              },
              'finishReason': 'OTHER',
            },
          ],
        }),
      ]);
      final stopReasonClient = GeminiClient(
        apiKey: 'test-key',
        client: Dio()..httpClientAdapter = stopReasonAdapter,
        maxRetries: 0,
      );

      await expectLater(
        stopReasonClient.generate([
          UserMessage.text('hello'),
        ], modelConfig: ModelConfig(model: 'gemini-test')),
        throwsA(
          predicate(
            (error) => error.toString() == 'Exception: Stop reason is OTHER',
          ),
        ),
      );
    });
  });
}

class _CaptureAdapter implements HttpClientAdapter {
  final List<ResponseBody Function(RequestOptions)> responses;
  final List<dynamic> bodies = [];

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
    if (bytes.isNotEmpty) {
      bodies.add(jsonDecode(utf8.decode(bytes)));
    }
    return responses.removeAt(0)(options);
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
