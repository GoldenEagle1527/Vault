import 'dart:io';

import 'package:archive/archive.dart';
import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

/// Extract a gzipped Alpine/proot-distro rootfs tarball.
///
/// The `archive` package skips **absolute** symlinks (e.g. `/bin/sh` →
/// `/bin/busybox`) as a zip-slip defense. Guest rootfs depends on those links,
/// so we rewrite absolute targets to relative paths inside the extract tree.
Future<void> extractGuestRootfs(String tarGzPath, String destPath) async {
  final out = Directory(destPath);
  if (await out.exists()) {
    await out.delete(recursive: true);
  }
  await out.create(recursive: true);

  final input = InputFileStream(tarGzPath);
  final tarPath = p.join(
    Directory.systemTemp.createTempSync('vault_rootfs').path,
    'rootfs.tar',
  );
  final tarOut = OutputFileStream(tarPath);
  try {
    GZipDecoder().decodeStream(input, tarOut);
  } finally {
    await input.close();
    await tarOut.close();
  }

  final tarIn = InputFileStream(tarPath);
  late final Archive archive;
  try {
    archive = TarDecoder().decodeStream(tarIn);
  } finally {
    await tarIn.close();
  }

  try {
    final nestPrefix = _detectNestPrefix(archive);
    final regular = <ArchiveFile>[];
    final links = <ArchiveFile>[];
    for (final file in archive) {
      if (file.isSymbolicLink) {
        links.add(file);
      } else {
        regular.add(file);
      }
    }

    for (final file in regular) {
      final name = _safeEntryName(file.name);
      if (name == null) continue;
      final filePath = p.join(destPath, name);
      if (!_isWithin(destPath, filePath)) continue;

      if (file.isDirectory) {
        Directory(filePath).createSync(recursive: true);
        continue;
      }
      if (!file.isFile) continue;

      final output = OutputFileStream(filePath);
      try {
        file.writeContent(output);
      } finally {
        await output.close();
      }
      // package:archive's extractFileToDisk chmods; we must too — proot
      // rejects guest cmds without S_IXUSR ("'bin/sh' is not executable").
      await _chmod(filePath, file.unixPermissions);
    }

    for (final file in links) {
      final name = _safeEntryName(file.name);
      if (name == null) continue;
      final filePath = p.join(destPath, name);
      if (!_isWithin(destPath, filePath)) continue;

      final rawTarget = file.symbolicLink ?? '';
      if (rawTarget.isEmpty) continue;

      final target = _guestLinkTarget(
        destPath: destPath,
        entryName: name,
        linkTarget: rawTarget,
        nestPrefix: nestPrefix,
      );
      if (target == null) continue;

      final link = Link(filePath);
      if (link.existsSync()) {
        link.deleteSync();
      }
      link.createSync(target, recursive: true);
    }

    await _flattenNest(destPath, nestPrefix);
    await _ensureGuestExecBits(destPath);
  } finally {
    await archive.clear();
    try {
      await File(tarPath).parent.delete(recursive: true);
    } catch (_) {}
  }
}

/// True if guest `/bin/sh` exists as a file or symlink (do not follow links).
bool guestHasBinSh(String rootfsPath) {
  final sh = p.join(rootfsPath, 'bin', 'sh');
  final type = FileSystemEntity.typeSync(sh, followLinks: false);
  if (type == FileSystemEntityType.file || type == FileSystemEntityType.link) {
    return true;
  }
  return File(p.join(rootfsPath, 'bin', 'busybox')).existsSync();
}

String? _detectNestPrefix(Archive archive) {
  for (final file in archive) {
    final name = _safeEntryName(file.name);
    if (name == null) continue;
    if (name == 'bin/busybox' || name == 'bin/sh') {
      return null;
    }
    const suffix = '/bin/busybox';
    if (name.endsWith(suffix)) {
      return name.substring(0, name.length - suffix.length);
    }
  }
  // Fallback: single top-level directory that is not a standard rootfs dir.
  final tops = <String>{};
  for (final file in archive) {
    final name = _safeEntryName(file.name);
    if (name == null || name.isEmpty) continue;
    tops.add(name.split('/').first);
  }
  const std = {
    'bin',
    'boot',
    'dev',
    'etc',
    'home',
    'lib',
    'media',
    'mnt',
    'opt',
    'proc',
    'root',
    'run',
    'sbin',
    'srv',
    'sys',
    'tmp',
    'usr',
    'var',
  };
  if (tops.length == 1 && !std.contains(tops.first)) {
    return tops.first;
  }
  return null;
}

