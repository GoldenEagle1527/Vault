import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vault/agent/tools/glob_tool.dart';
import 'package:vault/agent/tools/grep_tool.dart';
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
  String get workspaceId => 'grep-glob-test';

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
  ) async {
    final dir = assertGuestPathUnderHome(guestAbsolutePath);
    final prefix = '$dir/';
    final children = <String, bool>{};
    for (final path in files.keys) {
      if (!path.startsWith(prefix)) continue;
      final rest = path.substring(prefix.length);
      if (rest.isEmpty) continue;
      final slash = rest.indexOf('/');
      if (slash < 0) {
        children[rest] = false;
      } else {
        children[rest.substring(0, slash)] = true;
      }
    }
    if (children.isEmpty && !_isKnownDir(dir)) {
      throw StateError('目录不存在：$dir');
    }
    final entries = [
      for (final e in children.entries)
        GuestFsEntry(
          name: e.key,
          guestPath: '$dir/${e.key}',
          isDirectory: e.value,
        ),
    ];
    sortGuestFsEntries(entries);
    return entries;
  }

  bool _isKnownDir(String dir) {
    final prefix = '$dir/';
    return files.keys.any((p) => p.startsWith(prefix));
  }

  @override
  Future<void> dispose() async {}
}

Future<AgentToolResult> _glob(
  SandboxWorkspace workspace,
  Map<String, dynamic> args,
) async {
  final tool = createGlobTool(workspace, projectPath: 'p1');
  return await tool.executable!(args) as AgentToolResult;
}

Future<AgentToolResult> _grep(
  SandboxWorkspace workspace,
  Map<String, dynamic> args,
) async {
  final tool = createGrepTool(workspace, projectPath: 'p1');
  return await tool.executable!(args) as AgentToolResult;
}

String _text(AgentToolResult result) {
  final part = result.content;
  if (part is TextPart) return part.text;
  return result.contents?.whereType<TextPart>().map((p) => p.text).join() ?? '';
}

_MemoryWorkspace _projectTree() {
  return _MemoryWorkspace({
    '/root/projects/p1/app.py': utf8.encode('def index():\n    return "ok"\n'),
    '/root/projects/p1/modules/user.py': utf8.encode('class User:\n    pass\n'),
    '/root/projects/p1/templates/home.html': utf8.encode('<h1>Hello</h1>\n'),
    '/root/projects/p1/.git/HEAD': utf8.encode('ref: refs/heads/main\n'),
    '/root/projects/p1/__pycache__/app.cpython-312.pyc': [0, 1, 2, 0],
    '/root/projects/p1/static/note.txt': utf8.encode('Index page helper\n'),
  });
}

void main() {
  test('glob lists *.py including subdirectories', () async {
    final result = await _glob(_projectTree(), {'glob_pattern': '*.py'});
    expect(result.metadata?['ok'], isTrue);
    expect(result.metadata?['matchCount'], 2);
    expect(_text(result), contains('/root/projects/p1/app.py'));
    expect(_text(result), contains('/root/projects/p1/modules/user.py'));
    expect(_text(result), isNot(contains('home.html')));
  });

  test('glob matches files in a subdirectory pattern', () async {
    final result = await _glob(_projectTree(), {
      'glob_pattern': 'templates/*.html',
    });
    expect(result.metadata?['ok'], isTrue);
    expect(_text(result), contains('/root/projects/p1/templates/home.html'));
    expect(_text(result), isNot(contains('app.py')));
  });

  test('glob respects head_limit', () async {
    final result = await _glob(_projectTree(), {
      'glob_pattern': '*',
      'head_limit': 1,
    });
    expect(result.metadata?['ok'], isTrue);
    expect(result.metadata?['matchCount'], 1);
    expect(result.metadata?['truncated'], isTrue);
    expect(result.metadata?['totalCount'], greaterThan(1));
  });

  test('glob skips .git', () async {
    final result = await _glob(_projectTree(), {'glob_pattern': 'HEAD'});
    expect(_text(result), isNot(contains('/.git/')));
  });

  test('grep returns path:line:snippet', () async {
    final result = await _grep(_projectTree(), {'pattern': 'class User'});
    expect(result.metadata?['ok'], isTrue);
    expect(result.metadata?['matchCount'], 1);
    expect(
      _text(result),
      contains('/root/projects/p1/modules/user.py:1:class User:'),
    );
  });

  test('grep case_insensitive matches', () async {
    final result = await _grep(_projectTree(), {
      'pattern': 'INDEX',
      'case_insensitive': true,
    });
    expect(result.metadata?['ok'], isTrue);
    expect(result.metadata?['matchCount'], 2);
    expect(_text(result), contains('app.py:1:def index():'));
    expect(_text(result), contains('static/note.txt:1:Index page helper'));
  });

  test('grep glob narrows files', () async {
    final result = await _grep(_projectTree(), {
      'pattern': 'index',
      'glob': '*.py',
      'case_insensitive': true,
    });
    expect(result.metadata?['ok'], isTrue);
    expect(result.metadata?['matchCount'], 1);
    expect(_text(result), contains('app.py'));
    expect(_text(result), isNot(contains('note.txt')));
  });

  test('grep skips .git and binary cache', () async {
    final result = await _grep(_projectTree(), {'pattern': 'ref:|cpython'});
    expect(_text(result), isNot(contains('/.git/')));
    expect(_text(result), isNot(contains('__pycache__')));
  });

  test('grep rejects invalid regex', () async {
    final result = await _grep(_projectTree(), {'pattern': '('});
    expect(result.metadata?['ok'], isFalse);
    expect(_text(result), contains('无效正则'));
  });
}
