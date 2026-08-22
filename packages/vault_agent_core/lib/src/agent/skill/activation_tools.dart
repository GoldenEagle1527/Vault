import 'package:logging/logging.dart';

import '../../core/tool.dart';
import '../agent_tool_result.dart';

final _logger = Logger('Skill');

final skillOperationTools = [_activateSkillsTool, _deactivateSkillsTool];

final _activateSkillsTool = Tool(
  name: 'activate_skills',
  description:
      'Activate specific skills from the registry to gain their capabilities and instructions.',
  parameters: {
    'type': 'object',
    'properties': {
      'skill_names': {
        'type': 'array',
        'items': {'type': 'string'},
        'description':
            'A list of skill names to activate (case-sensitive, must match registry).',
      },
    },
    'required': ['skill_names'],
  },
  executable: _activateSkills,
);

final _deactivateSkillsTool = Tool(
  name: 'deactivate_skills',
  description:
      'Deactivate specific skills to remove their instructions and tools from the context.',
  parameters: {
    'type': 'object',
    'properties': {
      'skill_names': {
        'type': 'array',
        'items': {'type': 'string'},
        'description': 'A list of skill names to deactivate.',
      },
    },
    'required': ['skill_names'],
  },
  executable: _deactivateSkills,
);

String _activateSkills(List<String> skillNames) {
  final state = AgentCallToolContext.current!.state;
  state.activeSkills ??= [];

  final skills = AgentCallToolContext.current!.agent.skills ?? [];
  final availableSkillNames = skills.map((skill) => skill.name).toList();
  final forceActiveSkillNames = skills
      .where((skill) => skill.forceActivate)
      .map((skill) => skill.name)
      .toList();

  final added = <String>[];
  final alreadyActive = <String>[];
  final forceActivated = <String>[];
  final notFound = <String>[];

  for (final name in skillNames) {
    if (!availableSkillNames.contains(name)) {
      notFound.add(name);
      continue;
    }
    if (forceActiveSkillNames.contains(name)) {
      forceActivated.add(name);
      continue;
    }
    if (!state.activeSkills!.contains(name)) {
      state.activeSkills!.add(name);
      added.add(name);
    } else {
      alreadyActive.add(name);
    }
  }

  final buffer = StringBuffer();
  if (forceActivated.isNotEmpty) {
    buffer.writeln(
      'Skills have been force activated: ${forceActivated.join(', ')}',
    );
  }
  if (added.isNotEmpty) {
    buffer.writeln('Skills have been activated: ${added.join(', ')}');
  }
  if (alreadyActive.isNotEmpty) {
    buffer.writeln('Skills are already active: ${alreadyActive.join(', ')}');
  }
  if (notFound.isNotEmpty) {
    buffer.writeln('Skills not found: ${notFound.join(', ')}');
  }

  _logger.info(buffer.toString());
  return buffer.toString();
}

String _deactivateSkills(List<String> skillNames) {
  final state = AgentCallToolContext.current!.state;
  final skills = AgentCallToolContext.current!.agent.skills ?? [];
  final forceActiveSkillNames = skills
      .where((skill) => skill.forceActivate)
      .map((skill) => skill.name)
      .toList();

  final removed = <String>[];
  final notFound = <String>[];
  final forceActivated = <String>[];

  for (final name in skillNames) {
    if (forceActiveSkillNames.contains(name)) {
      forceActivated.add(name);
      continue;
    }
    if (state.activeSkills!.contains(name)) {
      state.activeSkills!.remove(name);
      removed.add(name);
    } else {
      notFound.add(name);
    }
  }

  final result = StringBuffer();
  if (removed.isNotEmpty) {
    result.write('Skills have been deactivated: ${removed.join(', ')}. ');
  }
  if (notFound.isNotEmpty) {
    result.write('Skills not found: ${notFound.join(', ')}. ');
  }
  if (forceActivated.isNotEmpty) {
    result.write(
      'Skills are force activated: ${forceActivated.join(', ')}. '
      'Do not try to deactivate.',
    );
  }

  _logger.info(result.toString());
  return result.toString();
}
