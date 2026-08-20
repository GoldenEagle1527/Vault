import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:vault/sandbox/keep_alive_actions.dart';
import 'package:vault/sandbox/proot_host.dart';

export 'package:vault/sandbox/keep_alive_actions.dart'
    show kKeepAliveStopSiteAction, KeepAliveActions;

/// Android-only keep-alive: foreground service, notification permission,
/// battery optimization exemption.
class AndroidKeepAlive {
  AndroidKeepAlive._();

  static const _prefsFileName = 'keep_alive_prefs.json';
  static const _batteryPromptCooldown = Duration(days: 7);

  static VoidCallback? get onStopSiteRequested =>
      KeepAliveActions.onStopSiteRequested;
  static set onStopSiteRequested(VoidCallback? value) {
    KeepAliveActions.onStopSiteRequested = value;
  }

  static bool _handlerBound = false;

  static bool get supported => !kIsWeb && Platform.isAndroid;

  /// Listen for FGS notification actions (idempotent).
  static void bindNotificationActions() {
    if (!supported || _handlerBound) return;
    _handlerBound = true;
    ProotHost.bindKeepAliveActions((action) {
      if (action == kKeepAliveStopSiteAction) {
        KeepAliveActions.requestStopSite();
      }
    });
  }

  static void unbindNotificationActions() {
    if (!_handlerBound) return;
    _handlerBound = false;
    onStopSiteRequested = null;
    ProotHost.unbindKeepAliveActions();
  }

  static Future<AndroidKeepAliveStatus> status() {
    if (!supported) {
      return Future.value(
        const AndroidKeepAliveStatus(
          notificationsEnabled: true,
          batteryOptimizationIgnored: true,
          foregroundServiceRunning: false,
        ),
      );
    }
    return ProotHost.getKeepAliveStatus();
  }

  /// Start or refresh the foreground-service notification.
  static Future<void> ensureRunning({String? siteName}) async {
    if (!supported) return;
    bindNotificationActions();
    final named = siteName?.trim();
    final hasSite = named != null && named.isNotEmpty;
    final text = hasSite
        ? '站点「$named」正在运行，切到浏览器后也会保持后台。'
        : '沙箱与 Agent 任务在后台继续运行，点按返回应用。';
    try {
      await ProotHost.startForegroundService(
        title: 'Vault 工作区运行中',
        text: text,
        showStopSite: hasSite,
      );
    } catch (_) {
      // FGS may fail without notification permission; permissions flow handles it.
    }
  }

