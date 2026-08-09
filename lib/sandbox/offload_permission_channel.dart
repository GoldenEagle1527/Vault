import 'package:flutter/services.dart';
import 'package:vault/permissions/offload_permission_manager.dart';
import 'package:vault/permissions/permission_models.dart';

/// Dart-owned MethodChannel for Kotlin → Flutter permission checks.
///
/// Channel name: `vault.offload/permission`.
/// Kotlin [OffloadGate] invokes `checkPermission`; this side owns the handler
/// so it does not collide with `vault.offload/host` (Dart→Kotlin server control).
class OffloadPermissionChannel {
  OffloadPermissionChannel._();

  static const channelName = 'vault.offload/permission';
  static const channel = MethodChannel(channelName);

  static bool _registered = false;

  /// Register the Flutter MethodCallHandler (idempotent). Call before
  /// [OffloadHost.setBypassAll](false) so the gate can reach Dart.
  static void register() {
    if (_registered) return;
    channel.setMethodCallHandler(_onMethodCall);
    _registered = true;
  }

  /// Map OffloadServer capability tokens → [PermissionRegistry] ids.
  ///
  /// Wave2/3 tokens that already match registry ids
  /// (`calendar` / `contacts` / `photos` / `location` / `host_files` /
  /// `speak` / `speech` / `vault_config`) pass through unchanged.
  /// Short aliases from Android basename strip need rename.
  static String mapCapability(String capability) {
    switch (capability) {
      case 'device':
        return 'device_info';
      case 'open':
        return 'open_url';
      case 'config':
        return 'vault_config';
      case 'host_files':
      case 'speak':
      case 'speech':
      case 'vault_config':
        return capability;
      default:
        return capability;
    }
  }

  /// Local check used by the channel handler (and tests).
  ///
  /// Missing/blank [sessionId] → denied (exit 126 path on the host).
  static Future<bool> check({
    required String capability,
    required String sessionId,
  }) async {
    final sid = sessionId.trim();
    if (sid.isEmpty) return false;

    final permissionId = mapCapability(capability);
    final decision = await OffloadPermissionManager.instance.checkPermission(
      permissionId,
      sessionId: sid,
    );
    return decision == PermissionDecision.allowed;
  }

  static Future<dynamic> _onMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'checkPermission':
        final args = call.arguments;
        final map = args is Map ? args : const <Object?, Object?>{};
        final capability = map['capability']?.toString() ?? '';
        final sessionId = map['sessionId']?.toString() ?? '';
        final allowed = await check(
          capability: capability,
          sessionId: sessionId,
        );
        return <String, Object?>{'allowed': allowed};
      default:
        throw MissingPluginException(
          'No handler for ${call.method} on $channelName',
        );
    }
  }

  /// Test helper.
  static void resetForTest() {
    if (_registered) {
      channel.setMethodCallHandler(null);
    }
    _registered = false;
  }
}
