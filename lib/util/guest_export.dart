import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:vault/sandbox/android_file_export.dart';
import 'package:vault/sandbox/guest_export_archive.dart';
import 'package:vault/sandbox/guest_fs_ops.dart';
import 'package:vault/sandbox/sandbox_provider.dart';
import 'package:vault/util/host_file_saver.dart';

enum GuestExportMode { saveAs, share, pack }

class GuestExportProgress {
  const GuestExportProgress({
    required this.current,
    required this.total,
    required this.name,
  });

  final int current;
  final int total;
  final String name;
}

class GuestExportResult {
  const GuestExportResult({
    required this.cancelled,
    this.ok = 0,
    this.failed = 0,
    this.message,
  });

  final bool cancelled;
  final int ok;
  final int failed;
  final String? message;

  static const cancelledResult = GuestExportResult(cancelled: true);
}

/// User-initiated export of guest paths onto the host (save / share / zip).
class GuestExport {
  GuestExport({required this.provider, required this.workspaceId});

  final SandboxProvider provider;
  final String workspaceId;

  Future<GuestExportResult> run({
    required GuestExportMode mode,
    required List<String> guestPaths,
    void Function(GuestExportProgress)? onProgress,
  }) async {
    final paths = guestPaths
        .map(assertGuestPathUnderHome)
        .toList(growable: false);
    if (paths.isEmpty) {
      return const GuestExportResult(cancelled: false, message: '没有选中项');
    }
    return switch (mode) {
      GuestExportMode.saveAs => _saveAs(paths, onProgress),
      GuestExportMode.share => _share(paths, onProgress),
      GuestExportMode.pack => _packAndSave(paths, onProgress),
    };
  }

  Future<GuestExportResult> _saveAs(
    List<String> paths,
    void Function(GuestExportProgress)? onProgress,
  ) async {
    if (paths.length == 1) {
      final type = await guestEntityType(provider, workspaceId, paths.first);
      if (type == FileSystemEntityType.directory) {
        return _saveMany(paths, onProgress);
      }
      return _saveSingleFile(paths.first, onProgress);
    }
    return _saveMany(paths, onProgress);
  }

  Future<GuestExportResult> _saveSingleFile(
    String guestPath,
    void Function(GuestExportProgress)? onProgress,
  ) async {
    final name = sanitizeInboxFileName(p.posix.basename(guestPath));
    if (!kIsWeb && Platform.isAndroid) {
      onProgress?.call(GuestExportProgress(current: 1, total: 1, name: name));
      return _saveAndroidDownloads(guestPath, name);
    }
    final dest = await pickHostSaveFilePath(fileName: name);
    if (dest == null || dest.isEmpty) return GuestExportResult.cancelledResult;
    onProgress?.call(GuestExportProgress(current: 1, total: 1, name: name));
    await exportGuestFileToHost(
      provider: provider,
      workspaceId: workspaceId,
      guestAbsolutePath: guestPath,
      hostPath: dest,
    );
    return GuestExportResult(cancelled: false, ok: 1, message: '已导出 $name');
  }

  Future<GuestExportResult> _saveMany(
    List<String> paths,
    void Function(GuestExportProgress)? onProgress,
  ) async {
    if (!kIsWeb && Platform.isAndroid) {
      return _packThenAndroidDownloads(paths, onProgress);
    }
    if (paths.length == 1) {
      final type = await guestEntityType(provider, workspaceId, paths.first);
      if (type == FileSystemEntityType.directory) {
        final destDir = await pickHostDirectoryPath();
        if (destDir == null || destDir.isEmpty) {
          return GuestExportResult.cancelledResult;
        }
        final name = sanitizeInboxFileName(p.posix.basename(paths.first));
        onProgress?.call(GuestExportProgress(current: 1, total: 1, name: name));
        final dest = await allocateUniqueHostPath(destDir, name);
        await exportGuestDirectoryToHost(
          provider: provider,
          workspaceId: workspaceId,
          guestAbsolutePath: paths.first,
          hostDir: dest,
        );
        return GuestExportResult(cancelled: false, ok: 1, message: '已导出 $name');
      }
    }
    final destDir = await pickHostDirectoryPath();
    if (destDir == null || destDir.isEmpty) {
      return GuestExportResult.cancelledResult;
    }
    var ok = 0;
    var failed = 0;
    for (var i = 0; i < paths.length; i++) {
      final guest = paths[i];
      final name = sanitizeInboxFileName(p.posix.basename(guest));
      onProgress?.call(
        GuestExportProgress(current: i + 1, total: paths.length, name: name),
      );
      try {
        final dest = await allocateUniqueHostPath(destDir, name);
        await exportGuestPathToHost(
          provider: provider,
          workspaceId: workspaceId,
          guestAbsolutePath: guest,
          hostPath: dest,
        );
        ok++;
      } catch (_) {
        failed++;
      }
    }
    return GuestExportResult(
      cancelled: false,
      ok: ok,
      failed: failed,
      message: failed == 0 ? '已导出 $ok 项' : '导出完成：成功 $ok，失败 $failed',
    );
  }

