import 'package:vault/sandbox/android_keep_alive.dart';
import 'package:vault/sandbox/desktop_keep_alive.dart';

/// Cross-platform keep-alive: Android FGS notification + desktop tray.
class VaultKeepAlive {
  VaultKeepAlive._();

  static Future<void> sync({String? siteName}) async {
    await AndroidKeepAlive.ensureRunning(siteName: siteName);
    await DesktopKeepAlive.instance.updateStatus(siteName: siteName);
  }
}
