import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vault/agent/project_site_launcher.dart';
import 'package:vault/agent/project_store.dart';
import 'package:vault/sandbox/sandbox_models.dart';

class _FakeWorkspace implements SandboxWorkspace {
  _FakeWorkspace(this._handler);

  final Future<CommandResult> Function(String cmd) _handler;
  final List<String> commands = [];

  @override
  String get workspaceId => 'test';

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
  }) async {
    commands.add(cmd);
    return _handler(cmd);
  }

  @override
  Future<void> writeGuestFile(
    String guestAbsolutePath,
    List<int> bytes,
  ) async {}

  @override
  Future<void> dispose() async {}
}

const _site = ProjectUrlEntry(
  name: '网站',
  url: 'http://127.0.0.1:8080/',
  startCommand: 'python3 -m http.server 8080 --bind 127.0.0.1',
);

void main() {
  test('portFromSiteUrl reads explicit and default ports', () {
    expect(portFromSiteUrl('http://127.0.0.1:8080/'), 8080);
    expect(portFromSiteUrl('http://127.0.0.1/'), 80);
    expect(portFromSiteUrl('https://example.com/app'), 443);
    expect(portFromSiteUrl('not a url'), isNull);
  });

  test('isHttpServiceResponding treats any HTTP answer as up', () {
    expect(isHttpServiceResponding('200'), isTrue);
    expect(isHttpServiceResponding('301'), isTrue);
    expect(isHttpServiceResponding('404'), isTrue);
    expect(isHttpServiceResponding('500'), isTrue);
    expect(isHttpServiceResponding('0'), isFalse);
    expect(isHttpServiceResponding('000'), isFalse);
    expect(isHttpServiceResponding(''), isFalse);
  });

  test('siteRuntimeStem keeps CJK and includes port', () {
    expect(
      siteRuntimeStem('网站', url: 'http://127.0.0.1:8080/'),
      'vault_site_网站_8080',
    );
    expect(siteRuntimeStem('API'), 'vault_site_API');
  });

  test('siteStartShellCommand writes pid file', () {
    final cmd = siteStartShellCommand(
      projectDir: '/root/projects/p1',
      startCmd: 'python3 -m http.server 8080 --bind 127.0.0.1',
      logFileName: 'vault_site_web.log',
      pidFileName: 'vault_site_web.pid',
    );
    expect(cmd, contains('nohup sh -c'));
    expect(cmd, contains('vault_site_web.pid'));
    expect(cmd, contains(r'echo $!'));
  });

  test('siteStopShellCommand kills pid file and port', () {
    final cmd = siteStopShellCommand(
      projectDir: '/root/projects/p1',
      pidFileName: 'vault_site_web.pid',
      port: 8080,
    );
    expect(cmd, contains('vault_site_web.pid'));
    expect(cmd, contains('port=8080'));
    expect(cmd, contains('kill_port TERM'));
    expect(cmd, contains('kill_port KILL'));
  });

  test('siteProbeShellCommand checks /proc ports, not python', () {
    final cmd = siteProbeShellCommand(const [
      'http://127.0.0.1:8080/',
      'http://127.0.0.1:9000/',
    ]);
    expect(cmd, contains('/proc/net/tcp'));
    expect(cmd, contains('8080'));
    expect(cmd, contains('9000'));
    expect(cmd, contains('"0A"'));
    expect(cmd, isNot(contains('python')));
  });

  test('probeAll maps HTTP codes to running flags', () async {
    final ws = _FakeWorkspace((cmd) async {
      expect(cmd, contains('/proc/net/tcp'));
      return const CommandResult(exitCode: 0, stdout: '200 0', stderr: '');
    });
    final map = await ProjectSiteLauncher(ws).probeAll(const [
      _site,
      ProjectUrlEntry(name: 'API', url: 'http://127.0.0.1:9000/'),
    ]);
    expect(map['网站'], isTrue);
    expect(map['API'], isFalse);
  });

  test('start skips launch when probe says already up', () async {
    final ws = _FakeWorkspace((cmd) async {
      return const CommandResult(exitCode: 0, stdout: '200', stderr: '');
    });
    final result = await ProjectSiteLauncher(
      ws,
    ).start(projectPath: 'p1', entry: _site, openInBrowser: false);
    expect(result.alreadyUp, isTrue);
    expect(result.startedProcess, isFalse);
    expect(ws.commands.where((c) => c.contains('nohup')), isEmpty);
  });

  test('start writes pid when down without a second probe', () async {
    var probes = 0;
    final ws = _FakeWorkspace((cmd) async {
      if (cmd.contains('/proc/net/tcp')) {
        probes += 1;
        return const CommandResult(exitCode: 0, stdout: '0', stderr: '');
      }
      expect(cmd, contains('nohup'));
      expect(cmd, contains('.pid'));
      return const CommandResult(exitCode: 0, stdout: '4242', stderr: '');
    });
    final result = await ProjectSiteLauncher(
      ws,
    ).start(projectPath: 'p1', entry: _site, openInBrowser: false);
    expect(result.startedProcess, isTrue);
    expect(result.alreadyUp, isFalse);
    expect(result.message, '已后台启动');
    expect(probes, 1);
  });

  test('stop re-probes and reports still running', () async {
    final ws = _FakeWorkspace((cmd) async {
      if (cmd.contains('/proc/net/tcp')) {
        return const CommandResult(exitCode: 0, stdout: '200', stderr: '');
      }
      expect(cmd, contains('kill_port'));
      return const CommandResult(exitCode: 0, stdout: 'ok', stderr: '');
    });
    final result = await ProjectSiteLauncher(
      ws,
    ).stop(projectPath: 'p1', entry: _site);
    expect(result.stopped, isFalse);
    expect(result.message, contains('仍在响应'));
  });

  test('stop reports terminated when probe goes down', () async {
    final ws = _FakeWorkspace((cmd) async {
      if (cmd.contains('/proc/net/tcp')) {
        return const CommandResult(exitCode: 0, stdout: '0', stderr: '');
      }
      return const CommandResult(exitCode: 0, stdout: 'ok', stderr: '');
    });
    final result = await ProjectSiteLauncher(
      ws,
    ).stop(projectPath: 'p1', entry: _site);
    expect(result.stopped, isTrue);
    expect(result.message, '已终止');
  });
}
