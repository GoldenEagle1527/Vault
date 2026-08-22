class ModelUsage {
  final int promptTokens;
  final int completionTokens;
  final int totalTokens;
  final int cachedToken;
  final int thoughtToken;
  final String? model;
  final dynamic originalUsage;
  final int timestamp;

  ModelUsage({
    this.promptTokens = 0,
    this.completionTokens = 0,
    this.totalTokens = 0,
    this.model,
    this.originalUsage,
    this.cachedToken = 0,
    this.thoughtToken = 0,
    int? timestamp,
  }) : timestamp = timestamp ?? DateTime.now().microsecondsSinceEpoch;

  Map<String, dynamic> toJson() => {
    'promptTokens': promptTokens,
    'completionTokens': completionTokens,
    'totalTokens': totalTokens,
    'cachedToken': cachedToken,
    'thoughtToken': thoughtToken,
    'model': model,
    if (originalUsage != null) 'originalUsage': originalUsage,
    'timestamp': timestamp,
  };

  factory ModelUsage.fromJson(Map<String, dynamic> json) {
    return ModelUsage(
      promptTokens: json['promptTokens'] as int? ?? 0,
      completionTokens: json['completionTokens'] as int? ?? 0,
      totalTokens: json['totalTokens'] as int? ?? 0,
      model: json['model'],
      cachedToken: json['cachedToken'] as int? ?? 0,
      thoughtToken: json['thoughtToken'] as int? ?? 0,
      originalUsage: json['originalUsage'],
      timestamp: json['timestamp'] as int,
    );
  }
}

enum StreamingEventType {
  beforeCallModel,
  modelChunkMessage,
  modelRetrying,
  fullModelMessage,
  functionCallRequest,
  functionCallResult,

  /// A tool call exceeded `StatefulAgent.toolBackgroundAfter` and was detached.
  /// [StreamingEvent.data] is a background tool job.
  toolBackgrounded,

  /// A previously backgrounded tool finished.
  /// [StreamingEvent.data] is a background tool job.
  toolBackgroundCompleted,
}

class StreamingEvent {
  final StreamingEventType eventType;
  final dynamic data;

  StreamingEvent({required this.eventType, required this.data});
}
