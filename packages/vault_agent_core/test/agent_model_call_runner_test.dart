import 'dart:async';

import 'package:dio/dio.dart';
import 'package:test/test.dart';
import 'package:vault_agent_core/src/agent/agent_model_call_runner.dart';
import 'package:vault_agent_core/src/agent/agent_state.dart';
import 'package:vault_agent_core/src/core/llm_client.dart';
import 'package:vault_agent_core/src/core/message.dart';
import 'package:vault_agent_core/src/core/tool.dart';

void main() {
  test('generate forwards request and cancel token, then completes', () async {
    final usage = ModelUsage(
      promptTokens: 2,
      completionTokens: 3,
      totalTokens: 5,
    );
    final client = _RunnerClient(
      generated: ModelMessage(
        model: 'test-model',
        textOutput: 'generated',
        stopReason: 'stop',
        usage: usage,
      ),
    );
    final cancelToken = CancelToken();
    final events = await AgentModelCallRunner(client: client)
        .run(
          params: _params(stream: false),
          model: 'test-model',
          cancelToken: cancelToken,
          processChunk: (chunk, {required detectLoop}) {
            expect(detectLoop, isTrue);
            return chunk;
          },
        )
        .toList();

    expect(client.generateCalls, 1);
    expect(client.streamCalls, 0);
    expect(client.seenCancelToken, same(cancelToken));
    expect(events, hasLength(2));
    expect(
      (events.first as AgentModelCallChunk).message.textOutput,
      'generated',
    );
    final completed = events.last as AgentModelCallCompleted;
    expect(completed.message.textOutput, 'generated');
    expect(completed.message.usage, same(usage));
    expect(completed.isEmptyResponse, isFalse);
  });

  test(
    'stream retry resets chunks and merges replacement function call',
    () async {
      final usage = ModelUsage(totalTokens: 7);
      final client = _RunnerClient(
        streamed: [
          StreamingMessage(
            modelMessage: ModelMessage(
              model: 'test-model',
              textOutput: 'discarded',
              stopReason: 'stop',
            ),
          ),
          StreamingMessage(
            controlMessage: StreamingControlMessage(
              controlFlag: StreamingControlFlag.retry,
              data: const {'retryReason': 'transport'},
            ),
          ),
          StreamingMessage(
            modelMessage: ModelMessage(
              model: 'test-model',
              functionCalls: [
                FunctionCall(
                  id: 'call-1',
                  name: 'shell',
                  arguments: '{"cmd":"',
                ),
              ],
            ),
          ),
          StreamingMessage(
            modelMessage: ModelMessage(
              model: 'test-model',
              functionCalls: [
                FunctionCall(
                  id: 'call-1',
                  name: '',
                  arguments: '{"cmd":"pwd"}',
                ),
              ],
              stopReason: 'tool_calls',
              usage: usage,
            ),
          ),
        ],
      );

      final events = await AgentModelCallRunner(client: client)
          .run(
            params: _params(stream: true),
            model: 'test-model',
            processChunk: (chunk, {required detectLoop}) {
              expect(detectLoop, isTrue);
              return chunk;
            },
          )
          .toList();

      expect(client.generateCalls, 0);
      expect(client.streamCalls, 1);
      expect(events.whereType<AgentModelCallChunk>(), hasLength(3));
      expect(
        events.whereType<AgentModelCallRetry>().single.reason,
        'transport',
      );
      final completed = events.last as AgentModelCallCompleted;
      expect(completed.message.textOutput, isNull);
      expect(completed.message.functionCalls, hasLength(1));
      expect(completed.message.functionCalls.single.name, 'shell');
      expect(completed.message.functionCalls.single.arguments, '{"cmd":"pwd"}');
      expect(completed.message.usage, same(usage));
    },
  );

  test('transport cancellation is propagated unchanged', () async {
    final cancellation = DioException(
      requestOptions: RequestOptions(path: '/model'),
      type: DioExceptionType.cancel,
      error: 'cancelled by test',
    );
    final client = _RunnerClient(generatedError: cancellation);

    await expectLater(
      AgentModelCallRunner(client: client)
          .run(
            params: _params(stream: false),
            model: 'test-model',
            processChunk: (chunk, {required detectLoop}) => chunk,
          )
          .drain<void>(),
      throwsA(same(cancellation)),
    );
  });
}

CallLLMParams _params({required bool stream}) => CallLLMParams(
  messages: [UserMessage.text('hello')],
  tools: const [],
  modelConfig: ModelConfig(model: 'test-model'),
  stream: stream,
);

class _RunnerClient implements LLMClient {
  _RunnerClient({
    this.generated,
    this.generatedError,
    this.streamed = const [],
  });

  final ModelMessage? generated;
  final Object? generatedError;
  final List<StreamingMessage> streamed;
  int generateCalls = 0;
  int streamCalls = 0;
  CancelToken? seenCancelToken;

  @override
  Future<ModelMessage> generate(
    List<LLMMessage> messages, {
    List<Tool>? tools,
    ToolChoice? toolChoice,
    required ModelConfig modelConfig,
    bool? jsonOutput,
    CancelToken? cancelToken,
  }) async {
    generateCalls++;
    seenCancelToken = cancelToken;
    if (generatedError != null) {
      throw generatedError!;
    }
    return generated!;
  }

  @override
  Future<Stream<StreamingMessage>> stream(
    List<LLMMessage> messages, {
    List<Tool>? tools,
    ToolChoice? toolChoice,
    required ModelConfig modelConfig,
    bool? jsonOutput,
    CancelToken? cancelToken,
  }) async {
    streamCalls++;
    seenCancelToken = cancelToken;
    return Stream.fromIterable(streamed);
  }
}
