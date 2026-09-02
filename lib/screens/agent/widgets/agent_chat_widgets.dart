import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:vault/agent/agent_chat_model.dart';
import 'package:vault/agent/ask_user.dart';
import 'package:vault/agent/chat_attachment.dart';
import 'package:vault/agent/present_file.dart';
import 'package:vault/agent/sub_agent_display.dart';
import 'package:vault/agent/workspace_mode.dart';
import 'package:vault/sandbox/guest_fs_ops.dart';
import 'package:vault/sandbox/guest_media_kind.dart';
import 'package:vault/sandbox/sandbox_provider.dart';
import 'package:vault/screens/file_browser/file_preview_screen.dart';
import 'package:vault/util/guest_export.dart';
import 'package:vault/widgets/ask_user_panel.dart';
import 'package:vault/widgets/ask_user_transcript.dart';
import 'package:vault/widgets/chat_attachment_preview.dart';
import 'package:vault/widgets/glass.dart';

class AgentEmptyProject extends StatelessWidget {
  const AgentEmptyProject({super.key, required this.onCreate});

  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircleAvatar(
              radius: 36,
              backgroundColor: scheme.primaryContainer,
              foregroundColor: scheme.onPrimaryContainer,
              child: const Icon(Icons.create_new_folder_outlined, size: 36),
            ),
            const SizedBox(height: 16),
            Text(
              '先新建一个项目',
              style: Theme.of(context).textTheme.headlineSmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              '项目对应 Linux 里的时间戳目录；之后的多轮对话都会保存在该项目下。',
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.bodyLarge?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: onCreate,
              icon: const Icon(Icons.add),
              label: const Text('新建项目'),
            ),
          ],
        ),
      ),
    );
  }
}

class AgentEmptyChat extends StatelessWidget {
  const AgentEmptyChat({
    super.key,
    required this.onPrompt,
    this.mode = WorkspaceMode.chat,
  });

