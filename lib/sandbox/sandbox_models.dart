import 'dart:typed_data';

/// Default working directory / home inside every Vault guest workspace.
const String kGuestHome = '/root';

/// Host → guest file drop directory for Agent attachments.
const String kGuestInboxDir = '$kGuestHome/inbox';

/// Vault-managed metadata inside the guest Linux (conversations, etc.).
const String kGuestVaultDir = '$kGuestHome/.vault';

/// Dedicated area for user project working trees (timestamp folders + git).
///
/// Project / conversation **metadata** lives in the host [VaultMetaDb], not here.
const String kGuestProjectsDir = '$kGuestHome/projects';

/// Legacy (pre-project) conversation root — migrated into host SQLite on bootstrap.
const String kGuestLegacyConversationsDir = '$kGuestVaultDir/conversations';

/// Absolute guest path for one project's working directory.
String guestProjectDir(String projectPath) =>
    '$kGuestProjectsDir/$projectPath';

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

/// Metadata for one isolated Linux workspace (WSL distro or proot rootfs).
class WorkspaceInfo {
  const WorkspaceInfo({
    required this.workspaceId,
    required this.displayName,
    required this.createdAt,
    this.diskPath,
    this.approxDiskBytes,
  });

  final String workspaceId;
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

/// One entry from [SandboxProvider.listGuestDirectory].
class GuestFsEntry {
  const GuestFsEntry({
    required this.name,
    required this.guestPath,
    required this.isDirectory,
    this.sizeBytes,
  });

  final String name;
  final String guestPath;
  final bool isDirectory;
  final int? sizeBytes;
}

/// Directories first, then case-insensitive name.
void sortGuestFsEntries(List<GuestFsEntry> entries) {
  entries.sort((a, b) {
    if (a.isDirectory != b.isDirectory) {
      return a.isDirectory ? -1 : 1;
    }
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  });
}

/// Join [dir] + basename [name] under [kGuestHome].
String guestPathJoin(String dir, String name) {
  final base = assertGuestPathUnderHome(dir);
  final trimmed = name.trim();
  if (trimmed.isEmpty ||
      trimmed == '.' ||
      trimmed == '..' ||
      trimmed.contains('/') ||
      trimmed.contains('\\')) {
    throw ArgumentError('invalid guest entry name: $name');
  }
  return assertGuestPathUnderHome('$base/$trimmed');
}

/// Heuristic: treat as text unless NUL bytes appear in the sample.
bool looksLikeTextBytes(List<int> bytes, {int sampleLimit = 8192}) {
  final n = bytes.length < sampleLimit ? bytes.length : sampleLimit;
  for (var i = 0; i < n; i++) {
    if (bytes[i] == 0) return false;
  }
  return true;
}

/// Interactive PTY-like handle for one workspace. Does not expose [Process].
abstract class SandboxWorkspace {
  String get workspaceId;

  Stream<Uint8List> get output;

  void write(String data);

  void writeBytes(Uint8List data);

  void resize(int cols, int rows);

  Future<int> get exitCode;

  /// Non-interactive command for the agent loop.
  ///
  /// Implementations should run as root with cwd [kGuestHome] when practical.
  /// Prefer a **long-lived guest shell** so cwd / exports / background jobs
  /// persist across calls (OpenMinis PersistentShell pattern). One-shot
  /// `sh -c` with proot `--kill-on-exit` kills daemons started with `&`.
  ///
  /// [environment] is applied inside the guest shell (not host Process APIs
  /// exposed to callers). Used e.g. for `VAULT_CHAT_SESSION_ID`.
  ///
  /// When [timeout] elapses, return exit code 124 without tearing down the
  /// persistent shell (best-effort Ctrl+C).
  Future<CommandResult> run(
    String cmd, {
    Map<String, String>? environment,
    Duration? timeout,
  });

  /// Write [bytes] to an absolute guest path (e.g. `/root/inbox/a.txt`).
  ///
  /// Creates parent directories. Path must stay under [kGuestHome] (no `..` escape).
  Future<void> writeGuestFile(String guestAbsolutePath, List<int> bytes);

  Future<void> dispose();
}

/// Sanitize a user-facing file name for guest paths (basename only).
///
/// Keeps Unicode letters (including CJK). Strips path separators, control
/// characters, and characters that break Windows UNC (`\\wsl$\…`) mapping.
String sanitizeInboxFileName(String name) {
  var base = name.replaceAll('\\', '/').split('/').last.trim();
  if (base.isEmpty || base == '.' || base == '..') {
    base = 'upload.bin';
  }

  final buf = StringBuffer();
  for (final rune in base.runes) {
    if (rune < 0x20 || rune == 0x7F) {
      buf.write('_');
      continue;
    }
    final ch = String.fromCharCode(rune);
    // Path separators + Windows-illegal filename chars (UNC / Explorer).
    if (ch == '/' ||
        ch == '\\' ||
        ch == '<' ||
        ch == '>' ||
        ch == ':' ||
        ch == '"' ||
        ch == '|' ||
        ch == '?' ||
        ch == '*') {
      buf.write('_');
      continue;
    }
    buf.write(ch);
  }
  base = buf.toString().trim();
  // Avoid names that are only dots / empty after scrubbing.
  if (base.isEmpty || base == '.' || base == '..') {
    base = 'upload.bin';
  }
  // Windows trailing dots/spaces are problematic on UNC.
  while (base.endsWith('.') || base.endsWith(' ')) {
    base = base.substring(0, base.length - 1);
  }
  if (base.isEmpty || base == '.' || base == '..') {
    base = 'upload.bin';
  }
  if (base.length > 180) {
    final extDot = base.lastIndexOf('.');
    if (extDot > 0 && base.length - extDot <= 16) {
      final ext = base.substring(extDot);
      final stem = base.substring(0, extDot);
      final keep = 180 - ext.length;
      base = '${stem.substring(stem.length - keep)}$ext';
    } else {
      base = base.substring(base.length - 180);
    }
  }
  return base;
}

String inboxGuestPath(String fileName) =>
    '$kGuestInboxDir/${sanitizeInboxFileName(fileName)}';

/// POSIX single-quote for embedding values in guest `sh -c` strings.
String shellSingleQuote(String value) => "'${value.replaceAll("'", "'\\''")}'";

/// Prefix [cmd] with `env KEY=VAL … /bin/sh -c …` when [environment] is set.
String withGuestEnvironment(String cmd, Map<String, String>? environment) {
  if (environment == null || environment.isEmpty) return cmd;
  final assignments = <String>[];
  for (final e in environment.entries) {
    if (!RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(e.key)) {
      throw ArgumentError('invalid environment key: ${e.key}');
    }
    assignments.add('${e.key}=${shellSingleQuote(e.value)}');
  }
  return 'env ${assignments.join(' ')} /bin/sh -c ${shellSingleQuote(cmd)}';
}

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
