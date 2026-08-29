import 'dart:io';

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
