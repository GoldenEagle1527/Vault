import 'package:vault/agent/chat_attachment.dart';

/// UI-facing chat / tool step for the Agent screen.
sealed class AgentUiEvent {
  const AgentUiEvent();
}

class AgentUiUserMessage extends AgentUiEvent {
  const AgentUiUserMessage(
    this.text, {
    this.promptTokens,
    this.at,
    this.historyIndex,
    this.attachments = const [],
  });

  final String text;
  final int? promptTokens;
  final DateTime? at;
  final int? historyIndex;
  final List<ChatAttachmentMeta> attachments;
}

class AgentUiAssistantDelta extends AgentUiEvent {
  const AgentUiAssistantDelta(this.text);

  final String text;
}

class AgentUiAssistantFinal extends AgentUiEvent {
  const AgentUiAssistantFinal(
    this.text, {
    this.promptTokens,
    this.completionTokens,
    this.totalTokens,
    this.duration,
    this.at,
  });

  final String text;
  final int? promptTokens;
  final int? completionTokens;
  final int? totalTokens;
  final Duration? duration;
  final DateTime? at;
}

/// Token / latency stats for the latest model call (live stream).
class AgentUiModelUsage extends AgentUiEvent {
  const AgentUiModelUsage({
    required this.promptTokens,
    required this.completionTokens,
    this.totalTokens,
    this.duration,
    this.at,
  });

  final int promptTokens;
  final int completionTokens;
  final int? totalTokens;
  final Duration? duration;
  final DateTime? at;
}

/// Drop a trailing whitespace-only assistant draft (common before tool calls).
class AgentUiDiscardDraftAssistant extends AgentUiEvent {
  const AgentUiDiscardDraftAssistant();
}

class AgentUiToolCall extends AgentUiEvent {
  const AgentUiToolCall({
    required this.name,
    required this.arguments,
    this.callId,
    this.historyIndex,
  });

  final String name;
  final String arguments;
  final String? callId;
  final int? historyIndex;
}

class AgentUiToolResult extends AgentUiEvent {
  const AgentUiToolResult({
    required this.name,
    required this.result,
    this.callId,
    this.historyIndex,
    this.attachments = const [],
  });

  final String name;
  final String result;
  final String? callId;
  final int? historyIndex;
  final List<ChatAttachmentMeta> attachments;
}

/// Current conversation was replaced by a fork; UI should rehydrate.
class AgentUiConversationForked extends AgentUiEvent {
  const AgentUiConversationForked(this.conversationId);

  final String conversationId;
}

/// Tool exceeded the background threshold and is still running.
class AgentUiToolBackgrounded extends AgentUiEvent {
  const AgentUiToolBackgrounded({
    required this.name,
    required this.jobId,
    required this.callId,
    required this.stubResult,
  });

  final String name;
  final String jobId;
  final String callId;
  final String stubResult;
}

/// Previously backgrounded tool finished (UI card update; model may react next).
class AgentUiToolBackgroundCompleted extends AgentUiEvent {
  const AgentUiToolBackgroundCompleted({
    required this.name,
    required this.jobId,
    required this.callId,
    required this.result,
    required this.isError,
  });

  final String name;
  final String jobId;
  final String callId;
  final String result;
  final bool isError;
}

/// Shell notify_regex matched; process still running.
class AgentUiShellNotify extends AgentUiEvent {
  const AgentUiShellNotify({
    required this.jobId,
    required this.callId,
    required this.regex,
    required this.matchText,
  });

  final String jobId;
  final String callId;
  final String regex;
  final String matchText;
}

class AgentUiError extends AgentUiEvent {
  const AgentUiError(this.message);

  final String message;
}

/// Persistent system hint in the transcript (not a user/assistant bubble).
class AgentUiSystemNotice extends AgentUiEvent {
  const AgentUiSystemNotice(this.text, {this.isError = false});

  final String text;
  final bool isError;
}

class AgentUiStatus extends AgentUiEvent {
  const AgentUiStatus(this.message);

  final String message;
}
