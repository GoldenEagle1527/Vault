import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

class EventStreamDecoder
    extends StreamTransformerBase<List<int>, EventStreamMessage> {
  @override
  Stream<EventStreamMessage> bind(Stream<List<int>> stream) async* {
    final buffer = <int>[];
    await for (final chunk in stream) {
      buffer.addAll(chunk);
      while (true) {
        if (buffer.length < 8) break;
        final totalLengthData = Uint8List.fromList(buffer.sublist(0, 4));
        final totalLength = ByteData.view(
          totalLengthData.buffer,
        ).getUint32(0, Endian.big);
        if (buffer.length < totalLength) break;

        final messageBytes = Uint8List.fromList(buffer.sublist(0, totalLength));
        buffer.removeRange(0, totalLength);
        try {
          yield _parseMessage(messageBytes);
        } catch (error) {
          throw FormatException('Failed to parse EventStream message: $error');
        }
      }
    }
  }

  EventStreamMessage _parseMessage(Uint8List bytes) {
    final view = ByteData.view(bytes.buffer);
    final totalLength = view.getUint32(0, Endian.big);
    final headersLength = view.getUint32(4, Endian.big);
    final headersEnd = 12 + headersLength;
    final headers = _parseHeaders(bytes.sublist(12, headersEnd));
    final payload = bytes.sublist(headersEnd, totalLength - 4);
    return EventStreamMessage(headers, payload);
  }

  Map<String, String> _parseHeaders(Uint8List headerBytes) {
    final headers = <String, String>{};
    var offset = 0;
    final view = ByteData.view(headerBytes.buffer);
    while (offset < headerBytes.length) {
      final nameLength = headerBytes[offset++];
      final name = utf8.decode(
        headerBytes.sublist(offset, offset + nameLength),
      );
      offset += nameLength;
      final valueType = headerBytes[offset++];
      switch (valueType) {
        case 7:
          final valueLength = view.getUint16(offset, Endian.big);
          offset += 2;
          headers[name] = utf8.decode(
            headerBytes.sublist(offset, offset + valueLength),
          );
          offset += valueLength;
          break;
        case 6:
          final valueLength = view.getUint16(offset, Endian.big);
          offset += 2 + valueLength;
          break;
        default:
          throw FormatException(
            'Unsupported header value type: $valueType for header $name',
          );
      }
    }
    return headers;
  }
}

class EventStreamMessage {
  EventStreamMessage(this.headers, this.payload);

  final Map<String, String> headers;
  final Uint8List payload;

  String get payloadAsString => utf8.decode(payload);

  Map<String, dynamic>? get jsonPayload {
    try {
      return jsonDecode(payloadAsString) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  @override
  String toString() =>
      'EventStreamMessage(headers: $headers, '
      'payload: ${payload.length} bytes)';
}
