import 'package:vault/sandbox/android_keep_alive.dart';
import 'package:vault/sandbox/desktop_keep_alive.dart';

/// Cross-platform keep-alive: Android FGS notification + desktop tray.
class VaultKeepAlive {
  VaultKeepAlive._();

  static Future<void> sync({
    String? siteName,
    Iterable<String> siteNames = const [],
  }) async {
    final names = [
      ...siteNames.map((n) => n.trim()).where((n) => n.isNotEmpty),
      if (siteName != null && siteName.trim().isNotEmpty) siteName.trim(),
    ];
    final label = names.toSet().join('、');
    final value = label.isEmpty ? null : label;
    await AndroidKeepAlive.ensureRunning(siteName: value);
    await DesktopKeepAlive.instance.updateStatus(siteName: value);
  }
}
