import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:uuid/uuid.dart';
import 'package:vault/agent/agent_inbox.dart';
import 'package:vault/agent/agent_settings.dart';
import 'package:vault/agent/agent_system_prompt.dart';
import 'package:vault/agent/conversation_store.dart';
import 'package:vault/agent/project_site_launcher.dart';
import 'package:vault/agent/project_store.dart';
import 'package:vault/agent/site_gateway.dart';
import 'package:vault/agent/system_notice.dart';
import 'package:vault/agent/ask_user.dart';
import 'package:vault/agent/conversation_state.dart';
import 'package:vault/agent/project_checkpoint.dart';
import 'package:vault/agent/tools/ask_user_tool.dart';
import 'package:vault/agent/tools/inspect_site_tool.dart';
import 'package:vault/agent/tools/project_url_tool.dart';
import 'package:vault/agent/tools/shell_tool.dart';
import 'package:vault/agent/vault_meta_db.dart';
import 'package:vault/agent/workspace_mode.dart';
import 'package:vault/sandbox/sandbox_provider.dart';
import 'package:vault_agent_core/vault_agent_core.dart';

/// UI-facing chat / tool step for the Agent screen.
sealed class AgentUiEvent {
  const AgentUiEvent();
}

class AgentUiUserMessage extends AgentUiEvent {
  const AgentUiUserMessage(
    this.text, {
    this.promptTokens,
    this.at,
    this.historyIndex,
  });
  final String text;
  final int? promptTokens;
  final DateTime? at;
  final int? historyIndex;
}

class AgentUiAssistantDelta extends AgentUiEvent {
  const AgentUiAssistantDelta(this.text);
  final String text;
}

class AgentUiAssistantFinal extends AgentUiEvent {
  const AgentUiAssistantFinal(
    this.text, {
    this.promptTokens,
    this.completionTokens,
    this.totalTokens,
    this.duration,
    this.at,
  });
  final String text;
  final int? promptTokens;
  final int? completionTokens;
  final int? totalTokens;
  final Duration? duration;
  final DateTime? at;
}

/// Token / latency stats for the latest model call (live stream).
class AgentUiModelUsage extends AgentUiEvent {
  const AgentUiModelUsage({
    required this.promptTokens,
    required this.completionTokens,
    this.totalTokens,
    this.duration,
    this.at,
  });
  final int promptTokens;
  final int completionTokens;
  final int? totalTokens;
  final Duration? duration;
  final DateTime? at;
}

/// Drop a trailing whitespace-only assistant draft (common before tool calls).
class AgentUiDiscardDraftAssistant extends AgentUiEvent {
  const AgentUiDiscardDraftAssistant();
}

class AgentUiToolCall extends AgentUiEvent {
  const AgentUiToolCall({
    required this.name,
    required this.arguments,
    this.callId,
    this.historyIndex,
  });
  final String name;
  final String arguments;
  final String? callId;
  final int? historyIndex;
}

class AgentUiToolResult extends AgentUiEvent {
  const AgentUiToolResult({
    required this.name,
    required this.result,
    this.callId,
    this.historyIndex,
  });
  final String name;
  final String result;
  final String? callId;
  final int? historyIndex;
}

/// Current conversation was replaced by a fork; UI should rehydrate.
class AgentUiConversationForked extends AgentUiEvent {
  const AgentUiConversationForked(this.conversationId);
  final String conversationId;
}

/// Tool exceeded the background threshold and is still running.
class AgentUiToolBackgrounded extends AgentUiEvent {
  const AgentUiToolBackgrounded({
    required this.name,
    required this.jobId,
    required this.callId,
    required this.stubResult,
  });
  final String name;
  final String jobId;
  final String callId;
  final String stubResult;
}

/// Previously backgrounded tool finished (UI card update; model may react next).
class AgentUiToolBackgroundCompleted extends AgentUiEvent {
  const AgentUiToolBackgroundCompleted({
    required this.name,
    required this.jobId,
    required this.callId,
    required this.result,
    required this.isError,
  });
  final String name;
  final String jobId;
  final String callId;
  final String result;
  final bool isError;
}

