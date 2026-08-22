import 'dart:async';

import 'package:uuid/uuid.dart';

import '../core/message.dart';
import 'agent_tool_result.dart';
import 'background_tool_job.dart';

class BackgroundToolRaceOutcome {
  const BackgroundToolRaceOutcome({required this.result, this.backgroundedJob});

  final ExecutionToolResult result;
  final BackgroundToolJob? backgroundedJob;
}

/// Races foreground tool work against the background threshold.
///
/// This class owns no agent lifecycle state. It only updates the supplied job
/// registry and reminder map after the foreground future settles or detaches.
class BackgroundToolRacer {
  BackgroundToolRacer({required this.registry, String Function()? createJobId})
    : _createJobId = createJobId ?? const Uuid().v4;

  final BackgroundToolJobRegistry registry;
  final String Function() _createJobId;

  Future<BackgroundToolRaceOutcome> race({
    required FunctionCall call,
    required Future<ExecutionToolResult> work,
    required Duration threshold,
    required Map<String, String> systemReminders,
  }) async {
    final gate = Completer<ExecutionToolResult>();
    var backgrounded = false;
    late final String jobId;

    work.then(
      (result) {
        if (backgrounded) {
          registry.complete(jobId, _toFunctionResult(result));
          registry.syncReminders(systemReminders);
        } else if (!gate.isCompleted) {
          gate.complete(result);
        }
      },
      onError: (Object error, StackTrace stack) {
        final failed = ExecutionToolResult(
          id: call.id,
          name: call.name,
          arguments: call.arguments,
          content: [TextPart('Error executing ${call.name}: $error')],
          isError: true,
        );
        if (backgrounded) {
          registry.fail(jobId, error, result: _toFunctionResult(failed));
          registry.syncReminders(systemReminders);
        } else if (!gate.isCompleted) {
          gate.complete(failed);
        }
      },
    );

    final raced = await Future.any<ExecutionToolResult?>([
      gate.future,
      Future<ExecutionToolResult?>.delayed(threshold, () => null),
    ]);
    if (raced != null) {
      return BackgroundToolRaceOutcome(result: raced);
    }
    if (gate.isCompleted) {
      return BackgroundToolRaceOutcome(result: await gate.future);
    }

    backgrounded = true;
    jobId = _createJobId();
    final job = registry.register(
      jobId: jobId,
      callId: call.id,
      toolName: call.name,
      arguments: call.arguments,
    );
    registry.syncReminders(systemReminders);

    return BackgroundToolRaceOutcome(
      result: ExecutionToolResult(
        id: call.id,
        name: call.name,
        arguments: call.arguments,
        content: [
          TextPart(
            buildBackgroundToolStubText(
              toolName: call.name,
              jobId: jobId,
              callId: call.id,
              threshold: threshold,
              runningJobs: registry.runningJobs,
            ),
          ),
        ],
        metadata: {'background': true, 'jobId': jobId, 'callId': call.id},
      ),
      backgroundedJob: job,
    );
  }

  FunctionExecutionResult _toFunctionResult(ExecutionToolResult result) {
    return FunctionExecutionResult(
      id: result.id,
      name: result.name,
      isError: result.isError,
      arguments: result.arguments,
      content: result.content,
      metadata: result.metadata,
    );
  }
}
