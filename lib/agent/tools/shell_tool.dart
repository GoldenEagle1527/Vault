import 'dart:async';
import 'dart:convert';

import 'package:vault/sandbox/sandbox_models.dart';
import 'package:vault_agent_core/vault_agent_core.dart';

/// Default wall-clock timeout for a single sandbox shell invocation.
const Duration kDefaultShellToolTimeout = Duration(minutes: 5);

/// Builds a vault_agent_core [Tool] that runs commands inside [session].
Tool createShellTool(
  SandboxSession session, {
  Duration timeout = kDefaultShellToolTimeout,
}) {
  return Tool(
    name: 'shell',
    description:
        '在当前会话的隔离 Alpine Linux 内执行非交互命令（root，$kGuestHome，/bin/sh -c）。'
        '返回 exitCode、stdout、stderr。'
        '用于 apk、文件、编译、脚本等。'
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
        final result = await session.run(command).timeout(timeout);
        return jsonEncode({
          'ok': result.success,
          'exitCode': result.exitCode,
          'stdout': result.stdout,
          'stderr': result.stderr,
          'cwdHint': kGuestHome,
        });
      } on TimeoutException {
        return jsonEncode({
          'ok': false,
          'error': '命令超时',
          'exitCode': -1,
          'stdout': '',
          'stderr': '命令在 ${timeout.inSeconds} 秒内未完成',
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
