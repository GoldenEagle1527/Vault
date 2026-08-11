import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:vault/sandbox/guest_fs_list.dart';
import 'package:vault/sandbox/sandbox_provider.dart';

/// Byte-level guest filesystem access for a workspace (no PTY required).
///
/// Paths must stay under [kGuestHome]. Used for project / conversation
/// persistence inside the guest Linux.
abstract class WorkspaceGuestFs {
  Future<Uint8List?> readBytes(String workspaceId, String guestAbsolutePath);

  Future<void> writeBytes(
    String workspaceId,
    String guestAbsolutePath,
    List<int> bytes,
  );

  Future<void> deletePath(
    String workspaceId,
    String guestAbsolutePath, {
    bool recursive = false,
  });

  /// Non-recursive directory listing under [kGuestHome].
  Future<List<GuestFsEntry>> listDirectory(
    String workspaceId,
    String guestAbsolutePath,
  );

  Future<String?> readUtf8(String workspaceId, String guestAbsolutePath) async {
    final bytes = await readBytes(workspaceId, guestAbsolutePath);
    if (bytes == null) return null;
    return utf8.decode(bytes, allowMalformed: true);
  }

  Future<void> writeUtf8(
    String workspaceId,
    String guestAbsolutePath,
    String text,
  ) {
    return writeBytes(workspaceId, guestAbsolutePath, utf8.encode(text));
  }
}

/// Production backend: [SandboxProvider] guest IO (WSL UNC / proot rootfs).
class SandboxWorkspaceGuestFs extends WorkspaceGuestFs {
  SandboxWorkspaceGuestFs(this.provider);

  final SandboxProvider provider;

  @override
  Future<Uint8List?> readBytes(String workspaceId, String guestAbsolutePath) {
    return provider.readGuestFile(workspaceId, guestAbsolutePath);
  }

  @override
  Future<void> writeBytes(
    String workspaceId,
    String guestAbsolutePath,
    List<int> bytes,
  ) {
    return provider.writeGuestFile(workspaceId, guestAbsolutePath, bytes);
  }

  @override
  Future<void> deletePath(
    String workspaceId,
    String guestAbsolutePath, {
    bool recursive = false,
  }) {
    return provider.deleteGuestPath(
      workspaceId,
      guestAbsolutePath,
      recursive: recursive,
    );
  }

  @override
  Future<List<GuestFsEntry>> listDirectory(
    String workspaceId,
    String guestAbsolutePath,
  ) {
    return provider.listGuestDirectory(workspaceId, guestAbsolutePath);
  }
}

/// Test backend: maps guest `/root/...` onto `{root}/{workspaceId}/...` on host.
class LocalDirWorkspaceGuestFs extends WorkspaceGuestFs {
  LocalDirWorkspaceGuestFs(this.rootDirectory);

  final String rootDirectory;

  File _hostFile(String workspaceId, String guestAbsolutePath) {
    final guest = assertGuestPathUnderHome(guestAbsolutePath);
    final relative = guest.substring(1); // drop leading /
    return File(p.join(rootDirectory, workspaceId, relative));
  }

  String _hostPath(String workspaceId, String guestAbsolutePath) {
    final guest = assertGuestPathUnderHome(guestAbsolutePath);
    final relative = guest.substring(1);
    return p.join(rootDirectory, workspaceId, relative);
  }

  @override
  Future<Uint8List?> readBytes(
    String workspaceId,
    String guestAbsolutePath,
  ) async {
    final file = _hostFile(workspaceId, guestAbsolutePath);
    if (!await file.exists()) return null;
    return Uint8List.fromList(await file.readAsBytes());
  }

  @override
  Future<void> writeBytes(
    String workspaceId,
    String guestAbsolutePath,
    List<int> bytes,
  ) async {
    final file = _hostFile(workspaceId, guestAbsolutePath);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes, flush: true);
  }

  @override
  Future<void> deletePath(
    String workspaceId,
    String guestAbsolutePath, {
    bool recursive = false,
  }) async {
    final guest = assertGuestPathUnderHome(guestAbsolutePath);
    final relative = guest.substring(1);
    final path = p.join(rootDirectory, workspaceId, relative);
    final type = await FileSystemEntity.type(path);
    if (type == FileSystemEntityType.notFound) return;
    if (type == FileSystemEntityType.directory) {
      await Directory(path).delete(recursive: recursive);
    } else {
      await File(path).delete();
    }
  }

  @override
  Future<List<GuestFsEntry>> listDirectory(
    String workspaceId,
    String guestAbsolutePath,
  ) {
    final guest = assertGuestPathUnderHome(guestAbsolutePath);
    return listGuestDirectoryOnHost(
      hostPath: _hostPath(workspaceId, guest),
      guestDir: guest,
    );
  }
}
