import 'package:test/test.dart';
import 'package:vault_agent_core/vault_agent_core.dart';

void main() {
  const composer = AgentSystemComposer();

  test('composes system prompt from explicit dependencies', () {
    final state = AgentState.empty()..activeSkills = ['optional'];
    final message = composer.composeSystemMessage(
      systemPrompts: const ['primary', 'secondary'],
      state: state,
      disableSubAgents: true,
      subAgents: null,
      directorySkillModeEnabled: false,
      directorySkills: const [],
      javaScriptExecutionEnabled: false,
      skills: [
        _TestSkill(
          name: 'optional',
          systemPrompt: 'Use the optional workflow.',
        ),
      ],
      withGeneralPrinciples: true,
      planMode: PlanMode.auto,
    );

    expect(message, isNotNull);
    expect(message!.content, startsWith('primary\n\nsecondary'));
    expect(message.content, contains('Use the optional workflow.'));
    expect(message.content, contains('# General Principles:'));
    expect(message.content, contains('- Track tasks with Planner'));
  });

  test('composes tools without retaining StatefulAgent', () {
    final state = AgentState.empty()..activeSkills = ['optional'];
    final baseTool = _tool('base');
    final plannerTool = _tool('planner');
    final skillTool = _tool('skill');

    final tools = composer.composeTools(
      tools: [baseTool],
      plannerTools: [plannerTool],
      planMode: PlanMode.must,
      state: state,
      skills: [
        _TestSkill(
          name: 'optional',
          systemPrompt: 'optional',
          tools: [skillTool],
        ),
      ],
      directorySkillModeEnabled: false,
      javaScriptExecutor: null,
      disableSubAgents: true,
    );

    expect(tools.map((tool) => tool.name), [
      'base',
      'planner',
      'activate_skills',
      'deactivate_skills',
      'skill',
    ]);
  });
}

Tool _tool(String name) {
  return Tool(
    name: name,
    description: name,
    executable: () => name,
    parameters: const {'type': 'object', 'properties': <String, dynamic>{}},
  );
}

class _TestSkill extends Skill {
  _TestSkill({required super.name, required super.systemPrompt, super.tools})
    : super(description: name);
}
