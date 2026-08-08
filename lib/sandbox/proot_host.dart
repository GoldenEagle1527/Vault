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

  static Future<void> startForegroundService() async {
    await channel.invokeMethod<void>('startForegroundService');
  }

  static Future<void> stopForegroundService() async {
    await channel.invokeMethod<void>('stopForegroundService');
  }

  static Future<void> openBatteryOptimizationSettings() async {
    await channel.invokeMethod<void>('openBatteryOptimizationSettings');
  }
}
