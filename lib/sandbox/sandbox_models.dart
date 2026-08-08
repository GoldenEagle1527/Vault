import 'dart:typed_data';

/// Result of probing the host for sandbox support.
class SandboxCapabilities {
  const SandboxCapabilities({
    required this.available,
    required this.backend,
    required this.architecture,
    this.pageSizeBytes,
    this.hint,
    this.notes = const [],
  });

  final bool available;
  final SandboxBackend backend;
  final String architecture;
  final int? pageSizeBytes;

  /// User-facing recovery hint when [available] is false
  /// (e.g. "run wsl --install").
  final String? hint;

  /// Non-fatal caveats to surface in the UI (disk cost, shared kernel, etc.).
  final List<String> notes;
}

enum SandboxBackend { wsl, proot, unsupported }

class SandboxInfo {
  const SandboxInfo({
    required this.sessionId,
    required this.displayName,
    required this.createdAt,
    this.diskPath,
    this.approxDiskBytes,
  });

  final String sessionId;
  final String displayName;
  final DateTime createdAt;
  final String? diskPath;
  final int? approxDiskBytes;
}

class CommandResult {
  const CommandResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  final int exitCode;
  final String stdout;
  final String stderr;

  bool get success => exitCode == 0;
}

/// Interactive PTY-like session. Does not expose [Process].
abstract class SandboxSession {
  String get sessionId;

  Stream<Uint8List> get output;

  void write(String data);

  void writeBytes(Uint8List data);

  void resize(int cols, int rows);

  Future<int> get exitCode;

  /// Non-interactive command for the agent loop.
  Future<CommandResult> run(String cmd);

  Future<void> dispose();
}
