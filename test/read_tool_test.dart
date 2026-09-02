import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:vault/agent/tools/read_tool.dart';
import 'package:vault/sandbox/sandbox_models.dart';
import 'package:vault_agent_core/vault_agent_core.dart';

class _MemoryWorkspace implements SandboxWorkspace {
  _MemoryWorkspace([Map<String, List<int>>? seed])
    : files = {
        for (final e in (seed ?? const {}).entries)
          e.key: Uint8List.fromList(e.value),
      };

  final Map<String, Uint8List> files;

  @override
  String get workspaceId => 'read-test';

  @override
  Stream<Uint8List> get output => const Stream.empty();

  @override
  void write(String data) {}

  @override
  void writeBytes(Uint8List data) {}

  @override
  void resize(int cols, int rows) {}

  @override
  Future<int> get exitCode => Future.value(0);

  @override
  Future<CommandResult> run(
    String cmd, {
    Map<String, String>? environment,
    Duration? timeout,
  }) async => const CommandResult(exitCode: 0, stdout: '', stderr: '');

  @override
  Future<void> writeGuestFile(String guestAbsolutePath, List<int> bytes) async {
    files[assertGuestPathUnderHome(guestAbsolutePath)] = Uint8List.fromList(
      bytes,
    );
  }

  @override
  Future<Uint8List?> readGuestFile(String guestAbsolutePath) async {
    return files[assertGuestPathUnderHome(guestAbsolutePath)];
  }

  @override
  Future<List<GuestFsEntry>> listGuestDirectory(
    String guestAbsolutePath,
  ) async => const [];

  @override
  Future<void> dispose() async {}
}

Future<AgentToolResult> _read(
  SandboxWorkspace workspace,
  Map<String, dynamic> args,
) async {
  final tool = createReadTool(workspace, projectPath: 'p1');
  return await tool.executable!(args) as AgentToolResult;
}

String _text(AgentToolResult result) {
  final part = result.content;
  if (part is TextPart) return part.text;
  return result.contents?.whereType<TextPart>().map((p) => p.text).join() ?? '';
}

Uint8List _png({int w = 8, int h = 8}) {
  final image = img.Image(width: w, height: h);
  img.fill(image, color: img.ColorRgb8(10, 20, 30));
  return Uint8List.fromList(img.encodePng(image));
}

void main() {
  test('read slices text with 1-based line numbers', () async {
    final body = List.generate(8, (i) => 'line-${i + 1}').join('\n');
    final ws = _MemoryWorkspace({
      '/root/projects/p1/notes.md': utf8.encode(body),
    });
    final result = await _read(ws, {
      'path': '/root/projects/p1/notes.md',
      'offset': 3,
      'limit': 2,
    });
    final text = _text(result);
    expect(result.metadata?['ok'], isTrue);
    expect(text, contains('第 3–4 行'));
    expect(text, contains('     3|line-3'));
    expect(text, contains('     4|line-4'));
    expect(text, isNot(contains('line-2')));
    expect(text, contains('offset=5'));
  });

  test('read rejects path escape', () async {
    final result = await _read(_MemoryWorkspace(), {'path': '/etc/passwd'});
    expect(result.metadata?['ok'], isFalse);
    expect(_text(result), contains('非法路径'));
  });

  test('read rejects missing file', () async {
    final result = await _read(_MemoryWorkspace(), {
      'path': '/root/projects/p1/missing.txt',
    });
    expect(result.metadata?['ok'], isFalse);
    expect(_text(result), contains('不存在'));
  });

  test('read rejects binary', () async {
    final ws = _MemoryWorkspace({
      '/root/projects/p1/blob.bin': [0, 1, 2, 0, 9],
    });
    final result = await _read(ws, {'path': '/root/projects/p1/blob.bin'});
    expect(result.metadata?['ok'], isFalse);
    expect(_text(result), contains('不是文本或图片'));
  });

  test('read image returns path metadata without ImagePart', () async {
    final ws = _MemoryWorkspace({'/root/projects/p1/inbox/shot.png': _png()});
    final result = await _read(ws, {
      'path': '/root/projects/p1/inbox/shot.png',
    });
    expect(result.metadata?['ok'], isTrue);
    expect(result.metadata?['imagePath'], '/root/projects/p1/inbox/shot.png');
    expect(result.content, isA<TextPart>());
    expect(result.contents, isNull);
    expect(_text(result), contains('已读取图片'));
  });
}
