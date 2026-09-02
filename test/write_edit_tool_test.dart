import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vault/agent/tools/edit_tool.dart';
import 'package:vault/agent/tools/write_tool.dart';
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
  String get workspaceId => 'write-edit-test';

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

Future<AgentToolResult> _write(
  SandboxWorkspace workspace,
  Map<String, dynamic> args,
) async {
  final tool = createWriteTool(workspace, projectPath: 'p1');
  return await tool.executable!(args) as AgentToolResult;
}

Future<AgentToolResult> _edit(
  SandboxWorkspace workspace,
  Map<String, dynamic> args,
) async {
  final tool = createEditTool(workspace, projectPath: 'p1');
  return await tool.executable!(args) as AgentToolResult;
}

String _text(AgentToolResult result) {
  final part = result.content;
  if (part is TextPart) return part.text;
  return result.contents?.whereType<TextPart>().map((p) => p.text).join() ?? '';
}

void main() {
  test('write creates a new text file', () async {
    final ws = _MemoryWorkspace();
    final result = await _write(ws, {
      'path': '/root/projects/p1/app.py',
      'contents': 'print("hi")\n',
    });
    expect(result.metadata?['ok'], isTrue);
    expect(result.metadata?['created'], isTrue);
    expect(result.metadata?['lineCount'], 2);
    expect(_text(result), contains('已写入'));
    expect(utf8.decode(ws.files['/root/projects/p1/app.py']!), 'print("hi")\n');
  });

  test('write overwrites an existing file', () async {
    final ws = _MemoryWorkspace({
      '/root/projects/p1/app.py': utf8.encode('old'),
    });
    final result = await _write(ws, {
      'path': '/root/projects/p1/app.py',
      'contents': 'new',
    });
    expect(result.metadata?['ok'], isTrue);
    expect(result.metadata?['created'], isFalse);
    expect(_text(result), contains('已覆盖'));
    expect(utf8.decode(ws.files['/root/projects/p1/app.py']!), 'new');
  });

  test('write rejects empty path', () async {
    final result = await _write(_MemoryWorkspace(), {
      'path': '  ',
      'contents': 'x',
    });
    expect(result.metadata?['ok'], isFalse);
    expect(_text(result), contains('path 不能为空'));
  });

  test('write rejects path escape', () async {
    final result = await _write(_MemoryWorkspace(), {
      'path': '/etc/passwd',
      'contents': 'x',
    });
    expect(result.metadata?['ok'], isFalse);
    expect(_text(result), contains('非法路径'));
  });

  test('write rejects NUL bytes', () async {
    final result = await _write(_MemoryWorkspace(), {
      'path': '/root/projects/p1/a.txt',
      'contents': 'a\u0000b',
    });
    expect(result.metadata?['ok'], isFalse);
    expect(_text(result), contains('不是文本'));
  });

  test('edit replaces a unique occurrence', () async {
    final ws = _MemoryWorkspace({
      '/root/projects/p1/app.py': utf8.encode('alpha\nbeta\nalpha2\n'),
    });
    final result = await _edit(ws, {
      'path': '/root/projects/p1/app.py',
      'old_string': 'beta',
      'new_string': 'gamma',
    });
    expect(result.metadata?['ok'], isTrue);
    expect(result.metadata?['replacements'], 1);
    expect(_text(result), contains('替换 1 处'));
    expect(
      utf8.decode(ws.files['/root/projects/p1/app.py']!),
      'alpha\ngamma\nalpha2\n',
    );
  });

  test('edit fails when old_string is missing', () async {
    final ws = _MemoryWorkspace({
      '/root/projects/p1/app.py': utf8.encode('alpha\n'),
    });
    final result = await _edit(ws, {
      'path': '/root/projects/p1/app.py',
      'old_string': 'beta',
      'new_string': 'gamma',
    });
    expect(result.metadata?['ok'], isFalse);
    expect(result.metadata?['matches'], 0);
    expect(_text(result), contains('找不到'));
  });

  test('edit fails when old_string appears more than once', () async {
    final ws = _MemoryWorkspace({
      '/root/projects/p1/app.py': utf8.encode('foo\nfoo\n'),
    });
    final result = await _edit(ws, {
      'path': '/root/projects/p1/app.py',
      'old_string': 'foo',
      'new_string': 'bar',
    });
    expect(result.metadata?['ok'], isFalse);
    expect(result.metadata?['matches'], 2);
    expect(_text(result), contains('出现了 2 处'));
    expect(utf8.decode(ws.files['/root/projects/p1/app.py']!), 'foo\nfoo\n');
  });

  test('edit replace_all replaces every match', () async {
    final ws = _MemoryWorkspace({
      '/root/projects/p1/app.py': utf8.encode('foo\nfoo\n'),
    });
    final result = await _edit(ws, {
      'path': '/root/projects/p1/app.py',
      'old_string': 'foo',
      'new_string': 'bar',
      'replace_all': true,
    });
    expect(result.metadata?['ok'], isTrue);
    expect(result.metadata?['replacements'], 2);
    expect(utf8.decode(ws.files['/root/projects/p1/app.py']!), 'bar\nbar\n');
  });

  test('edit rejects identical old and new strings', () async {
    final ws = _MemoryWorkspace({
      '/root/projects/p1/app.py': utf8.encode('foo\n'),
    });
    final result = await _edit(ws, {
      'path': '/root/projects/p1/app.py',
      'old_string': 'foo',
      'new_string': 'foo',
    });
    expect(result.metadata?['ok'], isFalse);
    expect(_text(result), contains('相同'));
  });
}
