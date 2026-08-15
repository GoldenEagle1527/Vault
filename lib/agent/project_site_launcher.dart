import 'package:url_launcher/url_launcher.dart';
import 'package:vault/agent/project_store.dart';
import 'package:vault/agent/site_port.dart';
import 'package:vault/sandbox/sandbox_models.dart';

export 'package:vault/agent/site_port.dart' show portFromSiteUrl;

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

/// Result of stopping a registered project site from the UI.
class ProjectSiteStopResult {
  const ProjectSiteStopResult({required this.stopped, this.message});

  final bool stopped;
  final String? message;
}

/// HTTP status that means a listener answered (including 4xx/5xx).
bool isHttpServiceResponding(String code) {
  final n = int.tryParse(code.trim());
  return n != null && n >= 100 && n <= 599;
}

/// Guest basename prefix for pid/log files of one registered site.
String siteRuntimeStem(String name, {String? url}) {
  final port = url == null ? null : portFromSiteUrl(url);
  final safe = name.trim().replaceAll(RegExp(r'[/\\:*?"<>|\x00-\x1F]'), '_');
  if (safe.isEmpty) {
    return port == null ? 'vault_site' : 'vault_site_$port';
  }
  return port == null ? 'vault_site_$safe' : 'vault_site_${safe}_$port';
}

/// Probe whether each URL's port is **listening**; prints `200` or `0` per URL.
///
/// Only state `0A` (LISTEN) counts. TIME_WAIT / ESTABLISHED leftovers after
/// kill must not look like the server is still up.
String siteProbeShellCommand(List<String> urls) {
  final ports = [
    for (final url in urls) portFromSiteUrl(url)?.toString() ?? 'x',
  ];
  return '''
for port in ${ports.join(' ')}; do
  if [ "\$port" = "x" ]; then echo 0; continue; fi
  hex=\$(printf '%04X' "\$port")
  if awk -v h="\$hex" 'NR>1 { split(\$2, a, ":"); if (toupper(a[2]) == h && toupper(\$4) == "0A") { found=1; exit } } END { exit !found }' /proc/net/tcp /proc/net/tcp6 2>/dev/null; then
    echo 200
  else
    echo 0
  fi
done
''';
}

/// Whether this site's pid-file process is still alive (`1` / `0`).
String siteOwnPidAliveShellCommand({
  required String projectDir,
  required String pidFileName,
}) {
  final pidQ = shellSingleQuote('$projectDir/$pidFileName');
  return '''
# vault_site_own_pid
pidfile=$pidQ
if [ -f "\$pidfile" ]; then
  pid=\$(cat "\$pidfile" 2>/dev/null || true)
  if [ -n "\$pid" ] && [ -d "/proc/\$pid" ]; then
    echo 1
    exit 0
  fi
fi
echo 0
''';
}

/// Background-start [startCmd] under [projectDir] and persist `$!` to a pid file.
String siteStartShellCommand({
  required String projectDir,
  required String startCmd,
  required String logFileName,
  required String pidFileName,
}) {
  return 'mkdir -p ${shellSingleQuote(projectDir)} && '
      'cd ${shellSingleQuote(projectDir)} && '
      'nohup sh -c ${shellSingleQuote(startCmd)} '
      '>${shellSingleQuote(logFileName)} 2>&1 & '
      'echo \$! > ${shellSingleQuote(pidFileName)} && '
      'echo \$!';
}

/// Best-effort TERM/KILL of the pid-file process tree and port listeners.
String siteStopShellCommand({
  required String projectDir,
  required String pidFileName,
  int? port,
}) {
  final pidQ = shellSingleQuote('$projectDir/$pidFileName');
  final portLine = port == null ? 'port=' : 'port=$port';
  return '''
pidfile=$pidQ
$portLine
kill_pid() {
  _pid=\$1
  [ -z "\$_pid" ] && return 0
  [ "\$_pid" = "1" ] && return 0
  [ -d "/proc/\$_pid" ] || return 0
  kill -TERM "\$_pid" 2>/dev/null || true
}
if [ -f "\$pidfile" ]; then
  rootpid=\$(cat "\$pidfile" 2>/dev/null || true)
  if [ -n "\$rootpid" ]; then
    for st in /proc/[0-9]*/status; do
      [ -f "\$st" ] || continue
      ppid=\$(awk '/^PPid:/{print \$2}' "\$st" 2>/dev/null || true)
      if [ "\$ppid" = "\$rootpid" ]; then
        cpid=\${st#/proc/}
        cpid=\${cpid%/status}
        kill_pid "\$cpid"
      fi
    done
    kill_pid "\$rootpid"
  fi
  rm -f "\$pidfile"
fi
kill_port() {
  sig=\$1
  [ -z "\$port" ] && return 0
  hex=\$(printf '%04X' "\$port")
  inodes=\$(awk -v h="\$hex" 'NR>1 { split(\$2, a, ":"); if (toupper(a[2]) == h) print \$10 }' /proc/net/tcp /proc/net/tcp6 2>/dev/null)
  for inode in \$inodes; do
    [ -z "\$inode" ] && continue
    [ "\$inode" = "0" ] && continue
    for fd in /proc/[0-9]*/fd/*; do
      target=\$(readlink "\$fd" 2>/dev/null) || continue
      case "\$target" in
        socket:\\[\$inode\\])
          pid=\${fd#/proc/}
          pid=\${pid%%/*}
          [ "\$pid" = "1" ] && continue
          kill -\$sig "\$pid" 2>/dev/null || true
          ;;
      esac
    done
  done
}
kill_port TERM
sleep 0.4
kill_port KILL
echo ok
''';
}

