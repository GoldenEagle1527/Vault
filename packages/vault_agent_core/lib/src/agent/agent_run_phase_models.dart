import '../core/message.dart';
import 'agent_hook_model.dart';
import 'agent_state.dart';
import 'background_tool_job.dart';

class PreparedModelCallPhase {
  final ModelCallRequest request;
  final CallLLMParams params;
  final ModelMessage? syntheticResponse;
  final int systemPromptHash;
  final int toolsHash;

  const PreparedModelCallPhase({
    required this.request,
    required this.params,
    required this.syntheticResponse,
    required this.systemPromptHash,
    required this.toolsHash,
  });
}

class PromptToolHistoryHashes {
  final int systemPromptHash;
  final int toolsHash;

  const PromptToolHistoryHashes({
    required this.systemPromptHash,
    required this.toolsHash,
  });
}

class AfterModelCallPhase {
  final ModelMessage? response;
  final String? retryReason;

  const AfterModelCallPhase.proceed(ModelMessage this.response)
    : retryReason = null;

  const AfterModelCallPhase.retry(String this.retryReason) : response = null;

  bool get shouldRetry => retryReason != null;
}

class TurnCompletionPhase {
  final List<LLMMessage> messages;

  const TurnCompletionPhase.accept() : messages = const [];

  const TurnCompletionPhase.continueWith(this.messages);

  bool get shouldContinue => messages.isNotEmpty;
}

class ToolCallPhase {
  final FunctionExecutionResultMessage message;
  final List<LLMMessage> injectedMessages;
  final bool shouldStop;
  final List<BackgroundToolJob> backgroundedJobs;

  const ToolCallPhase({
    required this.message,
    required this.injectedMessages,
    required this.shouldStop,
    this.backgroundedJobs = const [],
  });
}
