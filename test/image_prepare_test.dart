import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:vault/agent/image_prepare.dart';

Uint8List _png({required int width, required int height}) {
  final image = img.Image(width: width, height: height);
  img.fill(image, color: img.ColorRgb8(200, 40, 40));
  return Uint8List.fromList(img.encodePng(image));
}

void main() {
  test('keeps original when both edges and bytes are within limits', () {
    final bytes = _png(width: 200, height: 120);
    final prepared = prepareImageForModel(bytes, hintExtension: 'png');
    expect(prepared.compressed, isFalse);
    expect(prepared.extension, 'png');
    expect(prepared.mimeType, 'image/png');
    expect(prepared.bytes, bytes);
  });

  test('resizes to 2000px JPEG when an edge exceeds the pixel cap', () {
    final bytes = _png(width: 2500, height: 100);
    final prepared = prepareImageForModel(bytes, hintExtension: 'png');
    expect(prepared.compressed, isTrue);
    expect(prepared.extension, 'jpg');
    expect(prepared.mimeType, 'image/jpeg');
    final decoded = img.decodeImage(prepared.bytes)!;
    expect(decoded.width, 2000);
    expect(decoded.height, lessThanOrEqualTo(2000));
  });

  test('JPEG ladder keeps both edges at or under 2000px', () {
    final bytes = _png(width: 4000, height: 3000);
    final prepared = prepareImageForModel(bytes, hintExtension: 'png');
    expect(prepared.compressed, isTrue);
    expect(prepared.extension, 'jpg');
    final decoded = img.decodeImage(prepared.bytes)!;
    expect(decoded.width, lessThanOrEqualTo(kImageMaxEdgePx));
    expect(decoded.height, lessThanOrEqualTo(kImageMaxEdgePx));
  });

  test('throws after three JPEG attempts still exceed the byte cap', () {
    final bytes = _png(width: 2500, height: 2500);
    expect(
      () => prepareImageForModel(bytes, maxEncodedBytes: 1),
      throwsA(isA<ImageTooLargeException>()),
    );
  });
}
