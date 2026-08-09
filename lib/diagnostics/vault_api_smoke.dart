import 'dart:async';
import 'dart:io' show Platform;

import 'package:dio/dio.dart';
import 'package:vault/permissions/permission_models.dart';
import 'package:vault/permissions/permission_registry.dart';
import 'package:vault/permissions/vault_native_offload.dart';
import 'package:vault/sandbox/sandbox_models.dart';

/// Wall-clock timeout per smoke case (guest CLI may be missing).
const Duration kVaultApiSmokeTimeout = Duration(seconds: 8);

/// Fixed guest session id for smoke so the Dart/Kotlin gate can authorize.
const String kVaultApiSmokeSessionId = 'smoke-test';

enum VaultApiSmokeStatus { pass, fail, skip, unsupported }

class VaultApiSmokeCase {
  const VaultApiSmokeCase({required this.permission, required this.command});

  final VaultPermissionInfo permission;
  final String command;
}

class VaultApiSmokeCaseResult {
  const VaultApiSmokeCaseResult({
    required this.permission,
    required this.status,
    required this.message,
    this.exitCode,
    this.stdout = '',
    this.stderr = '',
  });

  final VaultPermissionInfo permission;
  final VaultApiSmokeStatus status;
  final String message;
  final int? exitCode;
  final String stdout;
  final String stderr;
}

class VaultApiSmokeReport {
  const VaultApiSmokeReport({
    required this.platform,
    required this.appVersion,
    required this.workspaceId,
    required this.results,
    required this.startedAt,
    required this.finishedAt,
  });

  final String platform;
  final String appVersion;
  final String workspaceId;
  final List<VaultApiSmokeCaseResult> results;
  final DateTime startedAt;
  final DateTime finishedAt;

  String toMarkdown() {
    final buf = StringBuffer();
    buf.writeln('# Vault API 自检报告');
    buf.writeln();
    buf.writeln('- 平台：$platform');
    buf.writeln('- 应用版本：$appVersion');
    buf.writeln('- 工作区：`$workspaceId`');
    buf.writeln('- 开始：${startedAt.toIso8601String()}');
    buf.writeln('- 结束：${finishedAt.toIso8601String()}');
    buf.writeln();
    buf.writeln('| 能力 | CLI | 结果 | 说明 |');
    buf.writeln('|------|-----|------|------|');
    for (final r in results) {
      final status = _statusLabel(r.status);
      final detail = r.message.replaceAll('|', '\\|').replaceAll('\n', ' ');
      buf.writeln(
        '| ${r.permission.displayNameZh} | `${r.permission.cliName}` | '
        '$status | $detail |',
      );
    }
    buf.writeln();
    final pass = results
        .where((r) => r.status == VaultApiSmokeStatus.pass)
        .length;
    final fail = results
        .where((r) => r.status == VaultApiSmokeStatus.fail)
        .length;
    final skip = results
        .where((r) => r.status == VaultApiSmokeStatus.skip)
        .length;
    final unsupported = results
        .where((r) => r.status == VaultApiSmokeStatus.unsupported)
        .length;
    buf.writeln(
      '汇总：通过 $pass · 失败 $fail · 跳过 $skip · 不支持 $unsupported'
      '（共 ${results.length}）',
    );
    return buf.toString();
  }

  static String _statusLabel(VaultApiSmokeStatus s) {
    switch (s) {
      case VaultApiSmokeStatus.pass:
        return '通过';
      case VaultApiSmokeStatus.fail:
        return '失败';
      case VaultApiSmokeStatus.skip:
        return '跳过';
      case VaultApiSmokeStatus.unsupported:
        return '不支持';
    }
  }
}

/// Runs `vault-* smoke` (or probe) inside a [SandboxWorkspace].
///
/// Wave1–4 cases with [VaultPermissionInfo.bridgeImplemented*] true run
/// `vault-* smoke` with [kVaultApiSmokeSessionId] injected. Exit **125**
/// → [VaultApiSmokeStatus.unsupported]; exit **126** → fail with
/// `permission_denied`. Wave4 (`a11y`/`shizuku`) is included only when
/// [includeIntegrations] is true (and only on Android when implemented).
class VaultApiSmokeRunner {
  VaultApiSmokeRunner._();

  static List<VaultApiSmokeCase> buildCases({
    bool includeIntegrations = false,
    bool onlyImplemented = true,
    bool? isAndroid,
    bool? isWindows,
  }) {
    final android = isAndroid ?? Platform.isAndroid;
    final windows = isWindows ?? Platform.isWindows;

    final cases = <VaultApiSmokeCase>[];
    for (final p in PermissionRegistry.all) {
      if (p.category == PermissionCategory.integrations &&
          !includeIntegrations) {
        continue;
      }
      if (!p.supportedOn(isAndroid: android, isWindows: windows)) {
        continue;
      }
      if (onlyImplemented &&
          !p.implementedOn(isAndroid: android, isWindows: windows)) {
        continue;
      }
      final cli = p.cliName;
      cases.add(
        VaultApiSmokeCase(
          permission: p,
          command:
              'command -v $cli >/dev/null 2>&1; '
              'ec=\$?; if [ \$ec -ne 0 ]; then '
              'echo "CLI_MISSING:$cli" >&2; exit 127; fi; '
              '$cli smoke',
        ),
      );
    }
    return cases;
  }

