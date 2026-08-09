import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:vault/offload/handlers/offload_handler.dart';
import 'package:vault/offload/offload_protocol.dart';

/// `vault-host-files` — scoped host filesystem access.
///
/// Default allowed root: `%USERPROFILE%\Documents\VaultHost` (created on demand).
/// Optional in-memory [bookmarks] may add extra absolute roots for listing.
class HostFilesHandler implements OffloadHandler {
  HostFilesHandler({
    Directory? root,
    List<String>? bookmarks,
  })  : _rootOverride = root,
        _bookmarks = List<String>.from(bookmarks ?? const []);

  final Directory? _rootOverride;
  final List<String> _bookmarks;

  @override
  String get permissionId => 'host_files';

  @override
  String get command => 'vault-host-files';

  /// In-memory bookmark roots (absolute paths). Mutable for the process lifetime.
  List<String> get bookmarks => List.unmodifiable(_bookmarks);

  void addBookmark(String absolutePath) {
    final normalized = p.normalize(absolutePath);
    if (!_bookmarks.contains(normalized)) {
      _bookmarks.add(normalized);
    }
  }

  @override
  Future<OffloadResponse> handle(OffloadRequest request) async {
    final args = request.args;
    final sub = args.isEmpty ? 'list' : args.first;

    switch (sub) {
      case 'smoke':
        return _smoke();
      case 'list':
        final rel = args.length > 1 ? args.sublist(1).join(' ') : '';
        return _list(rel);
      default:
        return OffloadResponse.error(
          2,
          'usage: vault-host-files list [relpath]|smoke',
        );
    }
  }

  Future<Directory> _ensureRoot() async {
    final root = _rootOverride ?? _defaultRoot();
    if (root == null) {
      throw StateError('host files root unavailable (no USERPROFILE/HOME)');
    }
    if (!await root.exists()) {
      await root.create(recursive: true);
    }
    return root;
  }

  Directory? _defaultRoot() {
    final env = Platform.environment;
    final profile = env['USERPROFILE'] ?? env['HOME'];
    if (profile == null || profile.isEmpty) return null;
    return Directory(p.join(profile, 'Documents', 'VaultHost'));
  }

  Future<OffloadResponse> _smoke() async {
    try {
      final root = await _ensureRoot();
      final marker = 'vault-host-files-smoke-${DateTime.now().microsecondsSinceEpoch}';
      final file = File(p.join(root.path, '.vault_host_files_smoke.tmp'));
      await file.writeAsString(marker, flush: true);
      final got = await file.readAsString();
      try {
        await file.delete();
      } catch (_) {}
      if (got != marker) {
        return OffloadResponse.error(1, 'host_files smoke read mismatch');
      }
      return OffloadResponse.ok(
        jsonEncode({
          'ok': true,
          'root': root.path,
          'bookmarks': _bookmarks,
        }),
      );
    } catch (e) {
      return OffloadResponse.error(1, 'host_files smoke failed: $e');
    }
  }

  Future<OffloadResponse> _list(String relpath) async {
    if (_containsDotDot(relpath)) {
      return OffloadResponse.error(2, 'path rejected: ".." not allowed');
    }

    try {
      final root = await _ensureRoot();
      final target = _resolveUnderRoot(root, relpath);
      if (target == null) {
        return OffloadResponse.error(2, 'path escapes allowed root');
      }

      if (!await target.exists()) {
        return OffloadResponse.ok(
          jsonEncode({
            'ok': true,
            'root': root.path,
            'path': target.path,
            'items': <Map<String, dynamic>>[],
            'note': 'path not found',
          }),
        );
      }

      final items = <Map<String, dynamic>>[];
      await for (final entity in target.list(followLinks: false)) {
        final type = entity is Directory
            ? 'dir'
            : entity is File
                ? 'file'
                : 'other';
        items.add({
          'name': p.basename(entity.path),
          'type': type,
          'path': entity.path,
        });
      }
      items.sort((a, b) => '${a['name']}'.compareTo('${b['name']}'));

      return OffloadResponse.ok(
        jsonEncode({
          'ok': true,
          'root': root.path,
          'path': target.path,
          'count': items.length,
          'items': items,
          'bookmarks': _bookmarks,
        }),
      );
    } catch (e) {
      return OffloadResponse.error(1, 'host_files list failed: $e');
    }
  }

  bool _containsDotDot(String relpath) {
    if (relpath.isEmpty) return false;
    final parts = p.split(relpath.replaceAll('\\', '/'));
    return parts.any((part) => part == '..');
  }

  /// Resolve [relpath] under [root]; null if the result escapes the root.
  Directory? _resolveUnderRoot(Directory root, String relpath) {
    final rootCanon = p.normalize(root.absolute.path);
    if (relpath.trim().isEmpty) {
      return Directory(rootCanon);
    }
    final joined = p.normalize(p.join(rootCanon, relpath));
    final rootPrefix = rootCanon.endsWith(p.separator)
        ? rootCanon
        : '$rootCanon${p.separator}';
    if (joined != rootCanon && !joined.startsWith(rootPrefix)) {
      return null;
    }
    return Directory(joined);
  }
}
