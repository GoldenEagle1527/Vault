/// Host-side handler for `vault-*` guest CLIs.
///
/// TODO(native-android): Implement via Kotlin MethodChannel / AIDL — map
/// [permissionId] to ClipboardManager, CalendarContract, etc. Return process
/// exit semantics to the guest shim: `0` ok, `125` unsupported_platform,
/// `126` permission_denied.
///
/// TODO(native-windows): Implement via C++ / WinRT bridge for the same ids.
/// Do not call into this from Flutter UI until a concrete platform channel
/// is registered in `MainActivity` / `flutter_window`.
abstract class VaultNativeOffloadHandler {
  /// Invoke a host capability. [args] are CLI argv after the binary name.
  Future<VaultNativeOffloadResult> invoke(
    String permissionId,
    List<String> args, {
    String? sessionId,
  });
}

class VaultNativeOffloadResult {
  const VaultNativeOffloadResult({
    required this.exitCode,
    this.stdout = '',
    this.stderr = '',
  });

  final int exitCode;
  final String stdout;
  final String stderr;
}

/// Exit codes agreed with guest CLI shims (see docs/feat.md F8).
abstract final class VaultOffloadExitCode {
  static const ok = 0;
  static const unsupportedPlatform = 125;
  static const permissionDenied = 126;
}

/// Placeholder until native bridges exist. Always returns unsupported.
class UnimplementedVaultNativeOffloadHandler
    implements VaultNativeOffloadHandler {
  const UnimplementedVaultNativeOffloadHandler();

  @override
  Future<VaultNativeOffloadResult> invoke(
    String permissionId,
    List<String> args, {
    String? sessionId,
  }) async {
    return VaultNativeOffloadResult(
      exitCode: VaultOffloadExitCode.unsupportedPlatform,
      stderr:
          'native bridge not implemented for $permissionId '
          '(session=${sessionId ?? '-'})',
    );
  }
}
