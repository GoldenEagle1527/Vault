import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:test/test.dart';
import 'package:vault_agent_core/vault_agent_core.dart';

void main() {
  test('runStream keeps model-tool-persist-stop phase order', () async {
    final controller = AgentController();
    final controllerEvents = <Type>[];
    final subscription = controller.listen<Event>().listen(
      (event) => controllerEvents.add(event.runtimeType),
    );
    final persistenceSnapshots = <List<Type>>[];
    final client = _QueueClient([
      ModelMessage(
        model: 'fake-model',
        stopReason: 'tool_calls',
        functionCalls: [
          FunctionCall(
            id: 'call-1',
            name: 'finish',
            arguments: jsonEncode({'value': 'ok'}),
          ),
        ],
      ),
    ]);
    final agent = StatefulAgent(
      name: 'phase-order',
      client: client,
      modelConfig: ModelConfig(model: 'fake-model'),
      state: AgentState.empty(),
      withGeneralPrinciples: false,
      disableSubAgents: true,
      controller: controller,
      autoSaveStateFunc: (AgentState state) {
        persistenceSnapshots.add(
          state.history.messages.map((message) => message.runtimeType).toList(),
        );
      },
      tools: [
        Tool(
          name: 'finish',
          description: 'finish the run',
          parameters: const {
            'type': 'object',
            'properties': {
              'value': {'type': 'string'},
            },
          },
          parameterMode: ToolParameterMode.object,
          executable: (Map<String, dynamic> _) =>
              AgentToolResult(content: TextPart('stopped'), stopFlag: true),
        ),
      ],
    );

    final streamEvents = await agent
        .runStream([UserMessage.text('go')], useStream: false)
        .map((event) => event.eventType)
        .toList();
    await Future<void>.delayed(Duration.zero);

    expect(streamEvents, [
      StreamingEventType.beforeCallModel,
      StreamingEventType.modelChunkMessage,
      StreamingEventType.fullModelMessage,
      StreamingEventType.functionCallRequest,
      StreamingEventType.functionCallResult,
    ]);
    expect(
      client.generateCalls,
      1,
      reason: 'stopFlag ends before another turn',
    );
    expect(persistenceSnapshots, hasLength(2));
    expect(persistenceSnapshots.first, [
      UserMessage,
      ModelMessage,
      FunctionExecutionResultMessage,
    ]);
    expect(controllerEvents, [
      AgentStartedEvent,
      BeforeCallLLMEvent,
      LLMChunkEvent,
      AfterCallLLMEvent,
      BeforeToolCallEvent,
      AfterToolCallEvent,
      AgentRunSuccessedEvent,
      AgentStoppedEvent,
    ]);
    expect(agent.state.isRunning, isFalse);

    await subscription.cancel();
    controller.close();
  });

  test(
    'maxTurns stops before an extra model call and still finalizes',
    () async {
      final controller = AgentController();
      final stopped = <AgentStoppedEvent>[];
      final subscription = controller.listen<AgentStoppedEvent>().listen(
        stopped.add,
      );
      final client = _QueueClient([]);
      final agent = StatefulAgent(
        name: 'turn-limit',
        client: client,
        modelConfig: ModelConfig(model: 'fake-model'),
        state: AgentState.empty(),
        withGeneralPrinciples: false,
        disableSubAgents: true,
        controller: controller,
      );

      await expectLater(
        agent
            .runStream([UserMessage.text('go')], useStream: false, maxTurns: 0)
            .drain<void>(),
        throwsA(
          isA<AgentException>().having(
            (error) => error.code,
            'code',
            AgentExceptionCode.loopDetection,
          ),
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(client.generateCalls, 0);
      expect(stopped, hasLength(1));
      expect(stopped.single.error?.code, AgentExceptionCode.loopDetection);

      await subscription.cancel();
      controller.close();
    },
  );
}

class _QueueClient implements LLMClient {
  _QueueClient(this.replies);

  final List<ModelMessage> replies;
  int generateCalls = 0;

  @override
  Future<ModelMessage> generate(
    List<LLMMessage> messages, {
    List<Tool>? tools,
    ToolChoice? toolChoice,
    required ModelConfig modelConfig,
    bool? jsonOutput,
    CancelToken? cancelToken,
  }) async {
    final index = generateCalls++;
    if (index >= replies.length) {
      throw StateError('Unexpected model call ${index + 1}');
    }
    return replies[index];
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
    final message = await generate(
      messages,
      tools: tools,
      toolChoice: toolChoice,
      modelConfig: modelConfig,
      jsonOutput: jsonOutput,
      cancelToken: cancelToken,
    );
    return Stream.value(StreamingMessage(modelMessage: message));
  }
}
