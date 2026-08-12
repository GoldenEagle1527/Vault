import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vault/agent/tools/shell_job.dart';
import 'package:vault/agent/tools/shell_tool.dart';
import 'package:vault/sandbox/sandbox_models.dart';

class _FakeWorkspace implements SandboxWorkspace {
  _FakeWorkspace(this._handler);

  final Future<CommandResult> Function(
    String cmd, {
    Map<String, String>? environment,
    Duration? timeout,
  })
  _handler;

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
  }) =>
      _handler(cmd, environment: environment, timeout: timeout);

  @override
  Future<void> writeGuestFile(
    String guestAbsolutePath,
    List<int> bytes,
  ) async {}

  @override
  Future<void> dispose() async {}
}

/// Simulates guest detached jobs: start returns pid, poll becomes DONE after [delay].
class _DetachedJobWorkspace implements SandboxWorkspace {
  _DetachedJobWorkspace({this.delay = const Duration(milliseconds: 80)});

  final Duration delay;
  final Map<String, DateTime> _started = {};
  final List<String> commands = [];
  int inFlight = 0;
  int maxInFlight = 0;

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
    inFlight++;
    if (inFlight > maxInFlight) maxInFlight = inFlight;
    try {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      if (cmd.contains('printf') && cmd.contains('_pid') && cmd.contains('&')) {
        final match = RegExp(r'vault-shell-jobs/([A-Za-z0-9]+)').firstMatch(cmd);
        final jobId = match?.group(1) ?? 'unknown';
        _started[jobId] = DateTime.now();
        return CommandResult(exitCode: 0, stdout: '99\n', stderr: '');
      }
      if (cmd.contains(kShellJobDoneMarker) ||
          cmd.contains(kShellJobRunningMarker)) {
        final match = RegExp(r'vault-shell-jobs/([A-Za-z0-9]+)').firstMatch(cmd);
        final jobId = match?.group(1) ?? '';
        final started = _started[jobId];
        if (started != null &&
            DateTime.now().difference(started) >= delay) {
          return CommandResult(
            exitCode: 0,
            stdout: '$kShellJobDoneMarker\n0\n$kShellJobOutMarker\nok-$jobId\n'
                '$kShellJobEndMarker\n',
            stderr: '',
          );
        }
        return CommandResult(
          exitCode: 0,
          stdout: '$kShellJobRunningMarker\n99\n$kShellJobOutMarker\n'
              'still-running\n$kShellJobEndMarker\n',
          stderr: '',
        );
      }
      if (cmd.contains('kill')) {
        return const CommandResult(exitCode: 0, stdout: '', stderr: '');
      }
      return CommandResult(
        exitCode: -1,
        stdout: '',
        stderr: 'unexpected cmd: $cmd',
      );
    } finally {
      inFlight--;
    }
  }

  @override
  Future<void> writeGuestFile(
    String guestAbsolutePath,
    List<int> bytes,
  ) async {}

  @override
  Future<void> dispose() async {}
}