  Future<GuestExportResult> _packAndSave(
    List<String> paths,
    void Function(GuestExportProgress)? onProgress,
  ) async {
    final zipName = zipFileNameForSelection(paths);
    if (!kIsWeb && Platform.isAndroid) {
      final zip = await _zipToTemp(paths, zipName, onProgress);
      try {
        await AndroidFileExport.saveToDownloads(
          displayName: zipName,
          sourcePath: zip.path,
          mimeType: 'application/zip',
        );
        return GuestExportResult(
          cancelled: false,
          ok: 1,
          message: '已导出 $zipName',
        );
      } finally {
        await _deleteQuiet(zip);
      }
    }
    final dest = await pickHostSaveFilePath(fileName: zipName);
    if (dest == null || dest.isEmpty) return GuestExportResult.cancelledResult;
    await _zipToPath(paths, dest, onProgress);
    return GuestExportResult(cancelled: false, ok: 1, message: '已导出 $zipName');
  }

  Future<GuestExportResult> _share(
    List<String> paths,
    void Function(GuestExportProgress)? onProgress,
  ) async {
    final staged = <File>[];
    try {
      if (paths.length == 1) {
        final type = await guestEntityType(provider, workspaceId, paths.first);
        if (type != FileSystemEntityType.directory) {
          final name = sanitizeInboxFileName(p.posix.basename(paths.first));
          onProgress?.call(
            GuestExportProgress(current: 1, total: 1, name: name),
          );
          staged.add(await _stageFile(paths.first, name));
          final sent = await _shareFiles(staged);
          if (!sent) return GuestExportResult.cancelledResult;
          return GuestExportResult(
            cancelled: false,
            ok: 1,
            message: '已分享 $name',
          );
        }
      }
      final zipName = zipFileNameForSelection(paths);
      final zip = await _zipToTemp(paths, zipName, onProgress);
      staged.add(zip);
      final sent = await _shareFiles(staged);
      if (!sent) return GuestExportResult.cancelledResult;
      return GuestExportResult(
        cancelled: false,
        ok: 1,
        message: '已分享 $zipName',
      );
    } finally {
      for (final f in staged) {
        await _deleteQuiet(f);
      }
    }
  }

  Future<GuestExportResult> _saveAndroidDownloads(
    String guestPath,
    String name,
  ) async {
    final staged = await _stageFile(guestPath, name);
    try {
      await AndroidFileExport.saveToDownloads(
        displayName: name,
        sourcePath: staged.path,
      );
      return GuestExportResult(
        cancelled: false,
        ok: 1,
        message: '已保存到下载：$name',
      );
    } finally {
      await _deleteQuiet(staged);
    }
  }

  Future<GuestExportResult> _packThenAndroidDownloads(
    List<String> paths,
    void Function(GuestExportProgress)? onProgress,
  ) {
    return _packAndSave(paths, onProgress);
  }

  Future<void> _zipToPath(
    List<String> paths,
    String dest,
    void Function(GuestExportProgress)? onProgress,
  ) async {
    try {
      await zipGuestPathsToHost(
        provider: provider,
        workspaceId: workspaceId,
        guestPaths: paths,
        destZipPath: dest,
        onProgress: onProgress == null
            ? null
            : (c, t, n) => onProgress(
                GuestExportProgress(current: c, total: t, name: n),
              ),
      );
    } catch (_) {
      final dir = await _exportTempDir();
      final staging = Directory(p.join(dir.path, 'stage'));
      await zipGuestPathsViaStaging(
        provider: provider,
        workspaceId: workspaceId,
        guestPaths: paths,
        destZipPath: dest,
        stagingDir: staging,
        onProgress: onProgress == null
            ? null
            : (c, t, n) => onProgress(
                GuestExportProgress(current: c, total: t, name: n),
              ),
      );
      try {
        if (await staging.exists()) await staging.delete(recursive: true);
        if (await dir.exists()) await dir.delete(recursive: true);
      } catch (_) {}
    }
  }

  Future<File> _zipToTemp(
    List<String> paths,
    String zipName,
    void Function(GuestExportProgress)? onProgress,
  ) async {
    final dir = await _exportTempDir();
    final dest = p.join(dir.path, zipName);
    await _zipToPath(paths, dest, onProgress);
    return File(dest);
  }

  Future<File> _stageFile(String guestPath, String name) async {
    final dir = await _exportTempDir();
    final dest = p.join(dir.path, name);
    await exportGuestFileToHost(
      provider: provider,
      workspaceId: workspaceId,
      guestAbsolutePath: guestPath,
      hostPath: dest,
    );
    return File(dest);
  }

  Future<Directory> _exportTempDir() async {
    final root = kIsWeb ? Directory.systemTemp : await getTemporaryDirectory();
    final dir = Directory(
      p.join(
        root.path,
        'vault_export_${DateTime.now().microsecondsSinceEpoch}',
      ),
    );
    await dir.create(recursive: true);
    return dir;
  }

  Future<bool> _shareFiles(List<File> files) async {
    final payload = files
        .where((f) => f.existsSync())
        .map((f) => XFile(f.path, name: p.basename(f.path)))
        .toList(growable: false);
    if (payload.isEmpty) {
      throw StateError('没有可分享的文件');
    }
    final result = await SharePlus.instance.share(ShareParams(files: payload));
    return result.status != ShareResultStatus.dismissed;
  }
}

Future<void> _deleteQuiet(File file) async {
  try {
    if (await file.exists()) await file.delete();
    final parent = file.parent;
    if (p.basename(parent.path).startsWith('vault_export_') &&
        await parent.exists()) {
      final leftover = await parent.list().isEmpty;
      if (leftover) await parent.delete();
    }
  } catch (_) {}
}
