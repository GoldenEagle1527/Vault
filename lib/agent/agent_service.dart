import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:uuid/uuid.dart';
import 'package:vault/agent/agent_inbox.dart';
import 'package:vault/agent/agent_settings.dart';
import 'package:vault/agent/agent_stream_mapper.dart';
import 'package:vault/agent/agent_system_prompt.dart';
import 'package:vault/agent/agent_ui_history_mapper.dart'
    as agent_ui_history_mapper;
import 'package:vault/agent/agent_ui_events.dart';
import 'package:vault/agent/hydrate_images_hook.dart';
import 'package:vault/agent/conversation_store.dart';
import 'package:vault/agent/project_site_launcher.dart';
import 'package:vault/agent/project_store.dart';
import 'package:vault/agent/site_gateway.dart';
import 'package:vault/agent/ask_user.dart';
import 'package:vault/agent/present_file.dart';
import 'package:vault/agent/conversation_state.dart';
import 'package:vault/agent/project_checkpoint.dart';
import 'package:vault/agent/tools/ask_user_tool.dart';
import 'package:vault/agent/tools/inspect_site_tool.dart';
import 'package:vault/agent/tools/manage_site_tool.dart';
import 'package:vault/agent/tools/present_file_tool.dart';
import 'package:vault/agent/tools/read_tool.dart';
import 'package:vault/agent/tools/scaffold_site_tool.dart';
import 'package:vault/agent/tools/shell_tool.dart';
import 'package:vault/agent/vault_host_device.dart';
import 'package:vault/agent/vault_meta_db.dart';
import 'package:vault/agent/workspace_mode.dart';
import 'package:vault/sandbox/sandbox_provider.dart';
import 'package:vault_agent_core/vault_agent_core.dart';

export 'package:vault/agent/agent_stream_mapper.dart';
export 'package:vault/agent/agent_ui_events.dart';
export 'package:vault/agent/agent_ui_history_mapper.dart';

/// Tool names [AgentService] mounts for a conversation. Site tools are dev-only.
List<String> vaultMountedToolNames({
  required WorkspaceMode mode,
  required bool hasProjectStore,
  required bool hasGateway,
}) {
  return [
    kAskUserToolName,
    kReadToolName,
    kPresentFileToolName,
    'shell',
    if (mode == WorkspaceMode.dev && hasProjectStore) ...[
      kScaffoldSiteToolName,
      kManageSiteToolName,
    ],
    if (mode == WorkspaceMode.dev && hasGateway) kInspectSiteToolName,
  ];
}

class _PendingShellNotify {
  const _PendingShellNotify({
    required this.job,
    required this.matchText,
    required this.regex,
  });
  final BackgroundToolJob job;
  final String matchText;
  final String regex;
}

/// Thin Vault adapter over vendored [StatefulAgent] + sandbox shell tool.
class AgentService {
  AgentService({
    required SandboxWorkspace workspace,
    required AgentSettings settings,
    Duration shellTimeout = kDefaultShellToolTimeout,
    AgentState? initialState,
    ConversationStore? conversationStore,
    ProjectStore? projectStore,
    String? conversationId,
    String? projectPath,
    WorkspaceMode mode = WorkspaceMode.chat,
    SiteGateway? siteGateway,
  }) : _workspace = workspace,
       _settings = settings,
       _shellTimeout = shellTimeout,
       _pendingState = initialState,
       _store = conversationStore,
       _projectStore = projectStore,
       _mode = mode,
       _siteGateway = siteGateway,
       _projectPath =
           projectPath ?? initialState?.metadata['projectPath'] as String?,
       // AgentState.sessionId is the engine field for conversation id.
       _conversationId = conversationId ?? initialState?.sessionId;

  /// Open the project's active conversation (creating one if needed).
  static Future<AgentService> open({
    required SandboxWorkspace workspace,
    required AgentSettings settings,
    required String projectPath,
    ConversationStore? conversationStore,
    ProjectStore? projectStore,
    VaultMetaDb? metaDb,
    Duration shellTimeout = kDefaultShellToolTimeout,
    WorkspaceMode mode = WorkspaceMode.chat,
    SiteGateway? siteGateway,
  }) async {
    final store =
        conversationStore ??
        (metaDb != null ? ConversationStore(metaDb: metaDb) : null);
    if (store == null) {
      throw StateError('需要 ConversationStore 或 VaultMetaDb 以持久化会话');
    }
    final opened = await store.ensureActive(workspace.workspaceId, projectPath);
    return AgentService(
      workspace: workspace,
      settings: settings,
      shellTimeout: shellTimeout,
      conversationStore: store,
      projectStore: projectStore,
      projectPath: projectPath,
      conversationId: opened.state.sessionId,
      initialState: opened.state,
      mode: mode,
      siteGateway: siteGateway,
    );
  }

