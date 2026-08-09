import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:vault/sandbox/sandbox_models.dart';

/// Marker prefix for end-of-command framing (OpenMinis-style PersistentShell).
const String kPersistentShellMarkerPrefix = '__VAULT_DONE_';

/// Wrap [command] so the guest shell prints a unique completion marker with $?.
String wrapPersistentShellCommand(String command, String marker) {
  return '$command\n'
      'echo "$kPersistentShellMarkerPrefix${marker}_EXIT_\$?__"\n';
}

/// Result of finding a completion marker in a stdout buffer.
typedef PersistentShellMarkerMatch = ({String output, int exitCode, int end});

/// Search [buffer] for `__VAULT_DONE_<marker>_EXIT_<code>__`.
///
/// Returns null if the marker is not yet complete (handles chunk splits).
PersistentShellMarkerMatch? tryParsePersistentShellMarker(
  String buffer,
  String marker,
) {
  final pattern = '$kPersistentShellMarkerPrefix${marker}_EXIT_';
  final idx = buffer.indexOf(pattern);
  if (idx < 0) return null;

  final after = buffer.substring(idx + pattern.length);
  final endIdx = after.indexOf('__');
  if (endIdx < 0) return null;

  final codeStr = after.substring(0, endIdx);
  final exitCode = int.tryParse(codeStr);
  if (exitCode == null) return null;

  var output = buffer.substring(0, idx);
  if (output.endsWith('\r\n')) {
    output = output.substring(0, output.length - 2);
  } else if (output.endsWith('\n') || output.endsWith('\r')) {
    output = output.substring(0, output.length - 1);
  }

  final absoluteEnd = idx + pattern.length + endIdx + 2;
  return (output: output, exitCode: exitCode, end: absoluteEnd);
}

