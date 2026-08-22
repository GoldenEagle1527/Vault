import '../core/llm_client.dart';
import '../core/message.dart';
import '../core/tool.dart';
import 'memory.dart';
import 'planner.dart';
import 'util.dart';

class SystemPromptHistoryItem {
  final String content;
  final int validFromMessageIndex;

  SystemPromptHistoryItem({
    required this.content,
    required this.validFromMessageIndex,
  });

  Map<String, dynamic> toJson() => {
    'content': content,
    'validFromMessageIndex': validFromMessageIndex,
  };

  factory SystemPromptHistoryItem.fromJson(Map<String, dynamic> json) {
    return SystemPromptHistoryItem(
      content: json['content'],
      validFromMessageIndex: json['validFromMessageIndex'],
    );
  }
}

class ToolsHistoryItem {
  final List<Map<String, dynamic>> tools;
  final int validFromMessageIndex;

  ToolsHistoryItem({required this.tools, required this.validFromMessageIndex});

  Map<String, dynamic> toJson() => {
    'tools': tools,
    'validFromMessageIndex': validFromMessageIndex,
  };

  factory ToolsHistoryItem.fromJson(Map<String, dynamic> json) {
    return ToolsHistoryItem(
      tools: (json['tools'] as List).cast<Map<String, dynamic>>(),
      validFromMessageIndex: json['validFromMessageIndex'],
    );
  }
}

/// Represents the state of an AI agent, including its history, token usage,
/// active skills, and planning metadata.
class AgentState {
  /// Unique session identifier.
  String sessionId;
  bool isRunning;
  Map<String, String> systemReminders;
  AgentMessageHistory history;
  List<ModelUsage> usages;
  Map<String, dynamic> metadata;
  PlanState? plan;
  List<String>? activeSkills;
  int totalLoopCount;
  int currentLoopCount;
  List<ModelUsage> currentLoopUsages;
  String? lastError;
  List<SystemPromptHistoryItem> systemPromptHistory;
  List<ToolsHistoryItem> toolsHistory;

  AgentState({
    required this.sessionId,
    AgentMessageHistory? history,
    Map<String, String>? systemReminders,
    List<ModelUsage>? usages,
    List<ModelUsage>? currentLoopUsages,
    Map<String, dynamic>? metadata,
    this.plan,
    this.activeSkills,
    this.isRunning = false,
    this.totalLoopCount = 0,
    this.currentLoopCount = 0,
    this.lastError,
    List<SystemPromptHistoryItem>? systemPromptHistory,
    List<ToolsHistoryItem>? toolsHistory,
  }) : history = history ?? AgentMessageHistory(),
       systemReminders = systemReminders ?? {},
       usages = usages ?? [],
       metadata = metadata ?? {},
       currentLoopUsages = currentLoopUsages ?? [],
       systemPromptHistory = systemPromptHistory ?? [],
       toolsHistory = toolsHistory ?? [];

  Map<String, dynamic> toJson() => {
    'history': history.toJson(),
    'usages': usages.map((e) => e.toJson()).toList(),
    'metadata': metadata,
    'sessionId': sessionId,
    'systemReminders': systemReminders,
    'plan': plan?.toJson(),
    'activeSkills': activeSkills,
    'isRunning': isRunning,
    'totalLoopCount': totalLoopCount,
    'currentLoopCount': currentLoopCount,
    'currentLoopUsages': currentLoopUsages.map((e) => e.toJson()).toList(),
    'lastError': lastError,
    'systemPromptHistory': systemPromptHistory.map((e) => e.toJson()).toList(),
    'toolsHistory': toolsHistory.map((e) => e.toJson()).toList(),
  };

  factory AgentState.empty() {
    return AgentState(sessionId: uuid.v4());
  }

  factory AgentState.fromJson(Map<String, dynamic> json) {
    return AgentState(
      sessionId: json['sessionId'],
      history: AgentMessageHistory.fromJson(json['history']),
      usages:
          (json['usages'] as List?)
              ?.map((e) => ModelUsage.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
      currentLoopUsages:
          (json['currentLoopUsages'] as List?)
              ?.map((e) => ModelUsage.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
      metadata: json['metadata'] as Map<String, dynamic>? ?? {},
      systemReminders: (json['systemReminders'] as Map? ?? {})
          .cast<String, String>(),
      plan: json['plan'] != null ? PlanState.fromJson(json['plan']) : null,
      activeSkills: (json['activeSkills'] as List? ?? [])
          .cast<String>()
          .toList(),
      isRunning: json['isRunning'] as bool? ?? false,
      totalLoopCount: json['totalLoopCount'] as int? ?? 0,
      currentLoopCount: json['currentLoopCount'] as int? ?? 0,
      lastError: json['lastError'] as String?,
      systemPromptHistory:
          (json['systemPromptHistory'] as List?)
              ?.map(
                (e) =>
                    SystemPromptHistoryItem.fromJson(e as Map<String, dynamic>),
              )
              .toList() ??
          [],
      toolsHistory:
          (json['toolsHistory'] as List?)
              ?.map((e) => ToolsHistoryItem.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }
}

class CallLLMParams {
  final List<LLMMessage> messages;
  final List<Tool>? tools;
  final ToolChoice? toolChoice;
  final ModelConfig modelConfig;
  final bool stream;

  CallLLMParams({
    required this.messages,
    this.tools,
    this.toolChoice,
    required this.modelConfig,
    required this.stream,
  });
}
