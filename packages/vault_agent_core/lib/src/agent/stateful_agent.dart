import 'dart:async';
import 'dart:convert';
import 'package:vault_agent_core/src/agent/controller.dart';
import 'package:vault_agent_core/src/agent/events.dart';
import 'package:vault_agent_core/src/agent/exception.dart';
import 'package:vault_agent_core/src/agent/javascript_runtime.dart';
import 'package:vault_agent_core/src/agent/loop_detector.dart';
import 'package:vault_agent_core/src/agent/skill.dart';
import 'package:vault_agent_core/src/agent/sub_agent.dart';
import 'package:vault_agent_core/src/agent/util.dart';
import 'package:vault_agent_core/src/core/fs.dart';

import 'package:dio/dio.dart';
import 'package:logging/logging.dart';

import '../core/llm_client.dart';
import '../core/message.dart';
import '../core/tool.dart';
import 'agent_hook.dart';
import 'agent_model_call_logger.dart';
import 'agent_model_call_runner.dart';
import 'agent_run_phase_models.dart';
import 'agent_state.dart';
import 'agent_system_composer.dart';
import 'agent_tool_executor.dart';
import 'agent_tool_result.dart';
import 'background_tool_job.dart';
import 'background_tool_racer.dart';
import 'context_compressor.dart';
import 'planner.dart';

export 'agent_state.dart';
export 'agent_system_prompt.dart';
export 'agent_tool_result.dart';
export 'agent_hook.dart';

class StatefulAgent implements AgentHookHost {
  final Logger _logger = Logger('StatefulAgent');
  static const AgentSystemComposer _systemComposer = AgentSystemComposer();

  /// The human-readable name of the agent.
  final String name;

  /// Unique identifier generated for this agent instance.
  final String id = uuid.v4();

  /// The LLM client used to communicate with AI providers.
  final LLMClient client;

  /// Configuration for the LLM (model, temperature, etc.).
  final ModelConfig modelConfig;

  /// List of tools available to the agent.
  final List<Tool>? tools;

  /// List of system prompts that define the agent's behavior.
  final List<String> systemPrompts;

  /// Explicit instructions for tool selection.
  final ToolChoice? toolChoice;

  /// The current state of the agent.
  @override
  final AgentState state;

  /// Optional compressor for managing long contexts.
  final ContextCompressor? compressor;
  late final Planner _planner;

  /// The planning mode (auto, must, or null to disable).
  final PlanMode? planMode;

  /// Modular capabilities that can be activated/deactivated.
  final List<Skill>? skills;

  /// Directory-mode skills root path (SKILL.md).
  ///
  /// This mode is mutually exclusive with [skills].
  /// You must provide the agent with read, LS, and other file-operation tools yourself; otherwise directory skill functionality will not work.
  final String? skillDirectoryPath;
  final JavaScriptRuntime? javaScriptRuntime;
  final JavaScriptBridgeRegistry? javaScriptBridgeRegistry;

  /// Registered sub-agents for task delegation.
  final List<SubAgent>? subAgents;

  /// Whether to disable sub-agent delegation.
  final bool disableSubAgents;

  /// Whether to include general principles in the system message.
  final bool withGeneralPrinciples;

  /// Controller for intercepting agent events.
  final AgentController? controller;

  /// Ordered control pipeline for run/model/tool/persistence lifecycle phases.
  final List<AgentHook> hooks;
  late final AgentHookPipeline _hookPipeline;

  /// Whether this agent is running as a sub-agent.
  final bool isSubAgent;

  /// Mechanism for detecting infinite tool loops.
  late final LoopDetector loopDetector;

  /// Optional callback for persisting state on changes.
  final Function(AgentState state)? autoSaveStateFunc;

  /// Maximum number of hook-driven final-turn continuations allowed in a run.
  final int maxTurnContinuations;
  List<DirectorySkillMetadata> _directorySkills = [];
  late final JavaScriptBridgeRegistry _jsBridgeRegistry;

  /// Maximum number of turns (LLM calls) allowed in a single run.
  ///
  /// `null` means no hard turn cap. Infinite-loop protection relies on
  /// [loopDetector] (identical tool calls), not on raw turn count.
  final int? maxTurns;

  /// Wall-clock threshold after which an in-flight tool is detached from the
  /// agent loop (Cursor-style background task).
  ///
  /// `null` or [Duration.zero] disables auto-backgrounding.
  final Duration? toolBackgroundAfter;

  /// Jobs detached via [toolBackgroundAfter].
  final BackgroundToolJobRegistry backgroundJobs = BackgroundToolJobRegistry();
  late final AgentToolExecutor _toolExecutor;
  late final BackgroundToolRacer _backgroundToolRacer;
  late final AgentModelCallRunner _modelCallRunner;

