import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:test/test.dart';
import 'package:vault_agent_core/vault_agent_core.dart';

void main() {
  final modelConfig = ModelConfig(model: 'test-model');
  final messages = [UserMessage.text('hello')];

  test('OpenAI retries a server response with the shared backoff', () async {
    final adapter = _SequenceAdapter([
      _response('busy', 503),
      _jsonResponse({
        'model': 'test-model',
        'choices': [
          {
            'message': {'content': 'ok'},
            'finish_reason': 'stop',
          },
        ],
      }),
    ]);
    final client = OpenAIClient(
      apiKey: 'test-key',
      client: Dio()..httpClientAdapter = adapter,
      initialRetryDelayMs: 0,
      maxRetryDelayMs: 0,
    );

    expect(
      (await client.generate(messages, modelConfig: modelConfig)).textOutput,
      'ok',
    );
    expect(adapter.requestCount, 2);
  });

  test('Responses retries a server response with the shared backoff', () async {
    final adapter = _SequenceAdapter([
      _response('busy', 503),
      _jsonResponse({
        'id': 'resp_1',
        'status': 'completed',
        'output': [
          {
            'type': 'message',
            'content': [
              {'type': 'output_text', 'text': 'ok'},
            ],
          },
        ],
      }),
    ]);
    final client = ResponsesClient(
      apiKey: 'test-key',
      client: Dio()..httpClientAdapter = adapter,
      initialRetryDelayMs: 0,
      maxRetryDelayMs: 0,
    );

    expect(
      (await client.generate(messages, modelConfig: modelConfig)).textOutput,
      'ok',
    );
    expect(adapter.requestCount, 2);
  });

  test('Gemini retries a server response with the shared backoff', () async {
    final adapter = _SequenceAdapter([
      _response('busy', 503),
      _jsonResponse({
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
      initialRetryDelayMs: 0,
      maxRetryDelayMs: 0,
    );

    expect(
      (await client.generate(messages, modelConfig: modelConfig)).textOutput,
      'ok',
    );
    expect(adapter.requestCount, 2);
  });

  test('Claude retries a server response with the shared backoff', () async {
    final adapter = _SequenceAdapter([
      _response('busy', 503),
      _jsonResponse({
        'content': [
          {'type': 'text', 'text': 'ok'},
        ],
        'stop_reason': 'end_turn',
        'usage': {'input_tokens': 1, 'output_tokens': 1},
      }),
    ]);
    final client = ClaudeClient(
      apiKey: 'test-key',
      client: Dio()..httpClientAdapter = adapter,
      initialRetryDelayMs: 0,
      maxRetryDelayMs: 0,
    );

    expect(
      (await client.generate(messages, modelConfig: modelConfig)).textOutput,
      'ok',
    );
    expect(adapter.requestCount, 2);
  });
}

class _SequenceAdapter implements HttpClientAdapter {
  _SequenceAdapter(this.responses);

  final List<ResponseBody> responses;
  int requestCount = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requestCount++;
    return responses.removeAt(0);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _response(String body, int statusCode) =>
    ResponseBody.fromString(body, statusCode);

ResponseBody _jsonResponse(Map<String, dynamic> body) =>
    ResponseBody.fromString(
      jsonEncode(body),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
