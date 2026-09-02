import 'dart:convert';

import 'package:vault/sandbox/sandbox_models.dart';
import 'package:vault_agent_core/vault_agent_core.dart';

const String kWriteToolName = 'write';

/// Create or overwrite a UTF-8 text file in the guest workspace.
Tool createWriteTool(SandboxWorkspace workspace, {String? projectPath}) {
  final projectDir = projectPath == null ? null : guestProjectDir(projectPath);
  final workHint = projectDir ?? kGuestHome;

  return Tool(
    name: kWriteToolName,
    description:
        '新建或整文件覆盖沙箱内的 UTF-8 文本文件（代码、配置、表格等）。'
        '父目录不存在时会自动创建。路径必须是 $kGuestHome 下的绝对路径。'
        '优先写在 $workHint。'
        '已有文件要改几处时请用 edit，不要用这个工具整文件重写。'
        '不要用 shell 的 echo/tee/sed/python 写文本。',
    parameterMode: ToolParameterMode.object,
    allowBackground: false,
    parameters: {
      'type': 'object',
      'properties': {
        'path': {
          'type': 'string',
          'description': 'guest 绝对路径，例如 $workHint/app.py',
        },
        'contents': {'type': 'string', 'description': '完整文件内容（UTF-8 文本）。'},
      },
      'required': ['path', 'contents'],
    },
    executable: (Map<String, dynamic> args) => _executeWrite(workspace, args),
  );
}

Future<AgentToolResult> _executeWrite(
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

  final rawContents = args['contents'];
  if (rawContents is! String) {
    return AgentToolResult(
      content: TextPart('error: contents 必须是字符串'),
      metadata: {'ok': false, 'path': path},
    );
  }

  final bytes = utf8.encode(rawContents);
  if (!looksLikeTextBytes(bytes)) {
    return AgentToolResult(
      content: TextPart('error: contents 不是文本（含空字节），write 只支持 UTF-8 文本。'),
      metadata: {'ok': false, 'path': path},
    );
  }

  final existed = await workspace.readGuestFile(path) != null;
  await workspace.writeGuestFile(path, bytes);
  final lines = rawContents.isEmpty ? 0 : rawContents.split('\n').length;
  final verb = existed ? '已覆盖' : '已写入';
  return AgentToolResult(
    content: TextPart('$verb $path（$lines 行，${bytes.length} 字节）。'),
    metadata: {
      'ok': true,
      'path': path,
      'created': !existed,
      'lineCount': lines,
      'byteCount': bytes.length,
    },
  );
}