  /// Request missing OS permissions and optionally explain why (once per cooldown).
  static Future<void> ensurePermissions(
    BuildContext context, {
    bool forceBatteryPrompt = false,
  }) async {
    if (!supported || !context.mounted) return;

    var current = await status();
    if (!context.mounted) return;

    if (!current.notificationsEnabled) {
      await ProotHost.requestNotificationPermission();
      current = await status();
      if (!context.mounted) return;
    }

    await ensureRunning();

    final needsBattery = !current.batteryOptimizationIgnored;
    if (!needsBattery) return;

    final prefs = await _loadPrefs();
    final dismissedAt = prefs.batteryPromptDismissedAt;
    final cooledDown = dismissedAt == null ||
        DateTime.now().difference(dismissedAt) >= _batteryPromptCooldown;
    if (!forceBatteryPrompt && !cooledDown) return;
    if (!context.mounted) return;

    final choice = await showDialog<_KeepAliveChoice>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('允许 Vault 后台运行'),
        content: const Text(
          '为保证 Linux 沙箱、开发站点与 Agent 任务在你切到浏览器或锁屏后继续运行，'
          '请：\n\n'
          '1. 允许通知（用于前台服务保活）\n'
          '2. 关闭本应用的电池优化\n\n'
          '否则系统可能在后台终止沙箱，站点状态也会丢失。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, _KeepAliveChoice.later),
            child: const Text('稍后'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, _KeepAliveChoice.configure),
            child: const Text('去设置'),
          ),
        ],
      ),
    );
    if (!context.mounted) return;

    if (choice == _KeepAliveChoice.later) {
      await _savePrefs(
        prefs.copyWith(batteryPromptDismissedAt: DateTime.now()),
      );
      return;
    }
    if (choice != _KeepAliveChoice.configure) return;

    if (!current.notificationsEnabled) {
      await ProotHost.requestNotificationPermission();
    }
    final alreadyIgnored = await ProotHost.requestIgnoreBatteryOptimizations();
    if (!alreadyIgnored && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请在系统对话框中选择「允许」以关闭电池优化')),
      );
    }
    await ensureRunning();
  }

  static Future<_KeepAlivePrefs> _loadPrefs() async {
    if (!supported) return const _KeepAlivePrefs();
    try {
      final dir = await ProotHost.getFilesDir();
      final file = File('$dir/$_prefsFileName');
      if (!await file.exists()) return const _KeepAlivePrefs();
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return const _KeepAlivePrefs();
      final map = Map<String, dynamic>.from(decoded);
      return _KeepAlivePrefs(
        batteryPromptDismissedAt: DateTime.tryParse(
          map['batteryPromptDismissedAt'] as String? ?? '',
        ),
      );
    } catch (_) {
      return const _KeepAlivePrefs();
    }
  }

  static Future<void> _savePrefs(_KeepAlivePrefs prefs) async {
    if (!supported) return;
    try {
      final dir = await ProotHost.getFilesDir();
      final file = File('$dir/$_prefsFileName');
      await file.writeAsString(
        jsonEncode({
          if (prefs.batteryPromptDismissedAt != null)
            'batteryPromptDismissedAt':
                prefs.batteryPromptDismissedAt!.toIso8601String(),
        }),
        flush: true,
      );
    } catch (_) {}
  }
}

enum _KeepAliveChoice { configure, later }

class _KeepAlivePrefs {
  const _KeepAlivePrefs({this.batteryPromptDismissedAt});

  final DateTime? batteryPromptDismissedAt;

  _KeepAlivePrefs copyWith({DateTime? batteryPromptDismissedAt}) {
    return _KeepAlivePrefs(
      batteryPromptDismissedAt:
          batteryPromptDismissedAt ?? this.batteryPromptDismissedAt,
    );
  }
}

/// Whether leaving a workspace should warn (agent job or a live site).
bool shouldConfirmLeaveWorkspace({
  required bool agentRunning,
  required Iterable<String> runningSiteNames,
}) {
  return agentRunning || runningSiteNames.isNotEmpty;
}

/// Copy for the leave-workspace confirmation dialog.
String leaveWorkspaceConfirmMessage({
  required bool agentRunning,
  required Iterable<String> runningSiteNames,
}) {
  final names = runningSiteNames
      .map((n) => n.trim())
      .where((n) => n.isNotEmpty)
      .toList();
  final parts = <String>[];
  if (names.isNotEmpty) {
    final listed = names.length == 1
        ? '「${names.first}」'
        : names.map((n) => '「$n」').join('、');
    parts.add('站点$listed仍在运行。离开工作区会结束沙箱，站点也会停止。');
  }
  if (agentRunning) {
    parts.add('当前会话仍在运行，离开将取消正在进行的任务。');
  }
  if (parts.isEmpty) {
    return '确定离开当前工作区？';
  }
  return parts.join('\n\n');
}

/// Human-readable labels for [AndroidKeepAliveStatus] (settings / diagnostics).
List<String> androidKeepAliveStatusLines(AndroidKeepAliveStatus status) {
  return [
    '通知权限：${status.notificationsEnabled ? '已允许' : '未允许（前台服务可能无法启动）'}',
    '电池优化：${status.batteryOptimizationIgnored ? '已关闭' : '仍受限（后台可能被系统杀掉）'}',
    '前台服务：${status.foregroundServiceRunning ? '运行中' : '未运行'}',
  ];
}
