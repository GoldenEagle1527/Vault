import 'user_content_parts.dart';

/// Represents a function call to be executed.
class FunctionCall {
  final String id;
  final String name;
  final String arguments;

  FunctionCall({required this.id, required this.name, required this.arguments});

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'arguments': arguments,
  };

  factory FunctionCall.fromJson(Map<String, dynamic> json) {
    return FunctionCall(
      id: json['id'] as String,
      name: json['name'] as String,
      arguments: json['arguments'] as String,
    );
  }
}

class FunctionExecutionResult {
  final String id; // Matches FunctionCall.id
  final String name;
  final bool isError;
  final String arguments;
  final List<UserContentPart> content; // Structured multimodal content
  final Map<String, dynamic>? metadata;
  final int timestamp;

  FunctionExecutionResult({
    required this.id,
    required this.name,
    required this.isError,
    required this.arguments,
    required this.content,
    this.metadata,
    int? timestamp,
  }) : timestamp = timestamp ?? DateTime.now().microsecondsSinceEpoch;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'isError': isError,
    'arguments': arguments,
    'content': content.map((e) => e.toJson()).toList(),
    'metadata': metadata,
    'timestamp': timestamp,
  };

  factory FunctionExecutionResult.fromJson(Map<String, dynamic> json) {
    return FunctionExecutionResult(
      id: json['id'] as String,
      name: json['name'] as String,
      isError: json['isError'] as bool,
      arguments: json['arguments'] as String,
      content: (json['content'] as List)
          .map((e) => UserContentPart.fromJson(e as Map<String, dynamic>))
          .toList(),
      metadata: json['metadata'] as Map<String, dynamic>?,
      timestamp: json['timestamp'] as int,
    );
  }
}
