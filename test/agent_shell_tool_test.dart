import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vault/agent/tools/shell_tool.dart';
import 'package:vault/sandbox/sandbox_models.dart';

class _FakeSession implements SandboxSession {
  _FakeSession(this._handler);

  final Future<CommandResult> Function(String cmd) _handler;

  @override
  String get sessionId => 'test';

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
  Future<CommandResult> run(String cmd) => _handler(cmd);

  @override
  Future<void> writeGuestFile(String guestAbsolutePath, List<int> bytes) async {}

  @override
  Future<void> dispose() async {}
}

void main() {
  test('shell tool returns exitCode/stdout/stderr json', () async {
    final session = _FakeSession((cmd) async {
      expect(cmd, 'echo hi');
      return const CommandResult(exitCode: 0, stdout: 'hi\n', stderr: '');
    });
    final tool = createShellTool(session);
    final raw = await tool.executable!(<String, dynamic>{'command': 'echo hi'});
    final map = jsonDecode(raw as String) as Map<String, dynamic>;
    expect(map['ok'], isTrue);
    expect(map['exitCode'], 0);
    expect(map['stdout'], 'hi\n');
  });

  test('shell tool maps timeout to Chinese error payload', () async {
    final session = _FakeSession((cmd) async {
      await Future<void>.delayed(const Duration(seconds: 2));
      return const CommandResult(exitCode: 0, stdout: '', stderr: '');
    });
    final tool = createShellTool(
      session,
      timeout: const Duration(milliseconds: 50),
    );
    final raw = await tool.executable!(<String, dynamic>{'command': 'sleep'});
    final map = jsonDecode(raw as String) as Map<String, dynamic>;
    expect(map['ok'], isFalse);
    expect(map['error'], '命令超时');
  });

  test('empty command rejected', () async {
    final session = _FakeSession((_) async {
      fail('should not run');
    });
    final tool = createShellTool(session);
    final raw = await tool.executable!(<String, dynamic>{'command': '  '});
    final map = jsonDecode(raw as String) as Map<String, dynamic>;
    expect(map['ok'], isFalse);
    expect(map['error'], '命令为空');
  });
}