  StatefulAgent({
    required this.name,
    List<String>? systemPrompts,
    required this.client,
    required this.modelConfig,
    required this.state,
    this.tools,
    this.toolChoice,
    this.compressor,
    this.planMode,
    this.skills,
    this.skillDirectoryPath,
    this.javaScriptRuntime,
    this.javaScriptBridgeRegistry,
    this.subAgents,
    this.withGeneralPrinciples = true,
    this.autoSaveStateFunc,
    this.controller,
    List<AgentHook>? hooks,
    LoopDetector? loopDetector,
    this.isSubAgent = false,
    this.disableSubAgents = false,
    this.maxTurnContinuations = 3,
    this.maxTurns,
    this.toolBackgroundAfter = const Duration(minutes: 1),
  }) : assert(
         skills == null ||
             skills.isEmpty ||
             skillDirectoryPath == null ||
             skillDirectoryPath == '',
         'skills and skillDirectoryPath cannot be enabled at the same time',
       ),
       hooks = hooks ?? const [],
       systemPrompts = systemPrompts ?? [] {
    _planner = Planner(this, controller);
    _jsBridgeRegistry = javaScriptBridgeRegistry ?? JavaScriptBridgeRegistry();
    _hookPipeline = AgentHookPipeline(this.hooks);
    _toolExecutor = AgentToolExecutor();
    _backgroundToolRacer = BackgroundToolRacer(registry: backgroundJobs);
    _modelCallRunner = AgentModelCallRunner(client: client);
    this.loopDetector =
        loopDetector ??
        DefaultLoopDetector(
          state: state,
          client: client,
          modelConfig: modelConfig,
        );
  }

  SystemMessage? composeSystemMessage() {
    return _systemComposer.composeSystemMessage(
      systemPrompts: systemPrompts,
      state: state,
      disableSubAgents: disableSubAgents,
      subAgents: subAgents,
      directorySkillModeEnabled: _isDirectorySkillModeEnabled,
      directorySkills: _directorySkills,
      javaScriptExecutionEnabled: javaScriptRuntime != null,
      skills: skills,
      withGeneralPrinciples: withGeneralPrinciples,
      planMode: planMode,
    );
  }

  List<Tool> composeTools() {
    return _systemComposer.composeTools(
      tools: tools,
      plannerTools: _planner.tools,
      planMode: planMode,
      state: state,
      skills: skills,
      directorySkillModeEnabled: _isDirectorySkillModeEnabled,
      javaScriptExecutor: javaScriptRuntime == null
          ? null
          : _runJavaScriptScript,
      disableSubAgents: disableSubAgents,
    );
  }

  bool get _isDirectorySkillModeEnabled =>
      (skillDirectoryPath?.trim().isNotEmpty ?? false);

  void registerJavaScriptBridgeChannel(
    String channel,
    JavaScriptBridgeHandler handler,
  ) {
    _jsBridgeRegistry.register(channel, handler);
  }

  void unregisterJavaScriptBridgeChannel(String channel) {
    _jsBridgeRegistry.unregister(channel);
  }

  Future<String> _runJavaScriptScript(
    String scriptPath,
    String? args,
    int? timeoutMs,
  ) async {
    if (!_isDirectorySkillModeEnabled) {
      return 'Error: directory skill mode is not enabled.';
    }
    if (javaScriptRuntime == null) {
      return 'Error: JavaScript runtime is not configured.';
    }
    if (!_isAbsolutePath(scriptPath)) {
      return 'Error: script_path must be an absolute path.';
    }

    final root = fsAbsolutePath(skillDirectoryPath!);
    final rootWithSep = root.endsWith(fsPathSeparator)
        ? root
        : '$root$fsPathSeparator';
    final resolvedAbsolute = fsAbsolutePath(scriptPath);
    if (resolvedAbsolute != root && !resolvedAbsolute.startsWith(rootWithSep)) {
      return 'Error: script path must stay under skillDirectoryPath.';
    }
    if (!resolvedAbsolute.toLowerCase().endsWith('.js')) {
      return 'Error: only .js script files are supported.';
    }
    if (!fsFileExistsSync(resolvedAbsolute)) {
      return 'Error: script file not found: $scriptPath';
    }
    Map<String, dynamic>? parsedArgs;
    if (args != null && args.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(args);
        if (decoded is Map) {
          parsedArgs = decoded.cast<String, dynamic>();
        } else {
          return 'Error: args must be a JSON object string.';
        }
      } catch (e) {
        return 'Error: failed to parse args as JSON object string: $e';
      }
    }

