import 'dart:async';

import 'package:dio/dio.dart';
import 'package:vault/agent/agent_inbox.dart';
import 'package:vault/agent/agent_settings.dart';
import 'package:vault/agent/agent_system_prompt.dart';
import 'package:vault/agent/tools/shell_tool.dart';
import 'package:vault/sandbox/sandbox_models.dart';
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
    required SandboxSession session,
    required AgentSettings settings,
    Duration shellTimeout = kDefaultShellToolTimeout,
  })  : _session = session,
        _settings = settings,
        _shellTimeout = shellTimeout;

  final SandboxSession _session;
  final AgentSettings _settings;
  final Duration _shellTimeout;

  StatefulAgent? _agent;
  CancelToken? _cancelToken;
  bool _running = false;

  bool get isRunning => _running;

  void _ensureAgent() {
    if (_agent != null) return;
    if (!_settings.isConfigured) {
      throw StateError('未配置 API Key 或模型');
    }

    final client = OpenAIClient(
      apiKey: _settings.apiKey,
      baseUrl: _normalizeBaseUrl(_settings.apiBaseUrl),
    );

    _agent = StatefulAgent(
      name: 'vault_${_session.sessionId}',
      client: client,
      tools: [
        createShellTool(_session, timeout: _shellTimeout),
      ],
      modelConfig: ModelConfig(model: _settings.model),
      state: AgentState.empty(),
      systemPrompts: vaultAgentSystemPrompts(sessionId: _session.sessionId),
      controller: AgentController(),
    );
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
      yield const AgentUiError('请输入任务内容或添加附件');
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
        yield const AgentUiStatus('正在把附件写入会话 Linux…');
        guestPaths = await injectAttachmentsIntoInbox(_session, attachments);
        yield AgentUiStatus(
          '已写入 ${guestPaths.length} 个文件到 $kGuestInboxDir',
        );
      }

      yield const AgentUiStatus('正在思考…');
      _ensureAgent();
      final agent = _agent!;
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
          case StreamingEventType.beforeCallModel:
          case StreamingEventType.modelRetrying:
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

  void cancel() {
    final token = _cancelToken;
    if (token != null && !token.isCancelled) {
      token.cancel('用户取消');
    }
  }

  Future<void> dispose() async {
    cancel();
    _agent = null;
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
