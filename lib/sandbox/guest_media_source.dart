import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:vault/sandbox/sandbox_provider.dart';

/// Max bytes to copy into a host temp file when UNC / host mapping fails.
const int kGuestMediaTempCopyMaxBytes = 64 * 1024 * 1024;

/// Host-side handle for previewing a guest media file.
class GuestMediaSource {
  GuestMediaSource._({
    required this.hostFile,
    required this.isTemporary,
    this.bytes,
  });

  /// Path playable by [Image.file] / [VideoPlayerController.file] / audioplayers.
  final File hostFile;

  /// When true, caller should delete [hostFile] after dispose.
  final bool isTemporary;

  /// Optional in-memory bytes (images prefer this to avoid a second disk hit).
  final Uint8List? bytes;

  /// Existing host file (composer drop / paste preview). Not deleted on [dispose].
  factory GuestMediaSource.hostFile(File file, {Uint8List? bytes}) {
    return GuestMediaSource._(hostFile: file, isTemporary: false, bytes: bytes);
  }

  Future<void> dispose() async {
    if (!isTemporary) return;
    try {
      if (await hostFile.exists()) {
        await hostFile.delete();
      }
    } catch (_) {}
  }
}

/// Resolve a guest media path to a host [File], falling back to a temp copy.
Future<GuestMediaSource> openGuestMediaSource({
  required SandboxProvider provider,
  required String workspaceId,
  required String guestAbsolutePath,
  bool loadBytes = false,
}) async {
  final guest = assertGuestPathUnderHome(guestAbsolutePath);

  Uint8List? bytes;
  if (loadBytes) {
    bytes = await provider.readGuestFile(workspaceId, guest);
    if (bytes == null) {
      throw StateError('文件不存在或无法读取：$guest');
    }
  }

  try {
    final hostPath = await provider.resolveGuestHostPath(workspaceId, guest);
    final file = File(hostPath);
    if (await file.exists()) {
      return GuestMediaSource._(
        hostFile: file,
        isTemporary: false,
        bytes: bytes,
      );
    }
  } catch (_) {
    // Fall through to temp materialization.
  }

  bytes ??= await provider.readGuestFile(workspaceId, guest);
  if (bytes == null) {
    throw StateError('文件不存在或无法读取：$guest');
  }
  if (bytes.length > kGuestMediaTempCopyMaxBytes) {
    throw StateError(
      '文件过大（>${kGuestMediaTempCopyMaxBytes ~/ (1024 * 1024)} MB），'
      '无法通过临时文件预览',
    );
  }

  final ext = p.extension(guest);
  final tmp = File(
    p.join(
      Directory.systemTemp.path,
      'vault_preview_${workspaceId}_'
      '${DateTime.now().microsecondsSinceEpoch}$ext',
    ),
  );
  await tmp.writeAsBytes(bytes, flush: true);
  return GuestMediaSource._(hostFile: tmp, isTemporary: true, bytes: bytes);
}
