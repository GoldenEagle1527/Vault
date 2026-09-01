import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vault/agent/project_site_launcher.dart';
import 'package:vault/agent/project_store.dart';
import 'package:vault/agent/site_port.dart';
import 'package:vault/agent/site_supervisor.dart';
import 'package:vault/sandbox/sandbox_models.dart';

class _FakeWorkspace implements SandboxWorkspace {
  _FakeWorkspace(this._handler, {Map<String, List<int>>? files})
    : files = files ?? {};

  final Future<CommandResult> Function(String cmd) _handler;
  final List<String> commands = [];
  final Map<String, List<int>> files;

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
  Future<void> writeGuestFile(String guestAbsolutePath, List<int> bytes) async {
    files[guestAbsolutePath] = bytes;
  }

  @override
  Future<Uint8List?> readGuestFile(String guestAbsolutePath) async {
    final data = files[guestAbsolutePath];
    return data == null ? null : Uint8List.fromList(data);
  }

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
    expect(cmd, contains("'/root/projects/p1/vault_site_web.pid'"));
    expect(cmd, contains("'/root/projects/p1/vault_site_web.log'"));
    expect(cmd, contains(r'pid=$!'));
    // `cd ... && command & echo > relative.pid` backgrounds the `cd` list,
    // leaving the echo in the old cwd. Runtime files must use absolute paths.
    expect(cmd, isNot(contains("> 'vault_site_web.pid'")));
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

  test('start skips launch when supervisor already listening', () async {
    final ws = _FakeWorkspace((cmd) async {
      return const CommandResult(exitCode: 0, stdout: 'ok', stderr: '');
    });
    final supervisor = MemorySiteSupervisorClient();
    await supervisor.startSite(
      id: 'p1',
      cwd: '/root/projects/p1',
      cmd: 'python3 app.py',
    );
    final result = await ProjectSiteLauncher(
      ws,
      supervisor: supervisor,
    ).start(projectPath: 'p1', entry: _site, openInBrowser: false);
    expect(result.alreadyUp, isTrue);
    expect(result.startedProcess, isFalse);
    expect(ws.commands.where((c) => c.contains('kill_port')), isEmpty);
  });

  test('start fails when supervisor reports occupied port', () async {
    final ws = _FakeWorkspace((cmd) async {
      return const CommandResult(exitCode: 0, stdout: 'ok', stderr: '');
    });
    final supervisor = MemorySiteSupervisorClient()..occupied = true;
    final result = await ProjectSiteLauncher(
      ws,
      supervisor: supervisor,
    ).start(projectPath: 'p1', entry: _site, openInBrowser: false);
    expect(result.startedProcess, isFalse);
    expect(result.alreadyUp, isFalse);
    expect(result.message, contains('占用'));
  });

  test('start waits until supervisor reports listening', () async {
    final ws = _FakeWorkspace((cmd) async {
      return const CommandResult(exitCode: 0, stdout: 'ok', stderr: '');
    });
    final result = await ProjectSiteLauncher(
      ws,
      supervisor: MemorySiteSupervisorClient(),
    ).start(projectPath: 'p1', entry: _site, openInBrowser: false);
    expect(result.startedProcess, isTrue);
    expect(result.alreadyUp, isFalse);
    expect(result.message, '已后台启动');
  });

  test('start timeout does not mark ready and returns log tail', () async {
    final ws = _FakeWorkspace(
      (cmd) async {
        return const CommandResult(exitCode: 0, stdout: 'ok', stderr: '');
      },
      files: {
        '/root/projects/p1/vault_site_网站_8080.log': utf8.encode(
          'Traceback (most recent call last):\nImportError: no flask\n',
        ),
      },
    );
    final supervisor = MemorySiteSupervisorClient()..startFails = true;
    final result = await ProjectSiteLauncher(
      ws,
      supervisor: supervisor,
    ).start(projectPath: 'p1', entry: _site, openInBrowser: false);
    expect(result.startedProcess, isFalse);
    expect(result.alreadyUp, isFalse);
    expect(result.openedUrl, isFalse);
    expect(result.message, contains('启动超时'));
    expect(result.logTail, contains('ImportError: no flask'));
  });

  test('start maps supervisor throw to a message', () async {
    final ws = _FakeWorkspace((cmd) async {
      return const CommandResult(exitCode: 0, stdout: 'ok', stderr: '');
    });
    final supervisor = MemorySiteSupervisorClient()
      ..throwOnStart = StateError('无法启动站点看守');
    final result = await ProjectSiteLauncher(
      ws,
      supervisor: supervisor,
    ).start(projectPath: 'p1', entry: _site, openInBrowser: false);
    expect(result.startedProcess, isFalse);
    expect(result.message, contains('无法启动站点看守'));
  });

  test('allocateSitePort skips taken ports from 8765', () {
    expect(allocateSitePort(const []), 8765);
    expect(allocateSitePort(const [8765, 8766]), 8767);
  });

  test('trimLogTail keeps the last lines', () {
    final text = List.generate(5, (i) => 'L$i').join('\n');
    expect(trimLogTail(text, maxLines: 2), 'L3\nL4');
    expect(trimLogTail(text, maxLines: 10), text);
    expect(
      trimLogTail('line-a\nline-b\nline-c\n', maxLines: 2),
      'line-b\nline-c',
    );
  });

  test('stop reports terminated when supervisor exits the child', () async {
    final ws = _FakeWorkspace((cmd) async {
      return const CommandResult(exitCode: 0, stdout: 'ok', stderr: '');
    });
    final result = await ProjectSiteLauncher(
      ws,
      supervisor: MemorySiteSupervisorClient(),
    ).stop(projectPath: 'p1', entry: _site);
    expect(result.stopped, isTrue);
    expect(result.message, '已终止');
  });

  test('isProjectSiteUp requires supervisor listening, not pid alone', () async {
    final ws = _FakeWorkspace((cmd) async {
      if (cmd.contains('vault_site_own_pid')) {
        return const CommandResult(exitCode: 0, stdout: '1', stderr: '');
      }
      if (cmd.contains('/proc/net/tcp')) {
        return const CommandResult(exitCode: 0, stdout: '0', stderr: '');
      }
      return const CommandResult(exitCode: 0, stdout: '', stderr: '');
    });
    final supervisor = MemorySiteSupervisorClient();
    final down = await ProjectSiteLauncher(
      ws,
      supervisor: supervisor,
    ).isProjectSiteUp(projectPath: 'p1', entry: _site);
    expect(down, isFalse);

    await supervisor.startSite(
      id: 'p1',
      cwd: '/x',
      cmd: 'python3 app.py',
    );
    final up = await ProjectSiteLauncher(
      ws,
      supervisor: supervisor,
    ).isProjectSiteUp(projectPath: 'p1', entry: _site);
    expect(up, isTrue);
  });
}
