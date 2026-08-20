import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Cursor-aligned provider max: either edge above this must be resized.
const int kImageMaxEdgePx = 2000;

/// Encoded-size safety net (Claude-ish BYO). Pixel check is the primary gate.
const int kImageMaxEncodedBytes = 10 << 20;

const _kJpegSteps = <({int maxEdge, int quality})>[
  (maxEdge: 2000, quality: 85),
  (maxEdge: 1600, quality: 70),
  (maxEdge: 1280, quality: 50),
];

class ImageTooLargeException implements Exception {
  const ImageTooLargeException([this.message = '图片过大，压缩 3 次后仍超过限制，请换一张更小的图']);

  final String message;

  @override
  String toString() => message;
}

class PreparedImage {
  const PreparedImage({
    required this.bytes,
    required this.mimeType,
    required this.extension,
    required this.compressed,
  });

  final Uint8List bytes;
  final String mimeType;
  final String extension;
  final bool compressed;
}

bool imageWithinLimits(
  int width,
  int height,
  int encodedBytes, {
  int maxEncodedBytes = kImageMaxEncodedBytes,
}) {
  return width <= kImageMaxEdgePx &&
      height <= kImageMaxEdgePx &&
      encodedBytes <= maxEncodedBytes;
}

/// Keep the original encoding when it already fits; otherwise JPEG up to 3 times.
PreparedImage prepareImageForModel(
  Uint8List bytes, {
  String? hintExtension,
  int maxEncodedBytes = kImageMaxEncodedBytes,
}) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) {
    throw const FormatException('无法解码图片');
  }

  final hint = (hintExtension ?? '').toLowerCase().replaceAll('.', '');
  final originalExt = hint.isNotEmpty ? hint : _guessExt(bytes);
  final originalMime = originalExt == 'jpg' || originalExt == 'jpeg'
      ? 'image/jpeg'
      : originalExt == 'gif'
      ? 'image/gif'
      : originalExt == 'webp'
      ? 'image/webp'
      : 'image/png';

  if (imageWithinLimits(
    decoded.width,
    decoded.height,
    bytes.length,
    maxEncodedBytes: maxEncodedBytes,
  )) {
    return PreparedImage(
      bytes: bytes,
      mimeType: originalMime,
      extension: originalExt == 'jpeg' ? 'jpg' : originalExt,
      compressed: false,
    );
  }

  var current = decoded;
  for (final step in _kJpegSteps) {
    current = _fitMaxEdge(current, step.maxEdge);
    final encoded = Uint8List.fromList(
      img.encodeJpg(current, quality: step.quality),
    );
    if (imageWithinLimits(
      current.width,
      current.height,
      encoded.length,
      maxEncodedBytes: maxEncodedBytes,
    )) {
      return PreparedImage(
        bytes: encoded,
        mimeType: 'image/jpeg',
        extension: 'jpg',
        compressed: true,
      );
    }
  }

  throw const ImageTooLargeException();
}

img.Image _fitMaxEdge(img.Image source, int maxEdge) {
  final longest = source.width > source.height ? source.width : source.height;
  if (longest <= maxEdge) return source;
  final scale = maxEdge / longest;
  return img.copyResize(
    source,
    width: (source.width * scale).round().clamp(1, maxEdge),
    height: (source.height * scale).round().clamp(1, maxEdge),
    interpolation: img.Interpolation.linear,
  );
}

String _guessExt(Uint8List bytes) {
  if (bytes.length >= 3 &&
      bytes[0] == 0xFF &&
      bytes[1] == 0xD8 &&
      bytes[2] == 0xFF) {
    return 'jpg';
  }
  if (bytes.length >= 8 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4E &&
      bytes[3] == 0x47) {
    return 'png';
  }
  if (bytes.length >= 3 &&
      bytes[0] == 0x47 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46) {
    return 'gif';
  }
  return 'png';
}
