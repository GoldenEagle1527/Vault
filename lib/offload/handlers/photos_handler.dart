import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:vault/offload/handlers/offload_handler.dart';
import 'package:vault/offload/offload_protocol.dart';

/// `vault-photos` — read-only listing under the user Pictures folder.
///
/// Windows: `%USERPROFILE%\Pictures`. Other desktop hosts: `$HOME/Pictures`.
class PhotosHandler implements OffloadHandler {
  PhotosHandler({this.maxList = 50});

  /// Cap for `list` (and smoke sample).
  final int maxList;

  static const _imageExts = {
    '.jpg',
    '.jpeg',
    '.png',
    '.gif',
    '.webp',
    '.bmp',
    '.heic',
    '.heif',
    '.tif',
    '.tiff',
  };

  @override
  String get permissionId => 'photos';

  @override
  String get command => 'vault-photos';

  @override
  Future<OffloadResponse> handle(OffloadRequest request) async {
    final args = request.args;
    final sub = args.isEmpty ? 'list' : args.first;

    switch (sub) {
      case 'smoke':
        return _smoke();
      case 'list':
        return _list();
      default:
        return OffloadResponse.error(
          2,
          'usage: vault-photos list|smoke',
        );
    }
  }

  Future<OffloadResponse> _smoke() async {
    final dir = _picturesDir();
    if (dir == null) {
      return OffloadResponse.ok(
        jsonEncode({
          'ok': true,
          'limited': true,
          'note': 'Pictures folder path unavailable',
        }),
      );
    }
    if (!await dir.exists()) {
      return OffloadResponse.ok(
        jsonEncode({
          'ok': true,
          'limited': true,
          'note': 'Pictures folder not found: ${dir.path}',
          'path': dir.path,
        }),
      );
    }
    final sample = await _collectImages(dir, limit: 3);
    return OffloadResponse.ok(
      jsonEncode({
        'ok': true,
        'path': dir.path,
        'sampleCount': sample.length,
      }),
    );
  }

  Future<OffloadResponse> _list() async {
    final dir = _picturesDir();
    if (dir == null || !await dir.exists()) {
      return OffloadResponse.ok(
        jsonEncode({
          'ok': true,
          'limited': true,
          'items': <Map<String, dynamic>>[],
          'note': dir == null
              ? 'Pictures folder path unavailable'
              : 'Pictures folder not found: ${dir.path}',
        }),
      );
    }
    final items = await _collectImages(dir, limit: maxList);
    return OffloadResponse.ok(
      jsonEncode({
        'ok': true,
        'path': dir.path,
        'count': items.length,
        'truncated': maxList,
        'items': items,
      }),
    );
  }

  Directory? _picturesDir() {
    final env = Platform.environment;
    final profile = env['USERPROFILE'] ?? env['HOME'];
    if (profile == null || profile.isEmpty) return null;
    return Directory(p.join(profile, 'Pictures'));
  }

  Future<List<Map<String, dynamic>>> _collectImages(
    Directory root, {
    required int limit,
  }) async {
    final out = <Map<String, dynamic>>[];
    try {
      await for (final entity in root.list(recursive: true, followLinks: false)) {
        if (out.length >= limit) break;
        if (entity is! File) continue;
        final ext = p.extension(entity.path).toLowerCase();
        if (!_imageExts.contains(ext)) continue;
        final stat = await entity.stat();
        out.add({
          'path': entity.path,
          'name': p.basename(entity.path),
          'size': stat.size,
          'modified': stat.modified.toUtc().toIso8601String(),
        });
      }
    } on FileSystemException {
      // Permission / IO — still return what we collected.
    }
    return out;
  }
}
