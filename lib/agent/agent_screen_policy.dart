import 'package:vault/agent/agent_service.dart';

/// Stable categories used by AgentScreen when projecting service events.
enum AgentScreenEventKind {
  user,
  systemNotice,
  assistantDelta,
  assistantFinal,
  modelUsage,
  discardDraftAssistant,
  toolCall,
  toolResult,
  conversationForked,
  toolBackgrounded,
  toolBackgroundCompleted,
  shellNotify,
  error,
  status,
}

/// Streaming token deltas coalesce into one list rebuild per frame.
bool coalesceAgentChatUiFlush(AgentUiEvent event) {
  return event is AgentUiAssistantDelta;
}

AgentScreenEventKind classifyAgentScreenEvent(AgentUiEvent event) {
  return switch (event) {
    AgentUiUserMessage() => AgentScreenEventKind.user,
    AgentUiSystemNotice() => AgentScreenEventKind.systemNotice,
    AgentUiAssistantDelta() => AgentScreenEventKind.assistantDelta,
    AgentUiAssistantFinal() => AgentScreenEventKind.assistantFinal,
    AgentUiModelUsage() => AgentScreenEventKind.modelUsage,
    AgentUiDiscardDraftAssistant() =>
      AgentScreenEventKind.discardDraftAssistant,
    AgentUiToolCall() => AgentScreenEventKind.toolCall,
    AgentUiToolResult() => AgentScreenEventKind.toolResult,
    AgentUiConversationForked() => AgentScreenEventKind.conversationForked,
    AgentUiToolBackgrounded() => AgentScreenEventKind.toolBackgrounded,
    AgentUiToolBackgroundCompleted() =>
      AgentScreenEventKind.toolBackgroundCompleted,
    AgentUiShellNotify() => AgentScreenEventKind.shellNotify,
    AgentUiError() => AgentScreenEventKind.error,
    AgentUiStatus() => AgentScreenEventKind.status,
  };
}

enum AgentScreenStatusDisposition { completed, thinking, visible, hidden }

AgentScreenStatusDisposition agentScreenStatusDisposition(String message) {
  if (message == '已完成') return AgentScreenStatusDisposition.completed;
  if (message == '正在思考…' ||
      message == '正在调用模型…' ||
      message == '运行中…' ||
      message == '后台任务结果已送达，正在继续…' ||
      message == 'shell 匹配通知已送达，正在继续…' ||
      message == 'shell 输出已匹配，准备唤醒模型…') {
    return AgentScreenStatusDisposition.thinking;
  }
  if (message.startsWith('正在执行工具：')) {
    return AgentScreenStatusDisposition.hidden;
  }
  return AgentScreenStatusDisposition.visible;
}