  final ValueChanged<String> onPrompt;
  final WorkspaceMode mode;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final prompts = mode == WorkspaceMode.dev
        ? <(String, String, IconData)>[
            ('帮我做个记事页，打开就能写、刷新还在', '帮我做个记事页', Icons.edit_note_outlined),
            (
              '把下载的文件自动分类，做成一个能在浏览器里看的网页',
              '把下载的文件自动分类做成网页',
              Icons.folder_special_outlined,
            ),
            ('先做一个能用的最小版本，我打开网页就能试', '先做一个能用的最小版本', Icons.web_outlined),
            ('做个待办清单网页，勾选之后刷新还在', '做个待办清单网页', Icons.checklist_outlined),
          ]
        : <(String, String, IconData)>[
            ('帮我分析这份表格，找出最重要的三个趋势', '分析表格', Icons.table_chart_outlined),
            ('帮我整理一批文件，先给我一个不会误删文件的方案', '整理文件', Icons.folder_outlined),
            ('检查这个项目是否有明显问题，并用容易理解的方式告诉我', '检查项目', Icons.fact_check_outlined),
            ('教我完成一个简单目标，每次只告诉我下一步', '一步步教我', Icons.school_outlined),
          ];
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 32, 16, 24),
      children: [
        Center(
          child: CircleAvatar(
            radius: 36,
            backgroundColor: scheme.primaryContainer,
            foregroundColor: scheme.onPrimaryContainer,
            child: const Icon(Icons.smart_toy_outlined, size: 36),
          ),
        ),
        const SizedBox(height: 16),
        Text(
          '今天想完成什么？',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 8),
        Text(
          '直接说出目标，也可以从下面选一个例子开始。',
          textAlign: TextAlign.center,
          style: Theme.of(
            context,
          ).textTheme.bodyLarge?.copyWith(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 24),
        LayoutBuilder(
          builder: (context, constraints) {
            final twoColumns = constraints.maxWidth >= 640;
            return GridView.count(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              crossAxisCount: twoColumns ? 2 : 1,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: twoColumns ? 2.8 : 3.6,
              children: [
                for (final (index, prompt) in prompts.indexed)
                  FadeSlideIn(
                    index: index,
                    child: PressableScale(
                      onTap: () => onPrompt(prompt.$1),
                      child: GlassPanel(
                        borderRadius: 18,
                        tone: GlassTone.regular,
                        padding: const EdgeInsets.all(16),
                        child: Row(
                          children: [
                            CircleAvatar(
                              backgroundColor: scheme.primaryContainer
                                  .withValues(alpha: 0.85),
                              foregroundColor: scheme.onPrimaryContainer,
                              child: Icon(prompt.$3),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                prompt.$2,
                                style: Theme.of(context).textTheme.titleMedium
                                    ?.copyWith(fontWeight: FontWeight.w600),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}

Key agentChatItemKey(AgentChatItem item, int index) {
  if (item.thinkingPlaceholder) return const ValueKey('thinking-placeholder');
  final callId = item.toolCallId;
  if (item.kind == AgentChatKind.tool && callId != null && callId.isNotEmpty) {
    return ValueKey('tool-$callId');
  }
  return ValueKey('chat-$index-${item.kind.name}');
}

class SubAgentBackgroundCapsule extends StatelessWidget {
  const SubAgentBackgroundCapsule({super.key, required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Chip(
      label: Text(subAgentBackgroundCapsuleLabel(count)),
      avatar: Icon(
        Icons.hourglass_top_rounded,
        size: 16,
        color: scheme.primary,
      ),
      visualDensity: VisualDensity.compact,
      side: BorderSide.none,
      backgroundColor: scheme.primaryContainer.withValues(alpha: 0.75),
      labelStyle: TextStyle(color: scheme.onPrimaryContainer),
    );
  }
}

class AgentChatBubble extends StatelessWidget {
  const AgentChatBubble({
    super.key,
    required this.item,
    this.running = false,
    this.provider,
    this.workspaceId,
    this.interactiveAskUser = false,
    this.pendingAskUser,
    this.onAskUserSubmit,
    this.onCopy,
    this.onEdit,
    this.onReselectAskUser,
    this.branchSwitcher,
  });

  final AgentChatItem item;
  final bool running;
  final SandboxProvider? provider;
  final String? workspaceId;
  final bool interactiveAskUser;
  final AskUserSession? pendingAskUser;
  final ValueChanged<List<AskUserAnswer>>? onAskUserSubmit;
  final VoidCallback? onCopy;
  final VoidCallback? onEdit;
  final VoidCallback? onReselectAskUser;
  final Widget? branchSwitcher;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (item.thinkingPlaceholder) {
      return AgentThinkingRow(label: item.text);
    }
    if (item.kind == AgentChatKind.assistant && item.text.trim().isEmpty) {
      return const SizedBox.shrink();
    }
    if (item.kind == AgentChatKind.status || item.kind == AgentChatKind.error) {
      return _SystemNotice(
        text: item.text,
        isError: item.kind == AgentChatKind.error,
      );
    }
    if (item.kind == AgentChatKind.tool && item.toolName == kAskUserToolName) {
      final session = pendingAskUser;
      final submit = onAskUserSubmit;
      if (interactiveAskUser && session != null && submit != null) {
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AskUserPanel(
                key: ObjectKey(session),
                questionnaire: session.questionnaire,
                onSubmit: submit,
              ),
              if (branchSwitcher != null) branchSwitcher!,
            ],
          ),
        );
      }
      return AskUserTranscript(
        arguments: item.toolArguments ?? '',
        result: item.toolResult,
        onReselect: running ? null : onReselectAskUser,
        branchSwitcher: branchSwitcher,
      );
    }
    if (item.kind == AgentChatKind.tool &&
        item.toolName == kPresentFileToolName) {
      final presented = item.attachments.isNotEmpty
          ? item.attachments.first
          : presentFileAttachmentFromResult(resultText: item.toolResult);
      if (presented != null) {
        return PresentedFileCard(
          attachment: presented,
          provider: provider,
          workspaceId: workspaceId,
        );
      }
    }
    if (item.kind == AgentChatKind.tool) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Align(
          alignment: Alignment.centerLeft,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.sizeOf(context).width * 0.92,
            ),
            child: AgentToolCallCard(item: item),
          ),
        ),
      );
    }

    final (tint, foreground, alignment, solid) = switch (item.kind) {
      AgentChatKind.user => (
        scheme.primary,
        scheme.onPrimary,
        CrossAxisAlignment.end,
        true,
      ),
      AgentChatKind.assistant => (
        scheme.surface,
        scheme.onSurface,
        CrossAxisAlignment.start,
        false,
      ),
      AgentChatKind.status => (
        scheme.surfaceContainerHighest,
        scheme.onSurface,
        CrossAxisAlignment.start,
        false,
      ),
      AgentChatKind.error => (
        scheme.errorContainer,
        scheme.onErrorContainer,
        CrossAxisAlignment.start,
        true,
      ),
      AgentChatKind.tool => (
        scheme.surface,
        scheme.onSurface,
        CrossAxisAlignment.start,
        false,
      ),
    };
    final showText =
        item.text.trim().isNotEmpty &&
        !(item.attachments.isNotEmpty && item.text.trim() == '（仅附件）');
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (item.attachments.isNotEmpty)
          Padding(
            padding: EdgeInsets.only(bottom: showText ? 8 : 0),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final attachment in item.attachments)
                  ChatAttachmentTile(
                    displayName: attachment.displayName,
                    kind: attachment.kind,
                    guestPath: attachment.guestPath,
                    provider: provider,
                    workspaceId: workspaceId,
                    size: 88,
                  ),
              ],
            ),
          ),
        if (showText) _ChatMarkdown(data: item.text, color: foreground),
      ],
    );
    final bubble = solid
        ? DecoratedBox(
            decoration: BoxDecoration(
              color: tint.withValues(alpha: 0.92),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.white.withValues(alpha: 0.22)),
              boxShadow: [
                BoxShadow(
                  color: tint.withValues(alpha: 0.28),
                  blurRadius: 18,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Padding(padding: const EdgeInsets.all(14), child: body),
          )
        : GlassPanel(
            borderRadius: 20,
            tone: GlassTone.regular,
            tint: tint,
            padding: const EdgeInsets.all(14),
            child: body,
          );
    final meta = _ChatBubbleMeta(item: item);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: alignment,
        children: [
          ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.sizeOf(context).width * 0.88,
            ),
            child: bubble,
          ),
          Padding(
            padding: const EdgeInsets.only(top: 2, left: 2, right: 2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (meta.hasContent) meta,
                if (onCopy != null)
                  IconButton(
                    tooltip: '复制',
                    onPressed: onCopy,
                    icon: const Icon(Icons.copy_outlined, size: 16),
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints(
                      minWidth: 28,
                      minHeight: 28,
                    ),
                  ),
                if (onEdit != null && !running)
                  IconButton(
                    tooltip: '修改',
                    onPressed: onEdit,
                    icon: const Icon(Icons.edit_outlined, size: 16),
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints(
                      minWidth: 28,
                      minHeight: 28,
                    ),
                  ),
              ],
            ),
          ),
          ?branchSwitcher,
        ],
      ),
    );
  }
}

