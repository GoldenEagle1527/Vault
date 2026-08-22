import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:vault/agent/agent_chat_model.dart';
import 'package:vault/agent/agent_inbox.dart';
import 'package:vault/agent/ask_user.dart';
import 'package:vault/agent/chat_input_keys.dart';
import 'package:vault/agent/workspace_mode.dart';
import 'package:vault/sandbox/guest_media_kind.dart';
import 'package:vault/sandbox/sandbox_provider.dart';
import 'package:vault/screens/agent/widgets/agent_chat_widgets.dart';
import 'package:vault/screens/agent/widgets/agent_composer.dart';
import 'package:vault/widgets/ask_user_panel.dart';
import 'package:vault/widgets/chat_attachment_preview.dart';
import 'package:vault/widgets/glass.dart';

class AgentChatPane extends StatelessWidget {
  const AgentChatPane({
    super.key,
    required this.status,
    required this.hasProject,
    required this.mode,
    required this.items,
    required this.running,
    required this.provider,
    required this.workspaceId,
    required this.scrollController,
    required this.pendingAttachments,
    required this.pendingAskUser,
    required this.inputController,
    required this.inputFocus,
    required this.profileSwitcher,
    required this.dropEnabled,
    required this.dragging,
    required this.onCreateProject,
    required this.onPrompt,
    required this.onCopy,
    required this.onEdit,
    required this.onReselectAskUser,
    required this.branchSwitcherBuilder,
    required this.onRemoveAttachment,
    required this.onAskUserSubmit,
    required this.onAttach,
    required this.onPaste,
    required this.onSend,
    required this.onCancel,
    required this.onDragEntered,
    required this.onDragExited,
    required this.onDropDone,
  });

  final String? status;
  final bool hasProject;
  final WorkspaceMode mode;
  final List<AgentChatItem> items;
  final bool running;
  final SandboxProvider provider;
  final String workspaceId;
  final ScrollController scrollController;
  final List<AgentAttachment> pendingAttachments;
  final AskUserSession? pendingAskUser;
  final TextEditingController inputController;
  final FocusNode inputFocus;
  final Widget profileSwitcher;
  final bool dropEnabled;
  final bool dragging;
  final VoidCallback onCreateProject;
  final ValueChanged<String> onPrompt;
  final ValueChanged<AgentChatItem> onCopy;
  final ValueChanged<AgentChatItem> onEdit;
  final ValueChanged<AgentChatItem> onReselectAskUser;
  final Widget? Function(int? historyIndex) branchSwitcherBuilder;
  final ValueChanged<int> onRemoveAttachment;
  final ValueChanged<List<AskUserAnswer>> onAskUserSubmit;
  final VoidCallback onAttach;
  final VoidCallback onPaste;
  final VoidCallback onSend;
  final VoidCallback onCancel;
  final VoidCallback onDragEntered;
  final VoidCallback onDragExited;
  final ValueChanged<DropDoneDetails> onDropDone;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DropTarget(
      enable: dropEnabled,
      onDragEntered: (_) => onDragEntered(),
      onDragExited: (_) => onDragExited(),
      onDragDone: onDropDone,
      child: Stack(
        children: [
          Column(
            children: [
              if (status != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                  child: GlassPanel(
                    borderRadius: 16,
                    tone: GlassTone.regular,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 10,
                    ),
                    child: SizedBox(
                      width: double.infinity,
                      child: Text(status!),
                    ),
                  ),
                ),
              Expanded(child: _buildTranscript()),
              if (pendingAttachments.isNotEmpty)
                _AttachmentStrip(
                  attachments: pendingAttachments,
                  running: running,
                  onRemove: onRemoveAttachment,
                ),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
                  child: Align(
                    alignment: Alignment.center,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 840),
                      child: Column(
                        children: [
                          if (pendingAskUser != null) ...[
                            AskUserPanel(
                              questionnaire: pendingAskUser!.questionnaire,
                              onSubmit: onAskUserSubmit,
                            ),
                            const SizedBox(height: 8),
                          ],
                          AgentComposer(
                            controller: inputController,
                            focusNode: inputFocus,
                            running: running,
                            onAttach: onAttach,
                            onPaste: onPaste,
                            onSend: onSend,
                            onCancel: onCancel,
                            profileSwitcher: profileSwitcher,
                          ),
                          const SizedBox(height: 6),
                          Text(
                            desktopEnterHint(defaultTargetPlatform)
                                ? '回车发送 · Shift+回车换行。重要操作执行前会请求确认。'
                                : '重要操作执行前会请求确认。',
                            style: Theme.of(context).textTheme.labelSmall
                                ?.copyWith(color: scheme.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          if (dragging) const _DragOverlay(),
        ],
      ),
    );
  }

  Widget _buildTranscript() {
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 840),
        child: !hasProject
            ? AgentEmptyProject(onCreate: onCreateProject)
            : items.isEmpty
            ? AgentEmptyChat(mode: mode, onPrompt: onPrompt)
            : ListView.builder(
                controller: scrollController,
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                itemCount: items.length,
                itemBuilder: (context, index) {
                  final item = items[index];
                  return KeyedSubtree(
                    key: agentChatItemKey(item, index),
                    child: AgentChatBubble(
                      item: item,
                      running: running,
                      provider: provider,
                      workspaceId: workspaceId,
                      onCopy:
                          item.kind == AgentChatKind.user ||
                              item.kind == AgentChatKind.assistant
                          ? () => onCopy(item)
                          : null,
                      onEdit:
                          item.kind == AgentChatKind.user &&
                              item.historyIndex != null
                          ? () => onEdit(item)
                          : null,
                      onReselectAskUser:
                          item.kind == AgentChatKind.tool &&
                              item.toolName == kAskUserToolName
                          ? () => onReselectAskUser(item)
                          : null,
                      branchSwitcher: branchSwitcherBuilder(item.historyIndex),
                    ),
                  );
                },
              ),
      ),
    );
  }
}

class _AttachmentStrip extends StatelessWidget {
  const _AttachmentStrip({
    required this.attachments,
    required this.running,
    required this.onRemove,
  });

  final List<AgentAttachment> attachments;
  final bool running;
  final ValueChanged<int> onRemove;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 104,
      child: Align(
        alignment: Alignment.center,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 840),
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            itemCount: attachments.length,
            separatorBuilder: (_, _) => const SizedBox(width: 10),
            itemBuilder: (context, index) {
              final attachment = attachments[index];
              return ChatAttachmentTile(
                displayName: attachment.displayName,
                kind: guestMediaKindForPath(attachment.displayName),
                bytes: attachment.bytes,
                hostPath: attachment.hostPath,
                onRemove: running ? null : () => onRemove(index),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _DragOverlay extends StatelessWidget {
  const _DragOverlay();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Positioned.fill(
      child: IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: scheme.primary.withValues(alpha: 0.12),
            border: Border.all(color: scheme.primary, width: 2),
          ),
          child: Center(
            child: Material(
              color: scheme.surface,
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 14,
                ),
                child: Text(
                  '释放以添加到待发送附件',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
