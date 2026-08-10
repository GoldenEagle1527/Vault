import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:vault/agent/agent_inbox.dart';
import 'package:vault/agent/agent_service.dart';
import 'package:vault/agent/agent_settings.dart';
import 'package:vault/agent/conversation_store.dart';
import 'package:vault/agent/project_site_launcher.dart';
import 'package:vault/agent/project_store.dart';
import 'package:vault/permissions/active_workspace_holder.dart';
import 'package:vault/sandbox/sandbox_models.dart';
import 'package:vault/screens/settings_screen.dart';
import 'package:vault/screens/terminal_screen.dart';
import 'package:vault/widgets/glass.dart';
import 'package:vault/widgets/new_project_dialog.dart';

class AgentScreen extends StatefulWidget {
  const AgentScreen({
    super.key,
    required this.workspace,
    required this.title,
    required this.conversationStore,
    required this.projectStore,
    this.settingsStore,
  });

  final SandboxWorkspace workspace;
  final String title;
  final ConversationStore conversationStore;
  final ProjectStore projectStore;
  final AgentSettingsStore? settingsStore;

  @override
  State<AgentScreen> createState() => _AgentScreenState();
}

class _ChatItem {
  _ChatItem({
    required this.kind,
    required this.text,
    this.toolName,
    this.toolArguments,
    this.toolResult,
  });

  factory _ChatItem.tool({
    required String name,
    required String arguments,
    String? result,
  }) {
    return _ChatItem(
      kind: _ChatKind.tool,
      text: name,
      toolName: name,
      toolArguments: arguments,
      toolResult: result,
    );
  }

  final _ChatKind kind;
  String text;
  final String? toolName;
  final String? toolArguments;
  String? toolResult;
}

enum _ChatKind { user, assistant, tool, status, error }

class _AgentScreenState extends State<AgentScreen> {
  late final AgentSettingsStore _settingsStore;
  late final ConversationStore _conversationStore;
  late final ProjectStore _projectStore;
  final _inputCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  final List<_ChatItem> _items = [];
  final List<AgentAttachment> _pendingAttachments = [];
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  AgentService? _service;
  List<ProjectInfo> _projects = const [];
  List<ConversationInfo> _conversations = const [];
  String? _activeProjectPath;
  String? _activeConversationId;
  String _conversationTitle = kNewConversationTitle;
  bool _running = false;
  String? _status;
  bool _booting = true;
  bool _promptedNewProject = false;

  String get _activeProjectName {
    final path = _activeProjectPath;
    if (path == null) return '未选择项目';
    for (final p in _projects) {
      if (p.path == path) return p.name;
    }
    return path;
  }

  List<ProjectUrlEntry> get _activeProjectUrls {
    final path = _activeProjectPath;
    if (path == null) return const [];
    for (final p in _projects) {
      if (p.path == path) return p.urls;
    }
    return const [];
  }

  @override
  void initState() {
    super.initState();
    _settingsStore = widget.settingsStore ?? AgentSettingsStore();
    _conversationStore = widget.conversationStore;
    _projectStore = widget.projectStore;
    ActiveWorkspaceHolder.current = widget.workspace;
    _boot();
  }

