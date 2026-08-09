import 'dart:convert';

import 'package:vault/sandbox/sandbox_models.dart';
import 'package:vault_agent_core/vault_agent_core.dart';

/// Default wall-clock timeout for a single sandbox shell invocation.
const Duration kDefaultShellToolTimeout = Duration(minutes: 5);

/// Builds a vault_agent_core [Tool] that runs commands inside [workspace].
///
/// When [chatSessionId] is set, injects `VAULT_CHAT_SESSION_ID` into the guest
/// environment for each command (offload permission / bridge correlation).
Tool createShellTool(
  SandboxWorkspace workspace, {
  Duration timeout = kDefaultShellToolTimeout,
  String? chatSessionId,
}) {
  final sessionEnv = (chatSessionId == null || chatSessionId.trim().isEmpty)
      ? null
      : <String, String>{'VAULT_CHAT_SESSION_ID': chatSessionId.trim()};

  return Tool(
    name: 'shell',
    description:
        '在当前工作区的隔离 Alpine Linux 内执行非交互命令（root，$kGuestHome）。'
        '命令跑在长驻 shell 中：cwd、环境变量与后台进程（如 `uvicorn &`）在同工作区后续调用间保留。'
        '返回 exitCode、stdout、stderr。'
        '用于 apk、文件、编译、脚本、本地 HTTP 服务等。'
        '用户附件在 $kGuestInboxDir/。'
        '不要使用主机路径；不要做需要交互输入的命令。',
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
              'cd $kGuestHome/work && make',
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
        final result = await workspace.run(
          command,
          environment: sessionEnv,
          timeout: timeout,
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
            'cwdHint': kGuestHome,
          });
        }
        return jsonEncode({
          'ok': result.success,
          'exitCode': result.exitCode,
          'stdout': result.stdout,
          'stderr': result.stderr,
          'cwdHint': kGuestHome,
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
