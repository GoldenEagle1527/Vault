import 'dart:async';

import 'package:dio/dio.dart';
import 'package:uuid/uuid.dart';
import 'package:vault/agent/agent_inbox.dart';
import 'package:vault/agent/agent_settings.dart';
import 'package:vault/agent/agent_system_prompt.dart';
import 'package:vault/agent/conversation_store.dart';
import 'package:vault/agent/tools/shell_tool.dart';
import 'package:vault/sandbox/sandbox_provider.dart';
import 'package:vault/sandbox/workspace_guest_fs.dart';
import 'package:vault_agent_core/vault_agent_core.dart';

/// UI-facing chat / tool step for the Agent screen.
sealed class AgentUiEvent {
  const AgentUiEvent();
}

class AgentUiUserMessage extends AgentUiEvent {
  const AgentUiUserMessage(this.text);
  final String text;
}

class AgentUiAssistantDelta extends AgentUiEvent {
  const AgentUiAssistantDelta(this.text);
  final String text;
}

class AgentUiAssistantFinal extends AgentUiEvent {
  const AgentUiAssistantFinal(this.text);
  final String text;
}

/// Drop a trailing whitespace-only assistant draft (common before tool calls).
class AgentUiDiscardDraftAssistant extends AgentUiEvent {
  const AgentUiDiscardDraftAssistant();
}

class AgentUiToolCall extends AgentUiEvent {
  const AgentUiToolCall({required this.name, required this.arguments});
  final String name;
  final String arguments;
}

class AgentUiToolResult extends AgentUiEvent {
  const AgentUiToolResult({required this.name, required this.result});
  final String name;
  final String result;
}

