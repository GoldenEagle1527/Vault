import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:aws_common/aws_common.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';
import 'package:vault_agent_core/src/core/llm_client.dart';
import 'package:vault_agent_core/src/core/message.dart';
import 'package:vault_agent_core/src/core/tool.dart';
import 'package:vault_agent_core/src/llm/bedrock/aws_sigv4_signer.dart';
import 'package:vault_agent_core/src/llm/bedrock/client.dart';
import 'package:vault_agent_core/src/llm/bedrock/event_stream_decoder.dart';
import 'package:vault_agent_core/src/llm/bedrock/request_builder.dart';
import 'package:vault_agent_core/src/llm/bedrock/response_transformer.dart';
import 'package:vault_agent_core/src/llm/bedrock/stream_parser.dart';

void main() {
  const model = 'anthropic.claude-test-v1:0';
  final modelConfig = ModelConfig(model: model);

  group('BedrockRequestBuilder', () {
    test('builds Anthropic messages, tools, thinking, and output config', () {
      final originalBlock = <String, dynamic>{
        'type': 'redacted_thinking',
        'data': {
          'nested': ['opaque'],
        },
      };
      final body = BedrockRequestBuilder().build(
        [
          SystemMessage('first'),
          SystemMessage('second'),
          UserMessage([TextPart('hello'), ImagePart('aW1hZ2U=', 'image/png')]),
          ModelMessage(model: model, contentBlocks: [originalBlock]),
          FunctionExecutionResultMessage(
            results: [
              FunctionExecutionResult(
                id: 'toolu_1',
                name: 'read',
                isError: true,
                arguments: '{}',
                content: [TextPart('denied')],
              ),
            ],
          ),
        ],
        tools: [
          Tool(
            name: 'read',
            description: 'Read a file',
            parameters: {'type': 'object', 'properties': <String, dynamic>{}},
          ),
        ],
        toolChoice: ToolChoice(
          mode: ToolChoiceMode.required,
          allowedFunctionNames: ['read'],
        ),
        modelConfig: ModelConfig(
          model: model,
          maxTokens: 123,
          temperature: 0.2,
          topP: 0.8,
          topK: 10.9,
          extra: {
            'thinking': {'type': 'enabled', 'budget_tokens': 100},
            'output_config': {
              'format': {'type': 'json_schema'},
            },
          },
        ),
        jsonOutput: true,
      );

      expect(body['anthropic_version'], 'bedrock-2023-05-31');
      expect(body['max_tokens'], 123);
      expect(body['system'], 'first\nsecond');
      expect(body['temperature'], 0.2);
      expect(body['top_p'], 0.8);
      expect(body['top_k'], 10);
      expect(body['tool_choice'], {'type': 'tool', 'name': 'read'});
      expect((body['messages'] as List).last, {
        'role': 'user',
        'content': [
          {
            'type': 'tool_result',
            'tool_use_id': 'toolu_1',
            'content': [
              {'type': 'text', 'text': 'denied'},
            ],
            'is_error': true,
          },
        ],
      });

      final copiedBlock =
          ((body['messages'] as List)[1]['content'] as List).single
              as Map<String, dynamic>;
      (copiedBlock['data']['nested'] as List).add('changed');
      expect((originalBlock['data'] as Map)['nested'], ['opaque']);
    });

    test('reassembles continuation tool-call fragments', () {
      final body = BedrockRequestBuilder().build([
        ModelMessage(
          model: model,
          functionCalls: [
            FunctionCall(id: 'toolu_1', name: 'read', arguments: '{"path"'),
            FunctionCall(id: '', name: '', arguments: ':"a.md"}'),
          ],
        ),
      ], modelConfig: modelConfig);

      expect((body['messages'] as List).single['content'], [
        {
          'type': 'tool_use',
          'id': 'toolu_1',
          'name': 'read',
          'input': {'path': 'a.md'},
        },
      ]);
    });
  });

  group('BedrockResponseTransformer', () {
    test('preserves content, tool calls, thinking, usage, and stop reason', () {
      final message = BedrockResponseTransformer().transform({
        'content': [
          {'type': 'thinking', 'thinking': 'reason', 'signature': 'sig'},
          {'type': 'text', 'text': 'hello '},
          {'type': 'text', 'text': 'world'},
          {
            'type': 'tool_use',
            'id': 'toolu_1',
            'name': 'read',
            'input': {'path': 'a.md'},
          },
        ],
        'stop_reason': 'tool_use',
        'usage': {
          'input_tokens': 7,
          'output_tokens': 5,
          'cache_read_input_tokens': 3,
          'cache_creation_input_tokens': 2,
        },
      }, modelConfig);

      expect(message.textOutput, 'hello world');
      expect(message.thought, 'reason');
      expect(message.thoughtSignature, 'sig');
      expect(message.stopReason, 'tool_use');
      expect(message.functionCalls.single.arguments, '{"path":"a.md"}');
      expect(message.contentBlocks, hasLength(4));
      expect(message.usage?.promptTokens, 7);
      expect(message.usage?.completionTokens, 5);
      expect(message.usage?.totalTokens, 12);
      expect(message.usage?.cachedToken, 5);
    });

    test('keeps Bedrock error semantics', () {
      expect(
        () => BedrockResponseTransformer().transform({
          'type': 'error',
          'error': {'message': 'invalid request'},
        }, modelConfig),
        throwsA(
          predicate((error) => error.toString().contains('invalid request')),
        ),
      );
    });
  });

  group('BedrockStreamParser', () {
    test('emits ordered thinking and tool blocks with cumulative usage', () {
      final parser = BedrockStreamParser(modelConfig);
      final chunks = <ModelMessage?>[
        parser.parse({
          'type': 'message_start',
          'message': {
            'usage': {
              'input_tokens': 10,
              'output_tokens': 0,
              'cache_read_input_tokens': 4,
              'cache_creation_input_tokens': 1,
            },
          },
        }),
        parser.parse({
          'type': 'content_block_start',
          'content_block': {'type': 'thinking', 'thinking': ''},
        }),
        parser.parse({
          'type': 'content_block_delta',
          'delta': {'type': 'thinking_delta', 'thinking': 'reason'},
        }),
        parser.parse({
          'type': 'content_block_delta',
          'delta': {'type': 'signature_delta', 'signature': 'sig'},
        }),
        parser.parse({'type': 'content_block_stop'}),
        parser.parse({
          'type': 'content_block_start',
          'content_block': {
            'type': 'tool_use',
            'id': 'toolu_1',
            'name': 'read',
            'input': {},
          },
        }),
        parser.parse({
          'type': 'content_block_delta',
          'delta': {'type': 'input_json_delta', 'partial_json': '{"path"'},
        }),
        parser.parse({
          'type': 'content_block_delta',
          'delta': {'type': 'input_json_delta', 'partial_json': ':"a.md"}'},
        }),
        parser.parse({'type': 'content_block_stop'}),
        parser.parse({
          'type': 'message_delta',
          'delta': {'stop_reason': 'tool_use'},
          'usage': {
            'output_tokens': 8,
            'output_tokens_details': {'reasoning_tokens': 3},
          },
        }),
      ];

      final blocks = chunks
          .whereType<ModelMessage>()
          .expand((message) => message.contentBlocks)
          .toList();
      expect(blocks, [
        {'type': 'thinking', 'thinking': 'reason', 'signature': 'sig'},
        {
          'type': 'tool_use',
          'id': 'toolu_1',
          'name': 'read',
          'input': {'path': 'a.md'},
        },
      ]);
      final finalMessage = chunks.last!;
      expect(finalMessage.stopReason, 'tool_use');
      expect(finalMessage.usage?.promptTokens, 10);
      expect(finalMessage.usage?.completionTokens, 8);
      expect(finalMessage.usage?.cachedToken, 5);
      expect(finalMessage.usage?.thoughtToken, 3);
    });
  });

  group('EventStreamDecoder', () {
    test('decodes messages split across transport chunks', () async {
      final bytes = _eventStreamMessage(
        headers: {':event-type': 'chunk', ':content-type': 'application/json'},
        payload: utf8.encode('{"bytes":"e30="}'),
      );
      final messages = await Stream<List<int>>.fromIterable([
        bytes.sublist(0, 7),
        bytes.sublist(7, 19),
        bytes.sublist(19),
      ]).transform(EventStreamDecoder()).toList();

      expect(messages, hasLength(1));
      expect(messages.single.headers[':event-type'], 'chunk');
      expect(messages.single.jsonPayload, {'bytes': 'e30='});
    });

    test('rejects unsupported header types', () async {
      final bytes = _eventStreamMessage(
        headers: const {},
        payload: const [],
        rawHeaders: [1, 120, 0],
      );
      await expectLater(
        Stream<List<int>>.value(bytes).transform(EventStreamDecoder()),
        emitsError(isA<FormatException>()),
      );
    });
  });

  test('BedrockAwsSigV4Signer adds authorization and session token', () async {
    final signer = BedrockAwsSigV4Signer(
      accessKeyId: 'AKIDEXAMPLE',
      secretAccessKey: 'secret',
      sessionToken: 'token',
    );
    final request = AWSHttpRequest.post(
      Uri.parse(
        'https://bedrock-runtime.us-east-1.amazonaws.com/model/test/invoke',
      ),
      body: utf8.encode('{}'),
      headers: {'content-type': 'application/json'},
    );

    final signed = await signer.sign(request, region: 'us-east-1');

    expect(signed.headers['authorization'], contains('AKIDEXAMPLE'));
    expect(signed.headers['authorization'], contains('/us-east-1/bedrock/'));
    expect(signed.headers['x-amz-security-token'], 'token');
    expect(signed.headers, contains('x-amz-date'));
  });

  group('BedrockClaudeClient facade implementation', () {
    test('generate signs, retries 5xx, and transforms the response', () async {
      final adapter = _SequenceAdapter([
        ResponseBody.fromString('busy', 500),
        _jsonResponse({
          'content': [
            {'type': 'text', 'text': 'ok'},
          ],
          'stop_reason': 'end_turn',
          'usage': {'input_tokens': 1, 'output_tokens': 2},
        }),
      ]);
      final client = BedrockClaudeClient(
        region: 'us-east-1',
        accessKeyId: 'AKIDEXAMPLE',
        secretAccessKey: 'secret',
        client: Dio()..httpClientAdapter = adapter,
        initialRetryDelayMs: 0,
        maxRetryDelayMs: 0,
      );

      final response = await client.generate([
        UserMessage.text('hello'),
      ], modelConfig: modelConfig);

      expect(adapter.requests, hasLength(2));
      expect(
        adapter.requests.first.headers['authorization'],
        contains('/us-east-1/bedrock/'),
      );
      expect(response.textOutput, 'ok');
      expect(response.usage?.totalTokens, 3);
    });

    test(
      'stream decodes chunks and preserves stream exception semantics',
      () async {
        final chunk = {
          'type': 'content_block_delta',
          'delta': {'type': 'text_delta', 'text': 'hello'},
        };
        final eventBytes = <int>[
          ..._bedrockChunkEvent(chunk),
          ..._eventStreamMessage(
            headers: {':event-type': 'exception'},
            payload: utf8.encode('{"message":"stream failed"}'),
          ),
        ];
        final adapter = _SequenceAdapter([
          ResponseBody(
            Stream<Uint8List>.fromIterable([
              Uint8List.fromList(eventBytes.sublist(0, 13)),
              Uint8List.fromList(eventBytes.sublist(13)),
            ]),
            200,
            headers: {
              Headers.contentTypeHeader: ['application/vnd.amazon.eventstream'],
            },
          ),
        ]);
        final client = BedrockClaudeClient(
          region: 'us-east-1',
          accessKeyId: 'AKIDEXAMPLE',
          secretAccessKey: 'secret',
          client: Dio()..httpClientAdapter = adapter,
        );

        final stream = await client.stream([
          UserMessage.text('hello'),
        ], modelConfig: modelConfig);

        await expectLater(
          stream,
          emitsInOrder([
            predicate<StreamingMessage>(
              (event) => event.modelMessage?.textOutput == 'hello',
            ),
            emitsError(
              predicate((error) => error.toString().contains('stream failed')),
            ),
          ]),
        );
      },
    );
  });
}

