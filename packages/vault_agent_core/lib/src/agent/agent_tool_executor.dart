import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:logging/logging.dart';
import 'package:uuid/uuid.dart';

import '../core/message.dart';
import '../core/tool.dart';
import 'agent_state.dart';
import 'agent_tool_result.dart';
import 'background_tool_racer.dart';
import 'background_tool_job.dart';

typedef AgentToolCallContextFactory =
    AgentCallToolContext Function({
      required String batchCallId,
      required FunctionCall call,
      CancelToken? cancelToken,
    });

class AgentToolExecutionBatch {
  const AgentToolExecutionBatch({
    this.results = const [],
    this.backgroundedJobs = const [],
  });

  final List<ExecutionToolResult> results;
  final List<BackgroundToolJob> backgroundedJobs;
}

/// Looks up and invokes tools, decodes arguments, and normalizes their results.
///
/// Agent lifecycle coordination remains in the host. In particular, the
/// executor receives a context factory per batch instead of retaining an agent.
class AgentToolExecutor {
  AgentToolExecutor({String Function()? createBatchCallId, Logger? logger})
    : _createBatchCallId = createBatchCallId ?? const Uuid().v4,
      _logger = logger ?? Logger('AgentToolExecutor');

  final String Function() _createBatchCallId;
  final Logger _logger;

  Future<AgentToolExecutionBatch> execute({
    required List<FunctionCall> calls,
    required List<Tool>? tools,
    required AgentState state,
    required AgentToolCallContextFactory createCallContext,
    required String agentName,
    CancelToken? cancelToken,
    Duration? backgroundAfter,
    BackgroundToolRacer? backgroundRacer,
  }) async {
    // TODO(skill-scripts): Directory-skill script execution (especially JS
    // sandbox) should be integrated here, because this is the central tool-call
    // execution path. We intentionally do not execute scripts for mobile
    // runtime in this iteration.
    final batchCallId = _createBatchCallId();
    final backgroundEnabled =
        backgroundRacer != null &&
        backgroundAfter != null &&
        backgroundAfter > Duration.zero;

    final futures = calls.map((call) async {
      final tool = _lookupTool(call, tools);
      final work = _executeSingle(
        call: call,
        tool: tool,
        state: state,
        batchCallId: batchCallId,
        createCallContext: createCallContext,
        agentName: agentName,
        cancelToken: cancelToken,
      );
      if (!backgroundEnabled || tool?.allowBackground == false) {
        return BackgroundToolRaceOutcome(result: await work);
      }
      return backgroundRacer.race(
        call: call,
        work: work,
        threshold: backgroundAfter,
        systemReminders: state.systemReminders,
      );
    });

    final raced = await Future.wait(futures);
    return AgentToolExecutionBatch(
      results: [for (final item in raced) item.result],
      backgroundedJobs: [
        for (final item in raced)
          if (item.backgroundedJob != null) item.backgroundedJob!,
      ],
    );
  }

  Tool? _lookupTool(FunctionCall call, List<Tool>? tools) {
    final matched = tools?.where((tool) => tool.name == call.name);
    return matched == null || matched.isEmpty ? null : matched.first;
  }

  Future<ExecutionToolResult> _executeSingle({
    required FunctionCall call,
    required Tool? tool,
    required AgentState state,
    required String batchCallId,
    required AgentToolCallContextFactory createCallContext,
    required String agentName,
    CancelToken? cancelToken,
  }) async {
    if (tool == null || tool.executable == null) {
      return ExecutionToolResult(
        id: call.id,
        name: call.name,
        arguments: call.arguments,
        content: [TextPart('Function ${call.name} failed or not found.')],
        isError: true,
      );
    }

    try {
      final positionalArgs = <dynamic>[];
      final namedArgs = <Symbol, dynamic>{};

      Map<String, dynamic> decodedArgs;
      try {
        if (call.arguments.trim().isEmpty) {
          decodedArgs = {};
        } else {
          decodedArgs = (jsonDecode(call.arguments) as Map)
              .cast<String, dynamic>();
        }
      } catch (error) {
        return ExecutionToolResult(
          id: call.id,
          name: call.name,
          arguments: call.arguments,
          content: [TextPart('Error decoding arguments: $error')],
          isError: true,
        );
      }

      final properties = (tool.parameters['properties'] as Map? ?? {})
          .cast<String, dynamic>();

      void addArgument(String key, dynamic value) {
        dynamic castedValue = value;
        final property = (properties[key] as Map?)?.cast<String, dynamic>();
        if (property != null) {
          final type = property['type'];
          if (value is List && type == 'array') {
            final items = (property['items'] as Map?)?.cast<String, dynamic>();
            if (items != null) {
              final itemType = items['type'];
              if (itemType == 'string') {
                castedValue = value.cast<String>();
              } else if (itemType == 'integer') {
                castedValue = value.cast<int>();
              } else if (itemType == 'number') {
                castedValue = value.map((e) => (e as num).toDouble()).toList();
              } else if (itemType == 'boolean') {
                castedValue = value.cast<bool>();
              }
            }
          } else if (type == 'integer' && value is num) {
            castedValue = value.toInt();
          } else if (type == 'number' && value is num) {
            castedValue = value.toDouble();
          }
        }

        if (tool.namedParameters.contains(key)) {
          namedArgs[Symbol(key)] = castedValue;
        } else {
          positionalArgs.add(castedValue);
        }
      }

      for (final key in properties.keys) {
        if (decodedArgs.containsKey(key)) {
          addArgument(key, decodedArgs[key]);
        } else if (!tool.namedParameters.contains(key)) {
          positionalArgs.add(null);
        }
      }

      final result = runZoned(
        () {
          if (tool.parameterMode == ToolParameterMode.object) {
            return tool.executable!(decodedArgs);
          }
          return Function.apply(tool.executable!, positionalArgs, namedArgs);
        },
        zoneValues: {
          AgentCallToolContext.zoneKey: createCallContext(
            batchCallId: batchCallId,
            call: call,
            cancelToken: cancelToken,
          ),
        },
      );

      final resultValue = result is Future ? await result : result;
      final resultContent = <UserContentPart>[];
      var stopFlag = false;
      Map<String, dynamic>? metadata;
      if (resultValue is AgentToolResult) {
        if (resultValue.content != null) {
          resultContent.add(resultValue.content!);
        }
        if (resultValue.contents != null) {
          resultContent.addAll(resultValue.contents!);
        }
        stopFlag = resultValue.stopFlag;
        metadata = resultValue.metadata;
      } else {
        resultContent.add(TextPart(resultValue.toString()));
      }
      return ExecutionToolResult(
        id: call.id,
        name: call.name,
        arguments: call.arguments,
        content: resultContent,
        stopFlag: stopFlag,
        metadata: metadata,
      );
    } catch (error) {
      _logger.severe(
        '[$agentName] ❌ Error executing ${call.name} '
        'with args ${call.arguments}: $error',
      );
      return ExecutionToolResult(
        id: call.id,
        name: call.name,
        arguments: call.arguments,
        content: [TextPart('Error executing ${call.name}: $error')],
        isError: true,
      );
    }
  }
}
