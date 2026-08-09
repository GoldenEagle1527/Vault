import 'package:vault/offload/offload_protocol.dart';
import 'package:vault/permissions/offload_permission_manager.dart';
import 'package:vault/permissions/permission_models.dart';

/// Permission gate for host offload handlers (Dart registry).
///
/// Defaults to [OffloadPermissionManager.instance]. Tests may override
/// [checker] to inject a fixed decision.
typedef OffloadPermissionChecker = Future<OffloadResponse?> Function({
  required String permissionId,
  required String command,
  required String? sessionId,
});

class OffloadGate {
  OffloadGate._();

  /// If set, return a non-null [OffloadResponse] to short-circuit (e.g. 126).
  /// Return null to allow the handler to run.
  static OffloadPermissionChecker? checker;

  /// Maps Wave1–4 CLI basenames → registry permission ids.
  static String? permissionIdForCommand(String command) {
    switch (command) {
      case 'vault-clipboard':
        return 'clipboard';
      case 'vault-device':
        return 'device_info';
      case 'vault-open':
        return 'open_url';
      case 'vault-notification':
        return 'notification';
      case 'vault-calendar':
        return 'calendar';
      case 'vault-contacts':
        return 'contacts';
      case 'vault-photos':
        return 'photos';
      case 'vault-location':
        return 'location';
      case 'vault-host-files':
        return 'host_files';
      case 'vault-config':
        return 'vault_config';
      case 'vault-speak':
        return 'speak';
      case 'vault-speech':
        return 'speech';
      case 'vault-a11y':
        return 'a11y';
      case 'vault-shizuku':
        return 'shizuku';
      default:
        return null;
    }
  }

  static Future<OffloadResponse?> check({
    required String command,
    required String? sessionId,
  }) async {
    final permissionId = permissionIdForCommand(command);
    if (permissionId == null) {
      // Unknown CLIs are handled by the dispatcher (127), not the gate.
      return null;
    }

    final c = checker;
    if (c != null) {
      return c(
        permissionId: permissionId,
        command: command,
        sessionId: sessionId,
      );
    }

    // Spec: missing/unknown session → permission_denied (126).
    final sid = sessionId?.trim() ?? '';
    if (sid.isEmpty) {
      return OffloadResponse.permissionDenied('permission_denied: missing session');
    }

    final decision = await OffloadPermissionManager.instance.checkPermission(
      permissionId,
      sessionId: sid,
    );
    if (decision == PermissionDecision.denied) {
      return OffloadResponse.permissionDenied();
    }
    return null;
  }
}
