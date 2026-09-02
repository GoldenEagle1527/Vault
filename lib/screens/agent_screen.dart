import 'dart:async';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:vault/agent/agent_attachment_coordinator.dart';
import 'package:vault/agent/agent_chat_event_applier.dart';
import 'package:vault/agent/agent_chat_model.dart';
import 'package:vault/agent/agent_inbox.dart';
import 'package:vault/agent/agent_navigation_coordinator.dart';
import 'package:vault/agent/agent_service.dart';
import 'package:vault/agent/agent_settings.dart';
import 'package:vault/agent/agent_site_controller.dart';
import 'package:vault/agent/ask_user.dart';
import 'package:vault/agent/chat_input_keys.dart';
import 'package:vault/agent/conversation_state.dart';
import 'package:vault/agent/conversation_store.dart';
import 'package:vault/agent/project_site_launcher.dart';
import 'package:vault/agent/project_store.dart';
import 'package:vault/agent/site_gateway.dart';
import 'package:vault/agent/site_port.dart';
import 'package:vault/agent/workspace_mode.dart';
import 'package:vault/agent/workspace_store.dart';
import 'package:vault/permissions/active_workspace_holder.dart';
import 'package:vault/sandbox/android_keep_alive.dart';
import 'package:vault/sandbox/desktop_keep_alive.dart';
import 'package:vault/sandbox/keep_alive.dart';
import 'package:vault/sandbox/sandbox_provider.dart';
import 'package:vault/screens/agent/agent_dialogs.dart';
import 'package:vault/screens/agent/site_logs_screen.dart';
import 'package:vault/screens/agent/widgets/agent_chat_pane.dart';
import 'package:vault/screens/agent/widgets/agent_chat_widgets.dart';
import 'package:vault/screens/agent/widgets/agent_composer.dart';
import 'package:vault/screens/file_browser_screen.dart';
import 'package:vault/screens/agent/widgets/agent_navigation.dart';
import 'package:vault/screens/agent/widgets/agent_page_header.dart';
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

typedef _ChatItem = AgentChatItem;
typedef _ChatKind = AgentChatKind;

class _AgentScreenState extends State<AgentScreen> with WidgetsBindingObserver {
  late final AgentSettingsStore _settingsStore;
  late final ConversationStore _conversationStore;
  late final ProjectStore _projectStore;
  late final WorkspaceStore _workspaceStore;
  final SiteGateway _siteGateway = SiteGateway();
  final _inputCtrl = TextEditingController();
  late final FocusNode _inputFocus;
  final _scrollCtrl = ScrollController();
  late final AgentChatEventApplier _chat;
  late final AgentAttachmentCoordinator _attachments;
  late final AgentSiteController _siteController;
  final AgentNavigationCoordinator _navigationCoordinator =
      const AgentNavigationCoordinator();
  List<_ChatItem> get _items => _chat.items;
  List<AgentAttachment> get _pendingAttachments => _attachments.pending;
  String? get _status => _chat.status ?? _siteController.status;
  set _status(String? value) => _chat.status = value;
  bool _dragging = false;
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  AgentService? _service;
  List<ProjectInfo> _projects = const [];
  List<ConversationInfo> _conversations = const [];
  String? _activeProjectPath;
  String? _activeConversationId;
  String _conversationTitle = kNewConversationTitle;
  bool _running = false;
  bool _booting = true;
  bool _promptedNewProject = false;

