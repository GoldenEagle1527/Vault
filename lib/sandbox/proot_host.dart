import 'package:flutter/services.dart';

/// Android MethodChannel helpers for proot (nativeLibraryDir, FGS, page size).
class ProotHost {
  ProotHost._();

  static const channel = MethodChannel('vault.sandbox/proot');

  static Future<String> getNativeLibraryDir() async {
    final v = await channel.invokeMethod<String>('getNativeLibraryDir');
    if (v == null || v.isEmpty) {
      throw StateError('getNativeLibraryDir 返回空');
    }
    return v;
  }

  static Future<String> getFilesDir() async {
    final v = await channel.invokeMethod<String>('getFilesDir');
    if (v == null || v.isEmpty) {
      throw StateError('getFilesDir 返回空');
    }
    return v;
  }

  static Future<int> getPageSize() async {
    final v = await channel.invokeMethod<int>('getPageSize');
    return v ?? 4096;
  }

  static Future<String> getAbi() async {
    final v = await channel.invokeMethod<String>('getAbi');
    return v ?? 'unknown';
  }

  static Future<AndroidKeepAliveStatus> getKeepAliveStatus() async {
    final raw = await channel.invokeMethod<Map<Object?, Object?>>(
      'getKeepAliveStatus',
    );
    if (raw == null) {
      return const AndroidKeepAliveStatus(
        notificationsEnabled: false,
        batteryOptimizationIgnored: false,
        foregroundServiceRunning: false,
      );
    }
    return AndroidKeepAliveStatus(
      notificationsEnabled: raw['notificationsEnabled'] == true,
      batteryOptimizationIgnored: raw['batteryOptimizationIgnored'] == true,
      foregroundServiceRunning: raw['foregroundServiceRunning'] == true,
    );
  }

  static Future<void> startForegroundService({
    String? title,
    String? text,
    bool showStopSite = false,
  }) async {
    await channel.invokeMethod<void>('startForegroundService', {
      if (title != null) 'title': title,
      if (text != null) 'text': text,
      'showStopSite': showStopSite,
    });
  }

  static Future<void> updateForegroundService({
    String? title,
    String? text,
    bool showStopSite = false,
  }) async {
    await channel.invokeMethod<void>('updateForegroundService', {
      if (title != null) 'title': title,
      if (text != null) 'text': text,
      'showStopSite': showStopSite,
    });
  }

  static void bindKeepAliveActions(void Function(String action) handler) {
    channel.setMethodCallHandler((call) async {
      if (call.method == 'onKeepAliveAction') {
        final action = call.arguments?.toString() ?? '';
        if (action.isNotEmpty) handler(action);
      }
    });
  }

  static void unbindKeepAliveActions() {
    channel.setMethodCallHandler(null);
  }

  static Future<void> stopForegroundService() async {
    await channel.invokeMethod<void>('stopForegroundService');
  }

  static Future<bool> requestNotificationPermission() async {
    final v = await channel.invokeMethod<bool>('requestNotificationPermission');
    return v ?? false;
  }

  /// Opens the system dialog; returns whether optimization is already ignored.
  static Future<bool> requestIgnoreBatteryOptimizations() async {
    final v = await channel.invokeMethod<bool>(
      'requestIgnoreBatteryOptimizations',
    );
    return v ?? false;
  }

  static Future<void> openBatteryOptimizationSettings() async {
    await channel.invokeMethod<void>('openBatteryOptimizationSettings');
  }
}

/// Native keep-alive signals reported by [ProotHost.getKeepAliveStatus].
class AndroidKeepAliveStatus {
  const AndroidKeepAliveStatus({
    required this.notificationsEnabled,
    required this.batteryOptimizationIgnored,
    required this.foregroundServiceRunning,
  });

  final bool notificationsEnabled;
  final bool batteryOptimizationIgnored;
  final bool foregroundServiceRunning;

  bool get ready =>
      notificationsEnabled && batteryOptimizationIgnored && foregroundServiceRunning;
}
