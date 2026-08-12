import 'dart:convert';

import 'package:vault/agent/tools/shell_job.dart';
import 'package:vault/sandbox/sandbox_models.dart';
import 'package:vault_agent_core/vault_agent_core.dart';

/// Agent-loop threshold: tools still running past this are detached as
/// background jobs (Cursor-style). Shell wall-clock limit is longer so
/// backgrounded commands are not killed at the old 5-minute mark.
const Duration kAgentToolBackgroundAfter = Duration(minutes: 1);

/// Default wall-clock timeout for a single sandbox shell invocation.
///
/// Kept well above [kAgentToolBackgroundAfter] so auto-backgrounded shell
/// work can finish.
const Duration kDefaultShellToolTimeout = Duration(minutes: 60);

/// Builds a vault_agent_core [Tool] that runs commands inside [workspace].
///
/// Commands are started as **guest background jobs** and polled via short
/// PersistentShell calls, so a long `shell` does not block the agent shell
/// queue — other shell tool calls can run in parallel.
///
/// When [chatSessionId] is set, injects `VAULT_CHAT_SESSION_ID` into the guest
/// environment for each command (offload permission / bridge correlation).
Tool createShellTool(
  SandboxWorkspace workspace, {
  Duration timeout = kDefaultShellToolTimeout,
  String? chatSessionId,
  String? projectPath,
  Duration pollInterval = kShellJobPollInterval,
}) {
  final sessionEnv = (chatSessionId == null || chatSessionId.trim().isEmpty)
      ? null
      : <String, String>{'VAULT_CHAT_SESSION_ID': chatSessionId.trim()};
  final projectDir =
      projectPath == null ? null : guestProjectDir(projectPath);
  final cwdHint = projectDir ?? kGuestHome;

  return Tool(
    name: 'shell',
    description:
        '在当前工作区的隔离 Alpine Linux 内执行非交互命令（root，$kGuestHome）。'
        '${projectDir == null ? '' : '当前项目目录：$projectDir；网站与代码请写在这里。'}'
        '命令以 guest 后台任务启动并轮询结果：长任务不阻塞后续 shell 调用（可并行）。'
        '主 shell 的 cwd / 导出变量在启动瞬间被继承；返回 exitCode、stdout、stderr。'
        '用于 apk、文件、编译、脚本、本地 HTTP 服务等。'
        '用户附件在 $kGuestInboxDir/。'
        '不要使用主机路径；不要做需要交互输入的命令。'
        '网站可用后请再调用 register_project_url。',
    parameterMode: ToolParameterMode.object,
    parameters: {
      'type': 'object',
      'properties': {
        'command': {
          'type': 'string',
          'description':
              '在 Linux 沙箱内执行的命令。示例：'
              'pwd; ls -la $kGuestInboxDir; '
              'apk update && apk add curl; '
              '${projectDir == null ? 'cd $kGuestHome && python3 -m http.server 8080 --bind 127.0.0.1' : 'cd $projectDir && python3 -m http.server 8080 --bind 127.0.0.1'}',
        },
      },
      'required': ['command'],
    },
    executable: (Map<String, dynamic> args) async {
      final command = (args['command'] as String?)?.trim() ?? '';
      if (command.isEmpty) {
        return jsonEncode({
          'ok': false,
          'error': '命令为空',
          'exitCode': -1,
          'stdout': '',
          'stderr': 'command 参数不能为空',
        });
      }

      try {
        final result = await runDetachedShellJob(
          workspace,
          command: command,
          environment: sessionEnv,
          timeout: timeout,
          pollInterval: pollInterval,
        );
        if (result.exitCode == 124) {
          return jsonEncode({
            'ok': false,
            'error': '命令超时',
            'exitCode': 124,
            'stdout': result.stdout,
            'stderr': result.stderr.isEmpty
                ? '命令在 ${timeout.inSeconds} 秒内未完成'
                : result.stderr,
            'cwdHint': cwdHint,
          });
        }
        return jsonEncode({
          'ok': result.success,
          'exitCode': result.exitCode,
          'stdout': result.stdout,
          'stderr': result.stderr,
          'cwdHint': cwdHint,
        });
      } catch (e) {
        return jsonEncode({
          'ok': false,
          'error': '沙箱不可用或执行失败',
          'exitCode': -1,
          'stdout': '',
          'stderr': e.toString(),
        });
      }
    },
  );
}

/// Start [command] detached in the guest and poll until done or [timeout].
///
/// Visible for tests. Does not hold the PersistentShell queue for the full
/// duration of [command].
Future<CommandResult> runDetachedShellJob(
  SandboxWorkspace workspace, {
  required String command,
  Map<String, String>? environment,
  Duration timeout = kDefaultShellToolTimeout,
  Duration pollInterval = kShellJobPollInterval,
  String? jobId,
}) async {
  final id = jobId ?? newShellJobId();
  final start = await workspace.run(
    buildStartDetachedShellJobCommand(
      jobId: id,
      command: command,
      environment: environment,
    ),
    timeout: const Duration(seconds: 30),
  );
  if (!start.success) {
    return CommandResult(
      exitCode: start.exitCode == 0 ? -1 : start.exitCode,
      stdout: start.stdout,
      stderr: start.stderr.isEmpty
          ? '无法启动后台 shell 任务'
          : start.stderr,
    );
  }

  final deadline = DateTime.now().add(timeout);
  String? partialOut;
  while (true) {
    final remaining = deadline.difference(DateTime.now());
    if (remaining <= Duration.zero) {
      try {
        await workspace.run(
          buildKillDetachedShellJobCommand(id),
          timeout: const Duration(seconds: 10),
        );
      } catch (_) {}
      // Best-effort final poll for partial output.
      try {
        final last = await workspace.run(
          buildPollDetachedShellJobCommand(id),
          timeout: const Duration(seconds: 10),
        );
        final parsed = parseShellJobPollStdout(last.stdout);
        if (parsed.done) {
          partialOut = parsed.output;
        }
      } catch (_) {}
      return CommandResult(
        exitCode: 124,
        stdout: partialOut ?? '',
        stderr: '命令在 ${timeout.inSeconds} 秒内未完成',
      );
    }

    final poll = await workspace.run(
      buildPollDetachedShellJobCommand(id),
      timeout: const Duration(seconds: 15),
    );
    final parsed = parseShellJobPollStdout(poll.stdout);
    if (parsed.done) {
      return CommandResult(
        exitCode: parsed.exitCode ?? -1,
        stdout: parsed.output ?? '',
        stderr: '',
      );
    }
    await Future<void>.delayed(pollInterval);
  }
}