void main() {
  test('default shell timeout exceeds agent background threshold', () {
    expect(
      kDefaultShellToolTimeout,
      greaterThan(kAgentToolBackgroundAfter),
    );
    expect(kAgentToolBackgroundAfter, const Duration(minutes: 1));
  });

  test('parseShellJobPollStdout handles done and running', () {
    final done = parseShellJobPollStdout(
      '$kShellJobDoneMarker\n0\n$kShellJobOutMarker\nhello\n'
      '$kShellJobEndMarker\n',
    );
    expect(done.done, isTrue);
    expect(done.exitCode, 0);
    expect(done.output, 'hello');

    final running = parseShellJobPollStdout(
      '$kShellJobRunningMarker\n42\n$kShellJobOutMarker\npartial\n'
      '$kShellJobEndMarker\n',
    );
    expect(running.done, isFalse);
    expect(running.pid, '42');
    expect(running.output, 'partial');
  });

  test('findNotifyMatch finds pattern after scanned offset', () {
    final hit = findNotifyMatch(
      output: 'aaa Listening on :8080 bbb',
      pattern: RegExp('Listening on'),
      alreadyScanned: 0,
    );
    expect(hit, isNotNull);
    expect(hit!.match, contains('Listening on'));
    expect(
      findNotifyMatch(
        output: 'aaa Listening on :8080 bbb',
        pattern: RegExp('Listening on'),
        alreadyScanned: hit.scannedThrough,
      ),
      isNull,
    );
  });

  test('shell tool returns exitCode/stdout/stderr json via detached job', () async {
    final workspace = _DetachedJobWorkspace(
      delay: const Duration(milliseconds: 50),
    );
    final tool = createShellTool(
      workspace,
      pollInterval: const Duration(milliseconds: 20),
    );
    final raw = await tool.executable!(<String, dynamic>{'command': 'echo hi'});
    final map = jsonDecode(raw as String) as Map<String, dynamic>;
    expect(map['ok'], isTrue);
    expect(map['exitCode'], 0);
    expect(map['stdout'], contains('ok-'));
  });

  test('shell tool maps timeout to Chinese error payload', () async {
    final workspace = _DetachedJobWorkspace(
      delay: const Duration(seconds: 5),
    );
    final tool = createShellTool(
      workspace,
      timeout: const Duration(milliseconds: 80),
      pollInterval: const Duration(milliseconds: 20),
    );
    final raw = await tool.executable!(<String, dynamic>{'command': 'sleep'});
    final map = jsonDecode(raw as String) as Map<String, dynamic>;
    expect(map['ok'], isFalse);
    expect(map['error'], '命令超时');
    expect(map['exitCode'], 124);
    expect(
      workspace.commands.any((c) => c.contains('kill')),
      isTrue,
    );
  });

  test('empty command rejected', () async {
    final workspace = _FakeWorkspace((_, {environment, timeout}) async {
      fail('should not run');
    });
    final tool = createShellTool(workspace);
    final raw = await tool.executable!(<String, dynamic>{'command': '  '});
    final map = jsonDecode(raw as String) as Map<String, dynamic>;
    expect(map['ok'], isFalse);
    expect(map['error'], '命令为空');
  });

  test('shell tool embeds VAULT_CHAT_SESSION_ID in start script', () async {
    String? startCmd;
    final workspace = _FakeWorkspace((cmd, {environment, timeout}) async {
      if (cmd.contains('_pid') && cmd.contains('&')) {
        startCmd = cmd;
        return const CommandResult(exitCode: 0, stdout: '1\n', stderr: '');
      }
      return CommandResult(
        exitCode: 0,
        stdout: '$kShellJobDoneMarker\n0\n$kShellJobOutMarker\n\n'
            '$kShellJobEndMarker\n',
        stderr: '',
      );
    });
    final tool = createShellTool(workspace, chatSessionId: 'sess-abc');
    await tool.executable!(<String, dynamic>{'command': 'true'});
    expect(startCmd, contains('VAULT_CHAT_SESSION_ID'));
    expect(startCmd, contains('sess-abc'));
  });

  test('two shell tools can progress in parallel without serial wait', () async {
    final workspace = _DetachedJobWorkspace(
      delay: const Duration(milliseconds: 120),
    );
    final tool = createShellTool(
      workspace,
      pollInterval: const Duration(milliseconds: 25),
    );

    final sw = Stopwatch()..start();
    final futures = <Future<Object?>>[
      tool.executable!(<String, dynamic>{'command': 'job-a'}) as Future<Object?>,
      tool.executable!(<String, dynamic>{'command': 'job-b'}) as Future<Object?>,
    ];
    final results = await Future.wait(futures);
    sw.stop();

    for (final raw in results) {
      final map = jsonDecode(raw as String) as Map<String, dynamic>;
      expect(map['ok'], isTrue);
    }
    // Parallel: both finish near one delay, not 2x delay.
    expect(sw.elapsedMilliseconds, lessThan(350));
    // Start scripts should both have been issued (two job ids).
    final starts = workspace.commands
        .where((c) => c.contains('_pid') && c.contains('&'))
        .length;
    expect(starts, 2);
  });
}