  /// Service bound to a workspace with no active project yet.
  static AgentService withoutProject({
    required SandboxWorkspace workspace,
    required AgentSettings settings,
    ConversationStore? conversationStore,
    ProjectStore? projectStore,
    Duration shellTimeout = kDefaultShellToolTimeout,
    WorkspaceMode mode = WorkspaceMode.chat,
    SiteGateway? siteGateway,
  }) {
    return AgentService(
      workspace: workspace,
      settings: settings,
      shellTimeout: shellTimeout,
      conversationStore: conversationStore,
      projectStore: projectStore,
      mode: mode,
      siteGateway: siteGateway,
    );
  }

  final SandboxWorkspace _workspace;
  AgentSettings _settings;
  final Duration _shellTimeout;
  final ConversationStore? _store;
  final ProjectStore? _projectStore;
  final WorkspaceMode _mode;
  final SiteGateway? _siteGateway;
  final AskUserHost askUser = AskUserHost();

  StatefulAgent? _agent;

  /// Held between settings reloads / conversation switches until [_ensureAgent].
  AgentState? _pendingState;
  String? _conversationId;
  String? _projectPath;
  CancelToken? _cancelToken;
  bool _running = false;
  StreamSubscription<BackgroundToolJobEvent>? _backgroundSub;
  final List<BackgroundToolJob> _pendingCompletions = [];
  final List<_PendingShellNotify> _pendingNotifies = [];
  final StreamController<AgentUiEvent> _backgroundUi =
      StreamController<AgentUiEvent>.broadcast();
  late final AgentStreamMapper _streamMapper = AgentStreamMapper(
    runningBackgroundJobs: () => _agent?.backgroundJobs.runningJobs ?? const [],
  );
  bool _reactivationScheduled = false;

  bool get _hasPendingBackgroundWakeups =>
      _pendingCompletions.isNotEmpty || _pendingNotifies.isNotEmpty;

  /// Sandbox / workspace id (same value as [SandboxWorkspace.workspaceId]).
  String get workspaceId => _workspace.workspaceId;

  /// Events from idle background-task reactivation (listen alongside [run]).
  Stream<AgentUiEvent> get backgroundUiEvents => _backgroundUi.stream;

  /// Tools still running after the agent loop released them.
  int get runningBackgroundJobCount =>
      _agent?.backgroundJobs.runningJobs.length ?? 0;

  String? get projectPath => _projectPath;

  String? get conversationId => _conversationId;

  ConversationStore? get conversationStore => _store;

  bool get isRunning => _running;

  /// Messages currently in the agent conversation (including pending state).
  int get historyMessageCount =>
      (_agent?.state ?? _pendingState)?.history.messages.length ?? 0;

  AgentState? get currentState => _agent?.state ?? _pendingState;

  /// UI events reconstructed from persisted history (for screen hydrate).
  List<AgentUiEvent> get restoredUiEvents {
    final messages =
        (_agent?.state ?? _pendingState)?.history.messages ?? const [];
    return agent_ui_history_mapper.uiEventsFromHistory(messages);
  }

  String get conversationTitle {
    final messages =
        (_agent?.state ?? _pendingState)?.history.messages ?? const [];
    return ConversationStore.titleFromMessages(messages);
  }

  /// Apply new BYO settings without wiping conversation history.
  ///
  /// The live [StatefulAgent] is dropped so the next turn rebuilds the LLM
  /// client with the new credentials, but the same [AgentState] is reused.
  void applySettings(AgentSettings settings) {
    final unchanged =
        _settings.apiBaseUrl == settings.apiBaseUrl &&
        _settings.apiKey == settings.apiKey &&
        _settings.model == settings.model;
    _settings = settings;
    if (unchanged) return;

    final existing = _agent?.state;
    if (existing != null) {
      _pendingState = existing;
    }
    _agent = null;
  }

  Future<void> _persistIfNeeded(AgentState state) async {
    final store = _store;
    final projectPath = _projectPath;
    if (store == null || projectPath == null) return;
    await store.save(workspaceId, projectPath, state);
  }

