import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:vault/util/host_file_picker.dart';
import 'package:vault/agent/agent_inbox.dart';
import 'package:vault/agent/agent_service.dart';
import 'package:vault/agent/agent_settings.dart';
import 'package:vault/agent/ask_user.dart';
import 'package:vault/agent/chat_input_keys.dart';
import 'package:vault/agent/conversation_store.dart';
import 'package:vault/agent/project_site_launcher.dart';
import 'package:vault/agent/project_store.dart';
import 'package:vault/agent/site_gateway.dart';
import 'package:vault/agent/site_port.dart';
import 'package:vault/agent/system_notice.dart';
import 'package:vault/agent/workspace_mode.dart';
import 'package:vault/agent/workspace_store.dart';
import 'package:vault/permissions/active_workspace_holder.dart';
import 'package:vault/sandbox/sandbox_provider.dart';
import 'package:vault/screens/file_browser_screen.dart';
import 'package:vault/screens/settings_screen.dart';
import 'package:vault/screens/terminal_screen.dart';
import 'package:vault/widgets/ask_user_panel.dart';
import 'package:vault/widgets/glass.dart';
import 'package:vault/widgets/new_project_dialog.dart';

class AgentScreen extends StatefulWidget {
  const AgentScreen({
    super.key,
    required this.provider,
    required this.workspace,
    required this.title,
    required this.conversationStore,
    required this.projectStore,
    this.settingsStore,
    this.mode = WorkspaceMode.chat,
  });

  final SandboxProvider provider;
  final SandboxWorkspace workspace;
  final String title;
  final ConversationStore conversationStore;
  final ProjectStore projectStore;
  final AgentSettingsStore? settingsStore;
  final WorkspaceMode mode;

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
    this.toolCallId,
    this.toolJobId,
    this.toolBackgrounded = false,
    this.thinkingPlaceholder = false,
    this.promptTokens,
    this.completionTokens,
    this.totalTokens,
    this.duration,
    this.at,
  });

  factory _ChatItem.tool({
    required String name,
    required String arguments,
    String? result,
    String? callId,
    String? jobId,
    bool backgrounded = false,
  }) {
    return _ChatItem(
      kind: _ChatKind.tool,
      text: name,
      toolName: name,
      toolArguments: arguments,
      toolResult: result,
      toolCallId: callId,
      toolJobId: jobId,
      toolBackgrounded: backgrounded,
    );
  }

  factory _ChatItem.thinking() {
    return _ChatItem(
      kind: _ChatKind.assistant,
      text: 'Agent 正在思考…',
      thinkingPlaceholder: true,
    );
  }

  final _ChatKind kind;
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
}

enum _ChatKind { user, assistant, tool, status, error }

class _AgentScreenState extends State<AgentScreen> {
  late final AgentSettingsStore _settingsStore;
  late final ConversationStore _conversationStore;
  late final ProjectStore _projectStore;
  late final WorkspaceStore _workspaceStore;
  final SiteGateway _siteGateway = SiteGateway();
  final _inputCtrl = TextEditingController();
  late final FocusNode _inputFocus;
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

  StreamSubscription<AgentUiEvent>? _backgroundUiSub;
  AskUserHost? _askUserHost;
  final Map<String, bool> _siteUp = {};
  final Set<String> _siteBusy = {};
  Timer? _sitePollTimer;
  bool _siteProbeInFlight = false;
  List<AgentSettings> _profiles = const [AgentSettings.defaults];
  String _activeProfileId = AgentSettings.defaultProfileId;
  AgentSettings? _pendingProfile;

  String get _activeProjectName {
    final path = _activeProjectPath;
    if (path == null) return '未选择项目';
    for (final p in _projects) {
      if (p.path == path) return p.name;
    }
    return path;
  }