class _SystemNotice extends StatelessWidget {
  const _SystemNotice({required this.text, required this.isError});

  final String text;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 8),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: isError
              ? scheme.error.withValues(alpha: 0.68)
              : scheme.onSurfaceVariant.withValues(alpha: 0.62),
          height: 1.35,
        ),
      ),
    );
  }
}

class _ChatBubbleMeta extends StatelessWidget {
  const _ChatBubbleMeta({required this.item});

  static const _inputColor = Color(0xFF2A9D8F);
  static const _outputColor = Color(0xFFE07A3D);
  final AgentChatItem item;

  bool get hasContent {
    if (item.thinkingPlaceholder) return false;
    if (item.kind != AgentChatKind.user &&
        item.kind != AgentChatKind.assistant) {
      return false;
    }
    return (item.promptTokens ?? 0) > 0 ||
        (item.kind == AgentChatKind.assistant &&
            (item.completionTokens ?? 0) > 0) ||
        item.at != null;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final style = Theme.of(context).textTheme.labelSmall?.copyWith(
      color: scheme.onSurfaceVariant.withValues(alpha: 0.75),
      height: 1.1,
    );
    final children = <Widget>[];
    void separator() {
      if (children.isNotEmpty) children.add(Text(' · ', style: style));
    }

    if ((item.promptTokens ?? 0) > 0) {
      children.add(
        _TokenLabel(
          icon: Icons.arrow_upward_rounded,
          color: _inputColor,
          label: _formatTokenCount(item.promptTokens!),
          style: style,
        ),
      );
    }
    if (item.kind == AgentChatKind.assistant &&
        (item.completionTokens ?? 0) > 0) {
      separator();
      children.add(
        _TokenLabel(
          icon: Icons.arrow_downward_rounded,
          color: _outputColor,
          label: _formatTokenCount(item.completionTokens!),
          style: style,
        ),
      );
    }
    if (item.at != null) {
      separator();
      children.add(Text(_formatClockTime(item.at!), style: style));
    }
    return Row(mainAxisSize: MainAxisSize.min, children: children);
  }
}