    final result = await javaScriptRuntime!.executeFile(
      scriptPath: resolvedAbsolute,
      args: parsedArgs,
      timeout: Duration(milliseconds: timeoutMs ?? 30000),
      bridgeRegistry: _jsBridgeRegistry,
      bridgeContext: JavaScriptBridgeContext(
        agentName: name,
        sessionId: state.sessionId,
        scriptPath: resolvedAbsolute,
        scriptArgs: parsedArgs ?? <String, dynamic>{},
      ),
    );

    return jsonEncode({
      'success': result.success,
      if (result.result != null) 'result': result.result,
      if (result.error != null) 'error': result.error,
      if (result.stdout.isNotEmpty) 'stdout': result.stdout,
      if (result.stderr.isNotEmpty) 'stderr': result.stderr,
    });
  }

  bool _isAbsolutePath(String path) {
    final isAbsolute =
        path.startsWith('/') || (path.length >= 2 && path[1] == ':');
    return isAbsolute;
  }

  Future<void> _prepareDirectorySkills(
    List<LLMMessage> incomingMessages,
  ) async {
    if (!_isDirectorySkillModeEnabled) return;

    final root = skillDirectoryPath!.trim();
    final loaded = await loadDirectorySkillsFromRoot(root);
    _directorySkills = loaded.skills;

    for (final error in loaded.errors) {
      _logger.warning(
        '[$name] directory skill load error (${error.path}): ${error.message}',
      );
    }

    if (_directorySkills.isEmpty) {
      _logger.info('[$name] no directory skills found under: $root');
      return;
    }

    final mentionedSkills = collectExplicitDirectorySkillMentions(
      incomingMessages,
      _directorySkills,
    );
    if (mentionedSkills.isEmpty) {
      return;
    }

    final injections = await buildDirectorySkillInjections(mentionedSkills);
    for (final warning in injections.warnings) {
      _logger.warning('[$name] $warning');
    }
    if (injections.items.isNotEmpty) {
      state.history.messages.addAll(injections.items);
      _logger.info(
        '[$name] injected ${injections.items.length} directory skill instruction message(s)',
      );
    }
  }

  Future<List<LLMMessage>> resume({
    CancelToken? cancelToken,
    bool useStream = true,
    int? maxTurns,
  }) async {
    if (!state.isRunning) {
      throw AgentException(
        AgentExceptionCode.resumeFailed,
        'Agent is not running',
      );
    }
    controller?.publish(AgentResumedEvent(this));
    return run(
      [],
      cancelToken: cancelToken,
      useStream: useStream,
      maxTurns: maxTurns,
    );
  }

  Stream<StreamingEvent> resumeStream({
    CancelToken? cancelToken,
    bool useStream = true,
    int? maxTurns,
  }) async* {
    if (!state.isRunning) {
      throw AgentException(
        AgentExceptionCode.resumeFailed,
        'Agent is not running',
      );
    }
    controller?.publish(AgentResumedEvent(this));
    yield* runStream(
      [],
      cancelToken: cancelToken,
      useStream: useStream,
      maxTurns: maxTurns,
    );
  }

  Future<List<LLMMessage>> run(
    List<LLMMessage> messages, {
    CancelToken? cancelToken,
    bool useStream = true,
    int? maxTurns,
  }) async {
    final streamResponse = runStream(
      messages,
      cancelToken: cancelToken,
      useStream: useStream,
      maxTurns: maxTurns,
    );
    final responses = <LLMMessage>[];
    await for (final event in streamResponse) {
      if (event.eventType == StreamingEventType.fullModelMessage ||
          event.eventType == StreamingEventType.functionCallResult) {
        responses.add(event.data);
      }
    }
    return responses;
  }

  Stream<StreamingEvent> runStream(
    List<LLMMessage> messages, {
    CancelToken? cancelToken,
    bool useStream = true,
    int? maxTurns,
  }) async* {
    AgentException? error;
    final modelMessages = <ModelMessage>[];
    var effectiveInput = List<LLMMessage>.from(messages);
    final currentMaxTurns = maxTurns ?? this.maxTurns;
    int currentRetryCount = 0;
    const int maxRetryCount = 3;
    int turnContinuationCount = 0;
    var stopReason = 'unknown';
    try {
      effectiveInput = await _prepareRunPhase(
        effectiveInput,
        useStream: useStream,
        cancelToken: cancelToken,
      );
      controller?.publish(AgentStartedEvent(this, effectiveInput));

      if (effectiveInput.isNotEmpty) {
        state.history.messages.addAll(effectiveInput);
      }
      await _prepareDirectorySkills(effectiveInput);
      state.currentLoopCount = 0;
      state.currentLoopUsages.clear();
      int? lastSystemPromptHash = _lastRecordedSystemPromptHash();
      int? lastToolsHash = _lastRecordedToolsHash();

      state.isRunning = true;
      state.lastError = null;
      while (true) {
        if (currentMaxTurns != null &&
            state.currentLoopCount >= currentMaxTurns) {
          throw AgentException(
            AgentExceptionCode.loopDetection,
            'Maximum turns reached ($currentMaxTurns). Possible infinite loop.',
          );
        }

        if (compressor != null) {
          await compressor!.compress(state);
        }

        final modelCall = await _prepareModelCallPhase(
          useStream: useStream,
          lastSystemPromptHash: lastSystemPromptHash,
          lastToolsHash: lastToolsHash,
          cancelToken: cancelToken,
        );
        lastSystemPromptHash = modelCall.systemPromptHash;
        lastToolsHash = modelCall.toolsHash;

        final modelCallRequest = modelCall.request;
        final params = modelCall.params;
        final syntheticModelResponse = modelCall.syntheticResponse;

        controller?.publish(BeforeCallLLMEvent(this, params));

        yield StreamingEvent(
          eventType: StreamingEventType.beforeCallModel,
          data: params,
        );

        if (cancelToken?.isCancelled ?? false) {
          throw AgentException(
            AgentExceptionCode.cancelled,
            'Agent cancelled by user',
            error: cancelToken!.cancelError,
          );
        }
        state.currentLoopCount++;
        state.totalLoopCount++;

        AgentModelCallCompleted? completedCall;
        await for (final callEvent in _modelCallRunner.run(
          params: params,
          model: modelConfig.model,
          syntheticResponse: syntheticModelResponse,
          cancelToken: cancelToken,
          processChunk: (chunk, {required detectLoop}) =>
              _applyModelChunkPhase(params, chunk, detectLoop: detectLoop),
        )) {
          switch (callEvent) {
            case AgentModelCallChunk():
              final chunk = callEvent.message;
              controller?.publish(LLMChunkEvent(this, params, chunk));
              yield StreamingEvent(
                eventType: StreamingEventType.modelChunkMessage,
                data: chunk,
              );
            case AgentModelCallRetry():
              final retryReason = callEvent.reason;
              _logger.warning(
                '[$name] 🔄 Model requested retry!, reason:$retryReason',
              );
              yield StreamingEvent(
                eventType: StreamingEventType.modelRetrying,
                data: callEvent.data,
              );
              controller?.publish(LLMRetryingEvent(this, retryReason));
            case AgentModelCallCompleted():
              completedCall = callEvent;
          }
        }
        final modelCallResult = completedCall!;

        if (modelCallResult.message.stopReason == null) {
          _logger.warning(
            '[$name] ⚠️ Model returned empty stop reason, retry again',
          );
          currentRetryCount++;
          if (currentRetryCount >= maxRetryCount) {
            throw AgentException(
              AgentExceptionCode.loopDetection,
              'Maximum consecutive empty stop reason retries reached ($maxRetryCount).',
            );
          }
          yield StreamingEvent(
            eventType: StreamingEventType.modelRetrying,
            data: {"retryReason": "Model returned empty stop reason"},
          );
          controller?.publish(
            LLMRetryingEvent(this, "Model returned empty stop reason"),
          );
          continue;
        }

        if (modelCallResult.isEmptyResponse) {
          _logger.warning(
            '[$name] ⚠️ Model returned empty response, retry again',
          );
          currentRetryCount++;
          if (currentRetryCount >= maxRetryCount) {
            throw AgentException(
              AgentExceptionCode.loopDetection,
              'Maximum consecutive empty response retries reached ($maxRetryCount).',
            );
          }
          yield StreamingEvent(
            eventType: StreamingEventType.modelRetrying,
            data: {"retryReason": "Model returned empty response"},
          );
          controller?.publish(
            LLMRetryingEvent(this, "Model returned empty response"),
          );
          continue;
        }

        var fullMessage = modelCallResult.message;

        final afterModel = await _applyAfterModelCallPhase(params, fullMessage);
        if (afterModel.shouldRetry) {
          currentRetryCount++;
          if (currentRetryCount >= maxRetryCount) {
            throw AgentException(
              AgentExceptionCode.loopDetection,
              'Maximum consecutive hook retries reached ($maxRetryCount).',
            );
          }
          final retryReason = afterModel.retryReason!;
          yield StreamingEvent(
            eventType: StreamingEventType.modelRetrying,
            data: {'retryReason': retryReason},
          );
          controller?.publish(LLMRetryingEvent(this, retryReason));
          continue;
        }
        fullMessage = afterModel.response!;
        currentRetryCount = 0;

        AgentModelCallLogger.log(_logger, name, fullMessage, isChunk: false);
        stopReason = fullMessage.stopReason ?? "unknown";

        controller?.publish(
          AfterCallLLMEvent(this, params, fullMessage, stopReason),
        );

        yield StreamingEvent(
          eventType: StreamingEventType.fullModelMessage,
          data: fullMessage,
        );
        modelMessages.add(fullMessage);

        if (fullMessage.usage != null) {
          state.usages.add(fullMessage.usage!);
          state.currentLoopUsages.add(fullMessage.usage!);
        }

        final toolCalls = fullMessage.functionCalls;
        if (toolCalls.isEmpty) {
          state.history.messages.add(fullMessage);

          final completion = await _applyTurnCompletionPhase(
            fullMessage,
            continuationCount: turnContinuationCount,
          );
          if (completion.shouldContinue) {
            turnContinuationCount++;
            state.history.messages.addAll(completion.messages);
            continue;
          }

          break;
        }

        yield StreamingEvent(
          eventType: StreamingEventType.functionCallRequest,
          data: toolCalls,
        );

        final toolPhase = await _executeToolCallPhase(
          toolCalls,
          modelMessage: fullMessage,
          availableTools: modelCallRequest.tools,
          cancelToken: cancelToken,
        );

        for (final job in toolPhase.backgroundedJobs) {
          yield StreamingEvent(
            eventType: StreamingEventType.toolBackgrounded,
            data: job,
          );
        }

        yield StreamingEvent(
          eventType: StreamingEventType.functionCallResult,
          data: toolPhase.message,
        );

        state.history.messages.addAll([fullMessage, toolPhase.message]);
        if (toolPhase.injectedMessages.isNotEmpty) {
          state.history.messages.addAll(toolPhase.injectedMessages);
        }
        await _persistState('afterToolCall');

        if (toolPhase.shouldStop) {
          _logger.info('[$name] 🤖 Stop flag hit, breaking loop');
          break;
        }

        if (cancelToken?.isCancelled ?? false) {
          _logger.warning(
            '[$name] 🤖 Agent run cancelled: ${cancelToken!.cancelError}',
          );
          throw AgentException(
            AgentExceptionCode.cancelled,
            'Agent cancelled by user',
            error: cancelToken.cancelError,
          );
        }

        // Loop continues to stream the NEXT response
      }
      state.isRunning = false;

      controller?.publish(
        AgentRunSuccessedEvent(this, effectiveInput, modelMessages, stopReason),
      );
    } on AgentException catch (e) {
      error = e;
      _logger.severe('[$name] ❌ Agent run failed: $e');
      rethrow;
    } on DioException catch (e) {
      state.lastError = e.error?.toString() ?? e.message;
      if (isCancelled(e)) {
        _logger.warning(
          '[$name] 🤖 Agent run cancelled: ${e.message}, reason: ${e.error?.toString()}',
        );
        controller?.publish(OnAgentCancelEvent(this, e, e.error?.toString()));
        error = AgentException(
          AgentExceptionCode.cancelled,
          'Agent cancelled by user, reason: ${e.error?.toString()}',
          error: e,
        );
        throw error;
      } else {
        _logger.severe('[$name] ❌ Agent run failed: $e');
        controller?.publish(OnAgentExceptionEvent(this, e));
        error = AgentException(
          AgentExceptionCode.unknown,
          'Agent run failed, msg: ${e.toString()}',
          error: e,
        );
        throw error;
      }
    } on Exception catch (e) {
      _logger.severe('[$name] ❌ Agent run failed: $e');
      state.lastError = e.toString();
      controller?.publish(OnAgentExceptionEvent(this, e));
      error = AgentException(
        AgentExceptionCode.unknown,
        'Agent run failed, msg: ${e.toString()}',
        error: e,
      );
      throw error;
    } on Error catch (e) {
      _logger.severe('[$name] ❌ Agent run failed: $e');
      state.lastError = e.toString();
      controller?.publish(OnAgentErrorEvent(this, e.toString()));
      error = AgentException(
        AgentExceptionCode.unknown,
        'Agent run failed, msg: ${e.toString()}',
        error: e,
      );
      throw error;
    } finally {
      await _hookPipeline.afterRun(
        AfterRunHookContext(
          this,
          input: effectiveInput,
          modelMessages: modelMessages,
          error: error,
        ),
      );
      await _persistState('finally', runError: error);
      controller?.publish(
        AgentStoppedEvent(this, effectiveInput, modelMessages, error: error),
      );
    }
  }

  Future<void> _persistState(String reason, {AgentException? runError}) async {
    final context = StatePersistenceHookContext(
      this,
      reason: reason,
      runError: runError,
    );
    final decision = await _hookPipeline.beforePersistState(context);
    switch (decision.action) {
      case StatePersistenceHookAction.abort:
        throw _hookAbortException(
          'beforePersistState',
          decision.error,
          decision.reason,
        );
      case StatePersistenceHookAction.skip:
        return;
      case StatePersistenceHookAction.proceed:
        if (autoSaveStateFunc != null) {
          await autoSaveStateFunc!(state);
        }
        await _hookPipeline.afterPersistState(context);
    }
  }

  Future<List<LLMMessage>> _prepareRunPhase(
    List<LLMMessage> input, {
    required bool useStream,
    required CancelToken? cancelToken,
  }) async {
    final beforeRun = await _hookPipeline.beforeRun(
      BeforeRunHookContext(
        this,
        input: input,
        stream: useStream,
        cancelToken: cancelToken,
      ),
    );
    if (beforeRun.action == BeforeRunHookAction.abort) {
      throw _hookAbortException('beforeRun', beforeRun.error, beforeRun.reason);
    }
    return List<LLMMessage>.from(beforeRun.input ?? input);
  }

  Future<PreparedModelCallPhase> _prepareModelCallPhase({
    required bool useStream,
    required int? lastSystemPromptHash,
    required int? lastToolsHash,
    required CancelToken? cancelToken,
  }) async {
    final requestMessages = List<LLMMessage>.from(state.history.messages);
    _injectSystemReminder(requestMessages);

    var modelCallRequest = ModelCallRequest(
      systemMessage: composeSystemMessage(),
      requestMessages: requestMessages,
      tools: composeTools(),
      toolChoice: toolChoice,
      modelConfig: modelConfig,
      stream: useStream,
    );

    final beforeModel = await _hookPipeline.beforeModelCall(
      ModelCallHookContext(
        this,
        request: modelCallRequest,
        turnIndex: state.currentLoopCount,
        cancelToken: cancelToken,
      ),
    );
    if (beforeModel.action == ModelCallHookAction.abort) {
      throw _hookAbortException(
        'beforeModelCall',
        beforeModel.error,
        beforeModel.reason,
      );
    }

    modelCallRequest = beforeModel.request ?? modelCallRequest;

    final hashes = _recordModelContextHistory(
      modelCallRequest,
      lastSystemPromptHash: lastSystemPromptHash,
      lastToolsHash: lastToolsHash,
    );

    return PreparedModelCallPhase(
      request: modelCallRequest,
      params: modelCallRequest.toCallLLMParams(),
      syntheticResponse: beforeModel.action == ModelCallHookAction.respond
          ? beforeModel.response
          : null,
      systemPromptHash: hashes.systemPromptHash,
      toolsHash: hashes.toolsHash,
    );
  }

  PromptToolHistoryHashes _recordModelContextHistory(
    ModelCallRequest request, {
    required int? lastSystemPromptHash,
    required int? lastToolsHash,
  }) {
    final currentSystemPromptHash =
        request.systemMessage?.content.hashCode ?? 0;
    final toolNames = request.tools.map((t) => t.name).toList()..sort();
    final currentToolsHash = toolNames.join(',').hashCode;

    if (lastSystemPromptHash == null ||
        currentSystemPromptHash != lastSystemPromptHash) {
      if (lastSystemPromptHash != null) {
        _logger.info(
          '[$name] 🔄 System Prompt changed! Hash: $lastSystemPromptHash -> $currentSystemPromptHash',
        );
      }
      state.systemPromptHistory.add(
        SystemPromptHistoryItem(
          content: request.systemMessage?.content ?? '',
          validFromMessageIndex: state.history.messages.length,
        ),
      );
    }

    if (lastToolsHash == null || currentToolsHash != lastToolsHash) {
      if (lastToolsHash != null) {
        _logger.info(
          '[$name] 🔄 Tools attributes changed! Hash: $lastToolsHash -> $currentToolsHash',
        );
      }
      state.toolsHistory.add(
        ToolsHistoryItem(
          tools: request.tools.map((t) => t.toJson()).toList(),
          validFromMessageIndex: state.history.messages.length,
        ),
      );
    }

    return PromptToolHistoryHashes(
      systemPromptHash: currentSystemPromptHash,
      toolsHash: currentToolsHash,
    );
  }

  int? _lastRecordedSystemPromptHash() {
    if (state.systemPromptHistory.isEmpty) {
      return null;
    }
    return state.systemPromptHistory.last.content.hashCode;
  }

  int? _lastRecordedToolsHash() {
    if (state.toolsHistory.isEmpty) {
      return null;
    }
    final toolNames =
        state.toolsHistory.last.tools
            .map((t) => t['name'] as String? ?? '')
            .toList()
          ..sort();
    return toolNames.join(',').hashCode;
  }

  Future<ModelMessage?> _applyModelChunkPhase(
    CallLLMParams params,
    ModelMessage chunk, {
    required bool detectLoop,
  }) async {
    final chunkResult = await _hookPipeline.onModelChunk(
      ModelChunkHookContext(this, params: params, chunk: chunk),
    );
    if (chunkResult.action == ModelChunkHookAction.abort) {
      throw _hookAbortException(
        'onModelChunk',
        chunkResult.error,
        chunkResult.reason,
      );
    }
    if (chunkResult.action == ModelChunkHookAction.drop) {
      return null;
    }

    final nextChunk = chunkResult.chunk ?? chunk;
    AgentModelCallLogger.log(_logger, name, nextChunk, isChunk: true);
    if (detectLoop) {
      final loopDetectResult = await loopDetector.detect(nextChunk);
      if (loopDetectResult.isLoop) {
        throw AgentException(
          AgentExceptionCode.loopDetection,
          'Loop detected, ${loopDetectResult.message}',
        );
      }
    }
    return nextChunk;
  }

  Future<AfterModelCallPhase> _applyAfterModelCallPhase(
    CallLLMParams params,
    ModelMessage response,
  ) async {
    final afterModel = await _hookPipeline.afterModelCall(
      ModelResponseHookContext(this, params: params, response: response),
    );
    switch (afterModel.action) {
      case ModelResponseHookAction.abort:
        throw _hookAbortException(
          'afterModelCall',
          afterModel.error,
          afterModel.reason,
        );
      case ModelResponseHookAction.retry:
        return AfterModelCallPhase.retry(
          afterModel.retryReason ?? 'Hook requested retry',
        );
      case ModelResponseHookAction.proceed:
        return AfterModelCallPhase.proceed(afterModel.response ?? response);
    }
  }

  Future<TurnCompletionPhase> _applyTurnCompletionPhase(
    ModelMessage finalMessage, {
    required int continuationCount,
  }) async {
    if (continuationCount >= maxTurnContinuations) {
      if (!_hookPipeline.isEmpty) {
        _logger.warning(
          '[$name] turn-completion continuation budget exhausted '
          '($maxTurnContinuations); accepting completion.',
        );
      }
      return const TurnCompletionPhase.accept();
    }

    final completion = await _hookPipeline.onTurnCompletion(
      TurnCompletionHookContext(
        this,
        finalMessage: finalMessage,
        continuationCount: continuationCount,
        maxContinuations: maxTurnContinuations,
      ),
    );
    if (completion.action == TurnCompletionHookAction.abort) {
      throw _hookAbortException(
        'onTurnCompletion',
        completion.error,
        completion.reason,
      );
    }
    if (completion.action == TurnCompletionHookAction.continueRun &&
        completion.messages.isNotEmpty) {
      return TurnCompletionPhase.continueWith(completion.messages);
    }
    return const TurnCompletionPhase.accept();
  }

  Future<ToolCallPhase> _executeToolCallPhase(
    List<FunctionCall> toolCalls, {
    required ModelMessage modelMessage,
    required List<Tool> availableTools,
    required CancelToken? cancelToken,
  }) async {
    _logger.info(
      '[$name] 🔧 Executing tools\n:  ${toolCalls.map((e) => '${e.name}: ${e.arguments}').join("\n  ")}',
    );

    final callsToExecute = <FunctionCall>[];
    final syntheticResults = <String, ExecutionToolResult>{};
    for (final toolCall in toolCalls) {
      controller?.publish(BeforeToolCallEvent(this, toolCall));
      final beforeTool = await _hookPipeline.beforeToolCall(
        ToolCallHookContext(
          this,
          call: toolCall,
          modelMessage: modelMessage,
          availableTools: availableTools,
        ),
      );
      switch (beforeTool.action) {
        case ToolCallHookAction.abort:
          throw _hookAbortException(
            'beforeToolCall',
            beforeTool.error,
            beforeTool.reason,
          );
        case ToolCallHookAction.deny:
        case ToolCallHookAction.defer:
          syntheticResults[toolCall.id] = _syntheticToolResult(
            toolCall,
            beforeTool,
          );
        case ToolCallHookAction.proceed:
          callsToExecute.add(beforeTool.call ?? toolCall);
      }
    }

    final executed = callsToExecute.isEmpty
        ? const AgentToolExecutionBatch()
        : await _toolExecutor.execute(
            calls: callsToExecute,
            tools: availableTools,
            state: state,
            createCallContext:
                ({required batchCallId, required call, cancelToken}) =>
                    AgentCallToolContext(
                      state: state,
                      agent: this,
                      batchCallId: batchCallId,
                      callId: call.id,
                      toolName: call.name,
                      cancelToken: cancelToken,
                    ),
            agentName: name,
            cancelToken: cancelToken,
            backgroundAfter: toolBackgroundAfter,
            backgroundRacer: _backgroundToolRacer,
          );
    final executedById = {for (final r in executed.results) r.id: r};
    final toolExecutionResults = toolCalls
        .map((c) => executedById[c.id] ?? syntheticResults[c.id]!)
        .toList();
    final functionExecutionResults = toolExecutionResults.map((result) {
      return FunctionExecutionResult(
        id: result.id,
        name: result.name,
        isError: result.isError,
        arguments: result.arguments,
        content: result.content,
        metadata: result.metadata,
      );
    }).toList();

    final finalFunctionExecutionResults = <FunctionExecutionResult>[];
    final injectedMessages = <LLMMessage>[];
    var stopByHook = false;
    for (final toolResult in functionExecutionResults) {
      final afterTool = await _hookPipeline.afterToolCall(
        ToolResultHookContext(
          this,
          result: toolResult,
          modelMessage: modelMessage,
        ),
      );
      if (afterTool.action == ToolResultHookAction.abort) {
        throw _hookAbortException(
          'afterToolCall',
          afterTool.error,
          afterTool.reason,
        );
      }
      final finalToolResult = afterTool.result ?? toolResult;
      finalFunctionExecutionResults.add(finalToolResult);
      injectedMessages.addAll(afterTool.injectedMessages);
      if (afterTool.action == ToolResultHookAction.stop) {
        stopByHook = true;
      }
      controller?.publish(AfterToolCallEvent(this, finalToolResult));
    }

    _logger.info(
      '[$name] 🔧 Executed tools\n: ${finalFunctionExecutionResults.map((e) => '${e.name}: Success:${e.isError ? '❌ No' : '✅ Yes'}').join("\n  ")}',
    );

    return ToolCallPhase(
      message: FunctionExecutionResultMessage(
        results: finalFunctionExecutionResults,
      ),
      injectedMessages: injectedMessages,
      shouldStop:
          stopByHook || toolExecutionResults.any((result) => result.stopFlag),
      backgroundedJobs: executed.backgroundedJobs,
    );
  }

  ExecutionToolResult _syntheticToolResult(
    FunctionCall call,
    ToolCallHookResult result,
  ) {
    final supplied = result.syntheticResult;
    if (supplied != null) {
      return ExecutionToolResult(
        id: call.id,
        name: supplied.name,
        arguments: supplied.arguments,
        content: supplied.content,
        metadata: supplied.metadata,
        stopFlag: supplied.stopFlag,
        isError: supplied.isError,
      );
    }
    final actionText = result.action == ToolCallHookAction.defer
        ? 'deferred by hook'
        : 'denied by hook';
    return ExecutionToolResult(
      id: call.id,
      name: call.name,
      arguments: call.arguments,
      content:
          result.syntheticContent ??
          [TextPart('Tool call ${call.name} $actionText.')],
      metadata: result.metadata,
      isError: result.syntheticIsError,
    );
  }

  AgentException _hookAbortException(
    String phase,
    Exception? error,
    String? reason,
  ) {
    final suffix = reason == null || reason.isEmpty ? '' : ': $reason';
    return AgentException(
      AgentExceptionCode.stopByController,
      'Agent hook aborted at $phase$suffix',
      error: error,
    );
  }

  bool isSuspend(DioException error) {
    if (CancelToken.isCancel(error) && error.message == "Suspend") {
      return true;
    }
    return false;
  }

  bool isCancelled(Object error) {
    if (error is DioException && CancelToken.isCancel(error)) {
      return true;
    }
    return false;
  }

  void _injectSystemReminder(List<LLMMessage> requestMessages) {
    if (state.systemReminders.isEmpty) return;

    final buffer = StringBuffer();
    bool hasReminders = false;

    buffer.writeln("<system-reminders>");
    buffer.writeln("<note>Note: This is for your information only.</note>");

    for (var entry in state.systemReminders.entries) {
      if (entry.value.isNotEmpty) {
        buffer.writeln("<system-reminder>");
        buffer.writeln("<key>${entry.key}</key>");
        buffer.writeln("<content>");
        buffer.writeln(entry.value);
        buffer.writeln("</content>");
        buffer.writeln("</system-reminder>");
        hasReminders = true;
      }
    }
    buffer.writeln("</system-reminders>");

    if (hasReminders && requestMessages.isNotEmpty) {
      // Find the last UserMessage index
      int insertIndex = -1;
      for (var i = requestMessages.length - 1; i >= 0; i--) {
        if (requestMessages[i] is UserMessage) {
          insertIndex = i;
          break;
        }
      }

      if (insertIndex != -1) {
        requestMessages.insert(
          insertIndex,
          UserMessage.text(buffer.toString()),
        );
      } else {
        // Fallback: if no user message found, insert at the beginning
        requestMessages.insert(0, UserMessage.text(buffer.toString()));
      }
    }
  }
}
