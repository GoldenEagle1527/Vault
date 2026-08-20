/// Kind of guest file for preview routing in the file browser.
enum GuestMediaKind {
  image,
  video,
  audio,
  text,
  binary,
}

/// Classify [guestPath] by basename / extension (case-insensitive).
///
/// Text vs binary still needs a byte probe for unknown extensions; when this
/// returns [GuestMediaKind.text] the caller may refine with [looksLikeTextBytes].
GuestMediaKind guestMediaKindForPath(String guestPath) {
  final base = guestPath.replaceAll('\\', '/').split('/').last.toLowerCase();
  if (base.isEmpty) return GuestMediaKind.binary;

  final dot = base.lastIndexOf('.');
  if (dot <= 0 || dot == base.length - 1) {
    // Extensionless names that are usually text.
    switch (base) {
      case 'dockerfile':
      case 'makefile':
      case 'gnumakefile':
      case 'gemfile':
      case 'rakefile':
      case 'cmakelists.txt':
        return GuestMediaKind.text;
      default:
        return GuestMediaKind.text; // probe with looksLikeTextBytes
    }
  }

  final ext = base.substring(dot + 1);
  if (_imageExt.contains(ext)) return GuestMediaKind.image;
  if (_videoExt.contains(ext)) return GuestMediaKind.video;
  if (_audioExt.contains(ext)) return GuestMediaKind.audio;
  if (_textExt.contains(ext)) return GuestMediaKind.text;
  return GuestMediaKind.binary;
}

/// MIME for a guest/host image path, or null if not a known image extension.
String? imageMimeTypeForPath(String path) {
  final base = path.replaceAll('\\', '/').split('/').last.toLowerCase();
  final dot = base.lastIndexOf('.');
  if (dot <= 0 || dot == base.length - 1) return null;
  return switch (base.substring(dot + 1)) {
    'png' => 'image/png',
    'jpg' || 'jpeg' => 'image/jpeg',
    'gif' => 'image/gif',
    'webp' => 'image/webp',
    'bmp' || 'wbmp' => 'image/bmp',
    'ico' => 'image/x-icon',
    _ => null,
  };
}

const _imageExt = {
  'png',
  'jpg',
  'jpeg',
  'gif',
  'webp',
  'bmp',
  'wbmp',
  'ico',
};

const _videoExt = {
  'mp4',
  'webm',
  'mkv',
  'mov',
  'm4v',
  'avi',
  '3gp',
};

const _audioExt = {
  'mp3',
  'wav',
  'flac',
  'ogg',
  'oga',
  'm4a',
  'aac',
  'opus',
  'wma',
};

/// Extensions we treat as text without a NUL-byte probe (still decoded as UTF-8).
const _textExt = {
  'txt',
  'md',
  'markdown',
  'dart',
  'py',
  'pyw',
  'js',
  'mjs',
  'cjs',
  'jsx',
  'ts',
  'tsx',
  'json',
  'jsonc',
  'sh',
  'bash',
  'zsh',
  'fish',
  'yaml',
  'yml',
  'html',
  'htm',
  'xhtml',
  'xml',
  'svg',
  'vue',
  'css',
  'scss',
  'less',
  'c',
  'h',
  'cpp',
  'cc',
  'cxx',
  'hpp',
  'hh',
  'java',
  'kt',
  'kts',
  'go',
  'rs',
  'rb',
  'php',
  'swift',
  'sql',
  'toml',
  'ini',
  'cfg',
  'conf',
  'properties',
  'gradle',
  'cmake',
  'lua',
  'r',
  'pl',
  'pm',
  'cs',
  'fs',
  'graphql',
  'gql',
  'proto',
  'diff',
  'patch',
  'dockerfile',
  'mk',
  'makefile',
  'log',
  'csv',
  'tsv',
  'env',
  'gitignore',
  'gitattributes',
  'editorconfig',
  'lock',
};