String newPersistentShellMarker() {
  final r = Random.secure();
  final bytes = List<int>.generate(4, (_) => r.nextInt(256));
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// Long-lived guest `/bin/sh` for agent [SandboxWorkspace.run] calls.
///
/// Unlike one-shot `proot … --kill-on-exit /bin/sh -c`, this process stays up
/// so cwd, exports, and background jobs (e.g. `uvicorn &`) survive across
/// tool invocations — same pattern as OpenMinis `PersistentShell`.
class PersistentShell {
  PersistentShell({
    required this.executable,
    required this.arguments,
    required Map<String, String> environment,
    this.workingDirectory,
    this.includeParentEnvironment = true,
  }) : environment = Map<String, String>.from(environment);

  final String executable;
  final List<String> arguments;
  final Map<String, String> environment;
  final String? workingDirectory;
  final bool includeParentEnvironment;

  Process? _process;
  IOSink? _stdin;
  StreamSubscription<List<int>>? _outSub;
  StreamSubscription<List<int>>? _errSub;
  StreamSubscription<int>? _exitSub;

  final StringBuffer _readBuf = StringBuffer();
  Completer<CommandResult>? _pending;
  String? _pendingMarker;
  bool _dead = true;

  /// Serializes [run] so only one framed command is in flight.
  Future<void> _queue = Future<void>.value();

  bool get running => !_dead && _process != null;

  Future<void> ensureStarted() async {
    if (running) return;
    await _start();
  }

  Future<void> _start() async {
    await _tearDown(kill: true);

    final process = await Process.start(
      executable,
      arguments,
      environment: environment,
      workingDirectory: workingDirectory,
      includeParentEnvironment: includeParentEnvironment,
    );

    _process = process;
    _stdin = process.stdin;
    _dead = false;
    _readBuf.clear();

    void onBytes(List<int> chunk) {
      final text = utf8.decode(chunk, allowMalformed: true);
      _readBuf.write(text);
      _tryCompleteFromBuffer();
    }

    _outSub = process.stdout.listen(
      onBytes,
      onError: (Object e) {
        _failPending(CommandResult(
          exitCode: -1,
          stdout: _readBuf.toString(),
          stderr: 'persistent shell stdout error: $e',
        ));
      },
    );
    _errSub = process.stderr.listen(
      onBytes,
      onError: (Object e) {
        _failPending(CommandResult(
          exitCode: -1,
          stdout: _readBuf.toString(),
          stderr: 'persistent shell stderr error: $e',
        ));
      },
    );
    _exitSub = process.exitCode.asStream().listen((code) {
      _dead = true;
      _failPending(CommandResult(
        exitCode: code,
        stdout: _readBuf.toString(),
        stderr: 'persistent shell exited ($code)',
      ));
    });

    // Quiet shell; avoid login profiles polluting framed output.
    _stdin!.write('PS1=\nexport PS1=\nexport TERM=dumb\n');
    await _stdin!.flush();
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }

  void _tryCompleteFromBuffer() {
    final marker = _pendingMarker;
    final pending = _pending;
    if (marker == null || pending == null || pending.isCompleted) return;

    final snapshot = _readBuf.toString();
    final match = tryParsePersistentShellMarker(snapshot, marker);
    if (match == null) return;

    _readBuf
      ..clear()
      ..write(snapshot.substring(match.end));
    pending.complete(CommandResult(
      exitCode: match.exitCode,
      stdout: match.output,
      stderr: '',
    ));
    _pending = null;
    _pendingMarker = null;
  }

  void _failPending(CommandResult result) {
    final pending = _pending;
    if (pending != null && !pending.isCompleted) {
      pending.complete(result);
    }
    _pending = null;
    _pendingMarker = null;
  }

  /// Execute [command] in the long-lived shell and wait for the marker.
  Future<CommandResult> run(
    String command, {
    Map<String, String>? environment,
    Duration? timeout,
  }) {
    final gate = Completer<void>();
    final previous = _queue;
    _queue = previous.then((_) => gate.future);
    return previous.then((_) async {
      try {
        return await _runUnlocked(
          command,
          environment: environment,
          timeout: timeout,
        );
      } finally {
        if (!gate.isCompleted) gate.complete();
      }
    });
  }

  Future<CommandResult> _runUnlocked(
    String command, {
    Map<String, String>? environment,
    Duration? timeout,
  }) async {
    await ensureStarted();
    if (!running || _stdin == null) {
      return const CommandResult(
        exitCode: -1,
        stdout: '',
        stderr: 'persistent shell not running',
      );
    }

    final guestCmd = withGuestEnvironment(command, environment);
    final marker = newPersistentShellMarker();
    final wrapped = wrapPersistentShellCommand(guestCmd, marker);

    final completer = Completer<CommandResult>();
    _pending = completer;
    _pendingMarker = marker;
    _readBuf.clear();

    try {
      _stdin!.write(wrapped);
      await _stdin!.flush();
    } catch (e) {
      _pending = null;
      _pendingMarker = null;
      return CommandResult(
        exitCode: -1,
        stdout: '',
        stderr: 'persistent shell write failed: $e',
      );
    }

    try {
      if (timeout != null) {
        return await completer.future.timeout(timeout);
      }
      return await completer.future;
    } on TimeoutException {
      try {
        _stdin?.add(const [0x03]); // Ctrl+C
        await _stdin?.flush();
      } catch (_) {}
      final timedOut = CommandResult(
        exitCode: 124,
        stdout: _readBuf.toString(),
        stderr: '命令在 ${timeout!.inSeconds} 秒内未完成',
      );
      if (!completer.isCompleted) {
        completer.complete(timedOut);
      }
      _pending = null;
      _pendingMarker = null;
      return timedOut;
    }
  }

  Future<void> stop() => _tearDown(kill: true);

  Future<void> _tearDown({required bool kill}) async {
    _failPending(const CommandResult(
      exitCode: -1,
      stdout: '',
      stderr: 'persistent shell stopped',
    ));
    await _outSub?.cancel();
    await _errSub?.cancel();
    await _exitSub?.cancel();
    _outSub = null;
    _errSub = null;
    _exitSub = null;
    try {
      await _stdin?.close();
    } catch (_) {}
    _stdin = null;
    final process = _process;
    _process = null;
    _dead = true;
    if (kill && process != null) {
      process.kill(ProcessSignal.sigkill);
      try {
        await process.exitCode.timeout(const Duration(seconds: 2));
      } catch (_) {}
    }
    _readBuf.clear();
  }
}
