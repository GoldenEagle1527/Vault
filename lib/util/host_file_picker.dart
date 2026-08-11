import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Resolved [FilePicker.platform.pickFiles] args after MIME → [FileType] mapping.
///
/// On Android, [FileType.image] / [FileType.video] / [FileType.audio] /
/// [FileType.media] cause `file_picker` to send media MIME Intents so the
/// system DocumentsUI / gallery apps show album / video / music categories
/// instead of a generic file manager.
class HostFilePickerSelection {
  const HostFilePickerSelection({
    required this.type,
    this.allowedExtensions,
  });

  final FileType type;
  final List<String>? allowedExtensions;
}

/// Map Open File Picker–style MIME types (+ optional extensions) to [FileType].
///
/// Mapping (same rules as the webview `filesystem_handler` reference):
/// - all `image/*` → [FileType.image]
/// - all `video/*` → [FileType.video]
/// - all `audio/*` → [FileType.audio]
/// - mix of image + video → [FileType.media]
/// - only extensions → [FileType.custom]
/// - otherwise → [FileType.any]
HostFilePickerSelection resolveHostFilePickerType({
  Iterable<String>? mimeTypes,
  List<String>? allowedExtensions,
}) {
  final mimes = mimeTypes
          ?.map((m) => m.trim().toLowerCase())
          .where((m) => m.isNotEmpty)
          .toList() ??
      const <String>[];

  var exts = allowedExtensions
      ?.map((e) {
        final t = e.trim().toLowerCase();
        return t.startsWith('.') ? t.substring(1) : t;
      })
      .where((e) => e.isNotEmpty)
      .toList();
  if (exts != null && exts.isEmpty) exts = null;

  if (mimes.isNotEmpty && mimes.every((m) => m.startsWith('image/'))) {
    return const HostFilePickerSelection(type: FileType.image);
  }
  if (mimes.isNotEmpty && mimes.every((m) => m.startsWith('video/'))) {
    return const HostFilePickerSelection(type: FileType.video);
  }
  if (mimes.isNotEmpty && mimes.every((m) => m.startsWith('audio/'))) {
    return const HostFilePickerSelection(type: FileType.audio);
  }
  if (mimes.isNotEmpty &&
      mimes.every(
        (m) => m.startsWith('image/') || m.startsWith('video/'),
      )) {
    return const HostFilePickerSelection(type: FileType.media);
  }
  if (exts != null) {
    return HostFilePickerSelection(
      type: FileType.custom,
      allowedExtensions: exts,
    );
  }
  return const HostFilePickerSelection(type: FileType.any);
}

/// Parse `showOpenFilePicker({ types: [{ accept: { mime: ['.ext', ...] } }] })`.
({List<String> mimeTypes, List<String> allowedExtensions})
    parseOpenFilePickerTypes(Iterable<dynamic>? types) {
  final mimeTypes = <String>[];
  final extensions = <String>[];
  if (types == null) {
    return (mimeTypes: mimeTypes, allowedExtensions: extensions);
  }

  for (final entry in types) {
    if (entry is! Map) continue;
    final accept = entry['accept'];
    if (accept is! Map) continue;
    for (final MapEntry(:key, :value) in accept.entries) {
      final mime = key.toString().trim();
      if (mime.isNotEmpty) mimeTypes.add(mime);
      if (value is! Iterable) continue;
      for (final raw in value) {
        final ext = raw.toString().trim().toLowerCase();
        if (ext.isEmpty) continue;
        extensions.add(ext.startsWith('.') ? ext.substring(1) : ext);
      }
    }
  }
  return (mimeTypes: mimeTypes, allowedExtensions: extensions);
}

/// Pick files with MIME → [FileType] mapping (optional `showOpenFilePicker` types).
Future<FilePickerResult?> pickHostFiles({
  bool allowMultiple = false,
  bool withData = false,
  Iterable<String>? mimeTypes,
  List<String>? allowedExtensions,
  Iterable<dynamic>? openFilePickerTypes,
}) async {
  var mimes = mimeTypes?.toList();
  var exts = allowedExtensions;
  if (openFilePickerTypes != null) {
    final parsed = parseOpenFilePickerTypes(openFilePickerTypes);
    mimes ??= parsed.mimeTypes.isEmpty ? null : parsed.mimeTypes;
    exts ??=
        parsed.allowedExtensions.isEmpty ? null : parsed.allowedExtensions;
  }

  final selection = resolveHostFilePickerType(
    mimeTypes: mimes,
    allowedExtensions: exts,
  );
  return FilePicker.platform.pickFiles(
    allowMultiple: allowMultiple,
    type: selection.type,
    allowedExtensions: selection.allowedExtensions,
    withData: withData,
  );
}

enum _HostPickerCategory {
  image(mimeTypes: ['image/*'], label: '图片', icon: Icons.photo_library_outlined),
  video(mimeTypes: ['video/*'], label: '视频', icon: Icons.video_library_outlined),
  audio(mimeTypes: ['audio/*'], label: '音频', icon: Icons.library_music_outlined),
  media(
    mimeTypes: ['image/*', 'video/*'],
    label: '图片和视频',
    icon: Icons.perm_media_outlined,
  ),
  any(mimeTypes: null, label: '所有文件', icon: Icons.folder_open_outlined);

  const _HostPickerCategory({
    required this.mimeTypes,
    required this.label,
    required this.icon,
  });

  final List<String>? mimeTypes;
  final String label;
  final IconData icon;
}

/// UI entry: on Android ask for a media category so the system picker shows
/// album / video / music; elsewhere open a generic picker in one step.
Future<FilePickerResult?> pickHostFilesForUi(
  BuildContext context, {
  bool allowMultiple = true,
  bool withData = false,
}) async {
  final useCategorySheet =
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  if (!useCategorySheet) {
    return pickHostFiles(
      allowMultiple: allowMultiple,
      withData: withData,
    );
  }

  final category = await showModalBottomSheet<_HostPickerCategory>(
    context: context,
    showDragHandle: true,
    builder: (ctx) {
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: Text(
                '选择文件类型',
                style: Theme.of(ctx).textTheme.titleMedium,
              ),
            ),
            for (final c in _HostPickerCategory.values)
              ListTile(
                leading: Icon(c.icon),
                title: Text(c.label),
                onTap: () => Navigator.pop(ctx, c),
              ),
            const SizedBox(height: 8),
          ],
        ),
      );
    },
  );
  if (category == null) return null;
  if (!context.mounted) return null;

  return pickHostFiles(
    allowMultiple: allowMultiple,
    withData: withData,
    mimeTypes: category.mimeTypes,
  );
}
