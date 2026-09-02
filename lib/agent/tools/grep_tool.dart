import 'dart:convert';

import 'package:vault/agent/tools/guest_search.dart';
import 'package:vault/sandbox/guest_media_kind.dart';
import 'package:vault/sandbox/sandbox_models.dart';
import 'package:vault_agent_core/vault_agent_core.dart';

const String kGrepToolName = 'grep';

/// Search guest text files with a Dart [RegExp] via host-side listing.
Tool createGrepTool(SandboxWorkspace workspace, {String? projectPath}) {
  final projectDir = projectPath == null ? null : guestProjectDir(projectPath);
  final defaultRoot = projectDir ?? kGuestHome;

  return Tool(
    name: kGrepToolName,
    description:
        '在沙箱文本文件里按正则搜索（Dart/JS 风格）。'
        '返回 path:行号:片段。只扫文本，跳过二进制以及 .git / __pycache__ / node_modules。'
        '默认从 $defaultRoot 递归查找。'
        '找文件名请用 glob；读完整文件请用 read。',
    parameterMode: ToolParameterMode.object,
    allowBackground: false,
    parameters: {
      'type': 'object',
      'properties': {
        'pattern': {
          'type': 'string',
          'description': '正则，例如 def\\s+index 或 class\\s+User',
        },
        'path': {
          'type': 'string',
          'description': '搜索根目录（guest 绝对路径）。默认 $defaultRoot。',
        },
        'glob': {'type': 'string', 'description': '可选，只搜匹配的文件，例如 *.py、*.html'},
        'case_insensitive': {
          'type': 'boolean',
          'description': '忽略大小写。默认 false。',
        },
        'head_limit': {
          'type': 'integer',
          'description': '最多返回多少条命中。默认 $kGrepDefaultHeadLimit。',
        },
      },
      'required': ['pattern'],
    },
    executable: (Map<String, dynamic> args) =>
        _executeGrep(workspace, args, defaultRoot: defaultRoot),
  );
}

Future<AgentToolResult> _executeGrep(
  SandboxWorkspace workspace,
  Map<String, dynamic> args, {
  required String defaultRoot,
}) async {
  final rawPattern = (args['pattern'] as String?) ?? '';
  if (rawPattern.isEmpty) {
    return AgentToolResult(
      content: TextPart('error: pattern 不能为空'),
      metadata: {'ok': false},
    );
  }

  final caseInsensitive = _asBool(args['case_insensitive']) ?? false;
  late final RegExp regex;
  try {
    regex = RegExp(rawPattern, caseSensitive: !caseInsensitive);
  } on FormatException catch (e) {
    return AgentToolResult(
      content: TextPart('error: 无效正则：$e'),
      metadata: {'ok': false},
    );
  }

  final rawPath = (args['path'] as String?)?.trim();
  late final String root;
  try {
    root = assertGuestPathUnderHome(
      (rawPath == null || rawPath.isEmpty) ? defaultRoot : rawPath,
    );
  } on ArgumentError catch (e) {
    return AgentToolResult(
      content: TextPart('error: 非法路径（$e）'),
      metadata: {'ok': false},
    );
  }

  final glob = (args['glob'] as String?)?.trim();
  final limit = _asPositiveInt(args['head_limit']) ?? kGrepDefaultHeadLimit;

  late final List<GuestFsEntry> files;
  try {
    files = await collectGuestFiles(
      workspace: workspace,
      root: root,
      includeFile: (path) {
        if (glob != null &&
            glob.isNotEmpty &&
            !guestPathMatchesGlob(path, glob)) {
          return false;
        }
        final kind = guestMediaKindForPath(path);
        return kind == GuestMediaKind.text || kind == GuestMediaKind.binary;
      },
    );
  } on StateError catch (e) {
    return AgentToolResult(
      content: TextPart('error: $e'),
      metadata: {'ok': false, 'path': root},
    );
  } on ArgumentError catch (e) {
    return AgentToolResult(
      content: TextPart('error: 非法路径（$e）'),
      metadata: {'ok': false, 'path': root},
    );
  }

  files.sort((a, b) => a.guestPath.compareTo(b.guestPath));
  final hits = <_GrepHit>[];
  var truncated = false;
  for (final file in files) {
    if (hits.length >= limit) {
      truncated = true;
      break;
    }
    final bytes = await workspace.readGuestFile(file.guestPath);
    if (bytes == null) continue;
    if (!looksLikeTextBytes(bytes)) continue;
    final text = utf8.decode(bytes, allowMalformed: true);
    final lines = text.split('\n');
    for (var i = 0; i < lines.length; i++) {
      if (!regex.hasMatch(lines[i])) continue;
      hits.add(_GrepHit(path: file.guestPath, line: i + 1, snippet: lines[i]));
      if (hits.length >= limit) {
        truncated = true;
        break;
      }
    }
  }

  if (hits.isEmpty) {
    return AgentToolResult(
      content: TextPart('在 $root 下没有匹配 /$rawPattern/ 的文本。'),
      metadata: {'ok': true, 'path': root, 'matchCount': 0, 'truncated': false},
    );
  }

  final buf = StringBuffer();
  buf.writeln(
    '在 $root 匹配 /$rawPattern/：${hits.length} 处'
    '${truncated ? '（已达上限 $limit）' : ''}',
  );
  for (final hit in hits) {
    buf.writeln('${hit.path}:${hit.line}:${hit.snippet}');
  }
  return AgentToolResult(
    content: TextPart(buf.toString().trimRight()),
    metadata: {
      'ok': true,
      'path': root,
      'matchCount': hits.length,
      'truncated': truncated,
    },
  );
}

class _GrepHit {
  const _GrepHit({
    required this.path,
    required this.line,
    required this.snippet,
  });
  final String path;
  final int line;
  final String snippet;
}

int? _asPositiveInt(Object? raw) {
  if (raw is int && raw > 0) return raw;
  if (raw is num && raw > 0) return raw.toInt();
  if (raw is String) {
    final n = int.tryParse(raw.trim());
    if (n != null && n > 0) return n;
  }
  return null;
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
