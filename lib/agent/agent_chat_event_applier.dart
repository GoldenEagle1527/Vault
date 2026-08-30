import 'package:vault/agent/agent_chat_model.dart';
import 'package:vault/agent/agent_screen_policy.dart';
import 'package:vault/agent/agent_service.dart';
import 'package:vault/agent/chat_attachment.dart';
import 'package:vault/agent/system_notice.dart';

class AgentChatEventApplier {
  AgentChatEventApplier({this.onProjectUrlRegistered});

  final void Function()? onProjectUrlRegistered;
  final List<AgentChatItem> items = [];
  String? status;

  void applyRestored(AgentUiEvent event) {
    switch (event) {
      case AgentUiUserMessage(
        :final text,
        :final promptTokens,
        :final at,
        :final historyIndex,
        :final attachments,
      ):
        _addUserOrSystemNotice(
          text,
          promptTokens: promptTokens,
          at: at,
          historyIndex: historyIndex,
          attachments: attachments,
        );
      case AgentUiSystemNotice(:final text, :final isError):
        items.add(
          AgentChatItem(
            kind: isError ? AgentChatKind.error : AgentChatKind.status,
            text: text,
          ),
        );
      case AgentUiAssistantFinal(
        :final text,
        :final promptTokens,
        :final completionTokens,
        :final totalTokens,
        :final duration,
        :final at,
      ):
        items.add(
          AgentChatItem(
            kind: AgentChatKind.assistant,
            text: text,
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            totalTokens: totalTokens,
            duration: duration,
            at: at,
          ),
        );
      case AgentUiAssistantDelta(:final text):
        items.add(AgentChatItem(kind: AgentChatKind.assistant, text: text));
      case AgentUiModelUsage(
        :final promptTokens,
        :final completionTokens,
        :final totalTokens,
        :final duration,
        :final at,
      ):
        _applyModelUsage(
          promptTokens: promptTokens,
          completionTokens: completionTokens,
          totalTokens: totalTokens,
          duration: duration,
          at: at,
        );
      case AgentUiToolCall(
        :final name,
        :final arguments,
        :final callId,
        :final historyIndex,
      ):
        items.add(
          AgentChatItem.tool(
            name: name,
            arguments: arguments,
            callId: callId,
            historyIndex: historyIndex,
          ),
        );
      case AgentUiToolResult(
        :final name,
        :final result,
        :final callId,
        :final historyIndex,
        :final attachments,
      ):
        _attachToolResult(
          name,
          result,
          callId: callId,
          historyIndex: historyIndex,
          attachments: attachments,
        );
      case AgentUiToolBackgrounded(
        :final name,
        :final jobId,
        :final callId,
        :final stubResult,
      ):
        _markToolBackgrounded(
          name: name,
          jobId: jobId,
          callId: callId,
          stubResult: stubResult,
        );
      case AgentUiToolBackgroundCompleted(
        :final name,
        :final jobId,
        :final callId,
        :final result,
      ):
        _attachToolResult(
          name,
          result,
          callId: callId,
          jobId: jobId,
          clearBackgrounded: true,
        );
      case AgentUiError(:final message):
        items.add(AgentChatItem(kind: AgentChatKind.error, text: message));
      case AgentUiShellNotify():
      case AgentUiStatus():
      case AgentUiDiscardDraftAssistant():
      case AgentUiConversationForked():
        break;
    }
  }

