import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:vault/sandbox/android_keep_alive.dart';
import 'package:window_manager/window_manager.dart';

const kDesktopTrayIconIco = 'assets/tray/app_icon.ico';
const kDesktopTrayIconPng = 'assets/tray/app_icon.png';

const kDesktopTrayShowWindow = 'show_window';
const kDesktopTrayStopSite = 'stop_site';
const kDesktopTrayQuit = 'quit';

/// Close-to-tray keep-alive for Windows / Linux / macOS.
///
/// Aligns with Android foreground-service: hiding the window must not kill
/// the workspace or running sites. Real exit is only via the tray menu.
class DesktopKeepAlive with WindowListener, TrayListener {
  DesktopKeepAlive._();

  static final DesktopKeepAlive instance = DesktopKeepAlive._();

  static bool get supported =>
      !kIsWeb &&
      (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

  static bool get shouldAttach =>
      supported && !Platform.environment.containsKey('FLUTTER_TEST');

  GlobalKey<NavigatorState>? navigatorKey;

  /// Called after the window is shown from the tray (and by tests).
  VoidCallback? onForeground;

  String? _siteName;
  bool _attached = false;
  bool _quitting = false;

  bool get attached => _attached;

  /// Last site name synced into the tray tooltip; null when no site is running.
  String? get siteName => _siteName;

  /// Call after [windowManager.ensureInitialized] and a [navigatorKey] is set.
  Future<void> attach() async {
    if (!shouldAttach || _attached) return;
    _attached = true;
    windowManager.addListener(this);
    trayManager.addListener(this);
    try {
      await windowManager.setPreventClose(true);
      await _installTray();
    } catch (e, st) {
      stderr.writeln('DesktopKeepAlive attach failed: $e\n$st');
    }
  }

  Future<void> updateStatus({String? siteName}) async {
    final trimmed = siteName?.trim();
    _siteName = (trimmed == null || trimmed.isEmpty) ? null : trimmed;
    if (!shouldAttach || !_attached) return;
    try {
      await _refreshTray();
    } catch (_) {}
  }

  Future<void> showFromTray() async {
    if (shouldAttach) {
      await windowManager.setSkipTaskbar(false);
      await windowManager.show();
      await windowManager.focus();
    }
    notifyShownFromTray();
  }

  /// Invoke [onForeground] without touching the real window (tests / tray path).
  void notifyShownFromTray() => onForeground?.call();

  Future<void> hideToTray() async {
    if (!shouldAttach || _quitting) return;
    await windowManager.hide();
    await windowManager.setSkipTaskbar(true);
  }

  Future<void> quit() async {
    if (!shouldAttach || _quitting) return;
    _quitting = true;
    try {
      if (_siteName != null) {
        await showFromTray();
        final nav = navigatorKey?.currentState;
        if (nav != null && nav.mounted) {
          final ok = await showDialog<bool>(
            context: nav.context,
            builder: (ctx) => AlertDialog(
              title: const Text('退出 Vault？'),
              content: Text(
                '${leaveWorkspaceConfirmMessage(agentRunning: false, runningSiteNames: [_siteName!])}\n\n'
                '退出会结束工作区沙箱。从托盘退出才会真正关闭 Vault。',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('停止站点并退出'),
                ),
              ],
            ),
          );
          if (ok != true) {
            _quitting = false;
            return;
          }
        }
        KeepAliveActions.requestStopSite();
        await Future<void>.delayed(const Duration(milliseconds: 400));
      }
      await windowManager.setPreventClose(false);
      try {
        await trayManager.destroy();
      } catch (_) {}
      await windowManager.destroy();
    } catch (e, st) {
      _quitting = false;
      stderr.writeln('DesktopKeepAlive quit failed: $e\n$st');
    }
  }

  Future<void> _installTray() async {
    final icon = Platform.isWindows ? kDesktopTrayIconIco : kDesktopTrayIconPng;
    await trayManager.setIcon(icon);
    await _refreshTray();
  }

  Future<void> _refreshTray() async {
    await trayManager.setToolTip(desktopTrayTooltip(siteName: _siteName));
    await trayManager.setContextMenu(
      Menu(
        items: [
          for (final spec in desktopTrayMenuSpecs(siteRunning: _siteName != null))
            if (spec.key == 'separator')
              MenuItem.separator()
            else
              MenuItem(key: spec.key, label: spec.label),
        ],
      ),
    );
  }

  @override
  void onWindowClose() {
    unawaited(hideToTray());
  }

  @override
  void onTrayIconMouseDown() {
    if (Platform.isWindows) {
      unawaited(showFromTray());
    } else {
      unawaited(trayManager.popUpContextMenu());
    }
  }

  @override
  void onTrayIconRightMouseDown() {
    unawaited(trayManager.popUpContextMenu());
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case kDesktopTrayShowWindow:
        unawaited(showFromTray());
      case kDesktopTrayStopSite:
        KeepAliveActions.requestStopSite();
        unawaited(showFromTray());
      case kDesktopTrayQuit:
        unawaited(quit());
    }
  }
}

class DesktopTrayMenuSpec {
  const DesktopTrayMenuSpec({required this.key, this.label});

  final String key;
  final String? label;
}

List<DesktopTrayMenuSpec> desktopTrayMenuSpecs({required bool siteRunning}) {
  return [
    const DesktopTrayMenuSpec(key: kDesktopTrayShowWindow, label: '显示窗口'),
    if (siteRunning)
      const DesktopTrayMenuSpec(key: kDesktopTrayStopSite, label: '停止站点'),
    const DesktopTrayMenuSpec(key: 'separator'),
    const DesktopTrayMenuSpec(key: kDesktopTrayQuit, label: '退出 Vault'),
  ];
}

String desktopTrayTooltip({String? siteName}) {
  final named = siteName?.trim();
  if (named == null || named.isEmpty) {
    return 'Vault — 工作区在后台运行';
  }
  return 'Vault — 站点「$named」正在运行';
}

List<String> desktopKeepAliveStatusLines({required bool siteRunning}) {
  return [
    '关闭窗口：最小化到系统托盘（工作区继续运行）',
    '托盘右键：显示窗口${siteRunning ? ' / 停止站点' : ''} / 退出 Vault',
    '站点：${siteRunning ? '运行中（托盘可停止）' : '未启动'}',
  ];
}