class _TokenLabel extends StatelessWidget {
  const _TokenLabel({
    required this.icon,
    required this.color,
    required this.label,
    required this.style,
  });

  final IconData icon;
  final Color color;
  final String label;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 12, color: color),
        const SizedBox(width: 2),
        Text(
          label,
          style: style?.copyWith(color: color, fontWeight: FontWeight.w600),
        ),
      ],
    );
  }
}

class _ChatMarkdown extends StatelessWidget {
  const _ChatMarkdown({required this.data, required this.color});

  final String data;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base = theme.textTheme;
    final codeBackground = color.withValues(alpha: 0.14);
    return MarkdownBody(
      data: data,
      selectable: true,
      softLineBreak: true,
      styleSheet: MarkdownStyleSheet.fromTheme(theme).copyWith(
        p: base.bodyMedium?.copyWith(color: color, height: 1.35),
        h1: base.titleLarge?.copyWith(color: color),
        h2: base.titleMedium?.copyWith(color: color),
        h3: base.titleSmall?.copyWith(color: color),
        strong: base.bodyMedium?.copyWith(
          color: color,
          fontWeight: FontWeight.w700,
        ),
        em: base.bodyMedium?.copyWith(
          color: color,
          fontStyle: FontStyle.italic,
        ),
        a: base.bodyMedium?.copyWith(
          color: color,
          decoration: TextDecoration.underline,
        ),
        listBullet: base.bodyMedium?.copyWith(color: color),
        code: base.bodySmall?.copyWith(
          color: color,
          fontFamily: 'monospace',
          backgroundColor: codeBackground,
        ),
        codeblockDecoration: BoxDecoration(
          color: codeBackground,
          borderRadius: BorderRadius.circular(8),
        ),
        codeblockPadding: const EdgeInsets.all(10),
        blockquote: base.bodyMedium?.copyWith(
          color: color.withValues(alpha: 0.85),
        ),
        blockquoteDecoration: BoxDecoration(
          border: Border(
            left: BorderSide(color: color.withValues(alpha: 0.35), width: 3),
          ),
        ),
      ),
    );
  }
}

class AgentToolCallCard extends StatefulWidget {
  const AgentToolCallCard({super.key, required this.item});

  final AgentChatItem item;

  @override
  State<AgentToolCallCard> createState() => _AgentToolCallCardState();
}