  StreamSubscription<AgentUiEvent>? _backgroundUiSub;
  AskUserHost? _askUserHost;
  Map<String, bool> get _siteUp => _siteController.siteUp;
  Set<String> get _siteBusy => _siteController.siteBusy;
  bool _leaveConfirmInFlight = false;
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
    WidgetsBinding.instance.addObserver(this);
    _settingsStore = widget.settingsStore ?? AgentSettingsStore();
    _inputFocus = FocusNode(onKeyEvent: _onInputKeyEvent);
    _conversationStore = widget.conversationStore;
    _projectStore = widget.projectStore;
    _workspaceStore = WorkspaceStore(metaDb: _projectStore.metaDb);
    _chat = AgentChatEventApplier(
      onProjectUrlRegistered: () {
        unawaited(
          _refreshProjects().then((_) {
            if (!mounted) return;
            _siteController.invalidateProbe();
            unawaited(_refreshSiteStatus());
            setState(() {});
          }),
        );
      },
    );
    _attachments = AgentAttachmentCoordinator(
      provider: widget.provider,
      workspaceId: widget.workspace.workspaceId,
      activeProjectPath: () => _activeProjectPath,
      resolveCollision: _resolveInboxCollision,
      onChanged: () {
        if (mounted) setState(() {});
      },
    );
    _siteController = AgentSiteController(
      workspace: widget.workspace,
      projects: () => _projects,
      isMounted: () => mounted,
      onChanged: () {
        if (mounted) setState(() {});
      },
      publicUrl: _sitePublicUrl,
      beforeStart: (entry) async {
        await AndroidKeepAlive.ensurePermissions(
          context,
          forceBatteryPrompt: true,
        );
        await VaultKeepAlive.sync(siteNames: [entry.name]);
      },
      syncKeepAlive: (names) => VaultKeepAlive.sync(siteNames: names),
      onMessage: (message) {
        _items.add(
          _ChatItem(
            kind: message.isError ? _ChatKind.error : _ChatKind.status,
            text: message.text,
          ),
        );
        _scrollToEnd();
      },
    );
    ActiveWorkspaceHolder.current = widget.workspace;
    AndroidKeepAlive.bindNotificationActions();
    AndroidKeepAlive.onStopSiteRequested = _onNotificationStopSite;
    DesktopKeepAlive.instance.onForeground = () {
      unawaited(_onForegroundReturn());
    };
    _siteGateway.onBackendUnreachable = _siteController.noteUnreachable;
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
          siteController: _siteController,
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
          siteController: _siteController,
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
        unawaited(AndroidKeepAlive.ensurePermissions(context));
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
    if (!mounted) return;
    setState(() {});
    if (_askUserHost?.pending.value != null) {
      _scrollToEnd();
    }
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

  void _applyRestoredEvent(AgentUiEvent event) {
    _chat.applyRestored(event);
  }

  void _discardThinkingPlaceholder() {
    _chat.discardThinkingPlaceholder();
  }

