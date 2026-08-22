import 'dart:async';

import 'package:dio/dio.dart';
import 'package:test/test.dart';
import 'package:vault_agent_core/vault_agent_core.dart';

void main() {
  test(
    'decodes arguments and preserves context, stopFlag, and metadata',
    () async {
      final state = AgentState.empty();
      final agent = _hostAgent(state);
      final cancelToken = CancelToken();
      AgentCallToolContext? seenContext;
      Object? seenCount;
      Object? seenRatio;
      Object? seenValues;
      final executor = AgentToolExecutor(createBatchCallId: () => 'batch-1');

      final batch = await executor.execute(
        calls: [
          FunctionCall(
            id: 'call-1',
            name: 'typed',
            arguments: '{"count":2.9,"ratio":3,"values":[1,2.5]}',
          ),
        ],
        tools: [
          Tool(
            name: 'typed',
            description: 'typed',
            parameters: const {
              'type': 'object',
              'properties': {
                'count': {'type': 'integer'},
                'ratio': {'type': 'number'},
                'values': {
                  'type': 'array',
                  'items': {'type': 'number'},
                },
              },
            },
            executable: (int count, double ratio, List<double> values) {
              seenContext = AgentCallToolContext.current;
              seenCount = count;
              seenRatio = ratio;
              seenValues = values;
              return AgentToolResult(
                content: TextPart('one'),
                contents: [TextPart('two')],
                stopFlag: true,
                metadata: {'source': 'tool'},
              );
            },
          ),
        ],
        state: state,
        createCallContext:
            ({required batchCallId, required call, cancelToken}) =>
                AgentCallToolContext(
                  state: state,
                  agent: agent,
                  batchCallId: batchCallId,
                  callId: call.id,
                  toolName: call.name,
                  cancelToken: cancelToken,
                ),
        agentName: agent.name,
        cancelToken: cancelToken,
      );

      expect(seenCount, 2);
      expect(seenRatio, 3.0);
      expect(seenValues, [1.0, 2.5]);
      expect(seenContext?.state, same(state));
      expect(seenContext?.agent, same(agent));
      expect(seenContext?.batchCallId, 'batch-1');
      expect(seenContext?.callId, 'call-1');
      expect(seenContext?.toolName, 'typed');
      expect(seenContext?.cancelToken, same(cancelToken));
      expect(batch.results.single.stopFlag, isTrue);
      expect(batch.results.single.metadata, {'source': 'tool'});
      expect(
        batch.results.single.content.whereType<TextPart>().map((p) => p.text),
        ['one', 'two'],
      );
    },
  );

  test('starts tool calls in parallel and preserves input order', () async {
    final state = AgentState.empty();
    final agent = _hostAgent(state);
    final first = Completer<String>();
    final second = Completer<String>();
    final started = <String>[];
    final executor = AgentToolExecutor();
    final execution = executor.execute(
      calls: [
        FunctionCall(id: 'first', name: 'first', arguments: '{}'),
        FunctionCall(id: 'second', name: 'second', arguments: '{}'),
      ],
      tools: [
        _objectTool('first', () {
          started.add('first');
          return first.future;
        }),
        _objectTool('second', () {
          started.add('second');
          return second.future;
        }),
      ],
      state: state,
      createCallContext: ({required batchCallId, required call, cancelToken}) =>
          AgentCallToolContext(
            state: state,
            agent: agent,
            batchCallId: batchCallId,
            callId: call.id,
            toolName: call.name,
            cancelToken: cancelToken,
          ),
      agentName: agent.name,
    );

    await Future<void>.delayed(Duration.zero);
    expect(started, ['first', 'second']);
    second.complete('second-result');
    first.complete('first-result');

    final batch = await execution;
    expect(batch.results.map((result) => result.id), ['first', 'second']);
    expect(_text(batch.results[0]), 'first-result');
    expect(_text(batch.results[1]), 'second-result');
  });

  test('allowBackground false keeps slow work in the foreground', () async {
    final state = AgentState.empty();
    final agent = _hostAgent(state);
    final registry = BackgroundToolJobRegistry();
    final batch = await AgentToolExecutor().execute(
      calls: [FunctionCall(id: 'call-1', name: 'blocking', arguments: '{}')],
      tools: [
        Tool(
          name: 'blocking',
          description: 'blocking',
          parameters: const {
            'type': 'object',
            'properties': <String, dynamic>{},
          },
          parameterMode: ToolParameterMode.object,
          allowBackground: false,
          executable: (Map<String, dynamic> _) async {
            await Future<void>.delayed(const Duration(milliseconds: 10));
            return 'foreground';
          },
        ),
      ],
      state: state,
      createCallContext: ({required batchCallId, required call, cancelToken}) =>
          AgentCallToolContext(
            state: state,
            agent: agent,
            batchCallId: batchCallId,
            callId: call.id,
            toolName: call.name,
            cancelToken: cancelToken,
          ),
      agentName: agent.name,
      backgroundAfter: const Duration(milliseconds: 1),
      backgroundRacer: BackgroundToolRacer(registry: registry),
    );

    expect(_text(batch.results.single), 'foreground');
    expect(batch.backgroundedJobs, isEmpty);
    expect(registry.jobs, isEmpty);
    registry.dispose();
  });

  test('normalizes lookup, decoding, and execution errors verbatim', () async {
    final state = AgentState.empty();
    final agent = _hostAgent(state);
    final executor = AgentToolExecutor();
    final batch = await executor.execute(
      calls: [
        FunctionCall(id: 'missing', name: 'missing', arguments: '{}'),
        FunctionCall(id: 'decode', name: 'decode', arguments: '{'),
        FunctionCall(id: 'throws', name: 'throws', arguments: '{}'),
      ],
      tools: [
        _objectTool('decode', () => 'unused'),
        _objectTool('throws', () => throw StateError('boom')),
      ],
      state: state,
      createCallContext: ({required batchCallId, required call, cancelToken}) =>
          AgentCallToolContext(
            state: state,
            agent: agent,
            batchCallId: batchCallId,
            callId: call.id,
            toolName: call.name,
            cancelToken: cancelToken,
          ),
      agentName: agent.name,
    );

    expect(_text(batch.results[0]), 'Function missing failed or not found.');
    expect(_text(batch.results[1]), startsWith('Error decoding arguments:'));
    expect(_text(batch.results[2]), 'Error executing throws: Bad state: boom');
    expect(batch.results.every((result) => result.isError), isTrue);
  });
}