class AgentUiError extends AgentUiEvent {
  const AgentUiError(this.message);
  final String message;
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
    String? conversationId,
  })  : _workspace = workspace,
        _settings = settings,
        _shellTimeout = shellTimeout,
        _pendingState = initialState,
        _store = conversationStore,
        // AgentState.sessionId is the engine field for conversation id.
        _conversationId = conversationId ?? initialState?.sessionId;

  /// Open the workspace's active conversation (creating one if needed).
  static Future<AgentService> open({
    required SandboxWorkspace workspace,
    required AgentSettings settings,
    ConversationStore? conversationStore,
    SandboxProvider? sandboxProvider,
    Duration shellTimeout = kDefaultShellToolTimeout,
  }) async {
    final store = conversationStore ??
        (sandboxProvider != null
            ? ConversationStore(fs: SandboxWorkspaceGuestFs(sandboxProvider))
            : null);
    if (store == null) {
      throw StateError('需要 ConversationStore 或 SandboxProvider 以持久化会话');
    }
    final opened = await store.ensureActive(workspace.workspaceId);
    return AgentService(
      workspace: workspace,
      settings: settings,
      shellTimeout: shellTimeout,
      conversationStore: store,
      conversationId: opened.state.sessionId,
      initialState: opened.state,
    );
  }

  final SandboxWorkspace _workspace;
  AgentSettings _settings;
  final Duration _shellTimeout;
  final ConversationStore? _store;

  StatefulAgent? _agent;

  /// Held between settings reloads / conversation switches until [_ensureAgent].
  AgentState? _pendingState;
  String? _conversationId;
  CancelToken? _cancelToken;
  bool _running = false;

  /// Sandbox / workspace id (same value as [SandboxWorkspace.workspaceId]).
  String get workspaceId => _workspace.workspaceId;

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
    final unchanged = _settings.apiBaseUrl == settings.apiBaseUrl &&
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
    if (store == null) return;
    await store.save(workspaceId, state);
  }

  void _ensureAgent() {
    if (_agent != null) return;
    if (!_settings.isConfigured) {
      throw StateError('未配置 API Key 或模型');
    }

    final client = OpenAIClient(
      apiKey: _settings.apiKey,
      baseUrl: _normalizeBaseUrl(_settings.apiBaseUrl),
    );

    final conversationId = _conversationId ??
        _pendingState?.sessionId ??
        const Uuid().v4().replaceAll('-', '').substring(0, 12);
    _conversationId = conversationId;

    var state = _pendingState ??
        AgentState(
          sessionId: conversationId,
          metadata: {'workspaceId': workspaceId},
        );
    // Engine AgentState.sessionId == conversationId (not workspace id).
    if (state.sessionId != conversationId) {
      state.sessionId = conversationId;
    }
    state.metadata['workspaceId'] = workspaceId;
    _pendingState = null;

    _agent = StatefulAgent(
      name: 'vault_${workspaceId}_$conversationId',
      client: client,
      tools: [
        createShellTool(_workspace, timeout: _shellTimeout),
      ],
      modelConfig: ModelConfig(model: _settings.model),
      state: state,
      systemPrompts: vaultAgentSystemPrompts(workspaceId: workspaceId),
      controller: AgentController(),
      autoSaveStateFunc: _store == null
          ? null
          : (s) => _persistIfNeeded(s),
    );
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

  /// Persist current state (optional), then load [conversationId] as active.
  Future<void> switchConversation(
    String conversationId, {
    bool persistCurrent = true,
  }) async {
    await _waitUntilIdle();

    final store = _store;
    if (store == null) {
      throw StateError('未配置 ConversationStore，无法切换会话');
    }

    if (persistCurrent) {
      final current = _agent?.state ?? _pendingState;
      if (current != null) {
        await store.save(workspaceId, current);
      }
    }

    final state = await store.load(workspaceId, conversationId);
    await store.setActive(workspaceId, conversationId);
    _conversationId = conversationId;
    _pendingState = state;
    _agent = null;
  }

  /// Create a new empty conversation and make it active.
  Future<void> newConversation({bool persistCurrent = true}) async {
    final store = _store;
    if (store == null) {
      throw StateError('未配置 ConversationStore，无法新建会话');
    }
    await _waitUntilIdle();
    if (persistCurrent) {
      final current = _agent?.state ?? _pendingState;
      if (current != null) {
        await store.save(workspaceId, current);
      }
    }
    final created = await store.create(workspaceId);
    _conversationId = created.state.sessionId;
    _pendingState = created.state;
    _agent = null;
  }

  /// Runs one user turn; yields UI events until complete, cancelled, or failed.
  ///
  /// [attachments] are copied into the guest [kGuestInboxDir] before the model runs.
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

    final displayUser = trimmed.isEmpty ? '（仅附件）' : trimmed;
    yield AgentUiUserMessage(
      attachments.isEmpty
          ? displayUser
          : '$displayUser\n[附件 ${attachments.length} 个]',
    );

    try {
      List<String> guestPaths = const [];
      if (attachments.isNotEmpty) {
        yield const AgentUiStatus('正在把附件写入工作区 Linux…');
        guestPaths = await injectAttachmentsIntoInbox(_workspace, attachments);
        yield AgentUiStatus(
          '已写入 ${guestPaths.length} 个文件到 $kGuestInboxDir',
        );
      }

      yield const AgentUiStatus('正在思考…');
      _ensureAgent();
      final agent = _agent!;
      // Per model-turn buffer. Cleared on tool calls so preamble whitespace from
      // a tool-using turn does not prefix the final user-facing reply.
      final buffer = StringBuffer();

      final context = buildAttachmentContextMessage(guestPaths);
      final prompt = [
        if (context.isNotEmpty) context,
        if (trimmed.isNotEmpty) trimmed else '请查看附件并按我的意图处理（见上方 guest 路径）。',
      ].join('\n\n');

      await for (final event in agent.runStream(
        [UserMessage.text(prompt)],
        cancelToken: _cancelToken,
      )) {
        switch (event.eventType) {
          case StreamingEventType.modelChunkMessage:
            final chunk = event.data as ModelMessage;
            final text = chunk.textOutput;
            // Pass model text through unchanged.
            if (text != null && text.isNotEmpty) {
              buffer.write(text);
              yield AgentUiAssistantDelta(text);
            }
          case StreamingEventType.fullModelMessage:
            final full = event.data as ModelMessage;
            final text = full.textOutput;
            if (text != null && text.isNotEmpty && buffer.isEmpty) {
              buffer.write(text);
              yield AgentUiAssistantDelta(text);
            }
          case StreamingEventType.functionCallRequest:
            // End this model-turn's UI buffer. Do not rewrite text — only
            // choose whether the draft bubble stays (has content) or is dropped
            // (whitespace-only preamble before tools).
            for (final ui in _flushTurnBeforeTools(buffer)) {
              yield ui;
            }
            final calls = event.data;
            if (calls is List<FunctionCall>) {
              for (final call in calls) {
                yield AgentUiToolCall(
                  name: call.name,
                  arguments: call.arguments,
                );
                yield AgentUiStatus('正在执行工具：${call.name}');
              }
            } else if (calls is List) {
              for (final call in calls.whereType<FunctionCall>()) {
                yield AgentUiToolCall(
                  name: call.name,
                  arguments: call.arguments,
                );
                yield AgentUiStatus('正在执行工具：${call.name}');
              }
            }
          case StreamingEventType.functionCallResult:
            final data = event.data;
            if (data is FunctionExecutionResultMessage) {
              for (final r in data.results) {
                final text = r.content
                    .whereType<TextPart>()
                    .map((p) => p.text)
                    .join('\n');
                yield AgentUiToolResult(name: r.name, result: text);
              }
            }
          case StreamingEventType.modelRetrying:
            buffer.clear();
            yield const AgentUiDiscardDraftAssistant();
            yield const AgentUiStatus('正在调用模型…');
          case StreamingEventType.beforeCallModel:
            yield const AgentUiStatus('正在调用模型…');
        }
      }

      if (buffer.isNotEmpty) {
        yield AgentUiAssistantFinal(buffer.toString());
      }
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
    }
  }

  /// Close the current UI turn buffer when the model switches to tools.
  ///
  /// Model text is never rewritten. Whitespace-only drafts are discarded as a
  /// UI bubble (they are not the final answer); non-empty drafts are shown as-is.
  static Iterable<AgentUiEvent> _flushTurnBeforeTools(StringBuffer buffer) sync* {
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
    for (final m in messages) {
      if (m is UserMessage) {
        final text = m.contents
            .whereType<TextPart>()
            .map((p) => p.text)
            .join('\n')
            .trim();
        if (text.isNotEmpty) {
          out.add(AgentUiUserMessage(text));
        }
      } else if (m is ModelMessage) {
        final text = m.textOutput?.trim();
        if (text != null && text.isNotEmpty) {
          out.add(AgentUiAssistantFinal(text));
        }
        for (final call in m.functionCalls) {
          out.add(
            AgentUiToolCall(name: call.name, arguments: call.arguments),
          );
        }
      } else if (m is FunctionExecutionResultMessage) {
        for (final r in m.results) {
          final text = r.content
              .whereType<TextPart>()
              .map((p) => p.text)
              .join('\n');
          out.add(AgentUiToolResult(name: r.name, result: text));
        }
      }
    }
    return out;
  }

  void cancel() {
    final token = _cancelToken;
    if (token != null && !token.isCancelled) {
      token.cancel('用户取消');
    }
  }

  Future<void> dispose() async {
    cancel();
    final current = _agent?.state ?? _pendingState;
    if (current != null && _store != null) {
      try {
        await _store.save(workspaceId, current);
      } catch (_) {
        // Best-effort flush on leave.
      }
    }
    _agent = null;
    _pendingState = null;
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
    final cloudflare = lower.contains('cloudflare') ||
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