  static Future<VaultApiSmokeReport> run(
    SandboxWorkspace workspace, {
    bool includeIntegrations = false,
    bool onlyImplemented = true,
    CancelToken? cancelToken,
    bool Function()? shouldStop,
    Duration timeout = kVaultApiSmokeTimeout,
    String appVersion = '1.0.0+1',
  }) async {
    final started = DateTime.now();
    final android = Platform.isAndroid;
    final windows = Platform.isWindows;
    final results = <VaultApiSmokeCaseResult>[];

    // Always include unsupported-on-platform rows as "unsupported" for clarity
    // when not filtering to implemented-only (helps Settings report completeness).
    if (!onlyImplemented) {
      for (final p in PermissionRegistry.all) {
        if (p.category == PermissionCategory.integrations &&
            !includeIntegrations) {
          continue;
        }
        if (!p.supportedOn(isAndroid: android, isWindows: windows)) {
          results.add(
            VaultApiSmokeCaseResult(
              permission: p,
              status: VaultApiSmokeStatus.unsupported,
              message: '当前平台未声明支持',
            ),
          );
        }
      }
    }

    final cases = buildCases(
      includeIntegrations: includeIntegrations,
      onlyImplemented: onlyImplemented,
      isAndroid: android,
      isWindows: windows,
    );

    if (onlyImplemented && cases.isEmpty) {
      // Fallback if no bridgeImplemented flags match the platform.
      final implementedWaveIds = {
        ...PermissionRegistry.wave1Ids,
        ...PermissionRegistry.wave2Ids,
        ...PermissionRegistry.wave3Ids,
        if (android) ...PermissionRegistry.wave4Ids,
      };
      for (final p in PermissionRegistry.all) {
        if (!implementedWaveIds.contains(p.id)) continue;
        if (!p.supportedOn(isAndroid: android, isWindows: windows)) continue;
        results.add(
          VaultApiSmokeCaseResult(
            permission: p,
            status: VaultApiSmokeStatus.skip,
            message:
                '原生桥尚未标记为已实现（Wave1–4：${p.cliName}）。'
                '取消「仅测已实现项」可强制探测 guest CLI。',
          ),
        );
      }
    }

    final smokeEnv = <String, String>{
      'VAULT_CHAT_SESSION_ID': kVaultApiSmokeSessionId,
    };

    for (final c in cases) {
      if (cancelToken?.isCancelled == true || shouldStop?.call() == true) {
        results.add(
          VaultApiSmokeCaseResult(
            permission: c.permission,
            status: VaultApiSmokeStatus.skip,
            message: '已取消',
          ),
        );
        break;
      }

      try {
        final cmdResult = await workspace
            .run(c.command, environment: smokeEnv)
            .timeout(timeout);
        results.add(_classify(c.permission, cmdResult));
      } on TimeoutException {
        results.add(
          VaultApiSmokeCaseResult(
            permission: c.permission,
            status: VaultApiSmokeStatus.fail,
            message: '超时（${timeout.inSeconds}s）',
          ),
        );
      } catch (e) {
        results.add(
          VaultApiSmokeCaseResult(
            permission: c.permission,
            status: VaultApiSmokeStatus.fail,
            message: '执行异常：$e',
          ),
        );
      }
    }

    return VaultApiSmokeReport(
      platform: Platform.operatingSystem,
      appVersion: appVersion,
      workspaceId: workspace.workspaceId,
      results: results,
      startedAt: started,
      finishedAt: DateTime.now(),
    );
  }

  static VaultApiSmokeCaseResult _classify(
    VaultPermissionInfo permission,
    CommandResult result,
  ) {
    final code = result.exitCode;
    final err = result.stderr.trim();
    final out = result.stdout.trim();

    if (code == VaultOffloadExitCode.ok) {
      return VaultApiSmokeCaseResult(
        permission: permission,
        status: VaultApiSmokeStatus.pass,
        message: out.isEmpty ? 'ok' : out,
        exitCode: code,
        stdout: result.stdout,
        stderr: result.stderr,
      );
    }

    if (code == VaultOffloadExitCode.unsupportedPlatform) {
      return VaultApiSmokeCaseResult(
        permission: permission,
        status: VaultApiSmokeStatus.unsupported,
        message: err.isEmpty ? 'unsupported_platform (exit 125)' : err,
        exitCode: code,
        stdout: result.stdout,
        stderr: result.stderr,
      );
    }

    if (code == VaultOffloadExitCode.permissionDenied) {
      return VaultApiSmokeCaseResult(
        permission: permission,
        status: VaultApiSmokeStatus.fail,
        message: err.isEmpty
            ? 'permission_denied (exit 126)：权限被拒绝或未授权'
            : 'permission_denied (exit 126)：$err',
        exitCode: code,
        stdout: result.stdout,
        stderr: result.stderr,
      );
    }

    if (code == 127 || err.contains('CLI_MISSING')) {
      return VaultApiSmokeCaseResult(
        permission: permission,
        status: VaultApiSmokeStatus.fail,
        message: '未找到 CLI `${permission.cliName}`（guest 内尚未安装桥接脚本）',
        exitCode: code,
        stdout: result.stdout,
        stderr: result.stderr,
      );
    }

    return VaultApiSmokeCaseResult(
      permission: permission,
      status: VaultApiSmokeStatus.fail,
      message:
          'exit $code'
          '${err.isEmpty ? '' : '：$err'}',
      exitCode: code,
      stdout: result.stdout,
      stderr: result.stderr,
    );
  }
}
