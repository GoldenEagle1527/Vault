import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault/util/host_file_picker.dart';

void main() {
  group('resolveHostFilePickerType', () {
    test('empty MIME → FileType.image (raincurtain every() on empty)', () {
      final s = resolveHostFilePickerType();
      expect(s.type, FileType.image);
      expect(s.allowedExtensions, isNull);
    });

    test('all image/* → FileType.image (clears extensions)', () {
      final s = resolveHostFilePickerType(
        mimeTypes: ['image/*', 'image/png'],
        allowedExtensions: ['png', 'jpg'],
      );
      expect(s.type, FileType.image);
      expect(s.allowedExtensions, isNull);
    });

    test('all video/* → FileType.video', () {
      final s = resolveHostFilePickerType(mimeTypes: ['video/*']);
      expect(s.type, FileType.video);
      expect(s.allowedExtensions, isNull);
    });

    test('all audio/* → FileType.audio', () {
      final s = resolveHostFilePickerType(mimeTypes: ['audio/mpeg', 'audio/*']);
      expect(s.type, FileType.audio);
      expect(s.allowedExtensions, isNull);
    });

    test('image + video mix → FileType.media', () {
      final s = resolveHostFilePickerType(
        mimeTypes: ['image/*', 'video/mp4'],
      );
      expect(s.type, FileType.media);
      expect(s.allowedExtensions, isNull);
    });

    test('extensions only (non-media MIME path) → FileType.custom', () {
      final s = resolveHostFilePickerType(
        mimeTypes: ['application/pdf'],
        allowedExtensions: ['.pdf', 'txt'],
      );
      expect(s.type, FileType.custom);
      expect(s.allowedExtensions, ['pdf', 'txt']);
    });

    test('mixed non-media without extensions → FileType.any', () {
      final s = resolveHostFilePickerType(
        mimeTypes: ['application/pdf', 'text/plain'],
      );
      expect(s.type, FileType.any);
    });
  });

  group('parseOpenFilePickerTypes', () {
    test('extracts MIME keys and extension values', () {
      final parsed = parseOpenFilePickerTypes([
        {
          'accept': {
            'image/*': ['.png', '.jpg'],
            'image/webp': <String>[],
          },
        },
      ]);
      expect(parsed.mimeTypes, ['image/*', 'image/webp']);
      expect(parsed.allowedExtensions, ['png', 'jpg']);
    });

    test('null / empty → empty lists', () {
      final parsed = parseOpenFilePickerTypes(null);
      expect(parsed.mimeTypes, isEmpty);
      expect(parsed.allowedExtensions, isEmpty);
    });
  });
}