  void _applyLiveEvent(AgentUiEvent event) {
    _chat.applyLive(event);
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
          siteController: _siteController,
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
          siteController: _siteController,
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
        siteController: _siteController,
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

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_onForegroundReturn());
    }
  }

  Future<void> _onForegroundReturn() async {
    if (!mounted || _booting) return;
    // A probe started before backgrounding can finish after resume with a
    // stale `down` result. Invalidate it before starting the foreground probe.
    _invalidateSiteProbe();
    try {
      await _ensureSiteGateway();
    } catch (_) {
      // Gateway may already be running; keep last routes.
    }
    await _refreshSiteStatus();
    await _syncKeepAliveNotification();
    await Future<void>.delayed(const Duration(milliseconds: 800));
    if (mounted && !_booting) {
      await _refreshSiteStatus();
    }
  }

  void _syncSitePoll() {
    _siteController.syncPolling(enabled: mounted && !_booting);
  }

  Future<void> _refreshSiteStatus() => _siteController.refreshStatus();

  void _invalidateSiteProbe() {
    _siteController.invalidateProbe();
  }

  Future<void> _startSite(
    ProjectUrlEntry entry, {
    required String projectPath,
  }) => _siteController.start(entry, projectPath: projectPath);

  Future<void> _stopSite(
    ProjectUrlEntry entry, {
    required String projectPath,
  }) => _siteController.stop(entry, projectPath: projectPath);

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

  Future<void> _openSiteLogsFor(String projectPath) async {
    if (_siteFor(projectPath) == null) return;
    _closeDrawerIfOpen();
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SiteLogsScreen(
          title: _siteFor(projectPath)?.name ?? projectPath,
          isServing: () => _siteUp[projectPath] == true,
          captureEnabled: widget.mode == WorkspaceMode.dev,
          loadProcessLog: () {
            final entry = _siteFor(projectPath);
            if (entry == null) return Future<String?>.value(null);
            return _siteController.launcher.readLogTail(
              projectPath: projectPath,
              entry: entry,
              maxLines: kSiteLogPageTailLines,
            );
          },
          loadEvents: () async {
            final slug = _siteFor(projectPath)?.slug?.trim();
            if (slug == null || slug.isEmpty) return const [];
            return _siteGateway.recentEvents(slug: slug);
          },
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

  Future<void> _openSiteUrl(String projectPath) async {
    final site = _siteFor(projectPath);
    if (site == null) return;
    final url = _sitePublicUrl(site).trim();
    if (url.isEmpty) return;
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
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

  void _showAttachNeedsProject() {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('请先新建或选择一个项目再添加附件')));
  }

  bool get _desktopDropEnabled {
    if (kIsWeb) return false;
    switch (defaultTargetPlatform) {
      case TargetPlatform.windows:
      case TargetPlatform.linux:
      case TargetPlatform.macOS:
        return true;
      default:
        return false;
    }
  }

  Future<String?> _resolveInboxCollision(String name, Set<String> taken) async {
    if (!mounted) return null;
    return resolveAgentInboxCollision(context, name: name, taken: taken);
  }

  Future<void> _offerAttachments(List<AgentAttachment> incoming) async {
    if (incoming.isEmpty) return;
    if (_activeProjectPath == null) {
      _showAttachNeedsProject();
      return;
    }
    await _attachments.offer(incoming);
  }

  Future<void> _pickFiles() async {
    if (_running) return;
    if (_activeProjectPath == null) {
      _showAttachNeedsProject();
      return;
    }
    await _offerAttachments(await _attachments.pickFiles());
  }

  Future<void> _onDropDone(DropDoneDetails details) async {
    setState(() => _dragging = false);
    if (_running) return;
    await _offerAttachments(_attachments.fromDrop(details));
  }

  Future<void> _handlePaste() async {
    if (_running) return;
    if (_activeProjectPath == null) {
      await _pastePlainText();
      return;
    }
    final fromClipboard = await _attachments.readClipboardAttachments();
    if (fromClipboard.isNotEmpty) {
      await _offerAttachments(fromClipboard);
      return;
    }
    await _pastePlainText();
  }

  Future<void> _pastePlainText() async {
    await _attachments.pastePlainText(_inputCtrl);
  }

  List<(String, ProjectUrlEntry)> get _runningSitePairs =>
      _siteController.runningPairs;

  Iterable<String> get _runningSiteNames => _siteController.runningNames;

  bool get _leaveNeedsConfirm => shouldConfirmLeaveWorkspace(
    agentRunning: _running,
    runningSiteNames: _runningSiteNames,
  );

  Future<void> _syncKeepAliveNotification() async {
    final pairs = _runningSitePairs;
    await VaultKeepAlive.sync(siteNames: _runningSiteNames);
  }

  void _onNotificationStopSite() {
    if (!mounted) return;
    unawaited(_stopAllRunningSites());
  }

  Future<void> _stopAllRunningSites() async {
    await _siteController.stopAll();
  }

  Future<bool> _confirmLeaveWorkspace() async {
    if (!_leaveNeedsConfirm) return true;
    if (_leaveConfirmInFlight) return false;
    _leaveConfirmInFlight = true;
    try {
      if (!mounted) return false;
      final ok = await confirmLeaveAgentWorkspace(
        context,
        message: leaveWorkspaceConfirmMessage(
          agentRunning: _running,
          runningSiteNames: _runningSiteNames,
        ),
        hasRunningSites: _runningSitePairs.isNotEmpty,
      );
      if (!ok) return false;
      if (_runningSitePairs.isNotEmpty) {
        await _stopAllRunningSites();
      }
      return true;
    } finally {
      _leaveConfirmInFlight = false;
    }
  }

  Future<bool> _confirmLeaveRunning() async {
    if (!_running) return true;
    return confirmSwitchRunningConversation(context);
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
    setState(() => _status = '正在恢复项目文件…');
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
    if (!await confirmDeleteAgentConversation(context)) return;

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

    await _consumeAgentStream(service.run(text, attachments: attachments));
  }

  Future<void> _consumeAgentStream(Stream<AgentUiEvent> stream) async {
    final service = _service;
    if (service == null) return;
    await for (final event in stream) {
      if (!mounted) return;
      if (event is AgentUiConversationForked) {
        await _refreshConversationList();
        _hydrateFromService();
        _conversationTitle = service.conversationTitle;
        setState(() {});
        _scrollToEnd();
        continue;
      }
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

  Future<void> _editUserMessage(_ChatItem item) async {
    final index = item.historyIndex;
    final service = _service;
    if (index == null || service == null || _running) return;
    final initial = displayTextFromStoredUserPrompt(item.text);
    final edited = await showDialog<String>(
      context: context,
      builder: (ctx) => AgentEditUserMessageDialog(initialText: initial),
    );
    if (edited == null || !mounted) return;
    final trimmed = edited.trim();
    if (trimmed.isEmpty || trimmed == initial) return;
    setState(() {
      _running = true;
      _status = null;
    });
    await _consumeAgentStream(service.forkAndRerun(index, trimmed));
  }

  Future<void> _reselectAskUser(_ChatItem item) async {
    final service = _service;
    if (service == null || _running) return;
    final q = AskUserQuestionnaire.tryParseArguments(item.toolArguments ?? '');
    if (q == null) return;
    final initial = AskUserAnswer.tryParseResult(item.toolResult ?? '');
    final answers = await showModalBottomSheet<List<AskUserAnswer>>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        return Padding(
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            top: 16,
            bottom: MediaQuery.viewInsetsOf(ctx).bottom + 16,
          ),
          child: SingleChildScrollView(
            child: AskUserPanel(
              questionnaire: q,
              initialAnswers: initial,
              onSubmit: (value) => Navigator.pop(ctx, value),
            ),
          ),
        );
      },
    );
    if (answers == null || !mounted) return;
    setState(() {
      _running = true;
      _status = null;
    });
    await _consumeAgentStream(
      service.forkAndResubmitAskUser(
        answers: answers,
        historyIndex: item.historyIndex,
        callId: item.toolCallId,
      ),
    );
  }

  Future<void> _copyText(String text, {String done = '已复制'}) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(done), duration: const Duration(seconds: 1)),
    );
  }

  Widget? _branchSwitcher(int? messageIndex) {
    final id = _activeConversationId;
    if (id == null || messageIndex == null) return null;
    final siblings = _conversationStore.branchesAt(
      conversations: _conversations,
      currentId: id,
      messageIndex: messageIndex,
    );
    if (siblings.isEmpty) return null;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Wrap(
        spacing: 6,
        children: [
          for (final c in siblings)
            ActionChip(
              label: Text(c.isBranch ? '分支 · ${c.title}' : c.title),
              visualDensity: VisualDensity.compact,
              onPressed: _running
                  ? null
                  : () => unawaited(_switchConversation(c.id)),
            ),
        ],
      ),
    );
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
    WidgetsBinding.instance.removeObserver(this);
    DesktopKeepAlive.instance.onForeground = null;
    AndroidKeepAlive.onStopSiteRequested = null;
    if (identical(ActiveWorkspaceHolder.current, widget.workspace)) {
      ActiveWorkspaceHolder.current = null;
    }
    _siteGateway.onBackendUnreachable = null;
    _siteController.dispose();
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

  Widget _buildNavPanel({required bool showClose}) {
    final model = _navigationCoordinator.build(
      projects: _projects,
      conversations: _conversations,
      activeProjectPath: _activeProjectPath,
      activeConversationId: _activeConversationId,
      siteUp: _siteUp,
      siteBusy: _siteBusy,
      booting: _booting,
    );
    return AgentNavigationPanel(
      title: widget.title,
      model: model,
      mode: widget.mode,
      showClose: showClose,
      onCreateProject: () => unawaited(_createProject()),
      onClose: () => Navigator.of(context).maybePop(),
      onSelectProject: (path) => unawaited(_switchProject(path)),
      onOpenSite: (path) => unawaited(_openSiteUrl(path)),
      onOpenLogs: (path) => unawaited(_openSiteLogsFor(path)),
      onOpenTerminal: (path) => unawaited(_openTerminalFor(path)),
      onOpenFiles: (path) => unawaited(_openFileBrowserFor(path)),
      onToggleSite: (path) => unawaited(_toggleSiteFor(path)),
      onNewConversation: (path) =>
          unawaited(_newConversation(projectPath: path)),
      onSelectConversation: (id) {
        _closeDrawerIfOpen();
        unawaited(_switchConversation(id));
      },
      onDeleteConversation: (id) => unawaited(_deleteConversation(id)),
    );
  }

  Widget _buildChatColumn() {
    final dropEnabled =
        _desktopDropEnabled &&
        !_running &&
        _activeProjectPath != null &&
        (ModalRoute.of(context)?.isCurrent ?? true);
    return AgentChatPane(
      status: _status,
      hasProject: _activeProjectPath != null,
      mode: widget.mode,
      items: _items,
      running: _running,
      subAgentCount: _service?.runningSubAgentCount ?? 0,
      provider: widget.provider,
      workspaceId: widget.workspace.workspaceId,
      scrollController: _scrollCtrl,
      pendingAttachments: _pendingAttachments,
      pendingAskUser: _askUserHost?.pending.value,
      inputController: _inputCtrl,
      inputFocus: _inputFocus,
      profileSwitcher: AgentProfileSwitcher(
        profiles: _profiles,
        activeProfileId: _activeProfileId,
        onSelected: _switchChatProfile,
      ),
      dropEnabled: dropEnabled,
      dragging: _dragging,
      onCreateProject: () => unawaited(_createProject()),
      onPrompt: (prompt) {
        _inputCtrl.text = prompt;
        _inputCtrl.selection = TextSelection.collapsed(offset: prompt.length);
      },
      onCopy: (item) => unawaited(_copyText(item.text)),
      onEdit: (item) => unawaited(_editUserMessage(item)),
      onReselectAskUser: (item) => unawaited(_reselectAskUser(item)),
      branchSwitcherBuilder: _branchSwitcher,
      onRemoveAttachment: (index) {
        setState(() => _pendingAttachments.removeAt(index));
      },
      onAskUserSubmit: (answers) {
        _askUserHost?.pending.value?.complete(AskUserSubmission.ok(answers));
      },
      onAttach: () => unawaited(_pickFiles()),
      onPaste: () => unawaited(_handlePaste()),
      onSend: () => unawaited(_send()),
      onCancel: _cancel,
      onDragEntered: () => setState(() => _dragging = true),
      onDragExited: () => setState(() => _dragging = false),
      onDropDone: (details) => unawaited(_onDropDone(details)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 720;
    final chatBody = _booting
        ? const Center(child: CircularProgressIndicator())
        : _buildChatColumn();

    final scaffold = Scaffold(
      key: _scaffoldKey,
      backgroundColor: Colors.transparent,
      drawer: wide
          ? null
          : Drawer(width: 300, child: _buildNavPanel(showClose: true)),
      appBar: AgentPageHeader(
        hasProject: _activeProjectPath != null,
        conversationTitle: _conversationTitle,
        projectName: _activeProjectName,
        workspaceTitle: widget.title,
        wide: wide,
        running: _running,
        onOpenNavigation: () => _scaffoldKey.currentState?.openDrawer(),
        onOpenSettings: () => unawaited(_openSettings()),
      ),
      body: chatBody,
    );

    final child = !wide
        ? AmbientBackdrop(child: scaffold)
        : AmbientBackdrop(
            child: Row(
              children: [
                SizedBox(
                  width: 300,
                  child: GlassPanel(
                    borderRadius: 0,
                    tone: GlassTone.strong,
                    child: _buildNavPanel(showClose: false),
                  ),
                ),
                Expanded(child: scaffold),
              ],
            ),
          );

    return PopScope(
      canPop: !_leaveNeedsConfirm,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final leave = await _confirmLeaveWorkspace();
        if (!leave || !mounted) return;
        Navigator.of(this.context).pop();
      },
      child: child,
    );
  }
}
