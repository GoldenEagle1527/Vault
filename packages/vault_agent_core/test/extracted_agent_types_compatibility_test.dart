import 'dart:convert';

import 'package:test/test.dart';
import 'package:vault_agent_core/src/agent/agent_state.dart' as extracted_state;
import 'package:vault_agent_core/src/agent/agent_system_prompt.dart'
    as extracted_prompt;
import 'package:vault_agent_core/src/agent/agent_tool_result.dart'
    as extracted_tool;
import 'package:vault_agent_core/src/agent/stateful_agent.dart' as legacy;
import 'package:vault_agent_core/src/core/llm_client.dart';

void main() {
  test('stateful_agent.dart re-exports extracted state types', () {
    final legacy.AgentState state = extracted_state.AgentState(
      sessionId: 'compat-session',
      systemPromptHistory: [
        legacy.SystemPromptHistoryItem(
          content: 'system prompt',
          validFromMessageIndex: 2,
        ),
      ],
      toolsHistory: [
        legacy.ToolsHistoryItem(
          tools: [
            {'name': 'read', 'description': 'Read a file'},
          ],
          validFromMessageIndex: 3,
        ),
      ],
    );

    final json = jsonDecode(jsonEncode(state.toJson())) as Map<String, dynamic>;
    final decoded = extracted_state.AgentState.fromJson(json);

    expect(decoded.sessionId, 'compat-session');
    expect(decoded.systemPromptHistory.single.content, 'system prompt');
    expect(decoded.systemPromptHistory.single.validFromMessageIndex, 2);
    expect(decoded.toolsHistory.single.tools.single['name'], 'read');
    expect(decoded.toolsHistory.single.validFromMessageIndex, 3);
  });

  test('stateful_agent.dart re-exports prompt and tool result types', () {
    final legacy.SystemPromptPart prompt = extracted_prompt.SystemPromptPart(
      name: 'policy',
      content: 'Be concise.',
    );
    final legacy.AgentToolResult toolResult = extracted_tool.AgentToolResult(
      metadata: {'source': 'compatibility-test'},
    );
    final legacy.ExecutionToolResult executionResult =
        extracted_tool.ExecutionToolResult(
          id: 'call-1',
          name: 'read',
          arguments: '{}',
          content: const [],
        );

    expect(prompt.name, 'policy');
    expect(toolResult.metadata?['source'], 'compatibility-test');
    expect(executionResult.name, 'read');
  });

  test('CallLLMParams keeps one type across old and new imports', () {
    final legacy.CallLLMParams params = extracted_state.CallLLMParams(
      messages: const [],
      modelConfig: ModelConfig(model: 'test-model'),
      stream: true,
    );

    expect(params, isA<extracted_state.CallLLMParams>());
    expect(params.modelConfig.model, 'test-model');
    expect(params.stream, isTrue);
  });
}
