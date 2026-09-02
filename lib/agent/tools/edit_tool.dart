import 'dart:convert';

import 'package:vault/sandbox/sandbox_models.dart';
import 'package:vault_agent_core/vault_agent_core.dart';

const String kEditToolName = 'edit';

/// Replace an exact substring in an existing guest text file.
Tool createEditTool(SandboxWorkspace workspace, {String? projectPath}) {
  final projectDir = projectPath == null ? null : guestProjectDir(projectPath);
  final workHint = projectDir ?? kGuestHome;

  return Tool(
    name: kEditToolName,
    description:
        '在已有文本文件里做精确字符串替换。'
        '默认要求 old_string 只出现一次；多处相同片段请设 replace_all=true，或把 old_string 写得更独特。'
        '改之前先用 read 核对原文。路径必须是 $kGuestHome 下的绝对路径，优先 $workHint。'
        '新建文件请用 write。不要用 shell 的 sed/python 改文本。',
    parameterMode: ToolParameterMode.object,
    allowBackground: false,
    parameters: {
      'type': 'object',
      'properties': {
        'path': {
          'type': 'string',
          'description': 'guest 绝对路径，例如 $workHint/app.py',
        },
        'old_string': {
          'type': 'string',
          'description': '要替换的原文（必须与文件里的片段完全一致，含空白和换行）。',
        },
        'new_string': {'type': 'string', 'description': '替换后的文本。'},
        'replace_all': {
          'type': 'boolean',
          'description': '为 true 时替换所有匹配。默认 false（必须恰好一处）。',
        },
      },
      'required': ['path', 'old_string', 'new_string'],
    },
    executable: (Map<String, dynamic> args) => _executeEdit(workspace, args),
  );
}

Future<AgentToolResult> _executeEdit(
  SandboxWorkspace workspace,
  Map<String, dynamic> args,
) async {
  final rawPath = (args['path'] as String?)?.trim() ?? '';
  if (rawPath.isEmpty) {
    return AgentToolResult(
      content: TextPart('error: path 不能为空'),
      metadata: {'ok': false},
    );
  }

  late final String path;
  try {
    path = assertGuestPathUnderHome(rawPath);
  } on ArgumentError catch (e) {
    return AgentToolResult(
      content: TextPart('error: 非法路径（$e）'),
      metadata: {'ok': false},
    );
  }

  final oldString = args['old_string'];
  final newString = args['new_string'];
  if (oldString is! String || newString is! String) {
    return AgentToolResult(
      content: TextPart('error: old_string 和 new_string 必须是字符串'),
      metadata: {'ok': false, 'path': path},
    );
  }
  if (oldString.isEmpty) {
    return AgentToolResult(
      content: TextPart('error: old_string 不能为空'),
      metadata: {'ok': false, 'path': path},
    );
  }
  if (oldString == newString) {
    return AgentToolResult(
      content: TextPart('error: old_string 与 new_string 相同，没有可做的替换。'),
      metadata: {'ok': false, 'path': path},
    );
  }

  final bytes = await workspace.readGuestFile(path);
  if (bytes == null) {
    return AgentToolResult(
      content: TextPart('error: 文件不存在或无法读取：$path'),
      metadata: {'ok': false, 'path': path},
    );
  }
  if (!looksLikeTextBytes(bytes)) {
    return AgentToolResult(
      content: TextPart('error: $path 不是文本，edit 只支持 UTF-8 文本。'),
      metadata: {'ok': false, 'path': path},
    );
  }

  final text = utf8.decode(bytes, allowMalformed: true);
  final matches = _countOccurrences(text, oldString);
  final replaceAll = _asBool(args['replace_all']) ?? false;

  if (matches == 0) {
    return AgentToolResult(
      content: TextPart(
        'error: $path 中找不到 old_string。请用 read 核对原文（空白和换行必须完全一致）。',
      ),
      metadata: {'ok': false, 'path': path, 'matches': 0},
    );
  }
  if (matches > 1 && !replaceAll) {
    return AgentToolResult(
      content: TextPart(
        'error: $path 中 old_string 出现了 $matches 处。'
        '把 old_string 写得更独特，或设 replace_all=true。',
      ),
      metadata: {'ok': false, 'path': path, 'matches': matches},
    );
  }

  final next = replaceAll
      ? text.replaceAll(oldString, newString)
      : text.replaceFirst(oldString, newString);
  final nextBytes = utf8.encode(next);
  await workspace.writeGuestFile(path, nextBytes);
  final replacements = replaceAll ? matches : 1;
  final lines = next.isEmpty ? 0 : next.split('\n').length;
  return AgentToolResult(
    content: TextPart('已编辑 $path：替换 $replacements 处，现在 $lines 行。'),
    metadata: {
      'ok': true,
      'path': path,
      'replacements': replacements,
      'lineCount': lines,
    },
  );
}

int _countOccurrences(String haystack, String needle) {
  var count = 0;
  var from = 0;
  while (true) {
    final index = haystack.indexOf(needle, from);
    if (index < 0) return count;
    count++;
    from = index + needle.length;
  }
}

bool? _asBool(Object? raw) {
  if (raw is bool) return raw;
  if (raw is String) {
    switch (raw.trim().toLowerCase()) {
      case 'true':
      case '1':
      case 'yes':
        return true;
      case 'false':
      case '0':
      case 'no':
        return false;
    }
  }
  return null;
}