  void _ensureAgent() {
    if (_agent != null) return;
    if (!_settings.isConfigured) {
      throw StateError('未配置 API Key 或模型');
    }
    final projectPath = _projectPath;
    if (projectPath == null) {
      throw StateError('请先创建或选择一个项目');
    }

    final client = OpenAIClient(
      apiKey: _settings.apiKey,
      baseUrl: _normalizeBaseUrl(_settings.apiBaseUrl),
    );

    final conversationId =
        _conversationId ??
        _pendingState?.sessionId ??
        const Uuid().v4().replaceAll('-', '').substring(0, 12);
    _conversationId = conversationId;

    var state =
        _pendingState ??
        AgentState(
          sessionId: conversationId,
          metadata: {'workspaceId': workspaceId, 'projectPath': projectPath},
        );
    // Engine AgentState.sessionId == conversationId (not workspace id).
    if (state.sessionId != conversationId) {
      state.sessionId = conversationId;
    }
    state.metadata['workspaceId'] = workspaceId;
    state.metadata['projectPath'] = projectPath;
    _pendingState = null;

    final projectStore = _projectStore;
    final gateway = _siteGateway;
    final tools = <Tool>[
      createAskUserTool(askUser, onPresent: _snapshotAskUserPresented),
      createReadTool(_workspace, projectPath: projectPath),
      createPresentFileTool(_workspace),
      createShellTool(
        _workspace,
        timeout: _shellTimeout,
        chatSessionId: conversationId,
        projectPath: projectPath,
      ),
      if (_mode == WorkspaceMode.dev && projectStore != null) ...[
        createScaffoldSiteTool(
          workspace: _workspace,
          projectStore: projectStore,
          workspaceId: workspaceId,
          projectPath: projectPath,
          gateway: gateway,
        ),
        createManageSiteTool(
          workspace: _workspace,
          launcher: ProjectSiteLauncher(_workspace),
          projectStore: projectStore,
          workspaceId: workspaceId,
          projectPath: projectPath,
          gateway: gateway,
        ),
      ],
      if (_mode == WorkspaceMode.dev && gateway != null)
        createInspectSiteTool(
          gateway: gateway,
          projectSites: () => _projectSites(projectPath),
          probeUp: (sites) => ProjectSiteLauncher(_workspace).probeAll(sites),
        ),
    ];

    _agent = StatefulAgent(
      name: 'vault_${workspaceId}_${projectPath}_$conversationId',
      client: client,
      tools: tools,
      modelConfig: ModelConfig(model: _settings.model),
      state: state,
      systemPrompts: vaultAgentSystemPrompts(
        workspaceId: workspaceId,
        projectPath: projectPath,
        mode: _mode,
        hostDevice: VaultHostDevice.current(),
      ),
      controller: AgentController(),
      hooks: [HydrateConversationImagesHook(_workspace.readGuestFile)],
      autoSaveStateFunc: _store == null ? null : (s) => _persistIfNeeded(s),
      toolBackgroundAfter: kAgentToolBackgroundAfter,
      withGeneralPrinciples: _mode != WorkspaceMode.dev,
    );
    _attachBackgroundJobListener(_agent!);
  }

  void _attachBackgroundJobListener(StatefulAgent agent) {
    unawaited(_backgroundSub?.cancel());
    _backgroundSub = agent.backgroundJobs.events.listen(_onBackgroundJobEvent);
  }

  void _onBackgroundJobEvent(BackgroundToolJobEvent event) {
    final job = event.job;
    switch (event.kind) {
      case BackgroundToolJobEventKind.backgrounded:
        return;
      case BackgroundToolJobEventKind.notified:
        final text = event.notifyText ?? '';
        final regex = event.notifyRegex ?? job.notifyRegex ?? '';
        _pendingNotifies.add(
          _PendingShellNotify(job: job, matchText: text, regex: regex),
        );
      case BackgroundToolJobEventKind.completed:
        _pendingCompletions.add(job);
    }
    if (!_backgroundUi.isClosed) {
      for (final uiEvent in _streamMapper.mapBackgroundJobEvent(
        event,
        runningJobCount: runningBackgroundJobCount,
      )) {
        _backgroundUi.add(uiEvent);
      }
    }
    if (!_running) {
      unawaited(_scheduleIdleReactivation());
    }
  }

