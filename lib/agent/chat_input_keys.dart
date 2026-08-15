import 'package:flutter/foundation.dart';

/// Desktop Enter sends; Shift+Enter inserts a newline.
/// Mobile Enter always inserts a newline.
bool chatEnterShouldSend({
  required TargetPlatform platform,
  required bool shiftPressed,
  bool composing = false,
}) {
  if (composing) return false;
  return _desktopEnterHint(platform) && !shiftPressed;
}

bool _desktopEnterHint(TargetPlatform platform) {
  switch (platform) {
    case TargetPlatform.android:
    case TargetPlatform.iOS:
    case TargetPlatform.fuchsia:
      return false;
    case TargetPlatform.windows:
    case TargetPlatform.linux:
    case TargetPlatform.macOS:
      return true;
  }
}

/// Shown under the composer on desktop.
bool desktopEnterHint(TargetPlatform platform) => _desktopEnterHint(platform);
