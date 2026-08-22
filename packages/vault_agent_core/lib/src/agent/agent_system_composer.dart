import '../core/message.dart';
import '../core/tool.dart';
import 'agent_state.dart';
import 'agent_system_prompt.dart';
import 'memory.dart';
import 'planner.dart';
import 'skill.dart';
import 'sub_agent.dart';
import 'util.dart';

typedef JavaScriptToolExecutor =
    Future<String> Function(String scriptPath, String? args, int? timeoutMs);

/// Composes the system message and tool set from explicit agent dependencies.
class AgentSystemComposer {
  const AgentSystemComposer();

  SystemMessage? composeSystemMessage({
    required List<String> systemPrompts,
    required AgentState state,
    required bool disableSubAgents,
    required List<SubAgent>? subAgents,
    required bool directorySkillModeEnabled,
    required List<DirectorySkillMetadata> directorySkills,
    required bool javaScriptExecutionEnabled,
    required List<Skill>? skills,
    required bool withGeneralPrinciples,
    required PlanMode? planMode,
  }) {
    final parts = <SystemPromptPart>[];

    if (systemPrompts.isNotEmpty) {
      parts.add(
        SystemPromptPart(
          name: 'system_prompt',
          content: systemPrompts.join('\n\n'),
        ),
      );
    }

    if (!isSubAgentMode(state) && !disableSubAgents) {
      final instruction = buildSubAgentSystemPrompt(state, subAgents);
      if (instruction != null) {
        parts.add(instruction);
      }
    }

    if (directorySkillModeEnabled) {
      final instruction = buildDirectorySkillsSystemPrompt(
        directorySkills,
        javaScriptExecutionEnabled: javaScriptExecutionEnabled,
      );
      if (instruction != null) {
        parts.add(instruction);
      }
    } else if (skills != null && skills.isNotEmpty) {
      final instruction = buildSkillSystemPrompt(state, skills);
      if (instruction != null) {
        parts.add(instruction);
      }
    }

    if (withGeneralPrinciples) {
      parts.add(
        SystemPromptPart(
          name: 'general_principles',
          content: _composeGeneralPrinciples(planMode),
        ),
      );
    }

    if (parts.isEmpty) {
      return null;
    }
    return SystemMessage(parts.map((part) => part.content).join('\n\n'));
  }

  List<Tool> composeTools({
    required List<Tool>? tools,
    required List<Tool> plannerTools,
    required PlanMode? planMode,
    required AgentState state,
    required List<Skill>? skills,
    required bool directorySkillModeEnabled,
    required JavaScriptToolExecutor? javaScriptExecutor,
    required bool disableSubAgents,
  }) {
    final composed = List<Tool>.from(tools ?? const []);

    if (planMode == PlanMode.auto || planMode == PlanMode.must) {
      composed.addAll(plannerTools);
    }

    if (!directorySkillModeEnabled && skills != null && skills.isNotEmpty) {
      if (!skills.every((skill) => skill.forceActivate)) {
        composed.addAll(skillOperationTools);
      }

      final activeSkillNames = {
        ...?(state.activeSkills),
        ...skills
            .where((skill) => skill.forceActivate)
            .map((skill) => skill.name),
      };
      for (final skillName in activeSkillNames) {
        final skill = skills.firstWhere((skill) => skill.name == skillName);
        composed.addAll(skill.tools ?? const []);
      }
    }

    if (directorySkillModeEnabled && javaScriptExecutor != null) {
      composed.add(_createJavaScriptTool(javaScriptExecutor));
    }

    if (!isSubAgentMode(state) && !disableSubAgents) {
      composed.addAll(subAgentTools);
    }

    if (state.history.episodicMemories.isNotEmpty) {
      composed.addAll(memoryTools);
    }

    return composed;
  }

  String _composeGeneralPrinciples(PlanMode? planMode) {
    final buffer = StringBuffer("# General Principles:\n");
    buffer.writeln("- Concise output (< 4 lines unless asked for detail)");
    buffer.writeln("- No \"Here is.\" or \"| will..\" —just do it");
    buffer.writeln("- Do work with tools, not text explanations");
    buffer.writeln(
      "- Run independent tools in parallel; execute dependent tools sequentially",
    );
    if (planMode == PlanMode.auto || planMode == PlanMode.must) {
      buffer.writeln("- Track tasks with Planner");
    }
    return buffer.toString();
  }

  Tool _createJavaScriptTool(JavaScriptToolExecutor executor) {
    return Tool(
      name: 'RunJavaScript',
      description:
          'Execute a JavaScript (.js) script from the directory skill workspace.',
      executable: executor,
      parameters: const {
        'type': 'object',
        'properties': {
          'script_path': {
            'type': 'string',
            'description': 'Absolute path to a JavaScript file.',
          },
          'args': {
            'type': 'string',
            'description':
                'Optional JSON object string (for example: {"xx":"yy"}). The framework deserializes it, and JavaScript reads fields from `ctx.args` directly (for example: `ctx.args.xx`).',
          },
          'timeout_ms': {
            'type': 'integer',
            'description': 'Optional timeout in milliseconds. Default 30000.',
          },
        },
        'required': ['script_path'],
      },
    );
  }
}