  ProjectUrlEntry? _siteFor(String projectPath) {
    for (final p in _projects) {
      if (p.path == projectPath) return p.site;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    _settingsStore = widget.settingsStore ?? AgentSettingsStore();
    _inputFocus = FocusNode(onKeyEvent: _onInputKeyEvent);
    _conversationStore = widget.conversationStore;
    _projectStore = widget.projectStore;
    _workspaceStore = WorkspaceStore(metaDb: _projectStore.metaDb);
    ActiveWorkspaceHolder.current = widget.workspace;
    _boot();
  }

  Future<void> _boot() async {
    try {
      final bundle = await _settingsStore.loadBundle();
      if (!mounted) return;
      _profiles = bundle.profiles;
      _activeProfileId = bundle.active.id;
      final settings = bundle.active;
      await _projectStore.ensureBootstrapped(widget.workspace.workspaceId);
      await _refreshProjects();
      await _ensureSiteGateway();
      if (_projects.isEmpty) {
        _service = AgentService.withoutProject(
          workspace: widget.workspace,
          settings: settings,
          conversationStore: _conversationStore,
          projectStore: _projectStore,
          mode: widget.mode,
          siteGateway: _siteGateway,
        );
        _bindBackgroundUi(_service);
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
          _ChatItem(kind: _ChatKind.status, text: '请先新建一个项目，之后的对话都会保存在该项目下。'),
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
          mode: widget.mode,
          siteGateway: _siteGateway,
        );
        _service = service;
        _bindBackgroundUi(service);
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
        _syncSitePoll();
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
    _syncGatewayRoutes();
    _syncSitePoll();
  }

  Future<void> _ensureSiteGateway() async {
    final ws = widget.workspace.workspaceId;
    final preferred = await _workspaceStore.getGatewayPort(ws);
    final port = await _siteGateway.start(preferredPort: preferred ?? 0);
    if (port != preferred) {
      await _workspaceStore.setGatewayPort(ws, port);
    }
    _siteGateway.captureEnabled = widget.mode == WorkspaceMode.dev;
    _syncGatewayRoutes();
  }

  void _syncGatewayRoutes() {
    _siteGateway.updateRoutes(siteRoutesFromProjects(_projects));
  }

  String _sitePublicUrl(ProjectUrlEntry site) {
    final slug = site.slug?.trim();
    final port = _siteGateway.port;
    if (slug != null && slug.isNotEmpty && port != null) {
      return sitePublicUrl(slug: slug, gatewayPort: port);
    }
    return site.url;
  }

  Future<void> _refreshConversationList() async {
    final projectPath = _activeProjectPath ?? _service?.projectPath;
    if (projectPath == null) {
      _conversations = const [];
      _activeConversationId = null;
      _conversationTitle = kNewConversationTitle;
      return;
    }
    final index = await _conversationStore.list(
      widget.workspace.workspaceId,
      projectPath,
    );
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

  void _onAskUserChanged() {
    if (mounted) setState(() {});
  }

  void _bindAskUser(AgentService? service) {
    _askUserHost?.pending.removeListener(_onAskUserChanged);
    _askUserHost = service?.askUser;
    _askUserHost?.pending.addListener(_onAskUserChanged);
  }

  void _bindBackgroundUi(AgentService? service) {
    _bindAskUser(service);
    unawaited(_backgroundUiSub?.cancel());
    _backgroundUiSub = null;
    if (service == null) return;
    _backgroundUiSub = service.backgroundUiEvents.listen((event) {
      if (!mounted) return;
      if (event is AgentUiStatus &&
          (event.message == '后台任务结果已送达，正在继续…' ||
              event.message == 'shell 匹配通知已送达，正在继续…')) {
        _running = true;
      }
      _applyLiveEvent(event);
      if (event is AgentUiStatus && event.message == '已完成') {
        _running = false;
        _status = null;
        _discardThinkingPlaceholder();
      }
      _conversationTitle = service.conversationTitle;
      setState(() {});
      _scrollToEnd();
    });
  }

  void _addUserOrSystemNotice(String text, {int? promptTokens, DateTime? at}) {
    final notice = systemNoticeForUserText(text);
    if (notice != null) {
      _items.add(
        _ChatItem(
          kind: notice.isError ? _ChatKind.error : _ChatKind.status,
          text: notice.text,
        ),
      );
      return;
    }
    _items.add(
      _ChatItem(
        kind: _ChatKind.user,
        text: text,
        promptTokens: promptTokens,
        at: at,
      ),
    );
  }

  void _applyRestoredEvent(AgentUiEvent event) {
    switch (event) {
      case AgentUiUserMessage(:final text, :final promptTokens, :final at):
        _addUserOrSystemNotice(text, promptTokens: promptTokens, at: at);
      case AgentUiSystemNotice(:final text, :final isError):
        _items.add(
          _ChatItem(
            kind: isError ? _ChatKind.error : _ChatKind.status,
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
        _items.add(
          _ChatItem(
            kind: _ChatKind.assistant,
            text: text,
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            totalTokens: totalTokens,
            duration: duration,
            at: at,
          ),
        );
      case AgentUiAssistantDelta(:final text):
        _items.add(_ChatItem(kind: _ChatKind.assistant, text: text));
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
      case AgentUiToolCall(:final name, :final arguments, :final callId):
        if (name == kAskUserToolName) break;
        _items.add(
          _ChatItem.tool(name: name, arguments: arguments, callId: callId),
        );
      case AgentUiToolResult(:final name, :final result, :final callId):
        if (name == kAskUserToolName) break;
        _attachToolResult(name, result, callId: callId);
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
      case AgentUiShellNotify():
        break;
      case AgentUiError(:final message):
        _items.add(_ChatItem(kind: _ChatKind.error, text: message));
      case AgentUiStatus():
      case AgentUiDiscardDraftAssistant():
        break;
    }
  }

  bool _isThinkingStatus(String message) {
    return message == '正在思考…' ||
        message == '正在调用模型…' ||
        message == '运行中…' ||
        message == '后台任务结果已送达，正在继续…' ||
        message == 'shell 匹配通知已送达，正在继续…' ||
        message == 'shell 输出已匹配，准备唤醒模型…';
  }

  void _ensureThinkingPlaceholder() {
    if (_items.isNotEmpty &&
        _items.last.kind == _ChatKind.assistant &&
        _items.last.thinkingPlaceholder) {
      return;
    }
    _items.add(_ChatItem.thinking());
  }

  void _discardThinkingPlaceholder() {
    while (_items.isNotEmpty &&
        _items.last.kind == _ChatKind.assistant &&
        _items.last.thinkingPlaceholder) {
      _items.removeLast();
    }
  }

  void _applyLiveEvent(AgentUiEvent event) {
    switch (event) {
      case AgentUiUserMessage(:final text, :final promptTokens, :final at):
        _addUserOrSystemNotice(
          text,
          promptTokens: promptTokens,
          at: at ?? DateTime.now(),
        );
      case AgentUiSystemNotice(:final text, :final isError):
        _items.add(
          _ChatItem(
            kind: isError ? _ChatKind.error : _ChatKind.status,
            text: text,
          ),
        );
      case AgentUiAssistantDelta(:final text):
        if (!AgentService.isVisibleAssistantText(text)) {
          break;
        }
        if (_items.isNotEmpty && _items.last.kind == _ChatKind.assistant) {
          if (_items.last.thinkingPlaceholder) {
            _items.last.thinkingPlaceholder = false;
            _items.last.text = text;
          } else {
            _items.last.text += text;
          }
        } else {
          _items.add(_ChatItem(kind: _ChatKind.assistant, text: text));
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
          if (_items.isNotEmpty &&
              _items.last.kind == _ChatKind.assistant &&
              !_items.last.thinkingPlaceholder) {
            _mergeUsageInto(
              _items.last,
              promptTokens: promptTokens,
              completionTokens: completionTokens,
              totalTokens: totalTokens,
              duration: duration,
              at: at,
            );
          }
          break;
        }
        if (_items.isNotEmpty && _items.last.kind == _ChatKind.assistant) {
          final item = _items.last;
          item.thinkingPlaceholder = false;
          item.text = text;
          _mergeUsageInto(
            item,
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            totalTokens: totalTokens,
            duration: duration,
            at: at,
          );
        } else {
          _items.add(
            _ChatItem(
              kind: _ChatKind.assistant,
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
        _discardBlankAssistantDraft();
      case AgentUiToolCall(:final name, :final arguments, :final callId):
        if (name == kAskUserToolName) break;
        _upsertToolCall(name: name, arguments: arguments, callId: callId);
      case AgentUiToolResult(:final name, :final result, :final callId):
        if (name == kAskUserToolName) break;
        _attachToolResult(name, result, callId: callId);
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
        _status = 'shell 匹配通知：$regex';
      case AgentUiError(:final message):
        _discardThinkingPlaceholder();
        _items.add(_ChatItem(kind: _ChatKind.error, text: message));
      case AgentUiStatus(:final message):
        if (message == '已完成') {
          _status = null;
          _discardThinkingPlaceholder();
        } else if (_isThinkingStatus(message)) {
          _status = null;
          _ensureThinkingPlaceholder();
        } else {
          _status = message;
        }
    }
  }

  void _mergeUsageInto(
    _ChatItem item, {
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
    if (totalTokens != null && totalTokens > 0) {
      item.totalTokens = totalTokens;
    }
    if (duration != null) item.duration = duration;
    if (at != null) item.at = at;
  }

  void _attachPromptTokensToLastUser(int promptTokens) {
    for (var i = _items.length - 1; i >= 0; i--) {
      final item = _items[i];
      if (item.kind != _ChatKind.user) continue;
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
    if (promptTokens > 0) {
      _attachPromptTokensToLastUser(promptTokens);
    }
    for (var i = _items.length - 1; i >= 0; i--) {
      final item = _items[i];
      if (item.kind != _ChatKind.assistant || item.thinkingPlaceholder) {
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
  }) {
    _discardBlankAssistantDraft();
    for (var i = _items.length - 1; i >= 0; i--) {
      final item = _items[i];
      if (item.kind != _ChatKind.tool || item.toolResult != null) continue;
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
        item.toolName = name;
        item.text = name;
      }
      if (arguments.length >= (item.toolArguments?.length ?? 0)) {
        item.toolArguments = arguments;
      }
      return;
    }
    _items.add(
      _ChatItem.tool(name: name, arguments: arguments, callId: callId),
    );
  }

  void _markToolBackgrounded({
    required String name,
    required String jobId,
    required String callId,
    required String stubResult,
  }) {
    for (var i = _items.length - 1; i >= 0; i--) {
      final item = _items[i];
      if (item.kind != _ChatKind.tool) continue;
      final idMatch =
          item.toolCallId == callId ||
          (item.toolCallId == null &&
              item.toolName == name &&
              item.toolResult == null &&
              !item.toolBackgrounded);
      if (!idMatch) continue;
      item.toolCallId ??= callId;
      item.toolJobId = jobId;
      item.toolBackgrounded = true;
      // Keep result null so the card stays in "running/background" visual state.
      return;
    }
    _items.add(
      _ChatItem.tool(
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
  }) {
    for (var i = _items.length - 1; i >= 0; i--) {
      final item = _items[i];
      if (item.kind != _ChatKind.tool) continue;
      final idMatch = callId != null && item.toolCallId == callId;
      final jobMatch = jobId != null && item.toolJobId == jobId;
      final nameMatch =
          item.toolName == name &&
          (item.toolResult == null || item.toolBackgrounded);
      if (idMatch ||
          jobMatch ||
          (callId == null && jobId == null && nameMatch)) {
        item.toolResult = result;
        if (clearBackgrounded) item.toolBackgrounded = false;
        item.toolCallId ??= callId;
        item.toolJobId ??= jobId;
        if (name == 'register_project_url') {
          unawaited(
            _refreshProjects().then((_) {
              if (mounted) setState(() {});
            }),
          );
        }
        return;
      }
    }
    _items.add(
      _ChatItem.tool(
        name: name,
        arguments: '',
        result: result,
        callId: callId,
        jobId: jobId,
      ),
    );
  }

  Future<void> _reloadService() async {
    final bundle = await _settingsStore.loadBundle();
    if (!mounted) return;
    _profiles = bundle.profiles;
    _activeProfileId = bundle.active.id;
    _pendingProfile = null;
    final settings = bundle.active;
    final existing = _service;
    final projectPath = _activeProjectPath;
    if (existing == null) {
      if (projectPath == null) {
        _service = AgentService.withoutProject(
          workspace: widget.workspace,
          settings: settings,
          conversationStore: _conversationStore,
          projectStore: _projectStore,
          mode: widget.mode,
          siteGateway: _siteGateway,
        );
        _bindBackgroundUi(_service);
      } else {
        _service = await AgentService.open(
          workspace: widget.workspace,
          settings: settings,
          conversationStore: _conversationStore,
          projectStore: _projectStore,
          projectPath: projectPath,
          mode: widget.mode,
          siteGateway: _siteGateway,
        );
        _bindBackgroundUi(_service);
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
        mode: widget.mode,
        siteGateway: _siteGateway,
      );
      _bindBackgroundUi(_service);
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
    if (projectPath == _activeProjectPath) return;
    if (!await _confirmLeaveRunning()) return;
    if (!mounted) return;
    setState(() => _status = '正在切换项目…');
    try {
      final service = _service;
      if (service == null) return;
      await service.switchProject(projectPath);
      await _projectStore.setActive(widget.workspace.workspaceId, projectPath);
      _activeProjectPath = projectPath;
      await _refreshConversationList();
      _hydrateFromService();
      _pendingAttachments.clear();
      _syncSitePoll();
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

  void _syncSitePoll() {
    if (!mounted) {
      _sitePollTimer?.cancel();
      _sitePollTimer = null;
      return;
    }
    final shouldPoll = !_booting && _projects.any((p) => p.site != null);
    if (shouldPoll) {
      _sitePollTimer ??= Timer.periodic(const Duration(seconds: 4), (_) {
        unawaited(_refreshSiteStatus());
      });
      unawaited(_refreshSiteStatus());
    } else {
      _sitePollTimer?.cancel();
      _sitePollTimer = null;
    }
  }

  Future<void> _refreshSiteStatus() async {
    if (_siteProbeInFlight) return;
    final pairs = [
      for (final p in _projects)
        if (p.site != null) (p.path, p.site!),
    ];
    if (pairs.isEmpty) {
      if (_siteUp.isNotEmpty && mounted) {
        setState(_siteUp.clear);
      }
      return;
    }
    _siteProbeInFlight = true;
    try {
      final probe = await widget.workspace.run(
        siteProbeShellCommand([for (final pair in pairs) pair.$2.url]),
        timeout: const Duration(seconds: 15),
      );
      final codes = probe.stdout.trim().split(RegExp(r'\s+'));
      final next = <String, bool>{};
      for (var i = 0; i < pairs.length; i++) {
        final code = i < codes.length ? codes[i] : '0';
        next[pairs[i].$1] = isHttpServiceResponding(code);
      }
      if (!mounted) return;
      setState(() {
        _siteUp
          ..clear()
          ..addAll(next);
      });
    } catch (_) {
      // Keep last known status.
    } finally {
      _siteProbeInFlight = false;
    }
  }

  Future<void> _startSite(
    ProjectUrlEntry entry, {
    required String projectPath,
  }) async {
    setState(() {
      _status = '正在启动「${entry.name}」…';
      _siteBusy.add(projectPath);
    });
    var launched = false;
    try {
      final result = await ProjectSiteLauncher(widget.workspace).start(
        projectPath: projectPath,
        entry: entry,
        openUrl: _sitePublicUrl(entry),
      );
      if (!mounted) return;
      launched = result.startedProcess || result.alreadyUp;
      if (launched) _siteUp[projectPath] = true;
      final parts = <String>[
        if (result.alreadyUp) '服务已在运行',
        if (result.startedProcess) '已后台启动',
        if (result.openedUrl) '已打开浏览器',
        if (!result.openedUrl && _sitePublicUrl(entry).trim().isNotEmpty)
          '地址：${_sitePublicUrl(entry)}',
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
        setState(() {
          _status = null;
          _siteBusy.remove(projectPath);
        });
        _scrollToEnd();
        if (!launched) unawaited(_refreshSiteStatus());
      }
    }
  }

  Future<void> _stopSite(
    ProjectUrlEntry entry, {
    required String projectPath,
  }) async {
    setState(() {
      _status = '正在终止「${entry.name}」…';
      _siteBusy.add(projectPath);
    });
    try {
      final result = await ProjectSiteLauncher(
        widget.workspace,
      ).stop(projectPath: projectPath, entry: entry);
      if (!mounted) return;
      _siteUp[projectPath] = !result.stopped;
      _items.add(
        _ChatItem(
          kind: result.stopped ? _ChatKind.status : _ChatKind.error,
          text: result.message ?? (result.stopped ? '已终止' : '终止失败'),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      _items.add(_ChatItem(kind: _ChatKind.error, text: '终止失败：$e'));
    } finally {
      if (mounted) {
        setState(() {
          _status = null;
          _siteBusy.remove(projectPath);
        });
        _scrollToEnd();
        unawaited(_refreshSiteStatus());
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

  Future<void> _openTerminalFor(String projectPath) async {
    _closeDrawerIfOpen();
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TerminalScreen(
          title: widget.title,
          workspace: widget.workspace,
          disposeWorkspace: false,
          initialGuestCwd: guestProjectDir(projectPath),
        ),
      ),
    );
  }

  Future<void> _openFileBrowserFor(String projectPath) async {
    _closeDrawerIfOpen();
    final projectGuest = guestProjectDir(projectPath);
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => FileBrowserScreen(
          provider: widget.provider,
          workspaceId: widget.workspace.workspaceId,
          title: widget.title,
          initialPath: projectGuest,
          projectGuestPath: projectGuest,
        ),
      ),
    );
  }

  Future<void> _toggleSiteFor(String projectPath) async {
    final site = _siteFor(projectPath);
    if (site == null) return;
    if (_siteUp[projectPath] == true) {
      await _stopSite(site, projectPath: projectPath);
    } else {
      await _startSite(site, projectPath: projectPath);
    }
  }

  Future<void> _pickFiles() async {
    if (_running) return;
    // file_picker 11 + FileType.image → ACTION_GET_CONTENT DocumentsUI
    // (最近/图片/音频/文档), matching raincurtain.
    final result = await pickHostFilesForUi(
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

  Future<void> _newConversation({String? projectPath}) async {
    final path = projectPath ?? _activeProjectPath;
    if (path == null) {
      await _createProject();
      return;
    }
    if (path != _activeProjectPath) {
      await _switchProject(path);
      if (!mounted || _activeProjectPath != path) return;
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
    if (id == _activeConversationId) return;
    if (!await _confirmLeaveRunning()) return;
    if (!mounted) return;
    final service = _service;
    if (service == null) return;
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
      _status = null;
    });

    await for (final event in service.run(text, attachments: attachments)) {
      if (!mounted) return;
      _applyLiveEvent(event);
      _conversationTitle = service.conversationTitle;
      setState(() {});
      _scrollToEnd();
    }

    if (!mounted) return;
    await _refreshProjects();
    await _refreshConversationList();
    final pending = _pendingProfile;
    _pendingProfile = null;
    if (pending != null) {
      _service?.applySettings(pending);
    }
    setState(() {
      _running = false;
      _status = null;
      _discardThinkingPlaceholder();
    });
  }

  AgentSettings get _activeProfile {
    for (final p in _profiles) {
      if (p.id == _activeProfileId) return p;
    }
    return _profiles.isEmpty ? AgentSettings.defaults : _profiles.first;
  }

  Future<void> _switchChatProfile(String id) async {
    if (id == _activeProfileId) return;
    try {
      final bundle = await _settingsStore.selectProfile(id);
      if (!mounted) return;
      setState(() {
        _profiles = bundle.profiles;
        _activeProfileId = bundle.active.id;
      });
      if (_running) {
        _pendingProfile = bundle.active;
      } else {
        _pendingProfile = null;
        _service?.applySettings(bundle.active);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = '切换配置失败：$e');
    }
  }

  KeyEventResult _onInputKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final isEnter =
        event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter;
    if (!isEnter) return KeyEventResult.ignored;
    final shift =
        HardwareKeyboard.instance.logicalKeysPressed.contains(
          LogicalKeyboardKey.shiftLeft,
        ) ||
        HardwareKeyboard.instance.logicalKeysPressed.contains(
          LogicalKeyboardKey.shiftRight,
        );
    if (!chatEnterShouldSend(
      platform: defaultTargetPlatform,
      shiftPressed: shift,
      composing: _inputCtrl.value.composing.isValid,
    )) {
      return KeyEventResult.ignored;
    }
    unawaited(_send());
    return KeyEventResult.handled;
  }

  void _discardBlankAssistantDraft() {
    while (_items.isNotEmpty &&
        _items.last.kind == _ChatKind.assistant &&
        (_items.last.thinkingPlaceholder || _items.last.text.trim().isEmpty)) {
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

  String _compactRelativeTime(DateTime when) {
    final local = when.toLocal();
    final now = DateTime.now();
    final diff = now.difference(local);
    if (diff.inSeconds < 60) return '${diff.inSeconds.clamp(1, 59)}s';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m';
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(local.year, local.month, local.day);
    if (day == today) return '${diff.inHours.clamp(1, 23)}h';
    if (day == today.subtract(const Duration(days: 1))) return '昨天';
    if (local.year == now.year) return '${local.month}/${local.day}';
    return '${local.year}/${local.month}/${local.day}';
  }

  @override
  void dispose() {
    if (identical(ActiveWorkspaceHolder.current, widget.workspace)) {
      ActiveWorkspaceHolder.current = null;
    }
    _sitePollTimer?.cancel();
    unawaited(_siteGateway.stop());
    _askUserHost?.pending.removeListener(_onAskUserChanged);
    _askUserHost = null;
    unawaited(_backgroundUiSub?.cancel());
    unawaited(_service?.dispose() ?? Future.value());
    unawaited(widget.workspace.dispose());
    _inputCtrl.dispose();
    _inputFocus.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _closeDrawerIfOpen() {
    final scaffold = _scaffoldKey.currentState;
    if (scaffold?.isDrawerOpen == true) {
      Navigator.of(context).maybePop();
    }
  }

  Future<void> _onSelectProject(String path) async {
    await _switchProject(path);
  }

  Future<void> _onSelectConversation(String id) async {
    _closeDrawerIfOpen();
    await _switchConversation(id);
  }

  Widget _buildNavPanel({required bool showClose}) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
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
                        widget.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w600),
                      ),
                      Text(
                        '工作区导航',
                        style: Theme.of(context).textTheme.labelMedium
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                if (showClose)
                  IconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.of(context).maybePop(),
                    icon: const Icon(Icons.close),
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(child: _buildMergedNavBody(scheme)),
        ],
      ),
    );
  }

  Widget _headerIconButton({
    required String tooltip,
    required IconData icon,
    required VoidCallback? onPressed,
    Color? color,
  }) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Icon(icon, size: 20, color: color),
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.all(4),
      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
    );
  }

  Widget _buildProjectHeader(ColorScheme scheme, ProjectInfo project) {
    final active = project.path == _activeProjectPath;
    final site = project.site;
    final up = _siteUp[project.path] == true;
    final busy = _siteBusy.contains(project.path);
    final canAct = !_booting && !busy;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 0, 0),
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: _booting ? null : () => _onSelectProject(project.path),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 6, 4, 6),
                child: Row(
                  children: [
                    Icon(
                      active ? Icons.folder : Icons.folder_outlined,
                      size: 20,
                      color: active ? scheme.primary : scheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        project.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          _headerIconButton(
            tooltip: '终端',
            icon: Icons.terminal,
            onPressed: _booting
                ? null
                : () => unawaited(_openTerminalFor(project.path)),
          ),
          _headerIconButton(
            tooltip: '文件管理器',
            icon: Icons.folder_open_outlined,
            onPressed: _booting
                ? null
                : () => unawaited(_openFileBrowserFor(project.path)),
          ),
          busy
              ? const SizedBox(
                  width: 32,
                  height: 32,
                  child: Center(
                    child: SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                )
              : _headerIconButton(
                  tooltip: site == null
                      ? '尚未登记前端入口，让 Agent 调用 register_project_url'
                      : (up ? '停止项目' : '启动项目'),
                  icon: up ? Icons.stop : Icons.play_arrow,
                  color: site == null
                      ? scheme.onSurfaceVariant
                      : (up ? scheme.error : scheme.primary),
                  onPressed: canAct && site != null
                      ? () => unawaited(_toggleSiteFor(project.path))
                      : null,
                ),
          _headerIconButton(
            tooltip: '新会话',
            icon: Icons.add,
            onPressed: _booting
                ? null
                : () => unawaited(_newConversation(projectPath: project.path)),
          ),
        ],
      ),
    );
  }

  Widget _buildConversationTile(ColorScheme scheme, ConversationInfo c) {
    final selected = c.id == _activeConversationId;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 1, 8, 1),
      child: Material(
        color: selected ? scheme.surfaceContainerHighest : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => _onSelectConversation(c.id),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    c.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  _compactRelativeTime(c.updatedAt),
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                IconButton(
                  tooltip: '删除会话',
                  onPressed: () => _deleteConversation(c.id),
                  icon: const Icon(Icons.delete_outline, size: 18),
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.all(4),
                  constraints: const BoxConstraints(
                    minWidth: 28,
                    minHeight: 28,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMergedNavBody(ColorScheme scheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.only(bottom: 8),
            children: [
              if (_projects.isEmpty)
                ListTile(
                  title: Text(
                    '暂无项目',
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                  subtitle: const Text('点击下方「新项目」开始'),
                )
              else
                for (final p in _projects) ...[
                  _buildProjectHeader(scheme, p),
                  if (p.path == _activeProjectPath)
                    if (_conversations.isEmpty)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(36, 8, 16, 8),
                        child: Text(
                          '暂无会话',
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      )
                    else
                      for (final c in _conversations)
                        _buildConversationTile(scheme, c),
                ],
            ],
          ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
          child: FilledButton.tonalIcon(
            onPressed: _booting ? null : _createProject,
            icon: const Icon(Icons.create_new_folder_outlined),
            label: const Text('新项目'),
          ),
        ),
      ],
    );
  }

  Widget _buildProfileSwitcher(ColorScheme scheme) {
    final current = _activeProfile;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: PopupMenuButton<String>(
        tooltip: '切换模型配置',
        initialValue: current.id,
        enabled: _profiles.isNotEmpty,
        onSelected: _switchChatProfile,
        itemBuilder: (ctx) => [
          for (final p in _profiles)
            PopupMenuItem(
              value: p.id,
              child: Text(p.displayName, overflow: TextOverflow.ellipsis),
            ),
        ],
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, 8, 2, 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 96),
                child: Text(
                  current.displayName,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              Icon(
                Icons.arrow_drop_down,
                size: 20,
                color: scheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildChatColumn(ColorScheme scheme, bool hasChatContent) {
    return Column(
      children: [
        if (_status != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: GlassPanel(
              borderRadius: 16,
              tone: GlassTone.regular,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: SizedBox(width: double.infinity, child: Text(_status!)),
            ),
          ),
        Expanded(
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 840),
              child: _activeProjectPath == null
                  ? _EmptyProject(onCreate: _createProject)
                  : !hasChatContent
                  ? _EmptyChat(
                      mode: widget.mode,
                      onPrompt: (p) {
                        _inputCtrl.text = p;
                        _inputCtrl.selection = TextSelection.collapsed(
                          offset: p.length,
                        );
                      },
                    )
                  : ListView.builder(
                      controller: _scrollCtrl,
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                      itemCount: _items.length,
                      itemBuilder: (context, i) {
                        final item = _items[i];
                        return KeyedSubtree(
                          key: _chatItemKey(item, i),
                          child: _ChatBubble(item: item),
                        );
                      },
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
                  separatorBuilder: (_, _) => const SizedBox(width: 6),
                  itemBuilder: (context, i) {
                    final a = _pendingAttachments[i];
                    return InputChip(
                      label: Text(a.displayName),
                      onDeleted: _running
                          ? null
                          : () =>
                                setState(() => _pendingAttachments.removeAt(i)),
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
                    if (_askUserHost?.pending.value != null) ...[
                      AskUserPanel(
                        questionnaire:
                            _askUserHost!.pending.value!.questionnaire,
                        onSubmit: (answers) {
                          _askUserHost?.pending.value?.complete(
                            AskUserSubmission.ok(answers),
                          );
                        },
                      ),
                      const SizedBox(height: 8),
                    ],
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
                              focusNode: _inputFocus,
                              minLines: 1,
                              maxLines: 5,
                              enabled: !_running,
                              textInputAction: TextInputAction.newline,
                              keyboardType: TextInputType.multiline,
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
                            ),
                          ),
                          _buildProfileSwitcher(scheme),
                          Padding(
                            padding: const EdgeInsets.only(right: 4, bottom: 2),
                            child: IconButton.filled(
                              tooltip: _running ? '停止' : '发送',
                              onPressed: _running ? _cancel : _send,
                              icon: Icon(
                                _running ? Icons.stop_rounded : Icons.send,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      desktopEnterHint(defaultTargetPlatform)
                          ? '回车发送 · Shift+回车换行。重要操作执行前会请求确认。'
                          : '重要操作执行前会请求确认。',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
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

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final wide = MediaQuery.sizeOf(context).width >= 720;
    final hasChatContent = _items.isNotEmpty;

    final chatBody = _booting
        ? const Center(child: CircularProgressIndicator())
        : _buildChatColumn(scheme, hasChatContent);

    return AmbientBackdrop(
      child: Scaffold(
        key: _scaffoldKey,
        backgroundColor: Colors.transparent,
        drawer: wide
            ? null
            : Drawer(width: 300, child: _buildNavPanel(showClose: true)),
        appBar: AppBar(
          titleSpacing: 8,
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _activeProjectPath == null ? '新建项目以开始' : _conversationTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
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
          actions: [
            if (!wide)
              IconButton(
                tooltip: '工作区导航',
                onPressed: () => _scaffoldKey.currentState?.openDrawer(),
                icon: const Icon(Icons.menu_open),
              ),
            if (wide)
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Chip(
                  label: Text(() {
                    final bg = _service?.runningBackgroundJobCount ?? 0;
                    if (_running) return '运行中';
                    if (bg > 0) return '后台 $bg';
                    return '已连接';
                  }()),
                  avatar: Icon(
                    _running
                        ? Icons.sync
                        : (_service?.runningBackgroundJobCount ?? 0) > 0
                        ? Icons.hourglass_top_rounded
                        : Icons.check_circle,
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
              tooltip: '设置',
              onPressed: _openSettings,
              icon: const Icon(Icons.settings_outlined),
            ),
          ],
        ),
        body: wide
            ? Row(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(10, 0, 0, 10),
                    child: SizedBox(
                      width: 300,
                      child: GlassPanel(
                        borderRadius: 24,
                        tone: GlassTone.strong,
                        child: _buildNavPanel(showClose: false),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(child: chatBody),
                ],
              )
            : chatBody,
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

class _EmptyChat extends StatelessWidget {
  const _EmptyChat({required this.onPrompt, this.mode = WorkspaceMode.chat});

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

Key _chatItemKey(_ChatItem item, int index) {
  if (item.thinkingPlaceholder) return const ValueKey('thinking-placeholder');
  final callId = item.toolCallId;
  if (item.kind == _ChatKind.tool && callId != null && callId.isNotEmpty) {
    return ValueKey('tool-$callId');
  }
  return ValueKey('chat-$index-${item.kind.name}');
}

/// Centered muted line for site/workspace/background-task system hints.
class _SystemNotice extends StatelessWidget {
  const _SystemNotice({required this.text, this.isError = false});

  final String text;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = isError
        ? scheme.error.withValues(alpha: 0.68)
        : scheme.onSurfaceVariant.withValues(alpha: 0.62);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 8),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: Theme.of(
          context,
        ).textTheme.bodySmall?.copyWith(color: color, height: 1.35),
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

    if (item.thinkingPlaceholder) {
      return _ThinkingRow(label: item.text);
    }

    if (item.kind == _ChatKind.assistant && item.text.trim().isEmpty) {
      return const SizedBox.shrink();
    }

    if (item.kind == _ChatKind.status || item.kind == _ChatKind.error) {
      return _SystemNotice(
        text: item.text,
        isError: item.kind == _ChatKind.error,
      );
    }

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

    final contentColor = fg;
    final Widget body = _ChatMarkdown(data: item.text, color: contentColor);

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
        crossAxisAlignment: align,
        children: [
          ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.sizeOf(context).width * 0.88,
            ),
            child: bubble,
          ),
          if (meta.hasContent)
            Padding(
              padding: const EdgeInsets.only(top: 4, left: 4, right: 4),
              child: meta,
            ),
        ],
      ),
    );
  }
}

/// Token arrows + wall-clock time under a chat bubble.
class _ChatBubbleMeta extends StatelessWidget {
  const _ChatBubbleMeta({required this.item});

  /// Teal = input (↑), orange = output (↓).
  static const _inColor = Color(0xFF2A9D8F);
  static const _outColor = Color(0xFFE07A3D);

  final _ChatItem item;

  bool get hasContent {
    if (item.thinkingPlaceholder) return false;
    if (item.kind != _ChatKind.user && item.kind != _ChatKind.assistant) {
      return false;
    }
    final showIn = item.promptTokens != null && item.promptTokens! > 0;
    final showOut =
        item.kind == _ChatKind.assistant &&
        item.completionTokens != null &&
        item.completionTokens! > 0;
    return showIn || showOut || item.at != null;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final base = Theme.of(context).textTheme.labelSmall?.copyWith(
      color: scheme.onSurfaceVariant.withValues(alpha: 0.75),
      height: 1.1,
    );
    final children = <Widget>[];

    void addSep() {
      if (children.isEmpty) return;
      children.add(Text(' · ', style: base));
    }

    if (item.promptTokens != null && item.promptTokens! > 0) {
      children.add(
        _tokenChip(
          icon: Icons.arrow_upward_rounded,
          color: _inColor,
          label: _formatTokenCount(item.promptTokens!),
          style: base,
        ),
      );
    }
    if (item.kind == _ChatKind.assistant &&
        item.completionTokens != null &&
        item.completionTokens! > 0) {
      addSep();
      children.add(
        _tokenChip(
          icon: Icons.arrow_downward_rounded,
          color: _outColor,
          label: _formatTokenCount(item.completionTokens!),
          style: base,
        ),
      );
    }
    if (item.at != null) {
      addSep();
      children.add(Text(_formatClockTime(item.at!), style: base));
    }

    return Row(mainAxisSize: MainAxisSize.min, children: children);
  }

  Widget _tokenChip({
    required IconData icon,
    required Color color,
    required String label,
    required TextStyle? style,
  }) {
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

String _formatTokenCount(int n) {
  if (n >= 10000) return '${(n / 1000).round()}k';
  if (n >= 1000) {
    final v = n / 1000;
    final s = v.toStringAsFixed(1);
    return s.endsWith('.0') ? '${v.round()}k' : '${s}k';
  }
  return '$n';
}

String _formatClockTime(DateTime at) {
  final local = at.toLocal();
  final hh = local.hour.toString().padLeft(2, '0');
  final mm = local.minute.toString().padLeft(2, '0');
  final ss = local.second.toString().padLeft(2, '0');
  return '$hh:$mm:$ss';
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
    final String? output = result != null && !backgrounded
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

class _ThinkingRow extends StatelessWidget {
  const _ThinkingRow({required this.label});

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
  bool backgrounded = false,
}) {
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
