/// Port from a registered site URL (`http` → 80, `https` → 443 when omitted).
int? portFromSiteUrl(String url) {
  final uri = Uri.tryParse(url.trim());
  if (uri == null || uri.host.isEmpty) return null;
  if (uri.hasPort) return uri.port;
  if (uri.scheme == 'https') return 443;
  if (uri.scheme == 'http') return 80;
  return null;
}

/// ASCII hostname label for `http://{slug}.localhost:{port}/`.
///
/// Non-Latin names (e.g. 「网站」) become `site`, `site-2`, …
String allocateSiteSlug(String name, Iterable<String> taken) {
  var base = name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-');
  base = base.replaceAll(RegExp(r'^-+|-+$'), '');
  if (base.length > 32) {
    base = base.substring(0, 32).replaceAll(RegExp(r'-+$'), '');
  }
  if (base.isEmpty) base = 'site';
  final takenSet = {for (final s in taken) s.toLowerCase()};
  if (!takenSet.contains(base)) return base;
  for (var i = 2; ; i++) {
    final candidate = '$base-$i';
    if (!takenSet.contains(candidate)) return candidate;
  }
}

/// User-facing gateway URL. Public port is computed, never persisted as truth.
String sitePublicUrl({required String slug, required int gatewayPort}) {
  return 'http://$slug.localhost:$gatewayPort/';
}

/// Extract `{slug}` from `slug.localhost` / `slug.localhost:port`.
///
/// Bare `localhost` / `127.0.0.1` (with or without port) → `null` (directory).
String? siteSlugFromHost(String host) {
  var h = host.trim().toLowerCase();
  final colon = h.lastIndexOf(':');
  if (colon > 0 && !h.contains(']')) {
    final maybePort = h.substring(colon + 1);
    if (int.tryParse(maybePort) != null) {
      h = h.substring(0, colon);
    }
  }
  if (h == 'localhost' || h == '127.0.0.1') return null;
  const suffix = '.localhost';
  if (!h.endsWith(suffix)) return null;
  final slug = h.substring(0, h.length - suffix.length);
  if (slug.isEmpty || slug.contains('.')) return null;
  return slug;
}

/// One registered site that occupies an internal listen port.
class SitePortClaim {
  const SitePortClaim({
    required this.projectPath,
    required this.projectName,
    required this.siteName,
    required this.port,
    this.slug,
  });

  final String projectPath;
  final String projectName;
  final String siteName;
  final int port;
  final String? slug;
}

class SitePortConflictException implements Exception {
  SitePortConflictException(this.message, {this.claim});

  final String message;
  final SitePortClaim? claim;

  @override
  String toString() => message;
}

/// First unused TCP port at or above [start] (default 8765).
int allocateSitePort(Iterable<int> taken, {int start = 8765}) {
  final takenSet = taken.toSet();
  for (var port = start; port <= 65535; port++) {
    if (!takenSet.contains(port)) return port;
  }
  throw StateError('没有可用端口（已从 $start 查到 65535）');
}

/// First claim of [port] that is not in [ignoreProjectPath].
SitePortClaim? findWorkspacePortConflict({
  required Iterable<SitePortClaim> claims,
  required int port,
  String? ignoreProjectPath,
}) {
  for (final claim in claims) {
    if (ignoreProjectPath != null && claim.projectPath == ignoreProjectPath) {
      continue;
    }
    if (claim.port == port) return claim;
  }
  return null;
}