Tool _objectTool(String name, FutureOr<String> Function() executable) {
  return Tool(
    name: name,
    description: name,
    parameters: const {'type': 'object', 'properties': <String, dynamic>{}},
    parameterMode: ToolParameterMode.object,
    executable: (Map<String, dynamic> _) => executable(),
  );
}

String _text(ExecutionToolResult result) {
  return result.content.whereType<TextPart>().single.text;
}

StatefulAgent _hostAgent(AgentState state) {
  return StatefulAgent(
    name: 'host',
    client: _UnusedClient(),
    modelConfig: ModelConfig(model: 'unused'),
    state: state,
    withGeneralPrinciples: false,
    disableSubAgents: true,
  );
}

class _UnusedClient implements LLMClient {
  @override
  Future<ModelMessage> generate(
    List<LLMMessage> messages, {
    List<Tool>? tools,
    ToolChoice? toolChoice,
    required ModelConfig modelConfig,
    bool? jsonOutput,
    CancelToken? cancelToken,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<Stream<StreamingMessage>> stream(
    List<LLMMessage> messages, {
    List<Tool>? tools,
    ToolChoice? toolChoice,
    required ModelConfig modelConfig,
    bool? jsonOutput,
    CancelToken? cancelToken,
  }) {
    throw UnimplementedError();
  }
}
