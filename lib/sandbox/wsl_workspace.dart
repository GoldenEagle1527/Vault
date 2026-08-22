import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_pty/flutter_pty.dart';
import 'package:path/path.dart' as p;
import 'package:vault/sandbox/persistent_shell.dart';
import 'package:vault/sandbox/sandbox_models.dart';
import 'package:vault/sandbox/wsl_process_config.dart';

/// Interactive WSL handle for one workspace distro.
class WslWorkspace implements SandboxWorkspace {
  WslWorkspace({
    required this.workspaceId,
    required this.distroName,
    int rows = 32,
    int columns = 100,
  }) {
    // 显式启动 /bin/sh，并覆盖 PATH，避免把宿主超长 Windows PATH 传给 wsl.exe。
    _pty = Pty.start(
      'wsl.exe',
      arguments: [
        '-d',
        distroName,
        '-u',
        'root',
        '--cd',
        '/root',
        '-e',
        '/bin/sh',
        '-l',
      ],
      environment: wslHostEnvironment,
      rows: rows,
      columns: columns,
    );
  }

  @override
  final String workspaceId;

  final String distroName;
  late final Pty _pty;
  PersistentShell? _agentShell;
  bool _disposed = false;

  @override
  Stream<Uint8List> get output => _pty.output;

  @override
  void write(String data) {
    writeBytes(Uint8List.fromList(utf8.encode(data)));
  }

  @override
  void writeBytes(Uint8List data) {
    _pty.write(data);
  }

  @override
  void resize(int cols, int rows) {
    _pty.resize(rows, cols);
  }

  @override
  Future<int> get exitCode => _pty.exitCode;

  Future<PersistentShell> _ensureAgentShell() async {
    final existing = _agentShell;
    if (existing != null && existing.running) return existing;
    if (existing != null) await existing.stop();
    final shell = PersistentShell(
      executable: 'wsl.exe',
      arguments: [
        '-d',
        distroName,
        '-u',
        'root',
        '--cd',
        kGuestHome,
        '-e',
        '/bin/sh',
      ],
      environment: wslHostEnvironment,
      includeParentEnvironment: false,
    );
    _agentShell = shell;
    return shell;
  }

  @override
  Future<CommandResult> run(
    String cmd, {
    Map<String, String>? environment,
    Duration? timeout,
  }) async {
    final shell = await _ensureAgentShell();
    return shell.run(cmd, environment: environment, timeout: timeout);
  }

  @override
  Future<void> writeGuestFile(String guestAbsolutePath, List<int> bytes) async {
    final guestPath = assertGuestPathUnderHome(guestAbsolutePath);
    final parent = p.posix.dirname(guestPath);
    final mkdir = await run('mkdir -p ${shellSingleQuote(parent)}');
    if (!mkdir.success) {
      throw StateError('无法在沙箱内创建目录 $parent：${mkdir.stderr}');
    }

    // Prefer \\wsl$\ UNC (no size limit from argv); fall back to base64 pipe.
    final unc = _wslUncPath(guestPath);
    try {
      final file = File(unc);
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes, flush: true);
      return;
    } catch (_) {
      // Fall through.
    }

    final proc = await Process.start('wsl.exe', [
      '-d',
      distroName,
      '-u',
      'root',
      '--cd',
      kGuestHome,
      '-e',
      '/bin/sh',
      '-c',
      'base64 -d > ${shellSingleQuote(guestPath)}',
    ]);
    proc.stdin.add(utf8.encode(base64Encode(bytes)));
    await proc.stdin.close();
    final exit = await proc.exitCode;
    if (exit != 0) {
      final err = await proc.stderr.transform(utf8.decoder).join();
      throw StateError('写入沙箱文件失败（exit $exit）：$err');
    }
  }

  @override
  Future<Uint8List?> readGuestFile(String guestAbsolutePath) async {
    final guestPath = assertGuestPathUnderHome(guestAbsolutePath);
    try {
      final file = File(_wslUncPath(guestPath));
      if (await file.exists()) {
        return Uint8List.fromList(await file.readAsBytes());
      }
    } catch (_) {
      // Fall through to wsl base64.
    }
    final result = await run(
      'if [ -f ${shellSingleQuote(guestPath)} ]; then base64 ${shellSingleQuote(guestPath)}; else exit 2; fi',
    );
    if (result.exitCode == 2 || result.exitCode != 0) return null;
    try {
      final b64 = result.stdout.replaceAll(RegExp(r'\s+'), '');
      if (b64.isEmpty) return null;
      return Uint8List.fromList(base64Decode(b64));
    } catch (_) {
      return null;
    }
  }

  String _wslUncPath(String guestAbsolutePath) {
    final relative = guestAbsolutePath.startsWith('/')
        ? guestAbsolutePath.substring(1)
        : guestAbsolutePath;
    return '\\\\wsl\$\\$distroName\\${relative.replaceAll('/', '\\')}';
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _agentShell?.stop();
    _agentShell = null;
    _pty.kill();
  }
}
