import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault/agent/tools/shell_job.dart';
import 'package:vault/agent/tools/shell_tool.dart';
import 'package:vault/sandbox/sandbox_models.dart';
import 'package:vault_agent_core/vault_agent_core.dart';

class _NotifyWorkspace implements SandboxWorkspace {
  _NotifyWorkspace();

  final Map<String, StringBuffer> _outs = {};
  final Map<String, int?> _exits = {};
  int appendCount = 0;

  @override
  String get workspaceId => 'test';

  @override
  Stream<Uint8List> get output => const Stream.empty();

  @override
  void write(String data) {}

  @override
  void writeBytes(Uint8List data) {}

  @override
  void resize(int cols, int rows) {}

  @override
  Future<int> get exitCode => Future.value(0);

  @override
  Future<CommandResult> run(
    String cmd, {
    Map<String, String>? environment,
    Duration? timeout,
  }) async {
    final match = RegExp(r'vault-shell-jobs/([A-Za-z0-9]+)').firstMatch(cmd);
    final jobId = match?.group(1) ?? 'j0';
    if (cmd.contains('_pid') && cmd.contains('&')) {
      _outs[jobId] = StringBuffer();
      _exits[jobId] = null;
      return const CommandResult(exitCode: 0, stdout: '7\n', stderr: '');
    }
    if (cmd.contains(kShellJobDoneMarker) ||
        cmd.contains(kShellJobRunningMarker)) {
      appendCount++;
      // Grow output over polls until pattern appears, then finish.
      final buf = _outs.putIfAbsent(jobId, () => StringBuffer());
      if (appendCount == 1) {
        buf.write('booting...\n');
      } else if (appendCount == 2) {
        buf.write('Listening on 127.0.0.1:8080\n');
      } else if (appendCount >= 12) {
        // Stay running long enough for the notify assertion, then finish.
        _exits[jobId] = 0;
        buf.write('done\n');
      }
      final out = buf.toString();
      final exit = _exits[jobId];
      if (exit != null) {
        return CommandResult(
          exitCode: 0,
          stdout: '$kShellJobDoneMarker\n$exit\n$kShellJobOutMarker\n$out'
              '$kShellJobEndMarker\n',
          stderr: '',
        );
      }
      return CommandResult(
        exitCode: 0,
        stdout: '$kShellJobRunningMarker\n7\n$kShellJobOutMarker\n$out'
            '$kShellJobEndMarker\n',
        stderr: '',
      );
    }
    return const CommandResult(exitCode: 0, stdout: '', stderr: '');
  }

  @override
  Future<void> writeGuestFile(
    String guestAbsolutePath,
    List<int> bytes,
  ) async {}

  @override
  Future<void> dispose() async {}
}

class _SilentLLM implements LLMClient {
  @override
  Future<ModelMessage> generate(
    List<LLMMessage> messages, {
    List<Tool>? tools,
    ToolChoice? toolChoice,
    required ModelConfig modelConfig,
    bool? jsonOutput,
    CancelToken? cancelToken,
  }) async {
    return ModelMessage(
      textOutput: 'ok',
      model: modelConfig.model,
      stopReason: 'stop',
    );
  }

  @override
  Future<Stream<StreamingMessage>> stream(
    List<LLMMessage> messages, {
    List<Tool>? tools,
    ToolChoice? toolChoice,
    required ModelConfig modelConfig,
    bool? jsonOutput,
    CancelToken? cancelToken,
  }) async {
    final msg = await generate(
      messages,
      tools: tools,
      toolChoice: toolChoice,
      modelConfig: modelConfig,
      jsonOutput: jsonOutput,
      cancelToken: cancelToken,
    );
    return Stream.value(StreamingMessage(modelMessage: msg));
  }
}

void main() {
  test('notify_regex wakes registry without completing the job', () async {
    final workspace = _NotifyWorkspace();
    final state = AgentState.empty();
    final agent = StatefulAgent(
      name: 'notify-test',
      client: _SilentLLM(),
      modelConfig: ModelConfig(model: 'fake'),
      state: state,
      withGeneralPrinciples: false,
      disableSubAgents: true,
      toolBackgroundAfter: null,
      tools: [
        createShellTool(
          workspace,
          pollInterval: const Duration(milliseconds: 20),
          timeout: const Duration(seconds: 5),
        ),
      ],
    );

    final notifies = <BackgroundToolJobEvent>[];
    final completes = <BackgroundToolJobEvent>[];
    final sub = agent.backgroundJobs.events.listen((e) {
      if (e.kind == BackgroundToolJobEventKind.notified) {
        notifies.add(e);
      } else if (e.kind == BackgroundToolJobEventKind.completed) {
        completes.add(e);
      }
    });

    final tool = agent.tools!.first;
    final raw = await runZoned(
      () => tool.executable!(<String, dynamic>{
        'command': 'watch-me',
        'notify_regex': r'Listening on',
      }),
      zoneValues: {
        AgentCallToolContext.zoneKey: AgentCallToolContext(
          state: state,
          agent: agent,
          batchCallId: 'b1',
          callId: 'c1',
          toolName: 'shell',
        ),
      },
    );

    final map = jsonDecode(raw as String) as Map<String, dynamic>;
    expect(map['monitoring'], isTrue);
    expect(map['notify_regex'], 'Listening on');
    expect(agent.backgroundJobs.runningJobs, hasLength(1));

    // Wait until notify fires while job is still running.
    for (var i = 0; i < 40 && notifies.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    expect(notifies, isNotEmpty);
    expect(notifies.first.notifyText, contains('Listening on'));
    expect(
      agent.backgroundJobs.runningJobs,
      hasLength(1),
      reason: 'notify must not terminate the shell job',
    );

    for (var i = 0; i < 80 && completes.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    expect(completes, isNotEmpty);
    expect(agent.backgroundJobs.runningJobs, isEmpty);

    await sub.cancel();
  });

  test('buildShellNotifyMessage keeps still_running flag', () {
    final msg = buildShellNotifyMessage(
      jobId: 'j1',
      callId: 'c1',
      toolName: 'shell',
      regex: 'ERROR',
      matchText: 'line ERROR here',
    );
    expect(msg, contains('still_running="true"'));
    expect(msg, contains('line ERROR here'));
  });
}
