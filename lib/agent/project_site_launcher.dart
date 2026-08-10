import 'package:url_launcher/url_launcher.dart';
import 'package:vault/agent/project_store.dart';
import 'package:vault/sandbox/sandbox_models.dart';

/// Result of starting a registered project site from the UI.
class ProjectSiteStartResult {
  const ProjectSiteStartResult({
    required this.startedProcess,
    required this.alreadyUp,
    required this.openedUrl,
    this.message,
  });

  final bool startedProcess;
  final bool alreadyUp;
  final bool openedUrl;
  final String? message;
}

/// Starts a project's registered URL service inside the guest, then opens the URL.
class ProjectSiteLauncher {
  ProjectSiteLauncher(this.workspace);

  final SandboxWorkspace workspace;

  /// Run [entry.startCommand] (if any) under the project dir, then open [entry.url].
  Future<ProjectSiteStartResult> start({
    required String projectPath,
    required ProjectUrlEntry entry,
    bool openInBrowser = true,
  }) async {
    final dir = guestProjectDir(projectPath);
    final url = entry.url.trim();
    final startCmd = entry.startCommand?.trim();

    var alreadyUp = false;
    var startedProcess = false;

    if (url.isNotEmpty) {
      final probe = await workspace.run(
        'code=\$(curl -s -o /dev/null -w "%{http_code}" '
        '--connect-timeout 2 --max-time 3 ${shellSingleQuote(url)} 2>/dev/null || echo 000); '
        'echo \$code',
      );
      final code = probe.stdout.trim();
      alreadyUp = code.startsWith('2') || code.startsWith('3');
    }

    if (!alreadyUp && startCmd != null && startCmd.isNotEmpty) {
      final logName =
          'vault_site_${entry.name.replaceAll(RegExp(r'[^\w.-]'), '_')}.log';
      final result = await workspace.run(
        'mkdir -p ${shellSingleQuote(dir)} && '
        'cd ${shellSingleQuote(dir)} && '
        'nohup sh -c ${shellSingleQuote(startCmd)} '
        '>${shellSingleQuote(logName)} 2>&1 & '
        'echo \$!',
      );
      if (result.exitCode != 0) {
        return ProjectSiteStartResult(
          startedProcess: false,
          alreadyUp: false,
          openedUrl: false,
          message: '启动命令失败：${result.stderr}\n${result.stdout}',
        );
      }
      startedProcess = true;
      // Brief wait so a fast stdlib server can bind.
      await Future<void>.delayed(const Duration(milliseconds: 600));
    } else if (!alreadyUp && (startCmd == null || startCmd.isEmpty)) {
      return ProjectSiteStartResult(
        startedProcess: false,
        alreadyUp: false,
        openedUrl: false,
        message: '该条目没有 start_command，且当前无法访问 $url',
      );
    }

    var openedUrl = false;
    if (openInBrowser && url.isNotEmpty) {
      final uri = Uri.tryParse(url);
      if (uri != null && await canLaunchUrl(uri)) {
        openedUrl = await launchUrl(
          uri,
          mode: LaunchMode.externalApplication,
        );
      }
    }

    return ProjectSiteStartResult(
      startedProcess: startedProcess,
      alreadyUp: alreadyUp,
      openedUrl: openedUrl,
      message: alreadyUp
          ? '服务已在运行'
          : (startedProcess ? '已后台启动' : null),
    );
  }
}
