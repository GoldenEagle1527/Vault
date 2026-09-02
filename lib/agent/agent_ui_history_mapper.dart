import 'package:vault/agent/agent_ui_events.dart';
import 'package:vault/agent/chat_attachment.dart';
import 'package:vault/agent/conversation_state.dart';
import 'package:vault/agent/present_file.dart';
import 'package:vault/agent/system_notice.dart';
import 'package:vault_agent_core/vault_agent_core.dart';

/// Maps persisted agent history into UI events without side effects.
List<AgentUiEvent> uiEventsFromHistory(List<LLMMessage> messages) {
  final out = <AgentUiEvent>[];
  LLMMessage? previous;
  for (var i = 0; i < messages.length; i++) {
    final message = messages[i];
    if (message is UserMessage) {
      _mapUserMessage(message, i, out);
    } else if (message is ModelMessage) {
      _mapModelMessage(message, previous, i, out);
    } else if (message is FunctionExecutionResultMessage) {
      _mapToolResults(message, i, out);
    }
    previous = message;
  }
  return out;
}

void _mapUserMessage(
  UserMessage message,
  int historyIndex,
  List<AgentUiEvent> out,
) {
  final raw = message.contents
      .whereType<TextPart>()
      .map((part) => part.text)
      .join('\n')
      .trim();
  final attachments = ChatAttachmentMeta.listFromJson(
    message.metadata?['attachments'],
  );
  if (raw.isNotEmpty) {
    final notice = systemNoticeForUserText(raw);
    if (notice != null) {
      out.add(AgentUiSystemNotice(notice.text, isError: notice.isError));
      return;
    }
    var display = displayTextFromStoredUserPrompt(raw);
    if (display.isEmpty && attachments.isNotEmpty) {
      display = '（仅附件）';
    }
    out.add(
      AgentUiUserMessage(
        display,
        at: DateTime.fromMicrosecondsSinceEpoch(message.timestamp),
        historyIndex: historyIndex,
        attachments: attachments,
      ),
    );
  } else if (attachments.isNotEmpty) {
    out.add(
      AgentUiUserMessage(
        '（仅附件）',
        at: DateTime.fromMicrosecondsSinceEpoch(message.timestamp),
        historyIndex: historyIndex,
        attachments: attachments,
      ),
    );
  }
}

void _mapModelMessage(
  ModelMessage message,
  LLMMessage? previous,
  int historyIndex,
  List<AgentUiEvent> out,
) {
  final usage = message.usage;
  final at = DateTime.fromMicrosecondsSinceEpoch(message.timestamp);
  final duration = _durationBetween(previous, message);
  final text = message.textOutput?.trim();
  final thought = message.thought?.trim();
  final hasText = text != null && text.isNotEmpty;
  final hasThought = thought != null && thought.isNotEmpty;
  if (hasText || hasThought) {
    out.add(
      AgentUiAssistantFinal(
        text ?? '',
        thought: hasThought ? thought : null,
        promptTokens: usage?.promptTokens,
        completionTokens: usage?.completionTokens,
        totalTokens: usage == null
            ? null
            : (usage.totalTokens > 0
                  ? usage.totalTokens
                  : usage.promptTokens + usage.completionTokens),
        duration: duration,
        at: at,
      ),
    );
  } else if (usage != null &&
      (usage.promptTokens > 0 || usage.completionTokens > 0)) {
    out.add(
      AgentUiModelUsage(
        promptTokens: usage.promptTokens,
        completionTokens: usage.completionTokens,
        totalTokens: usage.totalTokens > 0
            ? usage.totalTokens
            : usage.promptTokens + usage.completionTokens,
        duration: duration,
        at: at,
      ),
    );
  }
  if (usage != null && usage.promptTokens > 0) {
    _attachPromptTokensToLastUserEvent(out, usage.promptTokens);
  }
  for (final call in message.functionCalls) {
    out.add(
      AgentUiToolCall(
        name: call.name,
        arguments: call.arguments,
        callId: call.id,
        historyIndex: historyIndex,
      ),
    );
  }
}

void _mapToolResults(
  FunctionExecutionResultMessage message,
  int historyIndex,
  List<AgentUiEvent> out,
) {
  for (final result in message.results) {
    final text = result.content
        .whereType<TextPart>()
        .map((part) => part.text)
        .join('\n');
    if (result.metadata?['background'] == true) {
      out.add(
        AgentUiToolBackgrounded(
          name: result.name,
          jobId: result.metadata?['jobId']?.toString() ?? result.id,
          callId: result.id,
          stubResult: text,
        ),
      );
    } else {
      final presented = result.name == kPresentFileToolName
          ? presentFileAttachmentFromResult(
              metadata: result.metadata,
              resultText: text,
            )
          : null;
      out.add(
        AgentUiToolResult(
          name: result.name,
          result: text,
          callId: result.id,
          historyIndex: historyIndex,
          attachments: presented == null ? const [] : [presented],
        ),
      );
    }
  }
}

Duration? _durationBetween(LLMMessage? previous, ModelMessage next) {
  if (previous == null) return null;
  final previousTimestamp = switch (previous) {
    UserMessage(:final timestamp) => timestamp,
    ModelMessage(:final timestamp) => timestamp,
    FunctionExecutionResultMessage(:final timestamp) => timestamp,
    _ => null,
  };
  if (previousTimestamp == null || next.timestamp <= previousTimestamp) {
    return null;
  }
  return Duration(microseconds: next.timestamp - previousTimestamp);
}

void _attachPromptTokensToLastUserEvent(
  List<AgentUiEvent> events,
  int promptTokens,
) {
  for (var i = events.length - 1; i >= 0; i--) {
    final event = events[i];
    if (event is AgentUiUserMessage) {
      if (event.promptTokens != null) return;
      events[i] = AgentUiUserMessage(
        event.text,
        promptTokens: promptTokens,
        at: event.at,
        historyIndex: event.historyIndex,
        attachments: event.attachments,
      );
      return;
    }
  }
}
