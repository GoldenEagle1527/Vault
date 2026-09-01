import 'dart:convert';

import 'package:vault/agent/agent_ui_events.dart';
import 'package:vault/agent/present_file.dart';
import 'package:vault/agent/system_notice.dart';
import 'package:vault/agent/tools/shell_tool.dart';
import 'package:vault_agent_core/vault_agent_core.dart';

/// Maps core streaming/background events into UI-facing events.
///
/// The mapper owns only per-model-call timing state. Agent execution and
/// background wake-up orchestration remain with the service.
class AgentStreamMapper {
  AgentStreamMapper({
    required this.runningBackgroundJobs,
    this._backgroundThreshold = kAgentToolBackgroundAfter,
  });

  final List<BackgroundToolJob> Function() runningBackgroundJobs;
  final Duration _backgroundThreshold;
  DateTime? _modelCallStartedAt;

  /// True after this model call already showed assistant prose (chunks or flush).
  /// Prevents [StreamingEventType.fullModelMessage] from painting the same
  /// paragraph again once tools have cleared [buffer].
  bool _visibleTextEmitted = false;

  Stream<AgentUiEvent> map(StreamingEvent event, StringBuffer buffer) async* {
    switch (event.eventType) {
      case StreamingEventType.modelChunkMessage:
        final chunk = event.data as ModelMessage;
        final text = chunk.textOutput;
        if (isVisibleAssistantText(text)) {
          buffer.write(text);
          _visibleTextEmitted = true;
          yield AgentUiAssistantDelta(text!);
        }
        if (chunk.functionCalls.isNotEmpty) {
          for (final uiEvent in _flushTurnBeforeTools(buffer)) {
            yield uiEvent;
          }
          for (final call in chunk.functionCalls) {
            if (call.id.isEmpty &&
                call.name.isEmpty &&
                call.arguments.isEmpty) {
              continue;
            }
            yield AgentUiToolCall(
              name: call.name,
              arguments: call.arguments,
              callId: call.id.isEmpty ? null : call.id,
            );
          }
        }
      case StreamingEventType.fullModelMessage:
        final full = event.data as ModelMessage;
        final text = full.textOutput;
        if (isVisibleAssistantText(text) &&
            buffer.isEmpty &&
            !_visibleTextEmitted) {
          buffer.write(text);
          _visibleTextEmitted = true;
          yield AgentUiAssistantDelta(text!);
        }
        final usage = full.usage;
        final at = DateTime.fromMicrosecondsSinceEpoch(full.timestamp);
        final started = _modelCallStartedAt;
        final prompt = usage?.promptTokens ?? 0;
        final completion = usage?.completionTokens ?? 0;
        yield AgentUiModelUsage(
          promptTokens: prompt,
          completionTokens: completion,
          totalTokens: usage == null
              ? null
              : (usage.totalTokens > 0
                    ? usage.totalTokens
                    : prompt + completion),
          duration: started == null ? null : at.difference(started),
          at: at,
        );
      case StreamingEventType.functionCallRequest:
        for (final uiEvent in _flushTurnBeforeTools(buffer)) {
          yield uiEvent;
        }
        final calls = event.data;
        final list = calls is List<FunctionCall>
            ? calls
            : calls is List
            ? calls.whereType<FunctionCall>().toList()
            : const <FunctionCall>[];
        for (final call in list) {
          yield AgentUiToolCall(
            name: call.name,
            arguments: call.arguments,
            callId: call.id,
          );
          yield AgentUiStatus('正在执行工具：${call.name}');
        }
      case StreamingEventType.toolBackgrounded:
        final job = event.data;
        if (job is BackgroundToolJob) {
          final running = runningBackgroundJobs();
          yield AgentUiToolBackgrounded(
            name: job.toolName,
            jobId: job.jobId,
            callId: job.callId,
            stubResult: buildBackgroundToolStubText(
              toolName: job.toolName,
              jobId: job.jobId,
              callId: job.callId,
              threshold: _backgroundThreshold,
              runningJobs: running.isEmpty ? [job] : running,
            ),
          );
          yield AgentUiStatus('工具已转后台：${running.length} 个进行中');
        }
      case StreamingEventType.functionCallResult:
        final data = event.data;
        if (data is FunctionExecutionResultMessage) {
          for (final result in data.results) {
            final text = result.content
                .whereType<TextPart>()
                .map((part) => part.text)
                .join('\n');
            final metadata = result.metadata;
            final isBackground =
                metadata?['background'] == true ||
                text.contains('"monitoring":true') ||
                text.contains('"background":true');
            if (isBackground) {
              yield AgentUiToolBackgrounded(
                name: result.name,
                jobId:
                    metadata?['jobId']?.toString() ??
                    _jobIdFromToolJson(text) ??
                    result.id,
                callId: result.id,
                stubResult: text,
              );
              final count = runningBackgroundJobs().length;
              if (count > 0) {
                yield AgentUiStatus('工具已转后台：$count 个进行中');
              }
              continue;
            }
            final presented = result.name == kPresentFileToolName
                ? presentFileAttachmentFromResult(
                    metadata: metadata,
                    resultText: text,
                  )
                : null;
            yield AgentUiToolResult(
              name: result.name,
              result: text,
              callId: result.id,
              attachments: presented == null ? const [] : [presented],
            );
          }
        }
      case StreamingEventType.toolBackgroundCompleted:
        break;
      case StreamingEventType.modelRetrying:
        buffer.clear();
        _visibleTextEmitted = false;
        _modelCallStartedAt = DateTime.now();
        yield const AgentUiDiscardDraftAssistant();
        yield const AgentUiStatus('正在调用模型…');
      case StreamingEventType.beforeCallModel:
        _visibleTextEmitted = false;
        _modelCallStartedAt = DateTime.now();
        yield const AgentUiStatus('正在调用模型…');
    }
  }

