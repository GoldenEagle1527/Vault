import '../core/message.dart';

/// Accumulates streamed model-message chunks into a single message.
class ModelMessageAccumulator {
  final StringBuffer _text = StringBuffer();
  final StringBuffer _thought = StringBuffer();
  final List<Map<String, dynamic>> _contentBlocks = [];
  final List<FunctionCall> _functionCalls = [];
  final List<ModelImagePart> _imageOutputs = [];
  final List<ModelVideoPart> _videoOutputs = [];
  final List<ModelAudioPart> _audioOutputs = [];

  String? stopReason;
  ModelUsage? usage;
  String? thoughtSignature;
  String? responseId;
  Map<String, dynamic>? metadata;

  bool get isEmptyResponse =>
      _functionCalls.isEmpty && _text.isEmpty && responseId == null;

  void add(ModelMessage chunk) {
    if (chunk.textOutput != null) {
      _text.write(chunk.textOutput);
    }
    for (final call in chunk.functionCalls) {
      _mergeFunctionCall(call);
    }
    _contentBlocks.addAll(chunk.contentBlocks);
    _imageOutputs.addAll(chunk.imageOutputs);
    _videoOutputs.addAll(chunk.videoOutputs);
    _audioOutputs.addAll(chunk.audioOutputs);
    if (chunk.stopReason != null) {
      stopReason = chunk.stopReason;
    }
    if (chunk.usage != null) {
      usage = chunk.usage;
    }
    if (chunk.metadata != null) {
      metadata = chunk.metadata;
    }
    if (chunk.thought != null) {
      _thought.write(chunk.thought!);
    }
    if (chunk.thoughtSignature != null) {
      thoughtSignature = chunk.thoughtSignature;
    }
    if (chunk.responseId != null) {
      responseId = chunk.responseId;
    }
  }

  void _mergeFunctionCall(FunctionCall incoming) {
    final index = incoming.id.isEmpty
        ? -1
        : _functionCalls.indexWhere((call) => call.id == incoming.id);
    if (index < 0) {
      _functionCalls.add(incoming);
      return;
    }

    final previous = _functionCalls[index];
    _functionCalls[index] = FunctionCall(
      id: incoming.id.isNotEmpty ? incoming.id : previous.id,
      name: incoming.name.isNotEmpty ? incoming.name : previous.name,
      arguments: incoming.arguments.length >= previous.arguments.length
          ? incoming.arguments
          : previous.arguments,
    );
  }

  void reset() {
    _text.clear();
    _thought.clear();
    _contentBlocks.clear();
    _functionCalls.clear();
    _imageOutputs.clear();
    _videoOutputs.clear();
    _audioOutputs.clear();
    stopReason = null;
    usage = null;
    thoughtSignature = null;
    responseId = null;
    metadata = null;
  }

  ModelMessage toModelMessage(String model) {
    return ModelMessage(
      textOutput: _text.isNotEmpty ? _text.toString() : null,
      functionCalls: _functionCalls,
      contentBlocks: _contentBlocks,
      imageOutputs: _imageOutputs,
      videoOutputs: _videoOutputs,
      audioOutputs: _audioOutputs,
      stopReason: stopReason,
      usage: usage,
      metadata: metadata,
      model: model,
      thought: _thought.isNotEmpty ? _thought.toString() : null,
      thoughtSignature: thoughtSignature,
      responseId: responseId,
    );
  }
}
