import 'package:vault/agent/tools/guest_search.dart';
import 'package:vault/sandbox/sandbox_models.dart';
import 'package:vault_agent_core/vault_agent_core.dart';

const String kGlobToolName = 'glob';

/// Find guest files by glob pattern via host-side directory listing.
Tool createGlobTool(SandboxWorkspace workspace, {String? projectPath}) {
  final projectDir = projectPath == null ? null : guestProjectDir(projectPath);
  final defaultRoot = projectDir ?? kGuestHome;

  return Tool(
    name: kGlobToolName,
    description:
        '按文件名模式列出沙箱内的路径（不读内容）。'
        '模式支持 *、**、?；未写 **/ 时会自动按任意深度匹配，例如 *.py。'
        '默认从 $defaultRoot 递归查找，跳过 .git / __pycache__ / node_modules。'
        '找文件名用这个工具；搜文件内容请用 grep。',
    parameterMode: ToolParameterMode.object,
    allowBackground: false,
    parameters: {
      'type': 'object',
      'properties': {
        'glob_pattern': {
          'type': 'string',
          'description': '文件名模式，例如 *.py、templates/*.html、**/config.py',
        },
        'path': {
          'type': 'string',
          'description': '搜索根目录（guest 绝对路径）。默认 $defaultRoot。',
        },
        'head_limit': {
          'type': 'integer',
          'description': '最多返回多少条路径。默认 $kGlobDefaultMaxResults。',
        },
      },
      'required': ['glob_pattern'],
    },
    executable: (Map<String, dynamic> args) =>
        _executeGlob(workspace, args, defaultRoot: defaultRoot),
  );
}

Future<AgentToolResult> _executeGlob(
  SandboxWorkspace workspace,
  Map<String, dynamic> args, {
  required String defaultRoot,
}) async {
  final pattern = (args['glob_pattern'] as String?)?.trim() ?? '';
  if (pattern.isEmpty) {
    return AgentToolResult(
      content: TextPart('error: glob_pattern 不能为空'),
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

  final limit = _asPositiveInt(args['head_limit']) ?? kGlobDefaultMaxResults;

  late final List<GuestFsEntry> files;
  try {
    files = await collectGuestFiles(
      workspace: workspace,
      root: root,
      includeFile: (path) => guestPathMatchesGlob(path, pattern),
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
  final total = files.length;
  final slice = total > limit ? files.sublist(0, limit) : files;
  if (slice.isEmpty) {
    return AgentToolResult(
      content: TextPart('在 $root 下没有匹配 $pattern 的文件。'),
      metadata: {'ok': true, 'path': root, 'matchCount': 0, 'truncated': false},
    );
  }

  final buf = StringBuffer();
  buf.writeln(
    '在 $root 匹配 $pattern：${slice.length} 个'
    '${total > limit ? '（共 $total，已截断）' : ''}',
  );
  for (final file in slice) {
    buf.writeln(file.guestPath);
  }
  return AgentToolResult(
    content: TextPart(buf.toString().trimRight()),
    metadata: {
      'ok': true,
      'path': root,
      'matchCount': slice.length,
      'totalCount': total,
      'truncated': total > limit,
    },
  );
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