  List<AgentUiEvent> mapBackgroundJobEvent(
    BackgroundToolJobEvent event, {
    required int runningJobCount,
  }) {
    final job = event.job;
    switch (event.kind) {
      case BackgroundToolJobEventKind.backgrounded:
        return const [];
      case BackgroundToolJobEventKind.notified:
        final text = event.notifyText ?? '';
        final regex = event.notifyRegex ?? job.notifyRegex ?? '';
        return [
          AgentUiShellNotify(
            jobId: job.jobId,
            callId: job.callId,
            regex: regex,
            matchText: text,
          ),
          const AgentUiStatus('shell 输出已匹配，准备唤醒模型…'),
        ];
      case BackgroundToolJobEventKind.completed:
        return [
          AgentUiToolBackgroundCompleted(
            name: job.toolName,
            jobId: job.jobId,
            callId: job.callId,
            result: job.resultText(),
            isError:
                job.status == BackgroundToolJobStatus.failed ||
                (job.result?.isError ?? false),
          ),
          AgentUiStatus(
            runningJobCount == 0 ? '后台任务已完成' : '后台任务进行中：$runningJobCount',
          ),
        ];
    }
  }

  static bool isVisibleAssistantText(String? text) =>
      text != null && text.trim().isNotEmpty;

  static Iterable<AgentUiEvent> flushTurnBeforeTools(
    StringBuffer buffer,
  ) sync* {
    final draft = buffer.toString();
    buffer.clear();
    if (draft.trim().isEmpty) {
      yield const AgentUiDiscardDraftAssistant();
      return;
    }
    yield AgentUiAssistantFinal(draft);
  }

  Iterable<AgentUiEvent> _flushTurnBeforeTools(StringBuffer buffer) sync* {
    for (final uiEvent in flushTurnBeforeTools(buffer)) {
      if (uiEvent is AgentUiAssistantFinal) {
        _visibleTextEmitted = true;
      }
      yield uiEvent;
    }
  }

  static AgentUiSystemNotice systemNoticeEvent(
    String raw, {
    required String fallback,
  }) {
    final notice = systemNoticeForUserText(raw);
    return AgentUiSystemNotice(
      notice?.text ?? fallback,
      isError: notice?.isError ?? false,
    );
  }

  static String? _jobIdFromToolJson(String text) {
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map && decoded['jobId'] != null) {
        return decoded['jobId'].toString();
      }
    } catch (_) {}
    return null;
  }
}