  Future<void> _scheduleIdleReactivation() async {
    if (_reactivationScheduled) return;
    _reactivationScheduled = true;
    try {
      await Future<void>.delayed(Duration.zero);
      while (!_running && _hasPendingBackgroundWakeups) {
        if (!_settings.isConfigured) {
          _pendingCompletions.clear();
          _pendingNotifies.clear();
          return;
        }
        _running = true;
        _cancelToken = CancelToken();
        try {
          final stream = _pendingNotifies.isNotEmpty
              ? _reactivateWithShellNotifies()
              : _reactivateWithBackgroundResults();
          await for (final event in stream) {
            if (!_backgroundUi.isClosed) {
              _backgroundUi.add(event);
            }
          }
        } catch (e) {
          if (!_backgroundUi.isClosed) {
            _backgroundUi.add(AgentUiError(_mapError(e)));
          }
        } finally {
          _running = false;
          _cancelToken = null;
        }
      }
    } finally {
      _reactivationScheduled = false;
      if (!_running && _hasPendingBackgroundWakeups) {
        unawaited(_scheduleIdleReactivation());
      }
    }
  }

  Stream<AgentUiEvent> _reactivateWithShellNotifies() async* {
    final items = List<_PendingShellNotify>.from(_pendingNotifies);
    _pendingNotifies.clear();
    if (items.isEmpty) return;

    _ensureAgent();
    final agent = _agent!;
    final bufferMsg = StringBuffer()
      ..writeln('以下 shell 监控触发了 notify_regex（进程仍在运行）：');
    for (final item in items) {
      bufferMsg.writeln(
        buildShellNotifyMessage(
          jobId: item.job.jobId,
          callId: item.job.callId,
          toolName: item.job.toolName,
          regex: item.regex,
          matchText: item.matchText,
        ),
      );
    }
    final prompt = bufferMsg.toString().trim();
    yield AgentStreamMapper.systemNoticeEvent(
      prompt,
      fallback: 'shell 输出已匹配，进程仍在运行',
    );
    yield const AgentUiStatus('shell 匹配通知已送达，正在继续…');

    final buffer = StringBuffer();
    await for (final event in agent.runStream([
      UserMessage.text(prompt),
    ], cancelToken: _cancelToken)) {
      yield* _streamMapper.map(event, buffer);
    }
    if (buffer.isNotEmpty) {
      yield AgentUiAssistantFinal(buffer.toString());
    }
    // Jobs stay registered — process still running until completion.
    agent.backgroundJobs.syncReminders(agent.state.systemReminders);
    yield const AgentUiStatus('已完成');
  }

  Stream<AgentUiEvent> _reactivateWithBackgroundResults() async* {
    final jobs = List<BackgroundToolJob>.from(_pendingCompletions);
    _pendingCompletions.clear();
    if (jobs.isEmpty) return;

    _ensureAgent();
    final agent = _agent!;
    final prompt = buildBackgroundTaskResultMessage(jobs);
    yield AgentStreamMapper.systemNoticeEvent(prompt, fallback: '后台任务已结束');
    yield const AgentUiStatus('后台任务结果已送达，正在继续…');

    final buffer = StringBuffer();
    await for (final event in agent.runStream([
      UserMessage.text(prompt),
    ], cancelToken: _cancelToken)) {
      yield* _streamMapper.map(event, buffer);
    }
    if (buffer.isNotEmpty) {
      yield AgentUiAssistantFinal(buffer.toString());
    }
    for (final job in jobs) {
      agent.backgroundJobs.remove(job.jobId);
    }
    agent.backgroundJobs.syncReminders(agent.state.systemReminders);
    yield const AgentUiStatus('已完成');
  }

  /// Bind to [projectPath] and load its active conversation.
  Future<void> switchProject(
    String projectPath, {
    bool persistCurrent = true,
  }) async {
    await _waitUntilIdle();
    final store = _store;
    if (store == null) {
      throw StateError('未配置 ConversationStore，无法切换项目');
    }
    if (persistCurrent && _projectPath != null) {
      await _snapshotCurrent(
        kind: kCheckpointTurnEnd,
        index: historyMessageCount,
      );
      final current = _agent?.state ?? _pendingState;
      if (current != null) {
        await store.save(workspaceId, _projectPath!, current);
      }
    }
    final opened = await store.ensureActive(workspaceId, projectPath);
    _projectPath = projectPath;
    _conversationId = opened.state.sessionId;
    _pendingState = opened.state;
    _dropLiveAgent();
    await _restoreHead(opened.state);
  }

  /// Visible for tests: materialize the agent with current settings/state.
  void ensureAgentForTest() => _ensureAgent();

