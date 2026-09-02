import 'package:vault/agent/agent_chat_model.dart';
import 'package:vault/agent/ask_user.dart';
import 'package:vault/agent/present_file.dart';

/// Interactive / rich tool cards that stay outside the compact tool group.
bool isGroupedToolItem(AgentChatItem item) {
  if (item.kind != AgentChatKind.tool) return false;
  final name = item.toolName ?? item.text;
  return name != kAskUserToolName && name != kPresentFileToolName;
}

bool agentChatItemHasThinking(AgentChatItem item) {
  if (item.kind != AgentChatKind.assistant) return false;
  if (item.thinkingPlaceholder) return true;
  return (item.thinkingText ?? '').trim().isNotEmpty;
}

bool agentChatItemHasAssistantBody(AgentChatItem item) {
  if (item.kind != AgentChatKind.assistant || item.thinkingPlaceholder) {
    return false;
  }
  return item.text.trim().isNotEmpty;
}

/// Streaming assistant bodies skip markdown until [AgentUiAssistantFinal].
bool agentChatItemRendersPlainText(AgentChatItem item) {
  return item.kind == AgentChatKind.assistant && item.streaming;
}

String agentThinkingLabel(AgentChatItem item) {
  if (item.thinkingPlaceholder) return '思考中';
  final seconds = item.duration?.inSeconds ?? 0;
  if (seconds > 0) return '思考 ${seconds}秒';
  return '思考';
}

String agentToolGroupLabel({required int count, required bool running}) {
  return running ? '正在执行 $count 个工具' : '执行了 $count 个工具';
}

sealed class AgentTranscriptSpan {
  const AgentTranscriptSpan();
}

final class AgentTranscriptSingle extends AgentTranscriptSpan {
  const AgentTranscriptSingle(this.index);

  final int index;
}

final class AgentTranscriptToolGroup extends AgentTranscriptSpan {
  const AgentTranscriptToolGroup({
    required this.start,
    required this.endExclusive,
  });

  final int start;
  final int endExclusive;

  int get count => endExclusive - start;
}

/// Collapses consecutive groupable tool items into one transcript row.
List<AgentTranscriptSpan> groupAgentTranscript(List<AgentChatItem> items) {
  final spans = <AgentTranscriptSpan>[];
  var index = 0;
  while (index < items.length) {
    if (isGroupedToolItem(items[index])) {
      var end = index + 1;
      while (end < items.length && isGroupedToolItem(items[end])) {
        end++;
      }
      spans.add(AgentTranscriptToolGroup(start: index, endExclusive: end));
      index = end;
      continue;
    }
    spans.add(AgentTranscriptSingle(index));
    index++;
  }
  return spans;
}
