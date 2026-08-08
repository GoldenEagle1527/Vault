import 'dart:io';

import 'package:vault/sandbox/proot_provider.dart';
import 'package:vault/sandbox/sandbox_models.dart';
import 'package:vault/sandbox/wsl_provider.dart';

export 'package:vault/sandbox/sandbox_models.dart';

/// Platform-agnostic sandbox lifecycle. Implementations must not leak
/// [Process] through this interface.
abstract class SandboxProvider {
  Future<SandboxCapabilities> probe();

  Future<SandboxSession> create(String sessionId);

  Future<SandboxSession> attach(String sessionId);

  Future<void> destroy(String sessionId);

  Future<List<SandboxInfo>> list();
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
