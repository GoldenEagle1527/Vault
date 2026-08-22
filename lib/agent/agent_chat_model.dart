import 'package:vault/agent/chat_attachment.dart';

enum AgentChatKind { user, assistant, tool, status, error }

class AgentChatItem {
  AgentChatItem({
    required this.kind,
    required this.text,
    this.toolName,
    this.toolArguments,
    this.toolResult,
    this.toolCallId,
    this.toolJobId,
    this.toolBackgrounded = false,
    this.thinkingPlaceholder = false,
    this.promptTokens,
    this.completionTokens,
    this.totalTokens,
    this.duration,
    this.at,
    this.historyIndex,
    this.attachments = const [],
  });

  factory AgentChatItem.tool({
    required String name,
    required String arguments,
    String? result,
    String? callId,
    String? jobId,
    bool backgrounded = false,
    int? historyIndex,
  }) {
    return AgentChatItem(
      kind: AgentChatKind.tool,
      text: name,
      toolName: name,
      toolArguments: arguments,
      toolResult: result,
      toolCallId: callId,
      toolJobId: jobId,
      toolBackgrounded: backgrounded,
      historyIndex: historyIndex,
    );
  }

  factory AgentChatItem.thinking() {
    return AgentChatItem(
      kind: AgentChatKind.assistant,
      text: 'Agent 正在思考…',
      thinkingPlaceholder: true,
    );
  }

  final AgentChatKind kind;
  String text;
  String? toolName;
  String? toolArguments;
  String? toolResult;
  String? toolCallId;
  String? toolJobId;
  bool toolBackgrounded;
  bool thinkingPlaceholder;
  int? promptTokens;
  int? completionTokens;
  int? totalTokens;
  Duration? duration;
  DateTime? at;
  int? historyIndex;
  List<ChatAttachmentMeta> attachments;
}
