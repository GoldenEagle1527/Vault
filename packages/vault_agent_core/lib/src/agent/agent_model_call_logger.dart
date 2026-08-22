import 'package:logging/logging.dart';

import '../core/message.dart';

class AgentModelCallLogger {
  const AgentModelCallLogger._();

  static void log(
    Logger logger,
    String agentName,
    ModelMessage message, {
    required bool isChunk,
  }) {
    final buffer = StringBuffer();
    if (!isChunk) {
      buffer.writeln('======= Full Agent Message ($agentName) =========');
    }
    buffer.writeln('🤖 Agent:');
    if (message.thought != null && message.thought!.isNotEmpty) {
      buffer.writeln('  🤔 [Thought]: ${message.thought!.trim()}');
    }
    if (message.textOutput != null && message.textOutput!.isNotEmpty) {
      final label = isChunk ? 'Chunk' : 'Text Output';
      buffer.writeln('  📖 [$label]: ${message.textOutput!.trim()}');
    }
    if (message.functionCalls.isNotEmpty) {
      buffer.writeln('  🔧 [Function Calls]');
      for (final call in message.functionCalls) {
        buffer.writeln('    > ${call.name}: ${call.arguments}');
      }
    }
    if (message.imageOutputs.isNotEmpty) {
      buffer.writeln('  🖼️ Images: ${message.imageOutputs.length}');
    }
    if (message.videoOutputs.isNotEmpty) {
      buffer.writeln('  📹 Video: ${message.videoOutputs.length}');
    }
    if (message.audioOutputs.isNotEmpty) {
      buffer.writeln('  🔊 Audio: ${message.audioOutputs.length}');
    }
    if (message.usage != null) {
      final usage = message.usage!;
      buffer.writeln(
        '  📊 [Usage]: Input: ${usage.promptTokens}(cached: ${usage.cachedToken})'
        ' | Output: ${usage.completionTokens}(thought: ${usage.thoughtToken})'
        ' | Total: ${usage.totalTokens}',
      );
    }
    if (message.stopReason != null) {
      buffer.writeln('  [Stop Reason]: ${message.stopReason}');
    }
    logger.info(buffer.toString());
  }
}
