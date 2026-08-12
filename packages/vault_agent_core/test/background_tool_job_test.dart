import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:test/test.dart';
import 'package:vault_agent_core/vault_agent_core.dart';

void main() {
  test('slow tool is backgrounded after threshold then completes', () async {
    final completer = Completer<String>();
    final client = _CapturingLLMClient([
      _toolCallReply('slow', {'value': 'x'}),
      _textReply('ack background'),
    ]);
    final state = AgentState.empty();
    final agent = StatefulAgent(
      name: 'bg',
      client: client,
      modelConfig: ModelConfig(model: 'fake-model'),
      state: state,
      withGeneralPrinciples: false,
      disableSubAgents: true,
      toolBackgroundAfter: const Duration(milliseconds: 40),
      tools: [
        Tool(
          name: 'slow',
          description: 'slow',
          parameters: const {
            'type': 'object',
            'properties': {
              'value': {'type': 'string'},
            },
          },
          parameterMode: ToolParameterMode.object,
          executable: (Map<String, dynamic> args) => completer.future,
        ),
      ],
    );

    final backgrounded = <BackgroundToolJob>[];
    final completed = <BackgroundToolJob>[];
    final sub = agent.backgroundJobs.events.listen((e) {
      if (e.kind == BackgroundToolJobEventKind.backgrounded) {
        backgrounded.add(e.job);
      } else {
        completed.add(e.job);
      }
    });

    final events = <StreamingEvent>[];
    final runFuture = () async {
      await for (final event in agent.runStream([
        UserMessage.text('go'),
      ], useStream: false)) {
        events.add(event);
      }
    }();

    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(backgrounded, hasLength(1));
    expect(agent.backgroundJobs.runningJobs, hasLength(1));
    expect(
      state.systemReminders.containsKey(kBackgroundJobsReminderKey),
      isTrue,
    );

    // Agent loop should finish with stub result while tool still runs.
    await runFuture.timeout(const Duration(seconds: 2));
    final toolResults = events
        .where((e) => e.eventType == StreamingEventType.functionCallResult)
        .map((e) => e.data as FunctionExecutionResultMessage)
        .toList();
    expect(toolResults, isNotEmpty);
    final stub = toolResults.first.results.single;
    expect(stub.metadata?['background'], isTrue);
    expect(stub.content.whereType<TextPart>().single.text, contains('后台'));

    completer.complete('done-value');
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(completed, hasLength(1));
    expect(completed.single.resultText(), 'done-value');
    expect(agent.backgroundJobs.runningJobs, isEmpty);

    await sub.cancel();
  });

  test('fast tool is not backgrounded', () async {
    final client = _CapturingLLMClient([
      _toolCallReply('echo', {'value': 'hi'}),
      _textReply('done'),
    ]);
    final agent = StatefulAgent(
      name: 'fast',
      client: client,
      modelConfig: ModelConfig(model: 'fake-model'),
      state: AgentState.empty(),
      withGeneralPrinciples: false,
      disableSubAgents: true,
      toolBackgroundAfter: const Duration(seconds: 5),
      tools: [
        Tool(
          name: 'echo',
          description: 'echo',
          parameters: const {
            'type': 'object',
            'properties': {
              'value': {'type': 'string'},
            },
          },
          parameterMode: ToolParameterMode.object,
          executable: (Map<String, dynamic> args) => args['value'],
        ),
      ],
    );

    await agent.run([UserMessage.text('go')], useStream: false);
    expect(agent.backgroundJobs.jobs, isEmpty);
  });

  test('toolBackgroundAfter null disables racing', () async {
    final client = _CapturingLLMClient([
      _toolCallReply('echo', {'value': 'hi'}),
      _textReply('done'),
    ]);
    final agent = StatefulAgent(
      name: 'off',
      client: client,
      modelConfig: ModelConfig(model: 'fake-model'),
      state: AgentState.empty(),
      withGeneralPrinciples: false,
      disableSubAgents: true,
      toolBackgroundAfter: null,
      tools: [
        Tool(
          name: 'echo',
          description: 'echo',
          parameters: const {
            'type': 'object',
            'properties': {
              'value': {'type': 'string'},
            },
          },
          parameterMode: ToolParameterMode.object,
          executable: (Map<String, dynamic> args) async {
            await Future<void>.delayed(const Duration(milliseconds: 60));
            return args['value'];
          },
        ),
      ],
    );

    await agent.run([UserMessage.text('go')], useStream: false);
    expect(agent.backgroundJobs.jobs, isEmpty);
  });
}

class _CapturingLLMClient implements LLMClient {
  _CapturingLLMClient(this._replies);

  final List<ModelMessage> _replies;
  int _i = 0;

  @override
  Future<ModelMessage> generate(
    List<LLMMessage> messages, {
    List<Tool>? tools,
    ToolChoice? toolChoice,
    required ModelConfig modelConfig,
    bool? jsonOutput,
    CancelToken? cancelToken,
  }) async {
    if (_i >= _replies.length) {
      return ModelMessage(
        textOutput: 'fallback',
        model: modelConfig.model,
        stopReason: 'stop',
      );
    }
    return _replies[_i++];
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
    final msg = await generate(
      messages,
      tools: tools,
      toolChoice: toolChoice,
      modelConfig: modelConfig,
      jsonOutput: jsonOutput,
      cancelToken: cancelToken,
    );
    return Stream.value(StreamingMessage(modelMessage: msg));
  }
}

ModelMessage _textReply(String text) {
  return ModelMessage(
    textOutput: text,
    model: 'fake-model',
    stopReason: 'stop',
  );
}

ModelMessage _toolCallReply(String name, Map<String, dynamic> arguments) {
  return ModelMessage(
    model: 'fake-model',
    stopReason: 'tool_calls',
    functionCalls: [
      FunctionCall(id: 'call-1', name: name, arguments: jsonEncode(arguments)),
    ],
  );
}
