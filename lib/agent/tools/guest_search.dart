import 'package:vault/sandbox/sandbox_models.dart';

const int kGlobDefaultMaxResults = 200;
const int kGrepDefaultHeadLimit = 100;

const Set<String> kGuestSearchSkipDirNames = {
  '.git',
  '__pycache__',
  'node_modules',
};

/// Prepend `**/` so `*.py` matches at any depth (Cursor-style).
String normalizeGuestGlob(String pattern) {
  final trimmed = pattern.trim();
  if (trimmed.isEmpty) return trimmed;
  if (trimmed.startsWith('**/')) return trimmed;
  return '**/$trimmed';
}

/// Convert a glob (`*`, `**`, `?`) to a [RegExp] anchored on the full string.
RegExp guestGlobToRegExp(String pattern) {
  final glob = normalizeGuestGlob(pattern);
  final buf = StringBuffer('^');
  for (var i = 0; i < glob.length; i++) {
    final c = glob[i];
    if (c == '*') {
      if (i + 1 < glob.length && glob[i + 1] == '*') {
        buf.write('.*');
        i++;
      } else {
        buf.write('[^/]*');
      }
    } else if (c == '?') {
      buf.write('[^/]');
    } else if (r'\.^$+{}[]()|'.contains(c)) {
      buf.write('\\$c');
    } else {
      buf.write(c);
    }
  }
  buf.write(r'$');
  return RegExp(buf.toString());
}

bool guestPathMatchesGlob(String guestPath, String pattern) {
  return guestGlobToRegExp(pattern).hasMatch(guestPath);
}

/// Recursively list files under [root], skipping junk directories.
///
/// [root] must be a directory. Throws [ArgumentError] / [StateError] from
/// [SandboxWorkspace.listGuestDirectory].
Future<List<GuestFsEntry>> collectGuestFiles({
  required SandboxWorkspace workspace,
  required String root,
  bool Function(String guestPath)? includeFile,
}) async {
  final out = <GuestFsEntry>[];
  final queue = <String>[root];
  while (queue.isNotEmpty) {
    final dir = queue.removeAt(0);
    final entries = await workspace.listGuestDirectory(dir);
    for (final entry in entries) {
      if (entry.isDirectory) {
        if (kGuestSearchSkipDirNames.contains(entry.name)) continue;
        queue.add(entry.guestPath);
        continue;
      }
      if (includeFile != null && !includeFile(entry.guestPath)) continue;
      out.add(entry);
    }
  }
  return out;
}
