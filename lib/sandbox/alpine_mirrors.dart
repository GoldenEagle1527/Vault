import 'dart:io';

import 'package:path/path.dart' as p;

/// Default Alpine apk mirror for mainland China (works without a proxy).
///
/// Preserves the version path from the rootfs (e.g. `/v3.21/main`).
const String kDefaultAlpineApkMirror =
    'https://mirrors.tuna.tsinghua.edu.cn/alpine';

/// Packages installed once when a workspace Alpine rootfs is first created.
///
/// Alpine 3.21+ ships `python3` as 3.12.x; `py3-pip` provides `pip`.
const List<String> kDefaultAlpinePackages = ['git', 'python3', 'py3-pip'];

/// Default PyPI index for mainland China (aligned with apk Tsinghua mirror).
const String kDefaultPipIndexUrl = 'https://pypi.tuna.tsinghua.edu.cn/simple';

/// Host allowed by pip when using [kDefaultPipIndexUrl] over HTTPS.
const String kDefaultPipTrustedHost = 'pypi.tuna.tsinghua.edu.cn';

/// Guest DNS used on Android proot (override rootfs defaults like 1.1.1.1).
const List<String> kDefaultAlpineNameservers = [
  '223.5.5.5', // AliDNS
  '119.29.29.29', // DNSPod
];

/// Matches `https://any.host/alpine` repo roots in `/etc/apk/repositories`.
final _alpineRepoRoot = RegExp(r'https?://[^/\s]+/alpine');

/// True when [repositories] still points away from [mirror].
bool alpineRepositoriesNeedMirror(
  String repositories, {
  String mirror = kDefaultAlpineApkMirror,
}) {
  final normalized = mirror.replaceAll(RegExp(r'/+$'), '');
  for (final match in _alpineRepoRoot.allMatches(repositories)) {
    if (match.group(0) != normalized) return true;
  }
  return false;
}

/// Rewrite apk repo hosts to [mirror], keeping version paths (`/v3.23/main`).
String rewriteAlpineApkRepositories(
  String content, {
  String mirror = kDefaultAlpineApkMirror,
}) {
  final normalized = mirror.replaceAll(RegExp(r'/+$'), '');
  return content.replaceAllMapped(_alpineRepoRoot, (_) => normalized);
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

/// Contents for guest `/etc/resolv.conf` (AliDNS + DNSPod).
String alpineResolvConfContent({
  List<String> nameservers = kDefaultAlpineNameservers,
}) {
  final buf = StringBuffer();
  for (final ns in nameservers) {
    buf.writeln('nameserver $ns');
  }
  return buf.toString();
}

/// Always overwrite `rootfsPath/etc/resolv.conf` with China-friendly DNS.
Future<void> applyAlpineResolvConfOnHost(
  String rootfsPath, {
  List<String> nameservers = kDefaultAlpineNameservers,
}) async {
  final file = File(p.join(rootfsPath, 'etc', 'resolv.conf'));
  await file.parent.create(recursive: true);
  await file.writeAsString(
    alpineResolvConfContent(nameservers: nameservers),
    flush: true,
  );
}

/// POSIX `/bin/sh` snippet that rewrites `/etc/apk/repositories` in-guest.
///
/// Safe for `wsl.exe ... -e /bin/sh -c <script>` — [mirror] must be a plain
/// https URL without shell metacharacters (the default constant is).
String alpineApkMirrorShellScript({
  String mirror = kDefaultAlpineApkMirror,
}) {
  final normalized = mirror.replaceAll(RegExp(r'/+$'), '');
  // Rewrite any `http(s)://host/alpine` root to the China mirror.
  return '''
f=/etc/apk/repositories
if [ -f "\$f" ]; then
  sed -i \\
    -e 's|https://[^/]*/alpine|$normalized|g' \\
    -e 's|http://[^/]*/alpine|$normalized|g' \\
    "\$f"
fi
''';
}

/// Contents for guest `/etc/pip.conf` (China PyPI mirror).
String alpinePipConfContent({
  String indexUrl = kDefaultPipIndexUrl,
  String trustedHost = kDefaultPipTrustedHost,
}) {
  return '[global]\n'
      'index-url = $indexUrl\n'
      'trusted-host = $trustedHost\n';
}

/// Write [alpinePipConfContent] to `rootfsPath/etc/pip.conf` on the host.
Future<void> applyAlpinePipConfOnHost(
  String rootfsPath, {
  String indexUrl = kDefaultPipIndexUrl,
  String trustedHost = kDefaultPipTrustedHost,
}) async {
  final file = File(p.join(rootfsPath, 'etc', 'pip.conf'));
  await file.parent.create(recursive: true);
  await file.writeAsString(
    alpinePipConfContent(indexUrl: indexUrl, trustedHost: trustedHost),
    flush: true,
  );
}

/// POSIX `/bin/sh` snippet that writes `/etc/pip.conf` in-guest.
String alpinePipMirrorShellScript({
  String indexUrl = kDefaultPipIndexUrl,
  String trustedHost = kDefaultPipTrustedHost,
}) {
  // Values come from constants / callers — must stay free of shell metacharacters.
  return '''
mkdir -p /etc
cat > /etc/pip.conf <<'PIPEOF'
${alpinePipConfContent(indexUrl: indexUrl, trustedHost: trustedHost)}PIPEOF
''';
}

/// POSIX `/bin/sh -c` snippet: refresh indexes, install [packages], set pip mirror.
///
/// Package names must be plain apk identifiers (no shell metacharacters).
String alpineApkInstallPackagesShellScript({
  List<String> packages = kDefaultAlpinePackages,
  String pipIndexUrl = kDefaultPipIndexUrl,
  String pipTrustedHost = kDefaultPipTrustedHost,
}) {
  final nameRe = RegExp(r'^[A-Za-z0-9._+-]+$');
  for (final pkg in packages) {
    if (!nameRe.hasMatch(pkg)) {
      throw ArgumentError.value(pkg, 'packages', '非法 apk 包名');
    }
  }
  final pip = alpinePipMirrorShellScript(
    indexUrl: pipIndexUrl,
    trustedHost: pipTrustedHost,
  ).trim();
  if (packages.isEmpty) return pip;
  return '''
set -e
apk update
apk add --no-cache ${packages.join(' ')}
$pip
''';
}
