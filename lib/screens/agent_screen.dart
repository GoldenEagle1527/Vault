import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:vault/agent/agent_inbox.dart';
import 'package:vault/agent/agent_service.dart';
import 'package:vault/agent/agent_settings.dart';
import 'package:vault/agent/conversation_store.dart';
import 'package:vault/sandbox/sandbox_models.dart';
import 'package:vault/screens/settings_screen.dart';
import 'package:vault/screens/terminal_screen.dart';
import 'package:vault/widgets/glass.dart';

class AgentScreen extends StatefulWidget {
  const AgentScreen({
    super.key,
    required this.workspace,
    required this.title,
    required this.conversationStore,
    this.settingsStore,
  });

  final SandboxWorkspace workspace;
  final String title;
  final ConversationStore conversationStore;
  final AgentSettingsStore? settingsStore;

  @override
  State<AgentScreen> createState() => _AgentScreenState();
}

class _ChatItem {
  _ChatItem({required this.kind, required this.text, this.subtitle});

  final _ChatKind kind;
  String text;
  final String? subtitle;
}

enum _ChatKind { user, assistant, tool, status, error }

class _AgentScreenState extends State<AgentScreen> {
  late final AgentSettingsStore _settingsStore;
  late final ConversationStore _conversationStore;
  final _inputCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  final List<_ChatItem> _items = [];
  final List<AgentAttachment> _pendingAttachments = [];
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  AgentService? _service;
  List<ConversationInfo> _conversations = const [];
  String? _activeConversationId;
  String _conversationTitle = kNewConversationTitle;
  bool _running = false;
  String? _status;
  bool _booting = true;

  @override
  void initState() {
    super.initState();
    _settingsStore = widget.settingsStore ?? AgentSettingsStore();
    _conversationStore = widget.conversationStore;
    _boot();
  }

  Future<void> _boot() async {
    try {
      final settings = await _settingsStore.load();
      if (!mounted) return;
      final service = await AgentService.open(
        workspace: widget.workspace,
        settings: settings,
        conversationStore: _conversationStore,
      );
      _service = service;
      await _refreshConversationList();
      _hydrateFromService();
      if (!settings.isConfigured) {
        _items.add(
          _ChatItem(
            kind: _ChatKind.status,
            text: '尚未配置 API。请先打开设置填写 Key 与模型。',
          ),
        );
      }
    } catch (e) {
      _items.add(_ChatItem(kind: _ChatKind.error, text: '初始化失败：$e'));
    } finally {
      if (mounted) {
        setState(() => _booting = false);
        _scrollToEnd();
      }
    }
  }

  Future<void> _refreshConversationList() async {
    final index = await _conversationStore.list(widget.workspace.workspaceId);
    _conversations = index.conversations;
    _activeConversationId =
        _service?.conversationId ?? index.activeConversationId;
    _conversationTitle = _service?.conversationTitle ?? kNewConversationTitle;
  }

  void _hydrateFromService() {
    _items.clear();
    final service = _service;
    if (service == null) return;
    for (final event in service.restoredUiEvents) {
      _applyRestoredEvent(event);
    }
    _conversationTitle = service.conversationTitle;
    _activeConversationId = service.conversationId;
  }

  void _applyRestoredEvent(AgentUiEvent event) {
    switch (event) {
      case AgentUiUserMessage(:final text):
        _items.add(_ChatItem(kind: _ChatKind.user, text: text));
      case AgentUiAssistantFinal(:final text):
        _items.add(_ChatItem(kind: _ChatKind.assistant, text: text));
      case AgentUiAssistantDelta(:final text):
        _items.add(_ChatItem(kind: _ChatKind.assistant, text: text));
      case AgentUiToolCall(:final name, :final arguments):
        _items.add(
          _ChatItem(
            kind: _ChatKind.tool,
            text: '调用 $name',
            subtitle: arguments,
          ),
        );
      case AgentUiToolResult(:final name, :final result):
        _items.add(
          _ChatItem(kind: _ChatKind.tool, text: '结果 $name', subtitle: result),
        );
      case AgentUiError(:final message):
        _items.add(_ChatItem(kind: _ChatKind.error, text: message));
      case AgentUiStatus():
      case AgentUiDiscardDraftAssistant():
        break;
    }
  }

