import 'package:test/test.dart';
import 'package:vault_agent_core/src/agent/agent_hook.dart';
import 'package:vault_agent_core/src/agent/agent_state.dart';
import 'package:vault_agent_core/src/core/message.dart';

void main() {
  test('hook pipeline can be imported without StatefulAgent', () async {
    final host = _HookHost();
    final pipeline = AgentHookPipeline([_AppendInputHook()]);
    final original = UserMessage.text('original');

    final result = await pipeline.beforeRun(
      BeforeRunHookContext(host, input: [original], stream: false),
    );

    expect(result.action, BeforeRunHookAction.proceed);
    expect(result.input, hasLength(2));
    expect(result.input!.last, isA<UserMessage>());
    final appended = result.input!.last as UserMessage;
    expect((appended.contents.single as TextPart).text, 'appended');
    expect(host.state, same(host.state));
  });
}

class _HookHost implements AgentHookHost {
  @override
  final AgentState state = AgentState.empty();
}

class _AppendInputHook extends AgentHook {
  @override
  BeforeRunHookResult beforeRun(BeforeRunHookContext context) {
    return BeforeRunHookResult.proceed([
      ...context.input,
      UserMessage.text('appended'),
    ]);
  }
}
