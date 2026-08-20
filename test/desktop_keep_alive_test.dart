import 'package:flutter_test/flutter_test.dart';
import 'package:vault/sandbox/desktop_keep_alive.dart';

void main() {
  test('desktopTrayTooltip names a running site', () {
    expect(desktopTrayTooltip(), contains('工作区在后台运行'));
    expect(desktopTrayTooltip(siteName: ' 网站 '), contains('「网站」'));
  });

  test('desktopTrayMenuSpecs adds stop when a site is up', () {
    final idle = desktopTrayMenuSpecs(siteRunning: false);
    expect(idle.map((e) => e.key), [
      kDesktopTrayShowWindow,
      'separator',
      kDesktopTrayQuit,
    ]);

    final live = desktopTrayMenuSpecs(siteRunning: true);
    expect(live.map((e) => e.key), [
      kDesktopTrayShowWindow,
      kDesktopTrayStopSite,
      'separator',
      kDesktopTrayQuit,
    ]);
  });

  test('desktopKeepAliveStatusLines mention tray quit', () {
    final lines = desktopKeepAliveStatusLines(siteRunning: true);
    expect(lines.join('\n'), contains('停止站点'));
    expect(lines.join('\n'), contains('退出 Vault'));
  });
}
