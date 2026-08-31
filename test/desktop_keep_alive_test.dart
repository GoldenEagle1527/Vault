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
    expect(lines.join('\n'), contains('运行中'));

    final idle = desktopKeepAliveStatusLines(siteRunning: false);
    expect(idle.join('\n'), contains('未启动'));
    expect(idle.join('\n'), isNot(contains('托盘可停止')));
  });

  test('notifyShownFromTray invokes onForeground', () {
    final desktop = DesktopKeepAlive.instance;
    var calls = 0;
    desktop.onForeground = () => calls++;
    addTearDown(() => desktop.onForeground = null);
    desktop.notifyShownFromTray();
    expect(calls, 1);
  });

  test('updateStatus records siteName without attaching the tray', () async {
    final desktop = DesktopKeepAlive.instance;
    addTearDown(() => desktop.updateStatus());
    await desktop.updateStatus(siteName: ' 演示站 ');
    expect(desktop.siteName, '演示站');
    await desktop.updateStatus();
    expect(desktop.siteName, isNull);
  });
}
