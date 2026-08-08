import 'dart:typed_data';

/// Default working directory / home inside every Vault guest session.
const String kGuestHome = '/root';

/// Host → guest file drop directory for Agent attachments.
const String kGuestInboxDir = '$kGuestHome/inbox';

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
  ///
  /// Implementations should run as root with cwd [kGuestHome] when practical.
  Future<CommandResult> run(String cmd);

  /// Write [bytes] to an absolute guest path (e.g. `/root/inbox/a.txt`).
  ///
  /// Creates parent directories. Path must stay under [kGuestHome] (no `..` escape).
  Future<void> writeGuestFile(String guestAbsolutePath, List<int> bytes);

  Future<void> dispose();
}

/// Sanitize a user-facing file name for [kGuestInboxDir] (basename only).
String sanitizeInboxFileName(String name) {
  var base = name.replaceAll('\\', '/').split('/').last.trim();
  if (base.isEmpty || base == '.' || base == '..') {
    base = 'upload.bin';
  }
  base = base.replaceAll(RegExp(r'[^\w.\-+=@()\[\]{} ]'), '_');
  if (base.length > 180) {
    base = base.substring(base.length - 180);
  }
  return base;
}

String inboxGuestPath(String fileName) =>
    '$kGuestInboxDir/${sanitizeInboxFileName(fileName)}';

/// Reject path traversal outside [kGuestHome].
String assertGuestPathUnderHome(String guestAbsolutePath) {
  final raw = guestAbsolutePath.trim();
  if (!raw.startsWith('/')) {
    throw ArgumentError('guest path must be absolute: $guestAbsolutePath');
  }
  final parts = <String>[];
  for (final seg in raw.split('/')) {
    if (seg.isEmpty || seg == '.') continue;
    if (seg == '..') {
      if (parts.isEmpty) {
        throw ArgumentError('guest path escapes root: $guestAbsolutePath');
      }
      parts.removeLast();
      continue;
    }
    parts.add(seg);
  }
  final normalized = '/${parts.join('/')}';
  if (normalized != kGuestHome && !normalized.startsWith('$kGuestHome/')) {
    throw ArgumentError(
      'guest path must be under $kGuestHome: $guestAbsolutePath',
    );
  }
  return normalized;
}