/// Starts a project's registered URL service inside the guest, then opens the URL.
class ProjectSiteLauncher {
  ProjectSiteLauncher(this.workspace);

  final SandboxWorkspace workspace;

  /// Whether each entry's URL currently answers HTTP (keyed by [ProjectUrlEntry.name]).
  Future<Map<String, bool>> probeAll(List<ProjectUrlEntry> entries) async {
    final result = <String, bool>{
      for (final entry in entries) entry.name: false,
    };
    if (entries.isEmpty) return result;
    final urls = [for (final entry in entries) entry.url.trim()];
    if (urls.every((url) => url.isEmpty)) return result;

    final probe = await workspace.run(
      siteProbeShellCommand(urls),
      timeout: const Duration(seconds: 15),
    );
    final codes = probe.stdout.trim().split(RegExp(r'\s+'));
    for (var i = 0; i < entries.length; i++) {
      final code = i < codes.length ? codes[i] : '0';
      result[entries[i].name] = isHttpServiceResponding(code);
    }
    return result;
  }

  Future<bool> isUp(ProjectUrlEntry entry) async {
    final map = await probeAll([entry]);
    return map[entry.name] ?? false;
  }

  /// True when this entry's pid-file process is still alive (not just the port).
  Future<bool> isOwnProcessAlive({
    required String projectPath,
    required ProjectUrlEntry entry,
  }) async {
    final dir = guestProjectDir(projectPath);
    final stem = siteRuntimeStem(entry.name, url: entry.url);
    final result = await workspace.run(
      siteOwnPidAliveShellCommand(projectDir: dir, pidFileName: '$stem.pid'),
      timeout: const Duration(seconds: 10),
    );
    return result.stdout.trim() == '1';
  }

  /// Run [entry.startCommand] (if any) under the project dir, then open [openUrl]
  /// (gateway public URL) or [entry.url].
  Future<ProjectSiteStartResult> start({
    required String projectPath,
    required ProjectUrlEntry entry,
    bool openInBrowser = true,
    String? openUrl,
  }) async {
    final dir = guestProjectDir(projectPath);
    final url = entry.url.trim();
    final startCmd = entry.startCommand?.trim();
    final stem = siteRuntimeStem(entry.name, url: url);

    final ownAlive = await isOwnProcessAlive(
      projectPath: projectPath,
      entry: entry,
    );
    final portUp = url.isNotEmpty && await isUp(entry);
    if (!ownAlive && portUp) {
      return ProjectSiteStartResult(
        startedProcess: false,
        alreadyUp: false,
        openedUrl: false,
        message: '端口已被其他进程占用，无法启动「${entry.name}」',
      );
    }
    var alreadyUp = ownAlive;
    var startedProcess = false;

    if (!alreadyUp && startCmd != null && startCmd.isNotEmpty) {
      final result = await workspace.run(
        siteStartShellCommand(
          projectDir: dir,
          startCmd: startCmd,
          logFileName: '$stem.log',
          pidFileName: '$stem.pid',
        ),
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
      // Brief wait so a fast stdlib server can bind before the browser opens.
      await Future<void>.delayed(const Duration(milliseconds: 600));
    } else if (!alreadyUp && (startCmd == null || startCmd.isEmpty)) {
      return ProjectSiteStartResult(
        startedProcess: false,
        alreadyUp: false,
        openedUrl: false,
        message: '该条目没有 start_command，且当前无法访问 $url',
      );
    }

    final browserUrl = (openUrl ?? url).trim();
    var openedUrl = false;
    if (openInBrowser && browserUrl.isNotEmpty) {
      final uri = Uri.tryParse(browserUrl);
      if (uri != null && await canLaunchUrl(uri)) {
        openedUrl = await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    }

    return ProjectSiteStartResult(
      startedProcess: startedProcess,
      alreadyUp: alreadyUp && !startedProcess,
      openedUrl: openedUrl,
      message: alreadyUp && !startedProcess
          ? '服务已在运行'
          : (startedProcess ? '已后台启动' : null),
    );
  }

  /// Stop the guest process for [entry] (pid file + port listeners), then re-probe.
  Future<ProjectSiteStopResult> stop({
    required String projectPath,
    required ProjectUrlEntry entry,
  }) async {
    final dir = guestProjectDir(projectPath);
    final url = entry.url.trim();
    final stem = siteRuntimeStem(entry.name, url: url);
    final result = await workspace.run(
      siteStopShellCommand(
        projectDir: dir,
        pidFileName: '$stem.pid',
        port: portFromSiteUrl(url),
      ),
      timeout: const Duration(seconds: 10),
    );
    if (result.exitCode != 0) {
      return ProjectSiteStopResult(
        stopped: false,
        message: '终止命令失败：${result.stderr}\n${result.stdout}',
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final stillUp = url.isNotEmpty && await isUp(entry);
    if (stillUp) {
      return const ProjectSiteStopResult(
        stopped: false,
        message: '未能终止，服务仍在响应',
      );
    }
    return const ProjectSiteStopResult(stopped: true, message: '已终止');
  }
}
