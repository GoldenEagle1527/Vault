import 'dart:convert';

import '../../core/fs.dart';
import 'model.dart';

Future<DirectorySkillLoadResult> loadDirectorySkillsFromRoot(
  String rootDirectoryPath, {
  int maxDepth = 6,
}) async {
  if (!fsDirectoryExistsSync(rootDirectoryPath)) {
    return DirectorySkillLoadResult(
      skills: [],
      errors: [
        DirectorySkillLoadError(
          path: rootDirectoryPath,
          message: 'skill directory does not exist',
        ),
      ],
    );
  }

  final skills = <DirectorySkillMetadata>[];
  final errors = <DirectorySkillLoadError>[];
  final seenPaths = <String>{};

  final files = await fsFindFiles(
    rootDirectoryPath,
    'SKILL.md',
    maxDepth: maxDepth,
  );
  for (final filePath in files) {
    final normalized = _normalizePath(filePath);
    if (!seenPaths.add(normalized)) continue;

    try {
      skills.add(await _parseDirectorySkillFile(filePath));
    } catch (error) {
      errors.add(
        DirectorySkillLoadError(path: filePath, message: error.toString()),
      );
    }
  }

  skills.sort((a, b) => a.name.compareTo(b.name));
  return DirectorySkillLoadResult(skills: skills, errors: errors);
}

Future<DirectorySkillMetadata> _parseDirectorySkillFile(
  String skillPath,
) async {
  final content = await fsReadAsString(skillPath);
  final frontmatter = _extractFrontmatter(content);
  if (frontmatter == null) {
    throw Exception('missing YAML frontmatter delimited by ---');
  }
  final parsed = _parseSimpleFrontmatter(frontmatter);
  final path = _normalizePath(fsAbsolutePath(skillPath));
  final fallbackName = _basename(_parentDir(path));
  final name = (parsed['name'] ?? fallbackName).trim();
  if (name.isEmpty) {
    throw Exception('missing skill name');
  }
  final description = (parsed['description'] ?? '').trim();
  if (description.isEmpty) {
    throw Exception('missing skill description');
  }
  return DirectorySkillMetadata(
    name: name,
    description: description,
    pathToSkillMd: path,
  );
}

String? _extractFrontmatter(String content) {
  final lines = const LineSplitter().convert(content);
  if (lines.isEmpty || lines.first.trim() != '---') return null;

  final buffer = StringBuffer();
  for (var i = 1; i < lines.length; i++) {
    final line = lines[i];
    if (line.trim() == '---') {
      return buffer.isEmpty ? null : buffer.toString();
    }
    buffer.writeln(line);
  }
  return null;
}

Map<String, String> _parseSimpleFrontmatter(String frontmatter) {
  final values = <String, String>{};
  for (final rawLine in const LineSplitter().convert(frontmatter)) {
    final line = rawLine.trimRight();
    if (line.trim().isEmpty || line.trimLeft().startsWith('#')) continue;
    final separator = line.indexOf(':');
    if (separator <= 0) continue;
    final key = line.substring(0, separator).trim();
    final value = _stripWrappingQuotes(line.substring(separator + 1).trim());
    if (key.isNotEmpty && value.isNotEmpty) {
      values[key] = value;
    }
  }
  return values;
}

String _stripWrappingQuotes(String value) {
  if (value.length >= 2 &&
      ((value.startsWith('"') && value.endsWith('"')) ||
          (value.startsWith("'") && value.endsWith("'")))) {
    return value.substring(1, value.length - 1);
  }
  return value;
}

String _normalizePath(String path) {
  if (path.startsWith('skill://')) {
    path = path.substring('skill://'.length);
  }
  return path.replaceAll('\\', '/');
}

String _basename(String path) {
  final parts = path.replaceAll('\\', '/').split('/');
  return parts.isEmpty ? path : parts.last;
}

String _parentDir(String path) {
  final normalized = path.replaceAll('\\', '/');
  final separator = normalized.lastIndexOf('/');
  if (separator <= 0) return normalized;
  return normalized.substring(0, separator);
}
