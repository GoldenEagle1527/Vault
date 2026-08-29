import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Android MethodChannel for streaming a host file into system Downloads.
class AndroidFileExport {
  AndroidFileExport._();

  static const channel = MethodChannel('vault.files/export');

  static Future<String> saveToDownloads({
    required String displayName,
    required String sourcePath,
    String? mimeType,
  }) async {
    if (kIsWeb) {
      throw UnsupportedError('saveToDownloads is Android-only');
    }
    final result = await channel.invokeMethod<String>('saveToDownloads', {
      'displayName': displayName,
      'sourcePath': sourcePath,
      if (mimeType != null) 'mimeType': mimeType,
    });
    if (result == null || result.isEmpty) {
      throw StateError('saveToDownloads 未返回路径');
    }
    return result;
  }
}
