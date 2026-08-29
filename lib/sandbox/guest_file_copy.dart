import 'dart:io';

import 'package:path/path.dart' as p;

/// Copy [sourcePath] to [destPath] without loading the whole file into memory.
///
/// Creates parent directories. On failure, deletes a partial destination when
/// possible so a retry does not leave a truncated guest file.
Future<void> streamCopyHostFile({
  required String sourcePath,
  required String destPath,
}) async {
  final source = File(sourcePath);
  if (!await source.exists()) {
    throw StateError('源文件不存在：$sourcePath');
  }
  final dest = File(destPath);
  await dest.parent.create(recursive: true);
  final sink = dest.openWrite();
  try {
    await source.openRead().pipe(sink);
  } catch (_) {
    try {
      if (await dest.exists()) await dest.delete();
    } catch (_) {}
    rethrow;
  }
}

/// Stream [sourcePath] onto [sink] (e.g. `wsl.exe` stdin). Closes [sink].
Future<void> streamCopyHostFileToSink({
  required String sourcePath,
  required IOSink sink,
}) {
  return File(sourcePath).openRead().pipe(sink);
}

/// Recursively copy [src] into [dst] without following symlinks.
Future<void> copyHostDirectoryTree(Directory src, Directory dst) async {
  await dst.create(recursive: true);
  await for (final entity in src.list(followLinks: false)) {
    final name = p.basename(entity.path);
    final target = p.join(dst.path, name);
    if (entity is Directory) {
      await copyHostDirectoryTree(entity, Directory(target));
    } else if (entity is File) {
      await entity.copy(target);
    }
  }
}

/// Stream [stream] onto [destPath]. Deletes a partial file on failure.
Future<void> streamCopyToHostFile({
  required Stream<List<int>> stream,
  required String destPath,
}) async {
  final dest = File(destPath);
  await dest.parent.create(recursive: true);
  final sink = dest.openWrite();
  try {
    await stream.pipe(sink);
  } catch (_) {
    try {
      if (await dest.exists()) await dest.delete();
    } catch (_) {}
    rethrow;
  }
}