  Future<void> _waitUntilIdle() async {
    if (!_running) return;
    cancel();
    for (var i = 0; i < 50 && _running; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  ProjectCheckpointStore? get _checkpoints {
    final path = _projectPath;
    if (path == null) return null;
    return ProjectCheckpointStore(
      runGuest: (cmd) => _workspace.run(cmd),
      projectPath: path,
    );
  }

  Future<String?> _snapshotCurrent({
    required String kind,
    required int index,
  }) async {
    final checkpoints = _checkpoints;
    final id = _conversationId;
    final state = _agent?.state ?? _pendingState;
    if (checkpoints == null || id == null || state == null) return null;
    final sha = await checkpoints.snapshot(id);
    if (sha == null) return null;
    recordCheckpoint(state, index: index, sha: sha, kind: kind);
    final store = _store;
    final projectPath = _projectPath;
    if (store != null && projectPath != null) {
      await store.save(workspaceId, projectPath, state);
    }
    return sha;
  }

  Future<void> _snapshotAskUserPresented() {
    return _snapshotCurrent(
      kind: kCheckpointAskUser,
      index: historyMessageCount,
    );
  }

  Future<void> _restoreHead(AgentState state) async {
    final sha = headTreeShaOf(state);
    if (sha == null) return;
    await _checkpoints?.restore(sha);
  }

  void _dropLiveAgent() {
    askUser.cancelAll();
    _agent?.backgroundJobs.dispose();
    _agent = null;
  }

  /// Persist current state (optional), then load [conversationId] as active.
  Future<void> switchConversation(
    String conversationId, {
    bool persistCurrent = true,
  }) async {
    await _waitUntilIdle();

    final store = _store;
    final projectPath = _projectPath;
    if (store == null) {
      throw StateError('未配置 ConversationStore，无法切换会话');
    }
    if (projectPath == null) {
      throw StateError('请先创建或选择一个项目');
    }

    if (persistCurrent) {
      await _snapshotCurrent(
        kind: kCheckpointTurnEnd,
        index: historyMessageCount,
      );
      final current = _agent?.state ?? _pendingState;
      if (current != null) {
        await store.save(workspaceId, projectPath, current);
      }
    }

    final state = await store.load(workspaceId, projectPath, conversationId);
    await store.setActive(workspaceId, projectPath, conversationId);
    _conversationId = conversationId;
    _pendingState = state;
    _dropLiveAgent();
    await _restoreHead(state);
  }

  /// Create a new empty conversation and make it active.
  Future<void> newConversation({bool persistCurrent = true}) async {
    final store = _store;
    final projectPath = _projectPath;
    if (store == null) {
      throw StateError('未配置 ConversationStore，无法新建会话');
    }
    if (projectPath == null) {
      throw StateError('请先创建或选择一个项目');
    }
    await _waitUntilIdle();
    if (persistCurrent) {
      await _snapshotCurrent(
        kind: kCheckpointTurnEnd,
        index: historyMessageCount,
      );
      final current = _agent?.state ?? _pendingState;
      if (current != null) {
        await store.save(workspaceId, projectPath, current);
      }
    }
    final created = await store.create(workspaceId, projectPath);
    _conversationId = created.state.sessionId;
    _pendingState = created.state;
    _dropLiveAgent();
    await _restoreHead(created.state);
  }

  /// Edit a user message: keep the old conversation, fork, restore files, rerun.
  Stream<AgentUiEvent> forkAndRerun(int historyIndex, String newText) async* {
    await _waitUntilIdle();
    final store = _store;
    final projectPath = _projectPath;
    final parent = _agent?.state ?? _pendingState;
    if (store == null || projectPath == null || parent == null) {
      yield const AgentUiError('无法分叉会话');
      return;
    }
    if (historyIndex < 0 || historyIndex >= parent.history.messages.length) {
      yield const AgentUiError('找不到要修改的消息');
      return;
    }
    await _snapshotCurrent(
      kind: kCheckpointTurnEnd,
      index: historyMessageCount,
    );
    await store.save(workspaceId, projectPath, parent);
    final restoreSha = checkpointShaAt(
      parent,
      historyIndex,
      kind: kCheckpointUserTurn,
    );
    final forked = await store.fork(
      workspaceId: workspaceId,
      projectPath: projectPath,
      parentState: parent,
      keepCount: historyIndex,
      forkedFromMessageIndex: historyIndex,
    );
    _conversationId = forked.state.sessionId;
    _pendingState = forked.state;
    _dropLiveAgent();
    if (restoreSha != null) {
      await _checkpoints?.restore(restoreSha);
    }
    yield AgentUiConversationForked(forked.state.sessionId);
    yield* run(newText);
  }

  /// Reselect `ask_user` answers: fork, replace the tool result, continue.
  Stream<AgentUiEvent> forkAndResubmitAskUser({
    required List<AskUserAnswer> answers,
    int? historyIndex,
    String? callId,
  }) async* {
    await _waitUntilIdle();
    final store = _store;
    final projectPath = _projectPath;
    final parent = _agent?.state ?? _pendingState;
    if (store == null || projectPath == null || parent == null) {
      yield const AgentUiError('无法分叉会话');
      return;
    }
    final located = _locateAskUser(
      parent,
      historyIndex: historyIndex,
      callId: callId,
    );
    if (located == null) {
      yield const AgentUiError('找不到提问记录');
      return;
    }
    await _snapshotCurrent(
      kind: kCheckpointTurnEnd,
      index: historyMessageCount,
    );
    await store.save(workspaceId, projectPath, parent);
    final restoreSha = checkpointShaAt(
      parent,
      located.modelIndex,
      kind: kCheckpointAskUser,
    );
    final call = located.call;
    final forked = await store.fork(
      workspaceId: workspaceId,
      projectPath: projectPath,
      parentState: parent,
      keepCount: located.modelIndex + 1,
      forkedFromMessageIndex: located.resultIndex,
      mutate: (state) {
        state.history.messages.add(
          FunctionExecutionResultMessage(
            results: [
              FunctionExecutionResult(
                id: call.id,
                name: kAskUserToolName,
                isError: false,
                arguments: call.arguments,
                content: [
                  TextPart(
                    jsonEncode(AskUserSubmission.ok(answers).toToolResult()),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
    _conversationId = forked.state.sessionId;
    _pendingState = forked.state;
    _dropLiveAgent();
    if (restoreSha != null) {
      await _checkpoints?.restore(restoreSha);
    }
    yield AgentUiConversationForked(forked.state.sessionId);
    yield* continueFromHistory();
  }

  static ({int modelIndex, int resultIndex, FunctionCall call})? _locateAskUser(
    AgentState state, {
    int? historyIndex,
    String? callId,
  }) {
    final messages = state.history.messages;
    int? resultIndex;
    if (historyIndex != null &&
        historyIndex >= 0 &&
        historyIndex < messages.length &&
        messages[historyIndex] is FunctionExecutionResultMessage) {
      resultIndex = historyIndex;
    } else {
      for (var i = 0; i < messages.length; i++) {
        final m = messages[i];
        if (m is! FunctionExecutionResultMessage) continue;
        if (m.results.any(
          (r) =>
              r.name == kAskUserToolName && (callId == null || r.id == callId),
        )) {
          resultIndex = i;
          if (callId != null) break;
        }
      }
    }
    if (resultIndex == null) return null;
    for (var i = resultIndex; i >= 0; i--) {
      final m = messages[i];
      if (m is! ModelMessage) continue;
      for (final call in m.functionCalls) {
        if (call.name != kAskUserToolName) continue;
        if (callId != null && call.id != callId) continue;
        return (modelIndex: i, resultIndex: resultIndex, call: call);
      }
    }
    return null;
  }

  /// Continue the agent loop from the current persisted history (no new user turn).
  Stream<AgentUiEvent> continueFromHistory() async* {
    if (_running) {
      yield const AgentUiError('已有任务在运行，请先取消或等待结束');
      return;
    }
    if (!_settings.isConfigured) {
      yield const AgentUiError('请先在设置中配置 API Key 与模型');
      return;
    }
    _running = true;
    _cancelToken = CancelToken();
    try {
      yield const AgentUiStatus('正在思考…');
      _ensureAgent();
      final agent = _agent!;
      final buffer = StringBuffer();
      await for (final event in agent.runStream(
        const [],
        cancelToken: _cancelToken,
      )) {
        yield* _streamMapper.map(event, buffer);
      }
      if (buffer.isNotEmpty) {
        yield AgentUiAssistantFinal(buffer.toString());
      }
      while (_hasPendingBackgroundWakeups) {
        if (_cancelToken?.isCancelled ?? false) break;
        if (_pendingNotifies.isNotEmpty) {
          yield* _reactivateWithShellNotifies();
        } else {
          yield* _reactivateWithBackgroundResults();
        }
      }
      await _snapshotCurrent(
        kind: kCheckpointTurnEnd,
        index: historyMessageCount,
      );
      yield const AgentUiStatus('已完成');
    } on AgentException catch (e) {
      if (e.code == AgentExceptionCode.cancelled) {
        yield const AgentUiError('已取消');
      } else {
        yield AgentUiError(_mapError(e));
      }
    } on DioException catch (e) {
      yield AgentUiError(_mapDioError(e));
    } catch (e) {
      yield AgentUiError(_mapError(e));
    } finally {
      _running = false;
      _cancelToken = null;
      if (_hasPendingBackgroundWakeups) {
        unawaited(_scheduleIdleReactivation());
      }
    }
  }

  /// Runs one user turn; yields UI events until complete, cancelled, or failed.
  ///
  /// [attachments] are copied into the current project's `inbox/` before the
  /// model runs. Completions that arrive while this turn is active are drained
  /// at the end of the stream; later idle completions go to [backgroundUiEvents].
  Stream<AgentUiEvent> run(
    String userText, {
    List<AgentAttachment> attachments = const [],
  }) async* {
    if (_running) {
      yield const AgentUiError('已有任务在运行，请先取消或等待结束');
      return;
    }
    if (!_settings.isConfigured) {
      yield const AgentUiError('请先在设置中配置 API Key 与模型');
      return;
    }

    final trimmed = userText.trim();
    if (trimmed.isEmpty && attachments.isEmpty) {
      yield const AgentUiError('请输入内容或添加附件');
      return;
    }

    _running = true;
    _cancelToken = CancelToken();

    final turnIndex = historyMessageCount;
    await _snapshotCurrent(kind: kCheckpointUserTurn, index: turnIndex);

    try {
      var metas = const <ChatAttachmentMeta>[];
      if (attachments.isNotEmpty) {
        final projectPath = _projectPath;
        if (projectPath == null || projectPath.isEmpty) {
          yield const AgentUiError('请先新建或选择一个项目再添加附件');
          return;
        }
        yield const AgentUiStatus('正在把附件写入项目 inbox…');
        metas = await injectAttachmentsIntoInbox(
          _workspace,
          projectPath: projectPath,
          attachments: attachments,
        );
        yield AgentUiStatus(
          '已写入 ${metas.length} 个文件到 ${guestProjectInboxDir(projectPath)}',
        );
      }

      yield AgentUiUserMessage(
        userTurnDisplayText(trimmed),
        historyIndex: turnIndex,
        attachments: metas,
      );

      yield const AgentUiStatus('正在思考…');
      _ensureAgent();
      final agent = _agent!;
      final buffer = StringBuffer();

      final guestPaths = [for (final m in metas) m.guestPath];
      final context = buildAttachmentContextMessage(
        guestPaths,
        projectPath: _projectPath,
      );
      final prompt = composeModelUserPrompt(
        userText: trimmed,
        attachmentContext: context,
      );

      await for (final event in agent.runStream([
        UserMessage(
          [TextPart(prompt)],
          metadata: {
            if (metas.isNotEmpty)
              'attachments': metas.map((m) => m.toJson()).toList(),
          },
        ),
      ], cancelToken: _cancelToken)) {
        yield* _streamMapper.map(event, buffer);
      }

      if (buffer.isNotEmpty) {
        yield AgentUiAssistantFinal(buffer.toString());
      }

      // Drain wakeups that arrived during this turn before releasing the lock.
      while (_hasPendingBackgroundWakeups) {
        if (_cancelToken?.isCancelled ?? false) break;
        if (_pendingNotifies.isNotEmpty) {
          yield* _reactivateWithShellNotifies();
        } else {
          yield* _reactivateWithBackgroundResults();
        }
      }

      await _snapshotCurrent(
        kind: kCheckpointTurnEnd,
        index: historyMessageCount,
      );
      yield const AgentUiStatus('已完成');
    } on AgentException catch (e) {
      if (e.code == AgentExceptionCode.cancelled) {
        yield const AgentUiError('已取消');
      } else {
        yield AgentUiError(_mapError(e));
      }
    } on DioException catch (e) {
      yield AgentUiError(_mapDioError(e));
    } catch (e) {
      yield AgentUiError(_mapError(e));
    } finally {
      _running = false;
      _cancelToken = null;
      if (_hasPendingBackgroundWakeups) {
        unawaited(_scheduleIdleReactivation());
      }
    }
  }

  /// True when streamed model text should become a visible assistant bubble.
  static bool isVisibleAssistantText(String? text) =>
      AgentStreamMapper.isVisibleAssistantText(text);

  /// Chat-bubble text for a user turn (never includes hidden Vault context).
  static String userTurnDisplayText(String trimmed, {int attachmentCount = 0}) {
    if (trimmed.isNotEmpty) return trimmed;
    return '（仅附件）';
  }

  Future<List<ProjectUrlEntry>> _projectSites(String projectPath) async {
    final store = _projectStore;
    if (store == null) return const [];
    final project = await store.getProject(workspaceId, projectPath);
    final site = project?.site;
    return site == null ? const [] : [site];
  }

  /// Map persisted [LLMMessage] history into UI events for rehydrate.
  static List<AgentUiEvent> uiEventsFromHistory(List<LLMMessage> messages) =>
      agent_ui_history_mapper.uiEventsFromHistory(messages);

  void cancel() {
    askUser.cancelAll();
    final token = _cancelToken;
    if (token != null && !token.isCancelled) {
      token.cancel('用户取消');
    }
  }

  Future<void> dispose() async {
    cancel();
    await _backgroundSub?.cancel();
    _backgroundSub = null;
    _pendingCompletions.clear();
    _pendingNotifies.clear();
    final current = _agent?.state ?? _pendingState;
    final projectPath = _projectPath;
    if (current != null && _store != null && projectPath != null) {
      try {
        await _store.save(workspaceId, projectPath, current);
      } catch (_) {
        // Best-effort flush on leave.
      }
    }
    _agent?.backgroundJobs.dispose();
    _agent = null;
    _pendingState = null;
    if (!_backgroundUi.isClosed) {
      await _backgroundUi.close();
    }
  }

  /// Visible for unit tests. Prefer calling via settings save path in production.
  static String normalizeBaseUrlForTest(String raw) => _normalizeBaseUrl(raw);

  /// OpenAIClient appends `/chat/completions`, so the base must end with `/v1`
  /// (e.g. `https://apihub.example.com/v1`).
  static String _normalizeBaseUrl(String raw) {
    var url = raw.trim();
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    if (url.isEmpty) {
      return '${AgentSettings.defaults.apiBaseUrl}/v1';
    }
    // User pasted a full completions URL — strip the leaf.
    const leaf = '/chat/completions';
    if (url.endsWith(leaf)) {
      url = url.substring(0, url.length - leaf.length);
    }
    if (!url.endsWith('/v1')) {
      url = '$url/v1';
    }
    return url;
  }

  static String _mapDioError(DioException e) {
    if (CancelToken.isCancel(e)) {
      return '已取消';
    }
    final status = e.response?.statusCode;
    final body = _shortBody(e.response?.data);
    final mapped = _mapHttpStatus(status, body);
    if (mapped != null) return mapped;
    if (e.type == DioExceptionType.connectionTimeout ||
        e.type == DioExceptionType.sendTimeout ||
        e.type == DioExceptionType.receiveTimeout) {
      return '网络超时：请检查网络或 API 地址';
    }
    if (e.type == DioExceptionType.connectionError) {
      return '网络错误：无法连接 API（${e.message ?? e.type.name}）';
    }
    if (status != null) {
      return 'API 错误（$status）：${e.message ?? "请求失败"}';
    }
    return '网络错误：${e.message ?? e.toString()}';
  }

  static String _mapError(Object e) {
    final s = e.toString();
    final mapped = _mapHttpStatus(_extractStatusCode(s), s);
    if (mapped != null) return mapped;
    if (s.contains('沙箱') || s.toLowerCase().contains('sandbox')) {
      return '沙箱不可用：$s';
    }
    if (s.toLowerCase().contains('timeout')) {
      return '超时：${_shortBody(s)}';
    }
    return 'Agent 失败：${_shortBody(s)}';
  }

  static int? _extractStatusCode(String s) {
    final m = RegExp(r'\b([45]\d\d)\b').firstMatch(s);
    return m == null ? null : int.tryParse(m.group(1)!);
  }

  static String? _mapHttpStatus(int? status, String body) {
    final lower = body.toLowerCase();
    final cloudflare =
        lower.contains('cloudflare') ||
        lower.contains('attention required') ||
        lower.contains('cf-error');
    if (status == 403 && cloudflare) {
      return 'API 被网关拦截（403 Cloudflare）。请确认 Base URL 含 /v1'
          '（例如 https://apihub.example.com/v1），或检查该服务是否屏蔽当前网络/客户端。';
    }
    if (status == 401 || (status == 403 && !cloudflare)) {
      return '鉴权失败（$status）：请检查 API Key 是否正确';
    }
    if (status == 404) {
      return 'API 地址无效（404）：请检查 Base URL 是否为 …/v1';
    }
    return null;
  }

  static String _shortBody(Object? data) {
    final s = data?.toString() ?? '';
    if (s.isEmpty) return '';
    final oneLine = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (oneLine.toLowerCase().contains('<!doctype html') ||
        oneLine.toLowerCase().contains('<html')) {
      return '（网关返回了网页而非 JSON，多为错误的 URL 或被 Cloudflare 拦截）';
    }
    if (oneLine.length <= 240) return oneLine;
    return '${oneLine.substring(0, 240)}…';
  }
}
