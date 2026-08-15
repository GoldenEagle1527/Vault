import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:test/test.dart';
import 'package:vault_agent_core/vault_agent_core.dart';

void main() {
  test('incremental function-call chunks merge into one request', () async {
    final client = _IncrementalToolClient();
    final agent = StatefulAgent(
      name: 'merge',
      client: client,
      modelConfig: ModelConfig(model: 'fake-model'),
      state: AgentState.empty(),
      withGeneralPrinciples: false,
      disableSubAgents: true,
      tools: [
        Tool(
          name: 'shell',
          description: 'shell',
          parameters: const {
            'type': 'object',
            'properties': {
              'command': {'type': 'string'},
            },
          },
          parameterMode: ToolParameterMode.object,
          executable: (Map<String, dynamic> args) => args['command'] ?? '',
        ),
      ],
    );

    final requests = <List<FunctionCall>>[];
    await for (final event in agent.runStream([
      UserMessage.text('go'),
    ], useStream: true)) {
      if (event.eventType == StreamingEventType.functionCallRequest) {
        requests.add(List<FunctionCall>.from(event.data as List<FunctionCall>));
      }
    }

    expect(requests, hasLength(1));
    expect(requests.single, hasLength(1));
    expect(requests.single.single.id, 'c1');
    expect(requests.single.single.name, 'shell');
    expect(jsonDecode(requests.single.single.arguments), {'command': 'ls -la'});
  });
}

class _IncrementalToolClient implements LLMClient {
  var _turn = 0;

  @override
  Future<ModelMessage> generate(
    List<LLMMessage> messages, {
    List<Tool>? tools,
    ToolChoice? toolChoice,
    required ModelConfig modelConfig,
    bool? jsonOutput,
    CancelToken? cancelToken,
  }) async {
    return ModelMessage(
      textOutput: 'done',
      model: modelConfig.model,
      stopReason: 'stop',
    );
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
    if (_turn++ == 0) {
      return Stream.fromIterable([
        StreamingMessage(
          modelMessage: ModelMessage(
            model: modelConfig.model,
            textOutput: '\n',
            functionCalls: [
              FunctionCall(id: 'c1', name: 'shell', arguments: '{"command":"'),
            ],
          ),
        ),
        StreamingMessage(
          modelMessage: ModelMessage(
            model: modelConfig.model,
            functionCalls: [
              FunctionCall(
                id: 'c1',
                name: 'shell',
                arguments: '{"command":"ls -la"}',
              ),
            ],
            stopReason: 'tool_calls',
          ),
        ),
      ]);
    }
    return Stream.value(
      StreamingMessage(
        modelMessage: ModelMessage(
          textOutput: 'done',
          model: modelConfig.model,
          stopReason: 'stop',
        ),
      ),
    );
  }
}
