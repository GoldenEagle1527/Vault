import 'dart:async';
import 'dart:convert';

class ResponsesChunkDecoder
    extends StreamTransformerBase<String, Map<String, dynamic>> {
  @override
  Stream<Map<String, dynamic>> bind(Stream<String> stream) async* {
    await for (final line in stream) {
      if (!line.startsWith('data: ')) continue;
      final data = line.substring(6).trim();
      if (data == '[DONE]') return;
      try {
        yield jsonDecode(data);
      } catch (_) {
        // Preserve the existing decoder behavior: malformed SSE data is ignored.
      }
    }
  }
}
