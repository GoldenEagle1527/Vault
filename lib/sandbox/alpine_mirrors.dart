import 'dart:io';

import 'package:path/path.dart' as p;

/// Default Alpine apk mirror for mainland China (works without a proxy).
///
/// Preserves the version path from the rootfs (e.g. `/v3.21/main`).
const String kDefaultAlpineApkMirror = 'https://mirrors.aliyun.com/alpine';

/// Packages installed once when a workspace Alpine rootfs is first created.
const List<String> kDefaultAlpinePackages = ['git'];

final _officialAlpineHost = RegExp(
  r'https?://(?:dl-cdn|dl-\d+)\.alpinelinux\.org/alpine',
);

/// True when [repositories] still points at the official Alpine CDN.
bool alpineRepositoriesNeedMirror(String repositories) =>
    _officialAlpineHost.hasMatch(repositories);

/// Rewrite official Alpine CDN URLs in `/etc/apk/repositories` content.
String rewriteAlpineApkRepositories(
  String content, {
  String mirror = kDefaultAlpineApkMirror,
}) {
  final normalized = mirror.replaceAll(RegExp(r'/+$'), '');
  return content.replaceAllMapped(_officialAlpineHost, (_) => normalized);
}

/// Apply [mirror] to `rootfsPath/etc/apk/repositories` on the host filesystem
/// (Android proot extracts rootfs as a normal directory tree).
Future<bool> applyAlpineApkMirrorOnHost(
  String rootfsPath, {
  String mirror = kDefaultAlpineApkMirror,
}) async {
  final file = File(p.join(rootfsPath, 'etc', 'apk', 'repositories'));
  if (!await file.exists()) return false;
  final original = await file.readAsString();
  final rewritten = rewriteAlpineApkRepositories(original, mirror: mirror);
  if (rewritten == original) return false;
  await file.writeAsString(rewritten, flush: true);
  return true;
}

/// POSIX `/bin/sh` snippet that rewrites `/etc/apk/repositories` in-guest.
///
/// Safe for `wsl.exe ... -e /bin/sh -c <script>` — [mirror] must be a plain
/// https URL without shell metacharacters (the default constant is).
String alpineApkMirrorShellScript({
  String mirror = kDefaultAlpineApkMirror,
}) {
  final normalized = mirror.replaceAll(RegExp(r'/+$'), '');
  // Explicit http/https replacements — BusyBox sed may not support `\?`.
  return '''
f=/etc/apk/repositories
if [ -f "\$f" ]; then
  sed -i \\
    -e 's|https://dl-cdn.alpinelinux.org/alpine|$normalized|g' \\
    -e 's|http://dl-cdn.alpinelinux.org/alpine|$normalized|g' \\
    -e 's|https://dl-[0-9].alpinelinux.org/alpine|$normalized|g' \\
    -e 's|http://dl-[0-9].alpinelinux.org/alpine|$normalized|g' \\
    "\$f"
fi
''';
}

/// POSIX `/bin/sh -c` snippet: refresh indexes then install [packages].
///
/// Package names must be plain apk identifiers (no shell metacharacters).
String alpineApkInstallPackagesShellScript({
  List<String> packages = kDefaultAlpinePackages,
}) {
  if (packages.isEmpty) return 'true';
  final nameRe = RegExp(r'^[A-Za-z0-9._+-]+$');
  for (final pkg in packages) {
    if (!nameRe.hasMatch(pkg)) {
      throw ArgumentError.value(pkg, 'packages', '非法 apk 包名');
    }
  }
  return 'apk update && apk add --no-cache ${packages.join(' ')}';
}
