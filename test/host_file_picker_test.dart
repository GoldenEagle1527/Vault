import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault/util/host_file_picker.dart';

void main() {
  group('resolveHostFilePickerType', () {
    test('all image/* → FileType.image (no extensions)', () {
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

    test('extensions only → FileType.custom (strips dots)', () {
      final s = resolveHostFilePickerType(
        allowedExtensions: ['.png', 'JPG', ''],
      );
      expect(s.type, FileType.custom);
      expect(s.allowedExtensions, ['png', 'jpg']);
    });

    test('unrestricted → FileType.any', () {
      final s = resolveHostFilePickerType();
      expect(s.type, FileType.any);
      expect(s.allowedExtensions, isNull);
    });

    test('mixed non-media MIME falls back to custom when extensions given', () {
      final s = resolveHostFilePickerType(
        mimeTypes: ['application/pdf', 'image/png'],
        allowedExtensions: ['pdf', 'png'],
      );
      expect(s.type, FileType.custom);
      expect(s.allowedExtensions, ['pdf', 'png']);
    });

    test('mixed non-media MIME without extensions → any', () {
      final s = resolveHostFilePickerType(
        mimeTypes: ['application/pdf', 'image/png'],
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
