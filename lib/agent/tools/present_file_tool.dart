import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:vault/agent/present_file.dart';
import 'package:vault/sandbox/guest_media_kind.dart';
import 'package:vault/sandbox/sandbox_models.dart';
import 'package:vault_agent_core/vault_agent_core.dart';

/// Show a finished guest file in the chat so the user can preview or download.
Tool createPresentFileTool(SandboxWorkspace workspace) {
  return Tool(
    name: kPresentFileToolName,
    description:
        '把沙箱里已经写好的成品文件展示到对话里，用户可以点预览或下载到主机。'
        '格式转换、导出表格/文档、生成图片等用户要拿走或查看的结果，写完后必须调用。'
        'path 必须是 $kGuestHome 下已存在的文件（不要传目录；目录请先打包成 zip 再展示）。'
        '中间 scratch、日志、临时文件不要调用。一次只展示一个文件。',
    parameterMode: ToolParameterMode.object,
    allowBackground: false,
    parameters: {
      'type': 'object',
      'properties': {
        'path': {
          'type': 'string',
          'description': 'guest 绝对路径，例如 $kGuestProjectsDir/…/out.csv',
        },
        'title': {'type': 'string', 'description': '可选显示名。默认用文件名。'},
      },
      'required': ['path'],
    },
    executable: (Map<String, dynamic> args) =>
        _executePresentFile(workspace, args),
  );
}

Future<AgentToolResult> _executePresentFile(
  SandboxWorkspace workspace,
  Map<String, dynamic> args,
) async {
  final rawPath = (args['path'] as String?)?.trim() ?? '';
  if (rawPath.isEmpty) {
    return AgentToolResult(
      content: TextPart('error: path 不能为空'),
      metadata: {'ok': false, 'present_file': false},
    );
  }

  late final String path;
  try {
    path = assertGuestPathUnderHome(rawPath);
  } on ArgumentError catch (e) {
    return AgentToolResult(
      content: TextPart('error: 非法路径（$e）'),
      metadata: {'ok': false, 'present_file': false},
    );
  }

  final probe = await _probe(workspace, path);
  if (probe == _PresentProbe.missing) {
    return AgentToolResult(
      content: TextPart('error: 文件不存在：$path'),
      metadata: {'ok': false, 'present_file': false, 'guestPath': path},
    );
  }
  if (probe == _PresentProbe.directory) {
    return AgentToolResult(
      content: TextPart(
        'error: $path 是目录。请先打成 zip（或展示目录里的具体文件），再调用 present_file。',
      ),
      metadata: {'ok': false, 'present_file': false, 'guestPath': path},
    );
  }

  final title = (args['title'] as String?)?.trim();
  final displayName = (title == null || title.isEmpty)
      ? p.posix.basename(path)
      : title;
  final kind = guestMediaKindForPath(path);
  final size = await _byteSize(workspace, path);
  final payload = presentFilePayload(
    guestPath: path,
    displayName: displayName,
    kind: kind,
    size: size,
  );
  return AgentToolResult(
    content: TextPart(
      '已展示文件 $path（$displayName）。用户可在对话卡片里预览或下载。\n'
      '${jsonEncode(payload)}',
    ),
    metadata: payload,
  );
}

enum _PresentProbe { file, directory, missing }

Future<_PresentProbe> _probe(SandboxWorkspace workspace, String path) async {
  final quoted = shellSingleQuote(path);
  final result = await workspace.run(
    'if [ -d $quoted ]; then echo dir; '
    'elif [ -f $quoted ]; then echo file; '
    'else echo missing; fi',
  );
  return switch (result.stdout.trim()) {
    'dir' => _PresentProbe.directory,
    'file' => _PresentProbe.file,
    _ => _PresentProbe.missing,
  };
}

Future<int?> _byteSize(SandboxWorkspace workspace, String path) async {
  final quoted = shellSingleQuote(path);
  final result = await workspace.run(
    'if [ -f $quoted ]; then wc -c < $quoted; fi',
  );
  if (!result.success) return null;
  return int.tryParse(result.stdout.trim());
}
