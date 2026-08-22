import 'dart:async';
import 'dart:convert';

import 'package:logging/logging.dart';

final Logger _logger = Logger('GeminiClient');

/// Decodes Gemini's streamed JSON array into individual response objects.
class GeminiChunkDecoder
    extends StreamTransformerBase<String, Map<String, dynamic>> {
  @override
  Stream<Map<String, dynamic>> bind(Stream<String> stream) async* {
    final buffer = StringBuffer();
    int braceCount = 0;
    bool inObject = false;

    await for (final line in stream) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      if (!inObject && (trimmed == '[' || trimmed == ']')) continue;

      for (int i = 0; i < line.length; i++) {
        final char = line[i];
        if (char == '{') {
          if (braceCount == 0) inObject = true;
          braceCount++;
        }
        if (inObject) {
          buffer.write(char);
        }
        if (char == '}') {
          braceCount--;
          if (braceCount == 0 && inObject) {
            inObject = false;
            final jsonString = buffer.toString();
            buffer.clear();
            try {
              final data = jsonDecode(jsonString);
              if (data is Map<String, dynamic>) {
                yield data;
              }
            } catch (error) {
              _logger.warning(
                'Error decoding JSON chunk: $error\nChunk: $jsonString',
              );
            }
          }
        }
      }
      if (inObject) {
        buffer.write('\n');
      }
    }
  }
}
