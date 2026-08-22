import '../../core/message.dart';
import '../../core/tool.dart';

abstract class Skill {
  final String name;
  final String description;
  final String systemPrompt;
  final List<Tool>? tools;
  bool forceActivate;

  Skill({
    required this.name,
    required this.description,
    required this.systemPrompt,
    this.tools,
    this.forceActivate = false,
  });
}

class DirectorySkillMetadata {
  final String name;
  final String description;
  final String pathToSkillMd;

  DirectorySkillMetadata({
    required this.name,
    required this.description,
    required this.pathToSkillMd,
  });
}

class DirectorySkillLoadError {
  final String path;
  final String message;

  DirectorySkillLoadError({required this.path, required this.message});
}

class DirectorySkillLoadResult {
  final List<DirectorySkillMetadata> skills;
  final List<DirectorySkillLoadError> errors;

  DirectorySkillLoadResult({required this.skills, required this.errors});
}

class DirectorySkillInjections {
  final List<UserMessage> items;
  final List<String> warnings;

  DirectorySkillInjections({required this.items, required this.warnings});
}
