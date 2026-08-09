import 'dart:io';

import 'package:flutter/services.dart';
import 'package:vault/sandbox/offload_permission_channel.dart';

/// Android MethodChannel helpers for the host offload TCP bridge.
class OffloadHost {
  OffloadHost._();

  static const channel = MethodChannel('vault.offload/host');

  static int? _port;
  static int _refcount = 0;

  static bool get isAndroid => Platform.isAndroid;

  static int? get port => _port;

  /// Start localhost TCP server if needed; returns bound port.
  static Future<int> ensureStarted() async {
    if (!isAndroid) {
      throw UnsupportedError('OffloadHost is Android-only');
    }
    if (_port != null && _port! > 0) return _port!;
    final v = await channel.invokeMethod<int>('startServer');
    if (v == null || v <= 0) {
      throw StateError('startServer 未返回有效端口');
    }
    _port = v;
    return v;
  }

  static Future<int> getPort() async {
    if (!isAndroid) return 0;
    final v = await channel.invokeMethod<int>('getPort');
    final p = v ?? 0;
    if (p > 0) _port = p;
    return p;
  }

  /// Refcount tied to live workspaces (same lifetime idea as FGS).
  static Future<int> acquire() async {
    if (!isAndroid) return 0;
    _refcount++;
    return ensureStarted();
  }

  static Future<void> release() async {
    if (!isAndroid) return;
    if (_refcount > 0) _refcount--;
    if (_refcount == 0) {
      try {
        await channel.invokeMethod<void>('stopServer');
      } catch (_) {}
      _port = null;
    }
  }

  /// Toggle Kotlin [OffloadGate.bypassAll]. Wave1 production path sets false
  /// after [OffloadPermissionChannel.register] so checks hit Dart.
  static Future<bool> setBypassAll(bool bypass) async {
    if (!isAndroid) return bypass;
    final v = await channel.invokeMethod<bool>(
      'setBypassAll',
      {'bypass': bypass},
    );
    return v ?? bypass;
  }

  /// Permission probe via Dart manager (same mapping as the permission channel).
  static Future<Map<String, Object?>> checkPermission({
    required String capability,
    String sessionId = '',
  }) async {
    final allowed = await OffloadPermissionChannel.check(
      capability: capability,
      sessionId: sessionId,
    );
    return <String, Object?>{
      'allowed': allowed,
      'capability': capability,
      'sessionId': sessionId,
    };
  }
}