String? _safeEntryName(String raw) {
  var name = raw.replaceAll('\\', '/');
  while (name.startsWith('./')) {
    name = name.substring(2);
  }
  if (name.isEmpty || name.contains('..')) {
    return null;
  }
  return p.posix.normalize(name);
}

bool _isWithin(String root, String candidate) {
  final r = p.canonicalize(root);
  final c = p.canonicalize(candidate);
  return p.equals(r, c) || p.isWithin(r, c);
}

/// Convert absolute guest symlinks (`/bin/busybox`) to relative host links.
String? _guestLinkTarget({
  required String destPath,
  required String entryName,
  required String linkTarget,
  required String? nestPrefix,
}) {
  final normalized = linkTarget.replaceAll('\\', '/');
  if (!p.posix.isAbsolute(normalized) && !normalized.startsWith('/')) {
    // Already relative — keep, but reject escapes outside dest.
    final abs = p.normalize(p.join(p.dirname(p.join(destPath, entryName)), normalized));
    if (!_isWithin(destPath, abs)) {
      return null;
    }
    return p.normalize(normalized);
  }

  // Absolute guest path → path under nestPrefix (or dest root).
  final guestRel = normalized.startsWith('/')
      ? normalized.substring(1)
      : normalized;
  final hostTarget = nestPrefix == null || nestPrefix.isEmpty
      ? p.join(destPath, guestRel)
      : p.join(destPath, nestPrefix, guestRel);
  final linkDir = p.dirname(p.join(destPath, entryName));
  if (!_isWithin(destPath, hostTarget)) {
    return null;
  }
  return p.relative(hostTarget, from: linkDir);
}

Future<void> _flattenNest(String destPath, String? nestPrefix) async {
  if (nestPrefix == null || nestPrefix.isEmpty) return;
  final nested = Directory(p.join(destPath, nestPrefix));
  if (!await nested.exists()) return;

  final parent = Directory(destPath).parent;
  final tmp = Directory(
    p.join(parent.path, '.vault_rootfs_${DateTime.now().microsecondsSinceEpoch}'),
  );
  if (await tmp.exists()) {
    await tmp.delete(recursive: true);
  }
  await nested.rename(tmp.path);

  final dest = Directory(destPath);
  await dest.delete(recursive: true);
  await tmp.rename(destPath);
}

Future<void> _chmod(String path, int modeBits) async {
  final mode = modeBits & 0x1ff;
  if (mode == 0) return;
  final octal = mode.toRadixString(8).padLeft(3, '0');
  try {
    await Process.run('chmod', [octal, path], runInShell: false);
  } catch (_) {
    // Android always has chmod for app-owned files; ignore host dry-runs.
  }
}

/// Safety net: ensure typical executable trees keep +x after extract/flatten.
Future<void> _ensureGuestExecBits(String rootfsPath) async {
  const dirs = [
    'bin',
    'sbin',
    'usr/bin',
    'usr/sbin',
    'lib',
    'usr/lib',
    'lib64',
  ];
  for (final rel in dirs) {
    final dir = Directory(p.join(rootfsPath, rel));
    if (!await dir.exists()) continue;
    await for (final ent in dir.list(recursive: true, followLinks: false)) {
      if (ent is! File) continue;
      await _chmod(ent.path, 0x1ed); // 0755
    }
  }
  // busybox is the real payload behind /bin/sh
  final busybox = p.join(rootfsPath, 'bin', 'busybox');
  if (File(busybox).existsSync()) {
    await _chmod(busybox, 0x1ed);
  }
}
