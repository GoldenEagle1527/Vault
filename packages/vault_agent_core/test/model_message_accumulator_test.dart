import 'package:test/test.dart';
import 'package:vault_agent_core/vault_agent_core.dart';

void main() {
  test('merges incremental function calls by id', () {
    final accumulator = ModelMessageAccumulator();

    accumulator.add(
      ModelMessage(
        model: 'test-model',
        textOutput: 'working',
        functionCalls: [
          FunctionCall(id: 'call-1', name: 'shell', arguments: '{"command":"'),
        ],
      ),
    );
    accumulator.add(
      ModelMessage(
        model: 'test-model',
        textOutput: ' done',
        functionCalls: [
          FunctionCall(
            id: 'call-1',
            name: '',
            arguments: '{"command":"dart test"}',
          ),
        ],
        stopReason: 'tool_calls',
      ),
    );

    final message = accumulator.toModelMessage('test-model');
    expect(message.textOutput, 'working done');
    expect(message.functionCalls, hasLength(1));
    expect(message.functionCalls.single.id, 'call-1');
    expect(message.functionCalls.single.name, 'shell');
    expect(message.functionCalls.single.arguments, '{"command":"dart test"}');
    expect(message.stopReason, 'tool_calls');
  });

  test('keeps separate calls and can reset accumulated state', () {
    final accumulator = ModelMessageAccumulator()
      ..add(
        ModelMessage(
          model: 'test-model',
          responseId: 'response-1',
          functionCalls: [
            FunctionCall(id: '', name: 'first', arguments: '{}'),
            FunctionCall(id: '', name: 'second', arguments: '{}'),
          ],
        ),
      );

    expect(accumulator.isEmptyResponse, isFalse);
    expect(
      accumulator.toModelMessage('test-model').functionCalls,
      hasLength(2),
    );

    accumulator.reset();

    expect(accumulator.isEmptyResponse, isTrue);
    expect(accumulator.toModelMessage('test-model').functionCalls, isEmpty);
  });
}
