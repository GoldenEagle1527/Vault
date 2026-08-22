import 'dart:async';

import 'package:dio/dio.dart';

import '../core/message.dart';
import 'agent_state.dart';
import 'stateful_agent.dart' show StatefulAgent;

class AgentCallToolContext {
  static final zoneKey = #AgentCallToolContext;

  static AgentCallToolContext? get current {
    return Zone.current[zoneKey] as AgentCallToolContext?;
  }

  final AgentState state;
  final StatefulAgent agent;
  final String batchCallId;
  final String callId;
  final String toolName;
  final CancelToken? cancelToken;

  AgentCallToolContext({
    required this.state,
    required this.agent,
    required this.batchCallId,
    required this.callId,
    required this.toolName,
    this.cancelToken,
  });
}

class AgentToolResult {
  final UserContentPart? content;
  final List<UserContentPart>? contents;
  final bool stopFlag;
  final Map<String, dynamic>? metadata;

  AgentToolResult({
    this.content,
    this.contents,
    this.stopFlag = false,
    this.metadata,
  });
}

class ExecutionToolResult {
  final String id;
  final String name;
  final String arguments;
  final List<UserContentPart> content;
  final Map<String, dynamic>? metadata;
  final bool stopFlag;
  final bool isError;

  ExecutionToolResult({
    required this.id,
    required this.name,
    required this.arguments,
    required this.content,
    this.stopFlag = false,
    this.isError = false,
    this.metadata,
  });
}
