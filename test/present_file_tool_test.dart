import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vault/agent/present_file.dart';
import 'package:vault/agent/tools/present_file_tool.dart';
import 'package:vault/sandbox/guest_media_kind.dart';
import 'package:vault/sandbox/sandbox_models.dart';
import 'package:vault_agent_core/vault_agent_core.dart';

class _MemoryWorkspace implements SandboxWorkspace {
  _MemoryWorkspace({Map<String, List<int>>? files, Set<String>? directories})
    : files = {
        for (final e in (files ?? const {}).entries)
          e.key: Uint8List.fromList(e.value),
      },
      directories = {...?directories};

  final Map<String, Uint8List> files;
  final Set<String> directories;

  @override
  String get workspaceId => 'present-test';

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

  String? _quotedPath(String cmd) {
    final match = RegExp(r"'([^']+)'").firstMatch(cmd);
    return match?.group(1);
  }

  @override
  Future<CommandResult> run(
    String cmd, {
    Map<String, String>? environment,
    Duration? timeout,
  }) async {
    final path = _quotedPath(cmd) ?? '';
    if (cmd.contains('echo dir')) {
      if (directories.contains(path)) {
        return const CommandResult(exitCode: 0, stdout: 'dir\n', stderr: '');
      }
      if (files.containsKey(path)) {
        return const CommandResult(exitCode: 0, stdout: 'file\n', stderr: '');
      }
      return const CommandResult(exitCode: 0, stdout: 'missing\n', stderr: '');
    }
    if (cmd.contains('wc -c')) {
      final bytes = files[path];
      if (bytes == null) {
        return const CommandResult(exitCode: 1, stdout: '', stderr: '');
      }
      return CommandResult(
        exitCode: 0,
        stdout: '${bytes.length}\n',
        stderr: '',
      );
    }
    return const CommandResult(exitCode: 1, stdout: '', stderr: 'unhandled');
  }

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
  Future<void> dispose() async {}
}

Future<AgentToolResult> _present(
  SandboxWorkspace workspace,
  Map<String, dynamic> args,
) async {
  final tool = createPresentFileTool(workspace);
  return await tool.executable!(args) as AgentToolResult;
}

String _text(AgentToolResult result) {
  final part = result.content;
  if (part is TextPart) return part.text;
  return result.contents?.whereType<TextPart>().map((p) => p.text).join() ?? '';
}

void main() {
  test('present_file succeeds for a file under /root', () async {
    final workspace = _MemoryWorkspace(
      files: {'/root/out.csv': utf8.encode('a,b\n1,2\n')},
    );
    final result = await _present(workspace, {
      'path': '/root/out.csv',
      'title': '表格',
    });
    expect(_text(result), contains('已展示文件 /root/out.csv'));
    expect(result.metadata?['present_file'], isTrue);
    expect(result.metadata?['ok'], isTrue);
    expect(result.metadata?['guestPath'], '/root/out.csv');
    expect(result.metadata?['displayName'], '表格');
    expect(result.metadata?['kind'], GuestMediaKind.text.name);
    expect(result.metadata?['size'], 8);

    final attachment = presentFileAttachmentFromResult(
      metadata: result.metadata,
      resultText: _text(result),
    );
    expect(attachment, isNotNull);
    expect(attachment!.guestPath, '/root/out.csv');
    expect(attachment.displayName, '表格');
    expect(attachment.kind, GuestMediaKind.text);
  });

  test('present_file rejects /etc', () async {
    final result = await _present(_MemoryWorkspace(), {'path': '/etc/passwd'});
    expect(_text(result), startsWith('error:'));
    expect(result.metadata?['present_file'], isFalse);
    expect(result.metadata?['ok'], isFalse);
    expect(
      presentFileAttachmentFromResult(
        metadata: result.metadata,
        resultText: _text(result),
      ),
      isNull,
    );
  });

  test('present_file errors when the file is missing', () async {
    final result = await _present(_MemoryWorkspace(), {
      'path': '/root/missing.txt',
    });
    expect(_text(result), contains('文件不存在'));
    expect(result.metadata?['present_file'], isFalse);
    expect(
      presentFileAttachmentFromResult(
        metadata: result.metadata,
        resultText: _text(result),
      ),
      isNull,
    );
  });

  test('present_file rejects a directory', () async {
    final result = await _present(
      _MemoryWorkspace(directories: {'/root/docs'}),
      {'path': '/root/docs'},
    );
    expect(_text(result), contains('是目录'));
    expect(result.metadata?['present_file'], isFalse);
  });
}