/// Shell notify_regex matched; process still running.
class AgentUiShellNotify extends AgentUiEvent {
  const AgentUiShellNotify({
    required this.jobId,
    required this.callId,
    required this.regex,
    required this.matchText,
  });
  final String jobId;
  final String callId;
  final String regex;
  final String matchText;
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

class AgentUiError extends AgentUiEvent {
  const AgentUiError(this.message);
  final String message;
}

/// Persistent system hint in the transcript (not a user/assistant bubble).
class AgentUiSystemNotice extends AgentUiEvent {
  const AgentUiSystemNotice(this.text, {this.isError = false});
  final String text;
  final bool isError;
}

class AgentUiStatus extends AgentUiEvent {
  const AgentUiStatus(this.message);
  final String message;
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
  DateTime? _modelCallStartedAt;
  StreamSubscription<BackgroundToolJobEvent>? _backgroundSub;
  final List<BackgroundToolJob> _pendingCompletions = [];
  final List<_PendingShellNotify> _pendingNotifies = [];
  final StreamController<AgentUiEvent> _backgroundUi =
      StreamController<AgentUiEvent>.broadcast();
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
    return uiEventsFromHistory(messages);
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
      createShellTool(
        _workspace,
        timeout: _shellTimeout,
        chatSessionId: conversationId,
        projectPath: projectPath,
      ),
      if (projectStore != null)
        ...createProjectUrlTools(
          projectStore: projectStore,
          workspaceId: workspaceId,
          projectPath: projectPath,
          workspace: _workspace,
          gateway: gateway,
        ),
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
      ),
      controller: AgentController(),
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
        if (!_backgroundUi.isClosed) {
          _backgroundUi.add(
            AgentUiShellNotify(
              jobId: job.jobId,
              callId: job.callId,
              regex: regex,
              matchText: text,
            ),
          );
          _backgroundUi.add(const AgentUiStatus('shell 输出已匹配，准备唤醒模型…'));
        }
      case BackgroundToolJobEventKind.completed:
        _pendingCompletions.add(job);
        if (!_backgroundUi.isClosed) {
          _backgroundUi.add(
            AgentUiToolBackgroundCompleted(
              name: job.toolName,
              jobId: job.jobId,
              callId: job.callId,
              result: job.resultText(),
              isError:
                  job.status == BackgroundToolJobStatus.failed ||
                  (job.result?.isError ?? false),
            ),
          );
          final n = runningBackgroundJobCount;
          _backgroundUi.add(AgentUiStatus(n == 0 ? '后台任务已完成' : '后台任务进行中：$n'));
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
    yield _systemNoticeEvent(prompt, fallback: 'shell 输出已匹配，进程仍在运行');
    yield const AgentUiStatus('shell 匹配通知已送达，正在继续…');

    final buffer = StringBuffer();
    await for (final event in agent.runStream([
      UserMessage.text(prompt),
    ], cancelToken: _cancelToken)) {
      yield* _mapStreamingEvent(event, buffer);
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
    yield _systemNoticeEvent(prompt, fallback: '后台任务已结束');
    yield const AgentUiStatus('后台任务结果已送达，正在继续…');

    final buffer = StringBuffer();
    await for (final event in agent.runStream([
      UserMessage.text(prompt),
    ], cancelToken: _cancelToken)) {
      yield* _mapStreamingEvent(event, buffer);
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

  Stream<AgentUiEvent> _mapStreamingEvent(
    StreamingEvent event,
    StringBuffer buffer,
  ) async* {
    switch (event.eventType) {
      case StreamingEventType.modelChunkMessage:
        final chunk = event.data as ModelMessage;
        final text = chunk.textOutput;
        if (isVisibleAssistantText(text)) {
          buffer.write(text);
          yield AgentUiAssistantDelta(text!);
        }
        if (chunk.functionCalls.isNotEmpty) {
          for (final ui in _flushTurnBeforeTools(buffer)) {
            yield ui;
          }
          for (final call in chunk.functionCalls) {
            if (call.id.isEmpty &&
                call.name.isEmpty &&
                call.arguments.isEmpty) {
              continue;
            }
            yield AgentUiToolCall(
              name: call.name,
              arguments: call.arguments,
              callId: call.id.isEmpty ? null : call.id,
            );
          }
        }
      case StreamingEventType.fullModelMessage:
        final full = event.data as ModelMessage;
        final text = full.textOutput;
        if (isVisibleAssistantText(text) && buffer.isEmpty) {
          buffer.write(text);
          yield AgentUiAssistantDelta(text!);
        }
        final usage = full.usage;
        final at = DateTime.fromMicrosecondsSinceEpoch(full.timestamp);
        final started = _modelCallStartedAt;
        final prompt = usage?.promptTokens ?? 0;
        final completion = usage?.completionTokens ?? 0;
        yield AgentUiModelUsage(
          promptTokens: prompt,
          completionTokens: completion,
          totalTokens: usage == null
              ? null
              : (usage.totalTokens > 0
                    ? usage.totalTokens
                    : prompt + completion),
          duration: started == null ? null : at.difference(started),
          at: at,
        );
      case StreamingEventType.functionCallRequest:
        for (final ui in _flushTurnBeforeTools(buffer)) {
          yield ui;
        }
        final calls = event.data;
        final list = calls is List<FunctionCall>
            ? calls
            : calls is List
            ? calls.whereType<FunctionCall>().toList()
            : const <FunctionCall>[];
        for (final call in list) {
          yield AgentUiToolCall(
            name: call.name,
            arguments: call.arguments,
            callId: call.id,
          );
          yield AgentUiStatus('正在执行工具：${call.name}');
        }
      case StreamingEventType.toolBackgrounded:
        final job = event.data;
        if (job is BackgroundToolJob) {
          yield AgentUiToolBackgrounded(
            name: job.toolName,
            jobId: job.jobId,
            callId: job.callId,
            stubResult: buildBackgroundToolStubText(
              toolName: job.toolName,
              jobId: job.jobId,
              callId: job.callId,
              threshold: kAgentToolBackgroundAfter,
              runningJobs: _agent?.backgroundJobs.runningJobs ?? [job],
            ),
          );
          final n = runningBackgroundJobCount;
          yield AgentUiStatus('工具已转后台：$n 个进行中');
        }
      case StreamingEventType.functionCallResult:
        final data = event.data;
        if (data is FunctionExecutionResultMessage) {
          for (final r in data.results) {
            final text = r.content
                .whereType<TextPart>()
                .map((p) => p.text)
                .join('\n');
            final meta = r.metadata;
            final isBackground =
                meta?['background'] == true ||
                text.contains('"monitoring":true') ||
                text.contains('"background":true');
            if (isBackground) {
              final jobId =
                  meta?['jobId']?.toString() ??
                  _jobIdFromToolJson(text) ??
                  r.id;
              yield AgentUiToolBackgrounded(
                name: r.name,
                jobId: jobId,
                callId: r.id,
                stubResult: text,
              );
              final n = runningBackgroundJobCount;
              if (n > 0) {
                yield AgentUiStatus('工具已转后台：$n 个进行中');
              }
              continue;
            }
            yield AgentUiToolResult(name: r.name, result: text, callId: r.id);
          }
        }
      case StreamingEventType.toolBackgroundCompleted:
        // Delivered via [backgroundJobs.events] → [_onBackgroundJobEvent].
        break;
      case StreamingEventType.modelRetrying:
        buffer.clear();
        _modelCallStartedAt = DateTime.now();
        yield const AgentUiDiscardDraftAssistant();
        yield const AgentUiStatus('正在调用模型…');
      case StreamingEventType.beforeCallModel:
        _modelCallStartedAt = DateTime.now();
        yield const AgentUiStatus('正在调用模型…');
    }
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
        yield* _mapStreamingEvent(event, buffer);
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
  /// [attachments] are copied into the guest [kGuestInboxDir] before the model runs.
  /// Completions that arrive while this turn is active are drained at the end
  /// of the stream; later idle completions go to [backgroundUiEvents].
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

    yield AgentUiUserMessage(
      userTurnDisplayText(trimmed, attachmentCount: attachments.length),
      historyIndex: turnIndex,
    );

    try {
      List<String> guestPaths = const [];
      if (attachments.isNotEmpty) {
        yield const AgentUiStatus('正在把附件写入工作区 Linux…');
        guestPaths = await injectAttachmentsIntoInbox(_workspace, attachments);
        yield AgentUiStatus('已写入 ${guestPaths.length} 个文件到 $kGuestInboxDir');
      }

      yield const AgentUiStatus('正在思考…');
      _ensureAgent();
      final agent = _agent!;
      final buffer = StringBuffer();

      final context = buildAttachmentContextMessage(
        guestPaths,
        projectPath: _projectPath,
      );
      final prompt = composeModelUserPrompt(
        userText: trimmed,
        attachmentContext: context,
      );

      await for (final event in agent.runStream([
        UserMessage.text(prompt),
      ], cancelToken: _cancelToken)) {
        yield* _mapStreamingEvent(event, buffer);
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

  static String? _jobIdFromToolJson(String text) {
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map && decoded['jobId'] != null) {
        return decoded['jobId'].toString();
      }
    } catch (_) {}
    return null;
  }

  static AgentUiSystemNotice _systemNoticeEvent(
    String raw, {
    required String fallback,
  }) {
    final notice = systemNoticeForUserText(raw);
    return AgentUiSystemNotice(
      notice?.text ?? fallback,
      isError: notice?.isError ?? false,
    );
  }

  /// True when streamed model text should become a visible assistant bubble.
  static bool isVisibleAssistantText(String? text) =>
      text != null && text.trim().isNotEmpty;

  /// Chat-bubble text for a user turn (never includes hidden Vault context).
  static String userTurnDisplayText(String trimmed, {int attachmentCount = 0}) {
    final display = trimmed.isEmpty ? '（仅附件）' : trimmed;
    if (attachmentCount == 0) return display;
    return '$display\n[附件 $attachmentCount 个]';
  }

  Future<List<ProjectUrlEntry>> _projectSites(String projectPath) async {
    final store = _projectStore;
    if (store == null) return const [];
    final project = await store.getProject(workspaceId, projectPath);
    final site = project?.site;
    return site == null ? const [] : [site];
  }

  /// Close the current UI turn buffer when the model switches to tools.
  ///
  /// Model text is never rewritten. Whitespace-only drafts are discarded as a
  /// UI bubble (they are not the final answer); non-empty drafts are shown as-is.
  static Iterable<AgentUiEvent> _flushTurnBeforeTools(
    StringBuffer buffer,
  ) sync* {
    final draft = buffer.toString();
    buffer.clear();
    if (draft.trim().isEmpty) {
      yield const AgentUiDiscardDraftAssistant();
      return;
    }
    yield AgentUiAssistantFinal(draft);
  }

  /// Map persisted [LLMMessage] history into UI events for rehydrate.
  static List<AgentUiEvent> uiEventsFromHistory(List<LLMMessage> messages) {
    final out = <AgentUiEvent>[];
    LLMMessage? prev;
    for (var i = 0; i < messages.length; i++) {
      final m = messages[i];
      if (m is UserMessage) {
        final raw = m.contents
            .whereType<TextPart>()
            .map((p) => p.text)
            .join('\n')
            .trim();
        if (raw.isNotEmpty) {
          final notice = systemNoticeForUserText(raw);
          if (notice != null) {
            out.add(AgentUiSystemNotice(notice.text, isError: notice.isError));
          } else {
            out.add(
              AgentUiUserMessage(
                displayTextFromStoredUserPrompt(raw),
                at: DateTime.fromMicrosecondsSinceEpoch(m.timestamp),
                historyIndex: i,
              ),
            );
          }
        }
      } else if (m is ModelMessage) {
        final usage = m.usage;
        final at = DateTime.fromMicrosecondsSinceEpoch(m.timestamp);
        final duration = _durationBetween(prev, m);
        final text = m.textOutput?.trim();
        if (text != null && text.isNotEmpty) {
          out.add(
            AgentUiAssistantFinal(
              text,
              promptTokens: usage?.promptTokens,
              completionTokens: usage?.completionTokens,
              totalTokens: usage == null
                  ? null
                  : (usage.totalTokens > 0
                        ? usage.totalTokens
                        : usage.promptTokens + usage.completionTokens),
              duration: duration,
              at: at,
            ),
          );
        } else if (usage != null &&
            (usage.promptTokens > 0 || usage.completionTokens > 0)) {
          out.add(
            AgentUiModelUsage(
              promptTokens: usage.promptTokens,
              completionTokens: usage.completionTokens,
              totalTokens: usage.totalTokens > 0
                  ? usage.totalTokens
                  : usage.promptTokens + usage.completionTokens,
              duration: duration,
              at: at,
            ),
          );
        }
        if (usage != null && usage.promptTokens > 0) {
          _attachPromptTokensToLastUserEvent(out, usage.promptTokens);
        }
        for (final call in m.functionCalls) {
          out.add(
            AgentUiToolCall(
              name: call.name,
              arguments: call.arguments,
              callId: call.id,
              historyIndex: i,
            ),
          );
        }
      } else if (m is FunctionExecutionResultMessage) {
        for (final r in m.results) {
          final text = r.content
              .whereType<TextPart>()
              .map((p) => p.text)
              .join('\n');
          final isBackground = r.metadata?['background'] == true;
          if (isBackground) {
            final jobId = r.metadata?['jobId']?.toString() ?? r.id;
            out.add(
              AgentUiToolBackgrounded(
                name: r.name,
                jobId: jobId,
                callId: r.id,
                stubResult: text,
              ),
            );
          } else {
            out.add(
              AgentUiToolResult(
                name: r.name,
                result: text,
                callId: r.id,
                historyIndex: i,
              ),
            );
          }
        }
      }
      prev = m;
    }
    return out;
  }

  static Duration? _durationBetween(LLMMessage? prev, ModelMessage next) {
    if (prev == null) return null;
    final prevTs = switch (prev) {
      UserMessage(:final timestamp) => timestamp,
      ModelMessage(:final timestamp) => timestamp,
      FunctionExecutionResultMessage(:final timestamp) => timestamp,
      _ => null,
    };
    if (prevTs == null || next.timestamp <= prevTs) return null;
    return Duration(microseconds: next.timestamp - prevTs);
  }

  static void _attachPromptTokensToLastUserEvent(
    List<AgentUiEvent> events,
    int promptTokens,
  ) {
    for (var i = events.length - 1; i >= 0; i--) {
      final e = events[i];
      if (e is AgentUiUserMessage) {
        if (e.promptTokens != null) return;
        events[i] = AgentUiUserMessage(
          e.text,
          promptTokens: promptTokens,
          at: e.at,
          historyIndex: e.historyIndex,
        );
        return;
      }
    }
  }

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