  void applyLive(AgentUiEvent event, {DateTime Function()? now}) {
    switch (event) {
      case AgentUiUserMessage(
        :final text,
        :final promptTokens,
        :final at,
        :final historyIndex,
        :final attachments,
      ):
        _addUserOrSystemNotice(
          text,
          promptTokens: promptTokens,
          at: at ?? (now ?? DateTime.now)(),
          historyIndex: historyIndex,
          attachments: attachments,
        );
      case AgentUiSystemNotice(:final text, :final isError):
        items.add(
          AgentChatItem(
            kind: isError ? AgentChatKind.error : AgentChatKind.status,
            text: text,
          ),
        );
      case AgentUiAssistantDelta(:final text):
        if (!AgentService.isVisibleAssistantText(text)) break;
        if (items.isNotEmpty && items.last.kind == AgentChatKind.assistant) {
          if (items.last.thinkingPlaceholder) {
            items.last
              ..thinkingPlaceholder = false
              ..text = text;
          } else {
            items.last.text += text;
          }
        } else {
          items.add(AgentChatItem(kind: AgentChatKind.assistant, text: text));
        }
      case AgentUiAssistantFinal(
        :final text,
        :final promptTokens,
        :final completionTokens,
        :final totalTokens,
        :final duration,
        :final at,
      ):
        if (!AgentService.isVisibleAssistantText(text)) {
          if (items.isNotEmpty &&
              items.last.kind == AgentChatKind.assistant &&
              !items.last.thinkingPlaceholder) {
            _mergeUsageInto(
              items.last,
              promptTokens: promptTokens,
              completionTokens: completionTokens,
              totalTokens: totalTokens,
              duration: duration,
              at: at,
            );
          }
          break;
        }
        if (items.isNotEmpty && items.last.kind == AgentChatKind.assistant) {
          final item = items.last;
          item
            ..thinkingPlaceholder = false
            ..text = text;
          _mergeUsageInto(
            item,
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            totalTokens: totalTokens,
            duration: duration,
            at: at,
          );
        } else {
          items.add(
            AgentChatItem(
              kind: AgentChatKind.assistant,
              text: text,
              promptTokens: promptTokens,
              completionTokens: completionTokens,
              totalTokens: totalTokens,
              duration: duration,
              at: at,
            ),
          );
        }
        if (promptTokens != null && promptTokens > 0) {
          _attachPromptTokensToLastUser(promptTokens);
        }
      case AgentUiModelUsage(
        :final promptTokens,
        :final completionTokens,
        :final totalTokens,
        :final duration,
        :final at,
      ):
        _applyModelUsage(
          promptTokens: promptTokens,
          completionTokens: completionTokens,
          totalTokens: totalTokens,
          duration: duration,
          at: at,
        );
      case AgentUiDiscardDraftAssistant():
        discardBlankAssistantDraft();
      case AgentUiToolCall(
        :final name,
        :final arguments,
        :final callId,
        :final historyIndex,
      ):
        _upsertToolCall(
          name: name,
          arguments: arguments,
          callId: callId,
          historyIndex: historyIndex,
        );
      case AgentUiToolResult(
        :final name,
        :final result,
        :final callId,
        :final historyIndex,
        :final attachments,
      ):
        _attachToolResult(
          name,
          result,
          callId: callId,
          historyIndex: historyIndex,
          attachments: attachments,
        );
      case AgentUiConversationForked():
        break;
      case AgentUiToolBackgrounded(
        :final name,
        :final jobId,
        :final callId,
        :final stubResult,
      ):
        _markToolBackgrounded(
          name: name,
          jobId: jobId,
          callId: callId,
          stubResult: stubResult,
        );
      case AgentUiToolBackgroundCompleted(
        :final name,
        :final jobId,
        :final callId,
        :final result,
      ):
        _attachToolResult(
          name,
          result,
          callId: callId,
          jobId: jobId,
          clearBackgrounded: true,
        );
      case AgentUiShellNotify(:final regex):
        status = 'shell 匹配通知：$regex';
      case AgentUiError(:final message):
        discardThinkingPlaceholder();
        items.add(AgentChatItem(kind: AgentChatKind.error, text: message));
      case AgentUiStatus(:final message):
        switch (agentScreenStatusDisposition(message)) {
          case AgentScreenStatusDisposition.completed:
            status = null;
            discardThinkingPlaceholder();
          case AgentScreenStatusDisposition.thinking:
            status = null;
            ensureThinkingPlaceholder();
          case AgentScreenStatusDisposition.visible:
            status = message;
          case AgentScreenStatusDisposition.hidden:
            status = null;
        }
    }
  }

  void ensureThinkingPlaceholder() {
    if (items.isNotEmpty &&
        items.last.kind == AgentChatKind.assistant &&
        items.last.thinkingPlaceholder) {
      return;
    }
    items.add(AgentChatItem.thinking());
  }

  void discardThinkingPlaceholder() {
    while (items.isNotEmpty &&
        items.last.kind == AgentChatKind.assistant &&
        items.last.thinkingPlaceholder) {
      items.removeLast();
    }
  }

  void discardBlankAssistantDraft() {
    while (items.isNotEmpty &&
        items.last.kind == AgentChatKind.assistant &&
        (items.last.thinkingPlaceholder || items.last.text.trim().isEmpty)) {
      items.removeLast();
    }
  }

  void _addUserOrSystemNotice(
    String text, {
    int? promptTokens,
    DateTime? at,
    int? historyIndex,
    List<ChatAttachmentMeta> attachments = const [],
  }) {
    final notice = systemNoticeForUserText(text);
    if (notice != null) {
      items.add(
        AgentChatItem(
          kind: notice.isError ? AgentChatKind.error : AgentChatKind.status,
          text: notice.text,
        ),
      );
      return;
    }
    items.add(
      AgentChatItem(
        kind: AgentChatKind.user,
        text: text,
        promptTokens: promptTokens,
        at: at,
        historyIndex: historyIndex,
        attachments: attachments,
      ),
    );
  }

