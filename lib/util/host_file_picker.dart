import 'package:file_picker/file_picker.dart';

/// Resolved [FilePicker.pickFiles] args after MIME → [FileType] mapping.
class HostFilePickerSelection {
  const HostFilePickerSelection({required this.type, this.allowedExtensions});

  final FileType type;
  final List<String>? allowedExtensions;
}

/// Map Open File Picker–style MIME types to [FileType] (raincurtain rules).
///
/// With `file_picker` ≥ 11, [FileType.image] / video / audio use
/// `ACTION_GET_CONTENT` so Android DocumentsUI shows sidebar categories
/// (最近 / 图片 / 音频 / 文档 / 下载). Empty MIME set → [FileType.image]
/// (same as raincurtain `mimeTypes.every(...)` on an empty set).
HostFilePickerSelection resolveHostFilePickerType({
  Iterable<String>? mimeTypes,
  List<String>? allowedExtensions,
  bool unrestricted = false,
}) {
  if (unrestricted) {
    return const HostFilePickerSelection(type: FileType.any);
  }
  final mimes =
      mimeTypes
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

  // Note: [].every(...) is true — unrestricted / empty → FileType.image.
  if (mimes.every((m) => m.startsWith('image/'))) {
    return const HostFilePickerSelection(type: FileType.image);
  }
  if (mimes.every((m) => m.startsWith('video/'))) {
    return const HostFilePickerSelection(type: FileType.video);
  }
  if (mimes.every((m) => m.startsWith('audio/'))) {
    return const HostFilePickerSelection(type: FileType.audio);
  }
  if (mimes.every((m) => m.startsWith('image/') || m.startsWith('video/'))) {
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

/// Pick files with raincurtain-compatible MIME → [FileType] mapping.
Future<FilePickerResult?> pickHostFiles({
  bool allowMultiple = false,
  bool withData = false,
  Iterable<String>? mimeTypes,
  List<String>? allowedExtensions,
  Iterable<dynamic>? openFilePickerTypes,
  bool unrestricted = false,
}) async {
  var mimes = mimeTypes?.toList();
  var exts = allowedExtensions;
  if (openFilePickerTypes != null) {
    final parsed = parseOpenFilePickerTypes(openFilePickerTypes);
    mimes ??= parsed.mimeTypes.isEmpty ? null : parsed.mimeTypes;
    exts ??= parsed.allowedExtensions.isEmpty ? null : parsed.allowedExtensions;
  }

  final selection = resolveHostFilePickerType(
    mimeTypes: mimes,
    allowedExtensions: exts,
    unrestricted: unrestricted,
  );
  // Same API surface as raincurtain (`FilePicker.pickFiles`).
  return FilePicker.pickFiles(
    allowMultiple: allowMultiple,
    type: selection.type,
    allowedExtensions: selection.allowedExtensions,
    withData: withData,
  );
}

/// File browser import: any file type (docs, code, archives, images, …).
///
/// Forwards `unrestricted: true` into [pickHostFiles]. Empty MIME still maps
/// to [FileType.image] (raincurtain `every()` on an empty set).
Future<FilePickerResult?> pickHostFilesForUi({
  bool allowMultiple = true,
  bool withData = false,
}) {
  return pickHostFiles(
    allowMultiple: allowMultiple,
    withData: withData,
    unrestricted: true,
  );
}

/// Agent composer: any file type (code, docs, images, …).
Future<FilePickerResult?> pickHostFilesForAgent({
  bool allowMultiple = true,
  bool withData = false,
}) {
  return pickHostFiles(
    allowMultiple: allowMultiple,
    withData: withData,
    unrestricted: true,
  );
}