class _SequenceAdapter implements HttpClientAdapter {
  _SequenceAdapter(this.responses);

  final List<ResponseBody> responses;
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return responses.removeAt(0);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _jsonResponse(Map<String, dynamic> body) =>
    ResponseBody.fromString(
      jsonEncode(body),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );

List<int> _bedrockChunkEvent(Map<String, dynamic> chunk) => _eventStreamMessage(
  headers: {':event-type': 'chunk'},
  payload: utf8.encode(
    jsonEncode({'bytes': base64Encode(utf8.encode(jsonEncode(chunk)))}),
  ),
);

List<int> _eventStreamMessage({
  required Map<String, String> headers,
  required List<int> payload,
  List<int>? rawHeaders,
}) {
  final headerBytes = rawHeaders ?? <int>[];
  if (rawHeaders == null) {
    for (final entry in headers.entries) {
      final name = utf8.encode(entry.key);
      final value = utf8.encode(entry.value);
      headerBytes
        ..add(name.length)
        ..addAll(name)
        ..add(7)
        ..add((value.length >> 8) & 0xff)
        ..add(value.length & 0xff)
        ..addAll(value);
    }
  }
  final totalLength = 12 + headerBytes.length + payload.length + 4;
  final prelude = ByteData(12)
    ..setUint32(0, totalLength, Endian.big)
    ..setUint32(4, headerBytes.length, Endian.big)
    ..setUint32(8, 0, Endian.big);
  return [
    ...prelude.buffer.asUint8List(),
    ...headerBytes,
    ...payload,
    0,
    0,
    0,
    0,
  ];
}