  void _mergeUsageInto(
    AgentChatItem item, {
    int? promptTokens,
    int? completionTokens,
    int? totalTokens,
    Duration? duration,
    DateTime? at,
  }) {
    if (promptTokens != null && promptTokens > 0) {
      item.promptTokens = promptTokens;
    }
    if (completionTokens != null && completionTokens > 0) {
      item.completionTokens = completionTokens;
    }
    if (totalTokens != null && totalTokens > 0) item.totalTokens = totalTokens;
    if (duration != null) item.duration = duration;
    if (at != null) item.at = at;
  }

  void _attachPromptTokensToLastUser(int promptTokens) {
    for (var i = items.length - 1; i >= 0; i--) {
      final item = items[i];
      if (item.kind != AgentChatKind.user) continue;
      item.promptTokens ??= promptTokens;
      return;
    }
  }

  void _applyModelUsage({
    required int promptTokens,
    required int completionTokens,
    int? totalTokens,
    Duration? duration,
    DateTime? at,
  }) {
    if (promptTokens > 0) _attachPromptTokensToLastUser(promptTokens);
    for (var i = items.length - 1; i >= 0; i--) {
      final item = items[i];
      if (item.kind != AgentChatKind.assistant || item.thinkingPlaceholder) {
        continue;
      }
      _mergeUsageInto(
        item,
        promptTokens: promptTokens,
        completionTokens: completionTokens,
        totalTokens: totalTokens,
        duration: duration,
        at: at,
      );
      return;
    }
  }

  void _upsertToolCall({
    required String name,
    required String arguments,
    String? callId,
    int? historyIndex,
  }) {
    discardBlankAssistantDraft();
    for (var i = items.length - 1; i >= 0; i--) {
      final item = items[i];
      if (item.kind != AgentChatKind.tool || item.toolResult != null) continue;
      final idMatch =
          callId != null && callId.isNotEmpty && item.toolCallId == callId;
      final adoptPending =
          !item.toolBackgrounded &&
          (item.toolCallId == null || item.toolCallId!.isEmpty) &&
          (name.isEmpty ||
              item.toolName == null ||
              item.toolName!.isEmpty ||
              item.toolName == name);
      if (!idMatch && !adoptPending) continue;
      if (callId != null && callId.isNotEmpty) item.toolCallId = callId;
      if (name.isNotEmpty) {
        item
          ..toolName = name
          ..text = name;
      }
      if (arguments.length >= (item.toolArguments?.length ?? 0)) {
        item.toolArguments = arguments;
      }
      item.historyIndex ??= historyIndex;
      return;
    }
    items.add(
      AgentChatItem.tool(
        name: name,
        arguments: arguments,
        callId: callId,
        historyIndex: historyIndex,
      ),
    );
  }

  void _markToolBackgrounded({
    required String name,
    required String jobId,
    required String callId,
    required String stubResult,
  }) {
    for (var i = items.length - 1; i >= 0; i--) {
      final item = items[i];
      if (item.kind != AgentChatKind.tool) continue;
      final matches =
          item.toolCallId == callId ||
          (item.toolCallId == null &&
              item.toolName == name &&
              item.toolResult == null &&
              !item.toolBackgrounded);
      if (!matches) continue;
      item.toolCallId ??= callId;
      item
        ..toolJobId = jobId
        ..toolBackgrounded = true;
      return;
    }
    items.add(
      AgentChatItem.tool(
        name: name,
        arguments: stubResult,
        callId: callId,
        jobId: jobId,
        backgrounded: true,
      ),
    );
  }

  void _attachToolResult(
    String name,
    String result, {
    String? callId,
    String? jobId,
    bool clearBackgrounded = false,
    int? historyIndex,
    List<ChatAttachmentMeta> attachments = const [],
  }) {
    for (var i = items.length - 1; i >= 0; i--) {
      final item = items[i];
      if (item.kind != AgentChatKind.tool) continue;
      final idMatch = callId != null && item.toolCallId == callId;
      final jobMatch = jobId != null && item.toolJobId == jobId;
      final nameMatch =
          item.toolName == name &&
          (item.toolResult == null || item.toolBackgrounded);
      if (!idMatch &&
          !jobMatch &&
          !(callId == null && jobId == null && nameMatch)) {
        continue;
      }
      item.toolResult = result;
      if (clearBackgrounded) item.toolBackgrounded = false;
      item.toolCallId ??= callId;
      item.toolJobId ??= jobId;
      if (historyIndex != null) item.historyIndex = historyIndex;
      if (attachments.isNotEmpty) item.attachments = attachments;
      if (name == 'scaffold_site' ||
          name == 'manage_site' ||
          name == 'register_project_url') {
        onProjectUrlRegistered?.call();
      }
      return;
    }
    items.add(
      AgentChatItem.tool(
        name: name,
        arguments: '',
        result: result,
        callId: callId,
        jobId: jobId,
        historyIndex: historyIndex,
        attachments: attachments,
      ),
    );
  }
}