  Future<void> _boot() async {
    try {
      final settings = await _settingsStore.load();
      if (!mounted) return;
      await _projectStore.ensureBootstrapped(widget.workspace.workspaceId);
      await _refreshProjects();
      if (_projects.isEmpty) {
        _service = AgentService.withoutProject(
          workspace: widget.workspace,
          settings: settings,
          conversationStore: _conversationStore,
          projectStore: _projectStore,
        );
        _conversations = const [];
        _activeConversationId = null;
        _conversationTitle = kNewConversationTitle;
        if (!settings.isConfigured) {
          _items.add(
            _ChatItem(
              kind: _ChatKind.status,
              text: '尚未配置 API。请先打开设置填写 Key 与模型。',
            ),
          );
        }
        _items.add(
          _ChatItem(
            kind: _ChatKind.status,
            text: '请先新建一个项目，之后的对话都会保存在该项目下。',
          ),
        );
      } else {
        final active = _activeProjectPath ?? _projects.first.path;
        _activeProjectPath = active;
        await _projectStore.setActive(widget.workspace.workspaceId, active);
        final service = await AgentService.open(
          workspace: widget.workspace,
          settings: settings,
          conversationStore: _conversationStore,
          projectStore: _projectStore,
          projectPath: active,
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
      }
    } catch (e) {
      _items.add(_ChatItem(kind: _ChatKind.error, text: '初始化失败：$e'));
    } finally {
      if (mounted) {
        setState(() => _booting = false);
        _scrollToEnd();
        if (_projects.isEmpty && !_promptedNewProject) {
          _promptedNewProject = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) unawaited(_createProject());
          });
        }
      }
    }
  }

  Future<void> _refreshProjects() async {
    final ws = widget.workspace.workspaceId;
    _projects = await _projectStore.list(ws);
    _activeProjectPath = await _projectStore.activePath(ws);
    if (_activeProjectPath == null && _projects.isNotEmpty) {
      _activeProjectPath = _projects.first.path;
    }
  }

  Future<void> _refreshConversationList() async {
    final projectPath = _activeProjectPath ?? _service?.projectPath;
    if (projectPath == null) {
      _conversations = const [];
      _activeConversationId = null;
      _conversationTitle = kNewConversationTitle;
      return;
    }
    final index =
        await _conversationStore.list(widget.workspace.workspaceId, projectPath);
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
        _items.add(_ChatItem.tool(name: name, arguments: arguments));
      case AgentUiToolResult(:final name, :final result):
        _attachToolResult(name, result);
      case AgentUiError(:final message):
        _items.add(_ChatItem(kind: _ChatKind.error, text: message));
      case AgentUiStatus():
      case AgentUiDiscardDraftAssistant():
        break;
    }
  }

  void _attachToolResult(String name, String result) {
    for (var i = _items.length - 1; i >= 0; i--) {
      final item = _items[i];
      if (item.kind == _ChatKind.tool &&
          item.toolName == name &&
          item.toolResult == null) {
        item.toolResult = result;
        return;
      }
    }
    _items.add(_ChatItem.tool(name: name, arguments: '', result: result));
  }

  Future<void> _reloadService() async {
    final settings = await _settingsStore.load();
    final existing = _service;
    final projectPath = _activeProjectPath;
    if (existing == null) {
      if (projectPath == null) {
        _service = AgentService.withoutProject(
          workspace: widget.workspace,
          settings: settings,
          conversationStore: _conversationStore,
          projectStore: _projectStore,
        );
      } else {
        _service = await AgentService.open(
          workspace: widget.workspace,
          settings: settings,
          conversationStore: _conversationStore,
          projectStore: _projectStore,
          projectPath: projectPath,
        );
        _hydrateFromService();
      }
    } else {
      existing.applySettings(settings);
    }
  }

  Future<void> _createProject() async {
    if (_running) {
      if (!await _confirmLeaveRunning()) return;
    }
    if (!mounted) return;
    final name = await showNewProjectDialog(
      context,
      existingNames: _projects.map((p) => p.name),
    );
    if (name == null || !mounted) return;

    setState(() => _status = '正在创建项目…');
    try {
      final created = await _projectStore.createProject(
        widget.workspace.workspaceId,
        name: name,
        conversationStore: _conversationStore,
      );
      final settings = await _settingsStore.load();
      await _service?.dispose();
      _service = await AgentService.open(
        workspace: widget.workspace,
        settings: settings,
        conversationStore: _conversationStore,
        projectStore: _projectStore,
        projectPath: created.path,
      );
      await _refreshProjects();
      _activeProjectPath = created.path;
      await _refreshConversationList();
      _hydrateFromService();
      _pendingAttachments.clear();
      _items.clear();
      _items.add(
        _ChatItem(
          kind: _ChatKind.status,
          text: '已创建项目「${created.name}」，目录：${created.guestDir}',
        ),
      );
    } catch (e) {
      if (!mounted) return;
      _items.add(_ChatItem(kind: _ChatKind.error, text: '创建项目失败：$e'));
    } finally {
      if (mounted) {
        setState(() => _status = null);
        _scrollToEnd();
      }
    }
  }

  Future<void> _switchProject(String projectPath) async {
    if (projectPath == _activeProjectPath) {
      Navigator.of(context).maybePop();
      return;
    }
    if (!await _confirmLeaveRunning()) return;
    if (!mounted) return;
    Navigator.of(context).maybePop();
    setState(() => _status = '正在切换项目…');
    try {
      final service = _service;
      if (service == null) return;
      await service.switchProject(projectPath);
      await _projectStore.setActive(widget.workspace.workspaceId, projectPath);
      _activeProjectPath = projectPath;
      await _refreshProjects();
      await _refreshConversationList();
      _hydrateFromService();
      _pendingAttachments.clear();
    } catch (e) {
      if (!mounted) return;
      _items.add(_ChatItem(kind: _ChatKind.error, text: '切换项目失败：$e'));
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

  Future<void> _startSite(ProjectUrlEntry entry) async {
    final projectPath = _activeProjectPath;
    if (projectPath == null) return;
    setState(() => _status = '正在启动「${entry.name}」…');
    try {
      final result = await ProjectSiteLauncher(widget.workspace).start(
        projectPath: projectPath,
        entry: entry,
      );
      if (!mounted) return;
      final parts = <String>[
        if (result.alreadyUp) '服务已在运行',
        if (result.startedProcess) '已后台启动',
        if (result.openedUrl) '已打开浏览器',
        if (!result.openedUrl && entry.url.trim().isNotEmpty)
          '地址：${entry.url}',
        if (result.message != null &&
            result.message != '服务已在运行' &&
            result.message != '已后台启动')
          result.message!,
      ];
      _items.add(
        _ChatItem(
          kind: result.startedProcess || result.alreadyUp || result.openedUrl
              ? _ChatKind.status
              : _ChatKind.error,
          text: parts.isEmpty ? '启动完成' : parts.join(' · '),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      _items.add(_ChatItem(kind: _ChatKind.error, text: '启动失败：$e'));
    } finally {
      if (mounted) {
        setState(() => _status = null);
        _scrollToEnd();
      }
    }
  }

  Future<void> _openSettings() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SettingsScreen(
          store: _settingsStore,
          workspaceResolver: () async => widget.workspace,
        ),
      ),
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
    if (_activeProjectPath == null) {
      await _createProject();
      return;
    }
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

    final projectPath = _activeProjectPath;
    if (projectPath == null) return;

    try {
      final deletingActive = id == _activeConversationId;
      final next = await _conversationStore.deleteConversation(
        widget.workspace.workspaceId,
        projectPath,
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
    if (_activeProjectPath == null) {
      await _createProject();
      return;
    }
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
          if (_items.isNotEmpty && _items.last.kind == _ChatKind.assistant) {
            _items.last.text += text;
          } else {
            _items.add(_ChatItem(kind: _ChatKind.assistant, text: text));
          }
        case AgentUiAssistantFinal(:final text):
          if (_items.isNotEmpty && _items.last.kind == _ChatKind.assistant) {
            _items.last.text = text;
          } else {
            _items.add(_ChatItem(kind: _ChatKind.assistant, text: text));
          }
        case AgentUiDiscardDraftAssistant():
          _discardBlankAssistantDraft();
        case AgentUiToolCall(:final name, :final arguments):
          _discardBlankAssistantDraft();
          _items.add(_ChatItem.tool(name: name, arguments: arguments));
        case AgentUiToolResult(:final name, :final result):
          _attachToolResult(name, result);
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
    await _refreshProjects();
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
    if (identical(ActiveWorkspaceHolder.current, widget.workspace)) {
      ActiveWorkspaceHolder.current = null;
    }
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
                              '项目与会话',
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
                  child: Row(
                    children: [
                      Expanded(
                        child: FilledButton.tonalIcon(
                          onPressed: _booting ? null : _createProject,
                          icon: const Icon(Icons.create_new_folder_outlined),
                          label: const Text('新项目'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: FilledButton.tonalIcon(
                          onPressed: _booting || _activeProjectPath == null
                              ? null
                              : _newConversation,
                          icon: const Icon(Icons.add),
                          label: const Text('新会话'),
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: ListView(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                        child: Text(
                          '项目',
                          style: Theme.of(context).textTheme.labelLarge
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ),
                      if (_projects.isEmpty)
                        ListTile(
                          title: Text(
                            '暂无项目',
                            style: TextStyle(color: scheme.onSurfaceVariant),
                          ),
                          subtitle: const Text('点击上方「新项目」开始'),
                        )
                      else
                        for (final p in _projects)
                          ListTile(
                            selected: p.path == _activeProjectPath,
                            leading: Icon(
                              p.path == _activeProjectPath
                                  ? Icons.folder
                                  : Icons.folder_outlined,
                            ),
                            title: Text(
                              p.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              p.urls.isEmpty
                                  ? p.path
                                  : '${p.path} · ${p.urls.length} 个站点',
                            ),
                            onTap: () => _switchProject(p.path),
                          ),
                      const Divider(height: 1),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                        child: Text(
                          '站点（一键启动）',
                          style: Theme.of(context).textTheme.labelLarge
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ),
                      if (_activeProjectPath == null)
                        ListTile(
                          title: Text(
                            '请先选择项目',
                            style: TextStyle(color: scheme.onSurfaceVariant),
                          ),
                        )
                      else if (_activeProjectUrls.isEmpty)
                        ListTile(
                          title: Text(
                            '暂无已登记站点',
                            style: TextStyle(color: scheme.onSurfaceVariant),
                          ),
                          subtitle: const Text(
                            '让 Agent 用 Python 做好网站后会自动登记到这里',
                          ),
                        )
                      else
                        for (final site in _activeProjectUrls)
                          ListTile(
                            leading: const Icon(Icons.language),
                            title: Text(
                              site.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              site.url,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: FilledButton.tonal(
                              onPressed: _booting || _running
                                  ? null
                                  : () => _startSite(site),
                              child: const Text('启动'),
                            ),
                          ),
                      const Divider(height: 1),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                        child: Text(
                          '当前项目会话',
                          style: Theme.of(context).textTheme.labelLarge
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ),
                      if (_activeProjectPath == null)
                        ListTile(
                          title: Text(
                            '请先选择或新建项目',
                            style: TextStyle(color: scheme.onSurfaceVariant),
                          ),
                        )
                      else if (_conversations.isEmpty)
                        ListTile(
                          title: Text(
                            '暂无会话',
                            style: TextStyle(color: scheme.onSurfaceVariant),
                          ),
                        )
                      else
                        for (final c in _conversations)
                          ListTile(
                            selected: c.id == _activeConversationId,
                            leading: Icon(
                              c.id == _activeConversationId
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
                          ),
                    ],
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
                      _activeProjectPath == null
                          ? '新建项目以开始'
                          : _conversationTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      _activeProjectPath == null
                          ? '${widget.title} · 工作区'
                          : '$_activeProjectName · ${widget.title}',
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
              tooltip: '新建项目',
              onPressed: _booting ? null : _createProject,
              icon: const Icon(Icons.create_new_folder_outlined),
            ),
            IconButton(
              tooltip: '项目与会话',
              onPressed: () => _scaffoldKey.currentState?.openEndDrawer(),
              icon: const Icon(Icons.history),
            ),
            IconButton(
              tooltip: '设置',
              onPressed: _openSettings,
              icon: const Icon(Icons.settings_outlined),
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
                        child: _activeProjectPath == null
                            ? _EmptyProject(
                                onCreate: _createProject,
                              )
                            : !hasChatContent
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
                                        tooltip: _running ? '停止' : '发送',
                                        onPressed: _running ? _cancel : _send,
                                        icon: Icon(
                                          _running
                                              ? Icons.stop_rounded
                                              : Icons.send,
                                        ),
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

class _EmptyProject extends StatelessWidget {
  const _EmptyProject({required this.onCreate});

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
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
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
        child: Align(
          alignment: Alignment.centerLeft,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.sizeOf(context).width * 0.92,
            ),
            child: _ToolCallCard(item: item),
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

    final md = _ChatMarkdown(data: item.text, color: fg);

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
              child: md,
            ),
          )
        : GlassPanel(
            borderRadius: 20,
            tone: GlassTone.regular,
            tint: tint,
            padding: const EdgeInsets.all(14),
            child: md,
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

class _ChatMarkdown extends StatelessWidget {
  const _ChatMarkdown({required this.data, required this.color});

  final String data;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base = theme.textTheme;
    final codeBg = color.withValues(alpha: 0.14);
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
          backgroundColor: codeBg,
        ),
        codeblockDecoration: BoxDecoration(
          color: codeBg,
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

/// Cursor-style collapsible tool call: command + output in one folded block.
class _ToolCallCard extends StatefulWidget {
  const _ToolCallCard({required this.item});

  final _ChatItem item;

  @override
  State<_ToolCallCard> createState() => _ToolCallCardState();
}

class _ToolCallCardState extends State<_ToolCallCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final command = _toolCommand(
      widget.item.toolName ?? widget.item.text,
      widget.item.toolArguments,
    );
    final result = widget.item.toolResult;
    final done = result != null;
    final summary = _toolSummary(
      toolName: widget.item.toolName ?? widget.item.text,
      command: command,
      done: done,
    );
    final output = done ? _formatToolResult(result) : null;

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
                      color: scheme.onSurfaceVariant,
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
      ],
    );
  }
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
  } catch (_) {}
  return raw;
}

String _toolSummary({
  required String toolName,
  required String command,
  required bool done,
}) {
  final firstLine = command.split(RegExp(r'\r?\n')).first.trim();
  final preview = firstLine.length > 72
      ? '${firstLine.substring(0, 72)}…'
      : firstLine;
  if (!done) {
    return preview.isEmpty ? 'Running $toolName…' : 'Running $preview';
  }
  if (preview.isEmpty) return 'Ran $toolName';
  return 'Ran $preview';
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
      final buf = StringBuffer();
      if (stdout.isNotEmpty) buf.write(stdout);
      if (stderr.isNotEmpty) {
        if (buf.isNotEmpty && !buf.toString().endsWith('\n')) {
          buf.writeln();
        }
        buf.write(stderr);
      }
      if (buf.isNotEmpty) return buf.toString();
      if (error != null && error.isNotEmpty) return error;
      final exit = decoded['exitCode'];
      if (exit != null) return 'exit $exit';
    }
  } catch (_) {}
  return raw;
}
