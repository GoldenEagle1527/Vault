import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:vault/agent/agent_inbox.dart';
import 'package:vault/agent/agent_service.dart';
import 'package:vault/agent/agent_settings.dart';
import 'package:vault/sandbox/sandbox_models.dart';
import 'package:vault/screens/settings_screen.dart';

class AgentScreen extends StatefulWidget {
  const AgentScreen({
    super.key,
    required this.session,
    required this.title,
    this.settingsStore,
  });

  final SandboxSession session;
  final String title;
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
  late final AgentSettingsStore _store;
  final _inputCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  final List<_ChatItem> _items = [];
  final List<AgentAttachment> _pendingAttachments = [];
  AgentService? _service;
  bool _running = false;
  String? _status;
  bool _booting = true;

  @override
  void initState() {
    super.initState();
    _store = widget.settingsStore ?? AgentSettingsStore();
    _boot();
  }

  Future<void> _boot() async {
    try {
      final settings = await _store.load();
      if (!mounted) return;
      _service = AgentService(session: widget.session, settings: settings);
      if (!settings.isConfigured) {
        _items.add(
          _ChatItem(
            kind: _ChatKind.status,
            text: '尚未配置 API。请先打开右上角设置填写 Key 与模型。',
          ),
        );
      }
    } catch (e) {
      _items.add(_ChatItem(kind: _ChatKind.error, text: '初始化失败：$e'));
    } finally {
      if (mounted) setState(() => _booting = false);
    }
  }

  Future<void> _reloadService() async {
    final settings = await _store.load();
    await _service?.dispose();
    _service = AgentService(session: widget.session, settings: settings);
  }

  Future<void> _openSettings() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => SettingsScreen(store: _store)),
    );
    if (!mounted) return;
    await _reloadService();
    setState(() {});
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
          AgentAttachment(
            hostPath: path,
            displayName: f.name,
          ),
        );
      }
    });
  }

  Future<void> _send() async {
    final text = _inputCtrl.text.trim();
    if ((text.isEmpty && _pendingAttachments.isEmpty) ||
        _running ||
        _service == null) {
      return;
    }

    // Recreate service with latest settings each turn (cheap).
    await _reloadService();
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
          if (_items.isEmpty || _items.last.kind != _ChatKind.assistant) {
            _items.add(_ChatItem(kind: _ChatKind.assistant, text: text));
          } else {
            _items.last.text = text;
          }
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
            _ChatItem(
              kind: _ChatKind.tool,
              text: '结果 $name',
              subtitle: result,
            ),
          );
        case AgentUiError(:final message):
          _items.add(_ChatItem(kind: _ChatKind.error, text: message));
        case AgentUiStatus(:final message):
          _status = message;
      }
      setState(() {});
      _scrollToEnd();
    }

    if (!mounted) return;
    setState(() {
      _running = false;
      _status = null;
    });
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

  @override
  void dispose() {
    _service?.dispose();
    // Own the attach lifecycle (same as SessionTerminal for the terminal path).
    unawaited(widget.session.dispose());
    _inputCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Agent · ${widget.title}'),
        actions: [
          IconButton(
            tooltip: '设置',
            onPressed: _openSettings,
            icon: const Icon(Icons.settings),
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
                  Material(
                    color: Theme.of(context).colorScheme.surfaceContainerHighest,
                    child: SizedBox(
                      width: double.infinity,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        child: Text(_status!),
                      ),
                    ),
                  ),
                Expanded(
                  child: ListView.builder(
                    controller: _scrollCtrl,
                    padding: const EdgeInsets.all(12),
                    itemCount: _items.length,
                    itemBuilder: (context, i) => _ChatBubble(item: _items[i]),
                  ),
                ),
                if (_pendingAttachments.isNotEmpty)
                  SizedBox(
                    height: 40,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      itemCount: _pendingAttachments.length,
                      separatorBuilder: (_, _) => const SizedBox(width: 6),
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
                SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                    child: Row(
                      children: [
                        IconButton(
                          tooltip: '添加文件到会话 Linux',
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
                              hintText: '描述要在本会话 Linux 中完成的任务…',
                              border: OutlineInputBorder(),
                            ),
                            onSubmitted: (_) => _send(),
                          ),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          onPressed: _running ? null : _send,
                          child: const Icon(Icons.send),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}

class _ChatBubble extends StatelessWidget {
  const _ChatBubble({required this.item});

  final _ChatItem item;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (bg, fg, align) = switch (item.kind) {
      _ChatKind.user => (
          scheme.primaryContainer,
          scheme.onPrimaryContainer,
          CrossAxisAlignment.end,
        ),
      _ChatKind.assistant => (
          scheme.secondaryContainer,
          scheme.onSecondaryContainer,
          CrossAxisAlignment.start,
        ),
      _ChatKind.tool => (
          scheme.tertiaryContainer,
          scheme.onTertiaryContainer,
          CrossAxisAlignment.start,
        ),
      _ChatKind.status => (
          scheme.surfaceContainerHighest,
          scheme.onSurface,
          CrossAxisAlignment.start,
        ),
      _ChatKind.error => (
          scheme.errorContainer,
          scheme.onErrorContainer,
          CrossAxisAlignment.start,
        ),
    };

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: align,
        children: [
          Container(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.sizeOf(context).width * 0.92,
            ),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SelectableText(item.text, style: TextStyle(color: fg)),
                if (item.subtitle != null) ...[
                  const SizedBox(height: 6),
                  SelectableText(
                    item.subtitle!,
                    style: TextStyle(
                      color: fg.withValues(alpha: 0.85),
                      fontFamily: 'monospace',
                      fontSize: 12,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
