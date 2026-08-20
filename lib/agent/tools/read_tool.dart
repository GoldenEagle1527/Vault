import 'dart:convert';
import 'dart:typed_data';

import 'package:vault/agent/image_prepare.dart';
import 'package:vault/sandbox/guest_media_kind.dart';
import 'package:vault/sandbox/sandbox_models.dart';
import 'package:vault_agent_core/vault_agent_core.dart';

const String kReadToolName = 'read';

const int kReadDefaultMaxChars = 100000;
const int kReadDefaultMaxLines = 2000;

/// Read a guest text or image file. Images persist as a path; the request hook
/// hydrates pixels when the model is called.
Tool createReadTool(SandboxWorkspace workspace, {String? projectPath}) {
  final inboxHint = projectPath == null
      ? kGuestInboxDir
      : guestProjectInboxDir(projectPath);

  return Tool(
    name: kReadToolName,
    description:
        '读取沙箱内的文本文件（代码、配置、日志等）或图片。'
        '文本返回带行号的内容；大文件请用 offset/limit 分页。'
        '图片只返回路径说明（对话里已出现的图会自动带给模型，不必再读）。'
        '路径必须是 $kGuestHome 下的绝对路径。用户附件在 $inboxHint/。'
        '不要用这个工具读视频、音频或其它二进制。',
    parameterMode: ToolParameterMode.object,
    allowBackground: false,
    parameters: {
      'type': 'object',
      'properties': {
        'path': {
          'type': 'string',
          'description': 'guest 绝对路径，例如 $inboxHint/notes.md',
        },
        'offset': {
          'type': 'integer',
          'description': '文本起始行（1-based）。默认从第 1 行。',
        },
        'limit': {
          'type': 'integer',
          'description': '最多返回多少行。默认 $kReadDefaultMaxLines。',
        },
      },
      'required': ['path'],
    },
    executable: (Map<String, dynamic> args) => _executeRead(workspace, args),
  );
}

Future<AgentToolResult> _executeRead(
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

  final bytes = await workspace.readGuestFile(path);
  if (bytes == null) {
    return AgentToolResult(
      content: TextPart('error: 文件不存在或无法读取：$path'),
      metadata: {'ok': false, 'path': path},
    );
  }

  final kind = guestMediaKindForPath(path);
  if (kind == GuestMediaKind.image) {
    return _readImage(path, bytes);
  }
  if (kind == GuestMediaKind.video || kind == GuestMediaKind.audio) {
    return AgentToolResult(
      content: TextPart(
        'error: $path 是${kind.name}，read 只支持文本和图片。请用 shell 处理。',
      ),
      metadata: {'ok': false, 'path': path, 'kind': kind.name},
    );
  }
  if (kind == GuestMediaKind.binary && !looksLikeTextBytes(bytes)) {
    return AgentToolResult(
      content: TextPart('error: $path 不是文本或图片，请用 shell 处理。'),
      metadata: {'ok': false, 'path': path, 'kind': 'binary'},
    );
  }

  final offset = _asPositiveInt(args['offset']) ?? 1;
  final limit = _asPositiveInt(args['limit']) ?? kReadDefaultMaxLines;
  return _readText(path, bytes, offset: offset, limit: limit);
}

AgentToolResult _readImage(String path, List<int> bytes) {
  try {
    final prepared = prepareImageForModel(
      bytes is Uint8List ? bytes : Uint8List.fromList(bytes),
      hintExtension: path,
    );
    final mime = imageMimeTypeForPath(path) ?? prepared.mimeType;
    return AgentToolResult(
      content: TextPart(
        '已读取图片 $path（$mime，${prepared.bytes.length} 字节'
        '${prepared.compressed ? '，已压缩' : ''}）。'
        '模型请求时会自动附上此图。',
      ),
      metadata: {
        'ok': true,
        'path': path,
        'kind': 'image',
        'imagePath': path,
        'mimeType': mime,
      },
    );
  } on ImageTooLargeException catch (e) {
    return AgentToolResult(
      content: TextPart('error: $path ${e.message}'),
      metadata: {'ok': false, 'path': path, 'kind': 'image'},
    );
  } on FormatException catch (e) {
    return AgentToolResult(
      content: TextPart('error: 无法解码图片 $path（$e）'),
      metadata: {'ok': false, 'path': path, 'kind': 'image'},
    );
  }
}

AgentToolResult _readText(
  String path,
  List<int> bytes, {
  required int offset,
  required int limit,
}) {
  final text = utf8.decode(bytes, allowMalformed: true);
  final lines = text.split('\n');
  final start = offset < 1 ? 1 : offset;
  if (start > lines.length) {
    return AgentToolResult(
      content: TextPart('已读取 $path：共 ${lines.length} 行，offset=$start 超出范围。'),
      metadata: {
        'ok': true,
        'path': path,
        'kind': 'text',
        'lineCount': lines.length,
      },
    );
  }

  final end = (start - 1 + limit) > lines.length
      ? lines.length
      : (start - 1 + limit);
  final slice = lines.sublist(start - 1, end);
  final buf = StringBuffer();
  buf.writeln('文件 $path （第 $start–$end 行 / 共 ${lines.length} 行）');
  for (var i = 0; i < slice.length; i++) {
    final n = start + i;
    buf.writeln('${n.toString().padLeft(6)}|${slice[i]}');
  }
  var body = buf.toString();
  if (body.length > kReadDefaultMaxChars) {
    body =
        '${body.substring(0, kReadDefaultMaxChars)}\n…（截断，请用更小的 limit 或更大的 offset 继续读）';
  } else if (end < lines.length) {
    body += '…还有 ${lines.length - end} 行，用 offset=${end + 1} 继续。\n';
  }

  return AgentToolResult(
    content: TextPart(body),
    metadata: {
      'ok': true,
      'path': path,
      'kind': 'text',
      'lineCount': lines.length,
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
