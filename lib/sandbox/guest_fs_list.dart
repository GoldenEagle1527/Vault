import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:vault/sandbox/sandbox_models.dart';

/// List [guestDir] via a host path that already maps into the guest rootfs.
Future<List<GuestFsEntry>> listGuestDirectoryOnHost({
  required String hostPath,
  required String guestDir,
}) async {
  final guest = assertGuestPathUnderHome(guestDir);
  final dir = Directory(hostPath);
  if (!await dir.exists()) {
    throw StateError('目录不存在：$guest');
  }
  final out = <GuestFsEntry>[];
  await for (final entity in dir.list(followLinks: false)) {
    final name = p.basename(entity.path);
    if (name.isEmpty || name == '.' || name == '..') continue;

    var isDir = false;
    int? size;
    if (entity is Directory) {
      isDir = true;
    } else if (entity is File) {
      try {
        size = await entity.length();
      } catch (_) {}
    } else {
      final type = await FileSystemEntity.type(
        entity.path,
        followLinks: false,
      );
      if (type == FileSystemEntityType.directory) {
        isDir = true;
      } else if (type == FileSystemEntityType.file) {
        try {
          size = await File(entity.path).length();
        } catch (_) {}
      }
    }

    out.add(
      GuestFsEntry(
        name: name,
        guestPath: guestPathJoin(guest, name),
        isDirectory: isDir,
        sizeBytes: isDir ? null : size,
      ),
    );
  }
  sortGuestFsEntries(out);
  return out;
}

/// Parse `ls -1Ap` stdout into [GuestFsEntry]s under [guestDir].
List<GuestFsEntry> parseLsMinusOneAp(String stdout, String guestDir) {
  final guest = assertGuestPathUnderHome(guestDir);
  final out = <GuestFsEntry>[];
  for (final rawLine in stdout.split('\n')) {
    var line = rawLine.replaceAll('\r', '').trimRight();
    if (line.isEmpty) continue;
    var isDir = false;
    if (line.endsWith('/')) {
      isDir = true;
      line = line.substring(0, line.length - 1);
    }
    // Strip other classify suffixes from ls -F style if present.
    if (line.endsWith('*') ||
        line.endsWith('|') ||
        line.endsWith('=') ||
        line.endsWith('@')) {
      line = line.substring(0, line.length - 1);
    }
    final name = line.trim();
    if (name.isEmpty || name == '.' || name == '..') continue;
    if (name.contains('/') || name.contains('\\')) continue;
    out.add(
      GuestFsEntry(
        name: name,
        guestPath: guestPathJoin(guest, name),
        isDirectory: isDir,
      ),
    );
  }
  sortGuestFsEntries(out);
  return out;
}