class _AgentToolCallCardState extends State<AgentToolCallCard> {
  bool _expanded = false;
  final _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final command = _toolCommand(
      widget.item.toolName ?? widget.item.text,
      widget.item.toolArguments,
    );
    final result = widget.item.toolResult;
    final backgrounded = widget.item.toolBackgrounded;
    final done = result != null && !backgrounded;
    final summary = _toolSummary(
      toolName: widget.item.toolName ?? widget.item.text,
      command: command,
      done: done,
      backgrounded: backgrounded,
    );
    final output = result != null && !backgrounded
        ? _formatToolResult(result)
        : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
            child: Row(
              children: [
                Icon(
                  _expanded
                      ? Icons.keyboard_arrow_down
                      : Icons.keyboard_arrow_right,
                  size: 18,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 4),
                if (!done) ...[
                  if (backgrounded)
                    Icon(
                      Icons.hourglass_top_rounded,
                      size: 14,
                      color: scheme.tertiary,
                    )
                  else
                    SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.5,
                        color: scheme.primary,
                      ),
                    ),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: Text(
                    summary,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: backgrounded
                          ? scheme.tertiary
                          : scheme.onSurfaceVariant,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (_expanded)
          Container(
            margin: const EdgeInsets.only(left: 8, top: 2),
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest.withValues(alpha: 0.72),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: scheme.outlineVariant.withValues(alpha: 0.45),
              ),
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 220),
              child: Scrollbar(
                controller: _scrollController,
                child: SingleChildScrollView(
                  controller: _scrollController,
                  primary: false,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SelectableText(
                        command,
                        style: TextStyle(
                          color: scheme.onSurface,
                          fontFamily: 'monospace',
                          fontSize: 12.5,
                          height: 1.4,
                        ),
                      ),
                      if (output != null && output.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        SelectableText(
                          output,
                          style: TextStyle(
                            color: scheme.onSurfaceVariant,
                            fontFamily: 'monospace',
                            fontSize: 12,
                            height: 1.4,
                          ),
                        ),
                      ] else if (!done)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            '执行中…',
                            style: TextStyle(
                              color: scheme.onSurfaceVariant,
                              fontFamily: 'monospace',
                              fontSize: 12,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class AgentThinkingRow extends StatelessWidget {
  const AgentThinkingRow({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
      child: Row(
        children: [
          Icon(
            Icons.keyboard_arrow_right,
            size: 18,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(width: 4),
          SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(
              strokeWidth: 1.5,
              color: scheme.primary,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
                fontStyle: FontStyle.italic,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class AgentEditUserMessageDialog extends StatefulWidget {
  const AgentEditUserMessageDialog({super.key, required this.initialText});

  final String initialText;

  @override
  State<AgentEditUserMessageDialog> createState() =>
      _AgentEditUserMessageDialogState();
}

class _AgentEditUserMessageDialogState
    extends State<AgentEditUserMessageDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialText);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('修改这条消息'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        minLines: 3,
        maxLines: 8,
        decoration: const InputDecoration(
          hintText: '输入新的内容',
          border: OutlineInputBorder(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _controller.text),
          child: const Text('用新内容继续'),
        ),
      ],
    );
  }
}

String _formatTokenCount(int count) {
  if (count >= 10000) return '${(count / 1000).round()}k';
  if (count >= 1000) {
    final value = count / 1000;
    final formatted = value.toStringAsFixed(1);
    return formatted.endsWith('.0') ? '${value.round()}k' : '${formatted}k';
  }
  return '$count';
}

String _formatClockTime(DateTime at) {
  final local = at.toLocal();
  final hours = local.hour.toString().padLeft(2, '0');
  final minutes = local.minute.toString().padLeft(2, '0');
  final seconds = local.second.toString().padLeft(2, '0');
  return '$hours:$minutes:$seconds';
}

String _toolCommand(String name, String? arguments) {
  final raw = arguments?.trim() ?? '';
  if (raw.isEmpty) return name;
  try {
    final decoded = jsonDecode(raw);
    if (decoded is Map) {
      final command = decoded['command'];
      if (command is String && command.trim().isNotEmpty) {
        return command.trim();
      }
    }
  } catch (_) {
    final partial = _partialJsonStringField(raw, 'command');
    if (partial != null && partial.isNotEmpty) return partial;
    if (name.isNotEmpty && (raw.startsWith('{') || raw.startsWith('['))) {
      return name;
    }
  }
  return raw;
}

String? _partialJsonStringField(String raw, String key) {
  final match = RegExp('"$key"\\s*:\\s*"((?:[^"\\\\]|\\\\.)*)').firstMatch(raw);
  final value = match?.group(1);
  if (value == null || value.isEmpty) return null;
  return value.replaceAll(r'\"', '"').replaceAll(r'\\', r'\');
}

String _toolSummary({
  required String toolName,
  required String command,
  required bool done,
  required bool backgrounded,
}) {
  if (isSubAgentTool(toolName)) return kStartSubAgentSummary;
  final firstLine = command.split(RegExp(r'\r?\n')).first.trim();
  final preview = firstLine.length > 72
      ? '${firstLine.substring(0, 72)}…'
      : firstLine;
  if (backgrounded) {
    return preview.isEmpty ? '后台执行中 $toolName' : '后台执行中 $preview';
  }
  if (!done) {
    if (preview.isEmpty && toolName.isEmpty) return '正在调用工具…';
    return preview.isEmpty ? 'Running $toolName…' : 'Running $preview';
  }
  return preview.isEmpty ? 'Ran $toolName' : 'Ran $preview';
}

String _formatToolResult(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return '';
  try {
    final decoded = jsonDecode(trimmed);
    if (decoded is Map) {
      final stdout = (decoded['stdout'] as String?) ?? '';
      final stderr = (decoded['stderr'] as String?) ?? '';
      final error = decoded['error']?.toString();
      final buffer = StringBuffer();
      if (stdout.isNotEmpty) buffer.write(stdout);
      if (stderr.isNotEmpty) {
        if (buffer.isNotEmpty && !buffer.toString().endsWith('\n')) {
          buffer.writeln();
        }
        buffer.write(stderr);
      }
      if (buffer.isNotEmpty) return buffer.toString();
      if (error != null && error.isNotEmpty) return error;
      final exitCode = decoded['exitCode'];
      if (exitCode != null) return 'exit $exitCode';
    }
  } catch (_) {}
  return raw;
}

/// Card for a successful [present_file] tool result (preview / download).
class PresentedFileCard extends StatelessWidget {
  const PresentedFileCard({
    super.key,
    required this.attachment,
    this.provider,
    this.workspaceId,
  });

  final ChatAttachmentMeta attachment;
  final SandboxProvider? provider;
  final String? workspaceId;

  bool get _isMedia =>
      attachment.kind == GuestMediaKind.image ||
      attachment.kind == GuestMediaKind.video ||
      attachment.kind == GuestMediaKind.audio;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Align(
        alignment: Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.sizeOf(context).width * 0.92,
          ),
          child: GlassPanel(
            borderRadius: 16,
            tone: GlassTone.regular,
            tint: scheme.surface,
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Icon(
                      _iconForKind(attachment.kind),
                      size: 22,
                      color: scheme.primary,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        attachment.displayName,
                        style: Theme.of(context).textTheme.titleSmall,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                if (_isMedia && provider != null && workspaceId != null) ...[
                  const SizedBox(height: 10),
                  ChatAttachmentTile(
                    displayName: attachment.displayName,
                    kind: attachment.kind,
                    guestPath: attachment.guestPath,
                    provider: provider,
                    workspaceId: workspaceId,
                    size: 88,
                  ),
                ],
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    FilledButton.tonalIcon(
                      onPressed: () => unawaited(_preview(context)),
                      icon: const Icon(Icons.visibility_outlined, size: 18),
                      label: const Text('预览'),
                    ),
                    FilledButton.tonalIcon(
                      onPressed: () =>
                          unawaited(_export(context, GuestExportMode.saveAs)),
                      icon: const Icon(Icons.download_outlined, size: 18),
                      label: const Text('下载'),
                    ),
                    TextButton.icon(
                      onPressed: () =>
                          unawaited(_export(context, GuestExportMode.share)),
                      icon: const Icon(Icons.share_outlined, size: 18),
                      label: const Text('分享'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<bool> _ensureGuestFile(BuildContext context) async {
    final sandbox = provider;
    final id = workspaceId;
    if (sandbox == null || id == null) {
      _snack(context, '无法访问沙箱');
      return false;
    }
    try {
      final exists = await guestPathExists(sandbox, id, attachment.guestPath);
      if (!exists) {
        if (context.mounted) _snack(context, '文件已不在沙箱');
        return false;
      }
      return true;
    } catch (_) {
      if (context.mounted) _snack(context, '文件已不在沙箱');
      return false;
    }
  }

  Future<void> _preview(BuildContext context) async {
    if (!await _ensureGuestFile(context) || !context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => FilePreviewScreen(
          provider: provider!,
          workspaceId: workspaceId!,
          guestPath: attachment.guestPath,
        ),
      ),
    );
  }

  Future<void> _export(BuildContext context, GuestExportMode mode) async {
    if (!await _ensureGuestFile(context) || !context.mounted) return;
    try {
      final result = await GuestExport(
        provider: provider!,
        workspaceId: workspaceId!,
      ).run(mode: mode, guestPaths: [attachment.guestPath]);
      if (!context.mounted || result.cancelled) return;
      _snack(
        context,
        result.message ?? (mode == GuestExportMode.share ? '已分享' : '已导出'),
        error: result.failed > 0,
      );
    } catch (error) {
      if (!context.mounted) return;
      _snack(context, '导出失败：$error', error: true);
    }
  }

  void _snack(BuildContext context, String message, {bool error = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: error ? Theme.of(context).colorScheme.error : null,
      ),
    );
  }
}

IconData _iconForKind(GuestMediaKind kind) {
  return switch (kind) {
    GuestMediaKind.image => Icons.image_outlined,
    GuestMediaKind.video => Icons.videocam_outlined,
    GuestMediaKind.audio => Icons.audiotrack_outlined,
    GuestMediaKind.text => Icons.description_outlined,
    GuestMediaKind.binary => Icons.insert_drive_file_outlined,
  };
}
