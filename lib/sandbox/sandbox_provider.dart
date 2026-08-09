import 'dart:io';
import 'dart:typed_data';

import 'package:vault/sandbox/proot_provider.dart';
import 'package:vault/sandbox/sandbox_models.dart';
import 'package:vault/sandbox/wsl_provider.dart';

export 'package:vault/sandbox/sandbox_models.dart';

/// Platform-agnostic workspace sandbox lifecycle. Implementations must not
/// leak [Process] through this interface.
abstract class SandboxProvider {
  Future<SandboxCapabilities> probe();

  Future<SandboxWorkspace> create(String workspaceId);

  Future<SandboxWorkspace> attach(String workspaceId);

  Future<void> destroy(String workspaceId);

  Future<List<WorkspaceInfo>> list();

  /// Read a guest file under [kGuestHome]. Returns null if missing / unreadable.
  Future<Uint8List?> readGuestFile(
    String workspaceId,
    String guestAbsolutePath,
  );

  /// Write a guest file under [kGuestHome] (creates parent dirs).
  Future<void> writeGuestFile(
    String workspaceId,
    String guestAbsolutePath,
    List<int> bytes,
  );

  /// Delete a guest file or directory under [kGuestHome].
  Future<void> deleteGuestPath(
    String workspaceId,
    String guestAbsolutePath, {
    bool recursive = false,
  });
}

SandboxProvider createSandboxProvider() {
  if (Platform.isWindows) {
    return WslProvider();
  }
  if (Platform.isAndroid) {
    return ProotProvider();
  }
  throw UnsupportedError(
    'Vault sandbox is only supported on Windows and Android '
    '(got ${Platform.operatingSystem}).',
  );
}
