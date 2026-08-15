import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault/agent/chat_input_keys.dart';

void main() {
  test('desktop Enter sends, Shift+Enter does not', () {
    for (final platform in [
      TargetPlatform.windows,
      TargetPlatform.linux,
      TargetPlatform.macOS,
    ]) {
      expect(
        chatEnterShouldSend(platform: platform, shiftPressed: false),
        isTrue,
      );
      expect(
        chatEnterShouldSend(platform: platform, shiftPressed: true),
        isFalse,
      );
      expect(desktopEnterHint(platform), isTrue);
    }
  });

  test('mobile Enter never sends', () {
    for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
      expect(
        chatEnterShouldSend(platform: platform, shiftPressed: false),
        isFalse,
      );
      expect(
        chatEnterShouldSend(platform: platform, shiftPressed: true),
        isFalse,
      );
      expect(desktopEnterHint(platform), isFalse);
    }
  });

  test('IME composing blocks send even on desktop', () {
    expect(
      chatEnterShouldSend(
        platform: TargetPlatform.windows,
        shiftPressed: false,
        composing: true,
      ),
      isFalse,
    );
  });
}
