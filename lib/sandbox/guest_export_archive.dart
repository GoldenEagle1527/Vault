import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;
import 'package:vault/sandbox/guest_fs_ops.dart';
import 'package:vault/sandbox/sandbox_provider.dart';

/// Zip guest files/directories onto [destZipPath] using host-mapped paths.
///
/// Does not load file bodies into Dart heaps ([ZipFileEncoder] streams).
/// Returns [destZipPath].
Future<String> zipGuestPathsToHost({
  required SandboxProvider provider,
  required String workspaceId,
  required List<String> guestPaths,
  required String destZipPath,
  void Function(int current, int total, String name)? onProgress,
}) async {
  if (guestPaths.isEmpty) {
    throw StateError('没有可打包的路径');
  }
  final dest = File(destZipPath);
  await dest.parent.create(recursive: true);
  if (await dest.exists()) await dest.delete();

  final encoder = ZipFileEncoder();
  encoder.create(destZipPath);
  final taken = <String>{};
  try {
    for (var i = 0; i < guestPaths.length; i++) {
      final guest = assertGuestPathUnderHome(guestPaths[i]);
      final name = allocateArchiveEntryName(p.posix.basename(guest), taken);
      taken.add(name);
      onProgress?.call(i + 1, guestPaths.length, name);
      final type = await guestEntityType(provider, workspaceId, guest);
      if (type == FileSystemEntityType.notFound) {
        throw StateError('源不存在：$guest');
      }
      final host = await provider.resolveGuestHostPath(workspaceId, guest);
      if (type == FileSystemEntityType.directory) {
        await encoder.addDirectory(
          Directory(host),
          includeDirName: true,
          followLinks: false,
        );
      } else {
        await encoder.addFile(File(host), name);
      }
    }
  } catch (_) {
    await encoder.close();
    try {
      if (await dest.exists()) await dest.delete();
    } catch (_) {}
    rethrow;
  }
  await encoder.close();
  return destZipPath;
}

/// Zip after staging onto the host (WSL UNC fallback).
Future<String> zipGuestPathsViaStaging({
  required SandboxProvider provider,
  required String workspaceId,
  required List<String> guestPaths,
  required String destZipPath,
  required Directory stagingDir,
  void Function(int current, int total, String name)? onProgress,
}) async {
  if (await stagingDir.exists()) {
    await stagingDir.delete(recursive: true);
  }
  await stagingDir.create(recursive: true);
  final taken = <String>{};
  for (var i = 0; i < guestPaths.length; i++) {
    final guest = assertGuestPathUnderHome(guestPaths[i]);
    final name = allocateArchiveEntryName(p.posix.basename(guest), taken);
    taken.add(name);
    onProgress?.call(i + 1, guestPaths.length, name);
    await exportGuestPathToHost(
      provider: provider,
      workspaceId: workspaceId,
      guestAbsolutePath: guest,
      hostPath: p.join(stagingDir.path, name),
    );
  }
  final encoder = ZipFileEncoder();
  encoder.create(destZipPath);
  try {
    await encoder.addDirectory(
      stagingDir,
      includeDirName: false,
      followLinks: false,
    );
  } catch (_) {
    await encoder.close();
    try {
      final dest = File(destZipPath);
      if (await dest.exists()) await dest.delete();
    } catch (_) {}
    rethrow;
  }
  await encoder.close();
  return destZipPath;
}

/// Pick `name`, then `stem-2.ext`, … not in [taken].
String allocateArchiveEntryName(String desired, Set<String> taken) {
  final name = sanitizeInboxFileName(desired);
  if (!taken.contains(name)) return name;
  final stem = p.basenameWithoutExtension(name);
  final ext = p.extension(name);
  var i = 2;
  while (taken.contains('$stem-$i$ext')) {
    i++;
    if (i > 999) {
      throw StateError('无法为压缩条目分配唯一名称：$name');
    }
  }
  return '$stem-$i$ext';
}

/// Default zip filename for a selection (`notes.zip`, `notes-and-2.zip`).
String zipFileNameForSelection(List<String> guestPaths) {
  if (guestPaths.isEmpty) return 'export.zip';
  final first = sanitizeInboxFileName(p.posix.basename(guestPaths.first));
  final stem = p.basenameWithoutExtension(first);
  final base = stem.isEmpty ? 'export' : stem;
  if (guestPaths.length == 1) return '$base.zip';
  return '$base-and-${guestPaths.length}.zip';
}

/// Host path that does not collide with an existing file/dir.
Future<String> allocateUniqueHostPath(String dir, String fileName) async {
  var name = sanitizeInboxFileName(fileName);
  var dest = p.join(dir, name);
  if (!await _hostExists(dest)) return dest;
  final stem = p.basenameWithoutExtension(name);
  final ext = p.extension(name);
  var i = 2;
  while (true) {
    dest = p.join(dir, sanitizeInboxFileName('$stem-$i$ext'));
    if (!await _hostExists(dest)) return dest;
    i++;
    if (i > 999) {
      throw StateError('无法分配唯一导出名称：$name');
    }
  }
}

Future<bool> _hostExists(String path) async {
  final type = await FileSystemEntity.type(path, followLinks: false);
  return type != FileSystemEntityType.notFound;
}