  Future<void> _reloadService() async {
    final settings = await _settingsStore.load();
    final existing = _service;
    if (existing == null) {
      _service = await AgentService.open(
        workspace: widget.workspace,
        settings: settings,
        conversationStore: _conversationStore,
      );
      _hydrateFromService();
    } else {
      existing.applySettings(settings);
    }
  }

  Future<void> _openSettings() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => SettingsScreen(store: _settingsStore)),
    );
    if (!mounted) return;
    await _reloadService();
    setState(() {});
  }

  Future<void> _openTerminal() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TerminalScreen(
          title: widget.title,
          workspace: widget.workspace,
          disposeWorkspace: false,
        ),
      ),
    );
  }

  Future<void> _pickFiles() async {
    if (_running) return;
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      withData: false,
    );
    if (result == null || !mounted) return;
    setState(() {
      for (final f in result.files) {
        final path = f.path;
        if (path == null || path.isEmpty) continue;
        _pendingAttachments.add(
          AgentAttachment(hostPath: path, displayName: f.name),
        );
      }
    });
  }

  Future<bool> _confirmLeaveRunning() async {
    if (!_running) return true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('切换会话？'),
        content: const Text('当前会话仍在运行，切换将取消正在进行的任务。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('切换并取消'),
          ),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _newConversation() async {
    if (!await _confirmLeaveRunning()) return;
    final service = _service;
    if (service == null) return;
    setState(() {
      _status = '正在新建会话…';
    });
    try {
      await service.newConversation();
      await _refreshConversationList();
      _hydrateFromService();
      _pendingAttachments.clear();
    } catch (e) {
      if (!mounted) return;
      _items.add(_ChatItem(kind: _ChatKind.error, text: '新建会话失败：$e'));
    } finally {
      if (mounted) {
        setState(() => _status = null);
        _scrollToEnd();
      }
    }
  }

  Future<void> _switchConversation(String id) async {
    if (id == _activeConversationId) {
      Navigator.of(context).maybePop();
      return;
    }
    if (!await _confirmLeaveRunning()) return;
    if (!mounted) return;
    final service = _service;
    if (service == null) return;
    Navigator.of(context).maybePop();
    setState(() => _status = '正在切换会话…');
    try {
      await service.switchConversation(id);
      await _refreshConversationList();
      _hydrateFromService();
      _pendingAttachments.clear();
    } catch (e) {
      if (!mounted) return;
      _items.add(_ChatItem(kind: _ChatKind.error, text: '切换会话失败：$e'));
    } finally {
      if (mounted) {
        setState(() {
          _running = false;
          _status = null;
        });
        _scrollToEnd();
      }
    }
  }

  Future<void> _deleteConversation(String id) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除会话？'),
        content: const Text('将删除该会话的对话历史。工作区 Linux 文件不会因此删除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    final service = _service;
    if (service == null) return;

    if (_running && id == _activeConversationId) {
      service.cancel();
    }

    try {
      final deletingActive = id == _activeConversationId;
      final next = await _conversationStore.deleteConversation(
        widget.workspace.workspaceId,
        id,
      );
      final active = next.activeConversationId;
      if (active != null) {
        // Never persist the deleted conversation back to disk.
        await service.switchConversation(
          active,
          persistCurrent: !deletingActive,
        );
      } else {
        await service.newConversation(persistCurrent: false);
      }
      await _refreshConversationList();
      _hydrateFromService();
      if (mounted) setState(() {});
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _items.add(_ChatItem(kind: _ChatKind.error, text: '删除会话失败：$e'));
      });
    }
  }

  Future<void> _send() async {
    final text = _inputCtrl.text.trim();
    if ((text.isEmpty && _pendingAttachments.isEmpty) ||
        _running ||
        _service == null) {
      return;
    }

    final service = _service!;
    final attachments = List<AgentAttachment>.from(_pendingAttachments);
    _inputCtrl.clear();
    setState(() {
      _pendingAttachments.clear();
      _running = true;
      _status = '运行中…';
    });

    await for (final event in service.run(text, attachments: attachments)) {
      if (!mounted) return;
      switch (event) {
        case AgentUiUserMessage(:final text):
          _items.add(_ChatItem(kind: _ChatKind.user, text: text));
        case AgentUiAssistantDelta(:final text):
          if (_items.isNotEmpty &&
              _items.last.kind == _ChatKind.assistant &&
              _items.last.subtitle == null) {
            _items.last.text += text;
          } else {
            _items.add(_ChatItem(kind: _ChatKind.assistant, text: text));
          }
        case AgentUiAssistantFinal(:final text):
          if (_items.isNotEmpty &&
              _items.last.kind == _ChatKind.assistant &&
              _items.last.subtitle == null) {
            _items.last.text = text;
          } else {
            _items.add(_ChatItem(kind: _ChatKind.assistant, text: text));
          }
        case AgentUiDiscardDraftAssistant():
          _discardBlankAssistantDraft();
        case AgentUiToolCall(:final name, :final arguments):
          _discardBlankAssistantDraft();
          _items.add(
            _ChatItem(
              kind: _ChatKind.tool,
              text: '调用 $name',
              subtitle: arguments,
            ),
          );
        case AgentUiToolResult(:final name, :final result):
          _items.add(
            _ChatItem(kind: _ChatKind.tool, text: '结果 $name', subtitle: result),
          );
        case AgentUiError(:final message):
          _items.add(_ChatItem(kind: _ChatKind.error, text: message));
        case AgentUiStatus(:final message):
          _status = message;
      }
      _conversationTitle = service.conversationTitle;
      setState(() {});
      _scrollToEnd();
    }

    if (!mounted) return;
    await _refreshConversationList();
    setState(() {
      _running = false;
      _status = null;
    });
  }

  void _discardBlankAssistantDraft() {
    while (_items.isNotEmpty &&
        _items.last.kind == _ChatKind.assistant &&
        _items.last.text.trim().isEmpty) {
      _items.removeLast();
    }
  }

  void _cancel() {
    _service?.cancel();
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollCtrl.hasClients) return;
      _scrollCtrl.animateTo(
        _scrollCtrl.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  String _relativeTime(DateTime when) {
    final local = when.toLocal();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(local.year, local.month, local.day);
    final hm =
        '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
    if (day == today) return '今天 $hm';
    if (day == today.subtract(const Duration(days: 1))) return '昨天 $hm';
    return '${local.month} 月 ${local.day} 日 $hm';
  }

  @override
  void dispose() {
    unawaited(_service?.dispose() ?? Future.value());
    unawaited(widget.workspace.dispose());
    _inputCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final wide = MediaQuery.sizeOf(context).width >= 720;
    final hasChatContent = _items.any(
      (i) =>
          i.kind == _ChatKind.user ||
          i.kind == _ChatKind.assistant ||
          i.kind == _ChatKind.tool,
    );

    return AmbientBackdrop(
      child: Scaffold(
        key: _scaffoldKey,
        backgroundColor: Colors.transparent,
        endDrawer: Drawer(
          child: SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '会话历史',
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                            Text(
                              widget.title,
                              style: Theme.of(context).textTheme.labelMedium
                                  ?.copyWith(color: scheme.onSurfaceVariant),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: '关闭',
                        onPressed: () => Navigator.of(context).maybePop(),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                  child: FilledButton.tonalIcon(
                    onPressed: _booting ? null : _newConversation,
                    icon: const Icon(Icons.add),
                    label: const Text('新会话'),
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: _conversations.isEmpty
                      ? Center(
                          child: Text(
                            '暂无会话',
                            style: TextStyle(color: scheme.onSurfaceVariant),
                          ),
                        )
                      : ListView.builder(
                          itemCount: _conversations.length,
                          itemBuilder: (context, i) {
                            final c = _conversations[i];
                            final selected = c.id == _activeConversationId;
                            return ListTile(
                              selected: selected,
                              leading: Icon(
                                selected
                                    ? Icons.chat_bubble
                                    : Icons.chat_bubble_outline,
                              ),
                              title: Text(
                                c.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(
                                '${_relativeTime(c.updatedAt)}'
                                '${c.messageCount > 0 ? ' · ${c.messageCount} 条消息' : ''}',
                              ),
                              onTap: () => _switchConversation(c.id),
                              trailing: IconButton(
                                tooltip: '删除会话',
                                onPressed: () => _deleteConversation(c.id),
                                icon: const Icon(Icons.delete_outline),
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        ),
        appBar: AppBar(
          titleSpacing: 0,
          title: Row(
            children: [
              Tooltip(
                message: 'Linux 终端',
                child: InkWell(
                  onTap: _openTerminal,
                  customBorder: const CircleBorder(),
                  child: CircleAvatar(
                    radius: 18,
                    backgroundColor:
                        scheme.primaryContainer.withValues(alpha: 0.9),
                    foregroundColor: scheme.onPrimaryContainer,
                    child: const Icon(Icons.smart_toy_outlined, size: 20),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _conversationTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      '${widget.title} · 工作区',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          actions: [
            if (wide)
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Chip(
                  label: Text(_running ? '运行中' : '已连接'),
                  avatar: Icon(
                    _running ? Icons.sync : Icons.check_circle,
                    size: 16,
                    color: scheme.primary,
                  ),
                  visualDensity: VisualDensity.compact,
                  side: BorderSide.none,
                  backgroundColor: scheme.primaryContainer.withValues(
                    alpha: 0.75,
                  ),
                  labelStyle: TextStyle(color: scheme.onPrimaryContainer),
                ),
              ),
            IconButton(
              tooltip: '会话历史',
              onPressed: () => _scaffoldKey.currentState?.openEndDrawer(),
              icon: const Icon(Icons.history),
            ),
            IconButton(
              tooltip: '设置',
              onPressed: _openSettings,
              icon: const Icon(Icons.settings_outlined),
            ),
            if (_running)
              IconButton(
                tooltip: '取消',
                onPressed: _cancel,
                icon: const Icon(Icons.stop_circle_outlined),
              ),
          ],
        ),
        body: _booting
            ? const Center(child: CircularProgressIndicator())
            : Column(
                children: [
                  if (_status != null)
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
                          child: Text(_status!),
                        ),
                      ),
                    ),
                  Expanded(
                    child: Align(
                      alignment: Alignment.topCenter,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 840),
                        child: !hasChatContent
                            ? _EmptyChat(
                                onPrompt: (p) {
                                  _inputCtrl.text = p;
                                  _inputCtrl.selection =
                                      TextSelection.collapsed(offset: p.length);
                                },
                              )
                            : ListView.builder(
                                controller: _scrollCtrl,
                                padding: const EdgeInsets.fromLTRB(
                                  16,
                                  16,
                                  16,
                                  24,
                                ),
                                itemCount: _items.length,
                                itemBuilder: (context, i) =>
                                    _ChatBubble(item: _items[i]),
                              ),
                      ),
                    ),
                  ),
                  if (_pendingAttachments.isNotEmpty)
                    SizedBox(
                      height: 44,
                      child: Align(
                        alignment: Alignment.center,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 840),
                          child: ListView.separated(
                            scrollDirection: Axis.horizontal,
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            itemCount: _pendingAttachments.length,
                            separatorBuilder: (_, _) =>
                                const SizedBox(width: 6),
                            itemBuilder: (context, i) {
                              final a = _pendingAttachments[i];
                              return InputChip(
                                label: Text(a.displayName),
                                onDeleted: _running
                                    ? null
                                    : () => setState(
                                        () => _pendingAttachments.removeAt(i),
                                      ),
                              );
                            },
                          ),
                        ),
                      ),
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
                              GlassPanel(
                                borderRadius: 28,
                                tone: GlassTone.strong,
                                padding: const EdgeInsets.fromLTRB(4, 4, 4, 4),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: [
                                    IconButton(
                                      tooltip: '添加文件',
                                      onPressed: _running ? null : _pickFiles,
                                      icon: const Icon(Icons.attach_file),
                                    ),
                                    Expanded(
                                      child: TextField(
                                        controller: _inputCtrl,
                                        minLines: 1,
                                        maxLines: 5,
                                        enabled: !_running,
                                        decoration: const InputDecoration(
                                          hintText: '继续描述你的需求…',
                                          border: InputBorder.none,
                                          enabledBorder: InputBorder.none,
                                          focusedBorder: InputBorder.none,
                                          filled: false,
                                          contentPadding: EdgeInsets.symmetric(
                                            horizontal: 4,
                                            vertical: 12,
                                          ),
                                        ),
                                        onSubmitted: (_) => _send(),
                                      ),
                                    ),
                                    Padding(
                                      padding: const EdgeInsets.only(
                                        right: 4,
                                        bottom: 2,
                                      ),
                                      child: IconButton.filled(
                                        tooltip: '发送',
                                        onPressed: _running ? null : _send,
                                        icon: const Icon(Icons.send),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                '重要操作执行前会请求确认。',
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
      ),
    );
  }
}

class _EmptyChat extends StatelessWidget {
  const _EmptyChat({required this.onPrompt});

  final ValueChanged<String> onPrompt;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final prompts = <(String, String, IconData)>[
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
            final twoCol = constraints.maxWidth >= 640;
            return GridView.count(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              crossAxisCount: twoCol ? 2 : 1,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: twoCol ? 2.8 : 3.6,
              children: [
                for (final (i, item) in prompts.indexed)
                  FadeSlideIn(
                    index: i,
                    child: PressableScale(
                      onTap: () => onPrompt(item.$1),
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
                              child: Icon(item.$3),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                item.$2,
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

class _ChatBubble extends StatelessWidget {
  const _ChatBubble({required this.item});

  final _ChatItem item;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    if (item.kind == _ChatKind.tool) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: GlassPanel(
          borderRadius: 18,
          tone: GlassTone.regular,
          child: Theme(
            data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              tilePadding: const EdgeInsets.symmetric(horizontal: 12),
              childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              title: Text(
                item.text,
                style: Theme.of(context).textTheme.titleSmall,
              ),
              children: [
                if (item.subtitle != null)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: SelectableText(
                      item.subtitle!,
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
      );
    }

    final (tint, fg, align, solid) = switch (item.kind) {
      _ChatKind.user => (
        scheme.primary,
        scheme.onPrimary,
        CrossAxisAlignment.end,
        true,
      ),
      _ChatKind.assistant => (
        scheme.surface,
        scheme.onSurface,
        CrossAxisAlignment.start,
        false,
      ),
      _ChatKind.status => (
        scheme.surfaceContainerHighest,
        scheme.onSurface,
        CrossAxisAlignment.start,
        false,
      ),
      _ChatKind.error => (
        scheme.errorContainer,
        scheme.onErrorContainer,
        CrossAxisAlignment.start,
        true,
      ),
      _ChatKind.tool => (
        scheme.surface,
        scheme.onSurface,
        CrossAxisAlignment.start,
        false,
      ),
    };

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
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: SelectableText(item.text, style: TextStyle(color: fg)),
            ),
          )
        : GlassPanel(
            borderRadius: 20,
            tone: GlassTone.regular,
            tint: tint,
            padding: const EdgeInsets.all(14),
            child: SelectableText(item.text, style: TextStyle(color: fg)),
          );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: align,
        children: [
          ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.sizeOf(context).width * 0.88,
            ),
            child: bubble,
          ),
        ],
      ),
    );
  }
}
