import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_pty/flutter_pty.dart';
import 'package:path/path.dart' as p;
import 'package:vault/sandbox/offload_host.dart';
import 'package:vault/sandbox/persistent_shell.dart';
import 'package:vault/sandbox/sandbox_models.dart';

/// Interactive proot handle for one workspace rootfs.
class ProotWorkspace implements SandboxWorkspace {
  ProotWorkspace({
    required this.workspaceId,
    required this.prootPath,
    required this.loaderPath,
    required this.rootfsPath,
    required List<String> prootArgs,
    required Map<String, String> environment,
    required this.onDisposed,
    int rows = 32,
    int columns = 100,
  }) : _hostEnvironment = Map<String, String>.from(environment) {
    _pty = Pty.start(
      prootPath,
      arguments: prootArgs,
      environment: environment,
      workingDirectory: rootfsPath,
      rows: rows,
      columns: columns,
    );
  }

  @override
  final String workspaceId;

  final String prootPath;
  final String loaderPath;
  final String rootfsPath;
  final Map<String, String> _hostEnvironment;
  final Future<void> Function() onDisposed;
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

  /// Agent shell: long-lived proot **/without** `--kill-on-exit`.
  Future<PersistentShell> _ensureAgentShell() async {
    final existing = _agentShell;
    if (existing != null && existing.running) return existing;
    if (existing != null) await existing.stop();

    final hostEnv = <String, String>{
      ..._hostEnvironment,
      'PROOT_LOADER': loaderPath,
      'PROOT_NO_SECCOMP': '1',
      'PROOT_TMP_DIR': p.join(rootfsPath, 'tmp'),
      'TMPDIR': p.join(rootfsPath, 'tmp'),
      'PATH': '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin',
      'HOME': kGuestHome,
      'USER': 'root',
      'LANG': 'C.UTF-8',
      'TERM': 'dumb',
      'PS1': '',
    };
    final offloadPort = OffloadHost.port;
    if (offloadPort != null && offloadPort > 0) {
      hostEnv.putIfAbsent('VAULT_OFFLOAD_PORT', () => '$offloadPort');
    }

    final shell = PersistentShell(
      executable: prootPath,
      arguments: [
        '--link2symlink',
        '--change-id=0:0',
        '--rootfs=$rootfsPath',
        '--cwd=$kGuestHome',
        '--bind=/dev',
        '--bind=/proc',
        '--bind=/sys',
        '--bind=$rootfsPath/tmp:/dev/shm',
        '/bin/sh',
      ],
      environment: hostEnv,
      workingDirectory: rootfsPath,
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
    final relative = guestPath.substring(1); // drop leading /
    final hostPath = p.join(rootfsPath, relative);
    final file = File(hostPath);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes, flush: true);
  }

  @override
  Future<Uint8List?> readGuestFile(String guestAbsolutePath) async {
    final guestPath = assertGuestPathUnderHome(guestAbsolutePath);
    final file = File(p.join(rootfsPath, guestPath.substring(1)));
    if (!await file.exists()) return null;
    return Uint8List.fromList(await file.readAsBytes());
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _agentShell?.stop();
    _agentShell = null;
    _pty.kill();
    await onDisposed();
  }
}
