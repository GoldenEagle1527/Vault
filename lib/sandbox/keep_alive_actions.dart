import 'package:flutter/foundation.dart';

/// Shared keep-alive actions for Android FGS notification and desktop tray.
const kKeepAliveStopSiteAction = 'stopSite';

class KeepAliveActions {
  KeepAliveActions._();

  static VoidCallback? onStopSiteRequested;

  static void requestStopSite() => onStopSiteRequested?.call();
}
