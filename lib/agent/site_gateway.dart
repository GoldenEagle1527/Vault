import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:vault/agent/project_store.dart';
import 'package:vault/agent/site_browser_log.dart';
import 'package:vault/agent/site_port.dart';

/// One Host-routed backend behind [SiteGateway].
class SiteRoute {
  const SiteRoute({
    required this.slug,
    required this.name,
    required this.projectName,
    required this.backend,
  });

  final String slug;
  final String name;
  final String projectName;
  final Uri backend;
}

/// Workspace-scoped loopback reverse proxy.
///
/// Binds one `127.0.0.1` port (sticky preferred, else ephemeral) and routes
/// `http://{slug}.localhost:{port}/` to each site's internal listen URL.
///
/// v1 is HTTP/1.1 only — no WebSocket upgrade (static / Flask is enough).
/// Some older Android WebViews resolve `*.localhost` poorly; we open the
/// system browser. A path fallback can be added later if a device needs it.
class SiteGateway {
  HttpServer? _server;
  HttpClient? _client;
  int? _port;
  List<SiteRoute> _routes = const [];
  final SiteBrowserLog _browserLog = SiteBrowserLog();

  /// When true, inject probe.js into HTML and keep a ring buffer of errors.
  bool captureEnabled = false;

  int? get port => _port;
  bool get isRunning => _server != null;
  List<SiteRoute> get routes => _routes;

  /// Recent captured events (console / network / gateway).
  List<SiteBrowserEvent> recentEvents({
    String? slug,
    DateTime? since,
    bool includeWarn = true,
    Iterable<String>? slugs,
  }) {
    return _browserLog.recent(
      slug: slug,
      since: since,
      includeWarn: includeWarn,
      slugs: slugs,
    );
  }

  void recordEvent(SiteBrowserEvent event) => _browserLog.add(event);

  /// Bind [preferredPort] when possible; otherwise `bind(0)`.
  Future<int> start({int preferredPort = 0}) async {
    if (_server != null && _port != null) return _port!;
    if (preferredPort > 0) {
      try {
        return await _bind(preferredPort);
      } catch (_) {
        // Preferred port taken by the environment — fall back to ephemeral.
      }
    }
    return _bind(0);
  }

  Future<int> _bind(int port) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    _server = server;
    _port = server.port;
    _client = HttpClient();
    server.listen(
      _handle,
      onError: (Object e, StackTrace st) {
        stderr.writeln('SiteGateway listen error: $e\n$st');
      },
    );
    return _port!;
  }

  void updateRoutes(List<SiteRoute> routes) {
    _routes = List.unmodifiable(routes);
  }

  String? publicUrl(String slug) {
    final p = _port;
    if (p == null || slug.trim().isEmpty) return null;
    return sitePublicUrl(slug: slug.trim(), gatewayPort: p);
  }

  Future<void> stop() async {
    final server = _server;
    final client = _client;
    _server = null;
    _client = null;
    _port = null;
    _routes = const [];
    _browserLog.clear();
    client?.close(force: true);
    await server?.close(force: true);
  }

  Future<void> _handle(HttpRequest req) async {
    try {
      final upgrade = req.headers.value(HttpHeaders.upgradeHeader);
      if (upgrade != null && upgrade.toLowerCase().contains('websocket')) {
        await _writeHtml(
          req,
          HttpStatus.notImplemented,
          '不支持 WebSocket',
          '工作区站点网关目前只反代普通 HTTP。',
        );
        return;
      }

      if (await _tryHandleVaultPath(req)) return;

      final host = req.headers.value(HttpHeaders.hostHeader) ?? '';
      final slug = siteSlugFromHost(host);
      if (slug == null) {
        await _writeDirectory(req);
        return;
      }
      SiteRoute? route;
      for (final r in _routes) {
        if (r.slug == slug) {
          route = r;
          break;
        }
      }
      if (route == null) {
        _recordGateway(
          slug: slug,
          path: req.uri.path,
          status: HttpStatus.notFound,
          message: '没有名为「$slug」的站点',
        );
        await _writeDirectory(req, missing: slug);
        return;
      }
      await _proxy(req, route);
    } catch (e, st) {
      stderr.writeln('SiteGateway request error: $e\n$st');
      try {
        await _writeHtml(
          req,
          HttpStatus.internalServerError,
          '网关错误',
          '处理请求时出错。',
        );
      } catch (_) {}
    }
  }

  Future<bool> _tryHandleVaultPath(HttpRequest req) async {
    final path = req.uri.path;
    if (path != kVaultProbePath && path != kVaultBrowserLogPath) {
      return false;
    }
    if (path == kVaultProbePath) {
      if (req.method != 'GET' && req.method != 'HEAD') {
        req.response.statusCode = HttpStatus.methodNotAllowed;
        await req.response.close();
        return true;
      }
      req.response.statusCode = HttpStatus.ok;
      req.response.headers.contentType = ContentType(
        'application',
        'javascript',
        charset: 'utf-8',
      );
      req.response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
      if (req.method == 'GET') {
        req.response.write(captureEnabled ? kVaultProbeJs : '');
      }
      await req.response.close();
      return true;
    }

    if (req.method != 'POST') {
      req.response.statusCode = HttpStatus.methodNotAllowed;
      await req.response.close();
      return true;
    }
    final raw = await utf8.decoder.bind(req).join();
    if (captureEnabled) {
      final host = req.headers.value(HttpHeaders.hostHeader) ?? '';
      final slug = siteSlugFromHost(host) ?? 'unknown';
      _ingestBrowserLog(raw, fallbackSlug: slug);
    }
    req.response.statusCode = HttpStatus.noContent;
    await req.response.close();
    return true;
  }

  void _ingestBrowserLog(String raw, {required String fallbackSlug}) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      final event = siteBrowserEventFromPayload(
        Map<String, dynamic>.from(decoded),
        fallbackSlug: fallbackSlug,
      );
      if (event != null) recordEvent(event);
    } catch (_) {}
  }

  void _recordGateway({
    required String slug,
    required String path,
    required int status,
    required String message,
  }) {
    if (!captureEnabled || isNoisyBrowserPath(path)) return;
    recordEvent(
      SiteBrowserEvent(
        at: DateTime.now(),
        slug: slug,
        type: 'gateway',
        level: 'error',
        message: message,
        href: path,
        status: status,
      ),
    );
  }

  Future<void> _proxy(HttpRequest req, SiteRoute route) async {
    final client = _client;
    if (client == null) {
      _recordGateway(
        slug: route.slug,
        path: req.uri.path,
        status: HttpStatus.badGateway,
        message: '网关未启动',
      );
      await _writeHtml(req, HttpStatus.badGateway, '网关未启动', '请重新进入工作区。');
      return;
    }
    final target = route.backend.replace(
      path: req.uri.path,
      query: req.uri.query.isEmpty ? null : req.uri.query,
    );
    try {
      final outbound = await client.openUrl(req.method, target);
      outbound.followRedirects = false;
      outbound.maxRedirects = 0;
      req.headers.forEach((name, values) {
        if (_hopByHop.contains(name.toLowerCase())) return;
        outbound.headers.set(name, values);
      });
      outbound.headers.set(
        HttpHeaders.hostHeader,
        target.hasPort ? '${target.host}:${target.port}' : target.host,
      );
      await outbound.addStream(req);
      final upstream = await outbound.close();
      if (upstream.statusCode >= 400) {
        _recordGateway(
          slug: route.slug,
          path: req.uri.path,
          status: upstream.statusCode,
          message: '上游 ${upstream.statusCode} ${req.method} ${req.uri.path}',
        );
      }
      if (captureEnabled && _isHtmlHeaders(upstream.headers)) {
        await _proxyHtml(req, upstream);
        return;
      }
      req.response.statusCode = upstream.statusCode;
      upstream.headers.forEach((name, values) {
        if (_hopByHop.contains(name.toLowerCase())) return;
        req.response.headers.set(name, values);
      });
      await req.response.addStream(upstream);
      await req.response.close();
    } catch (_) {
      _recordGateway(
        slug: route.slug,
        path: req.uri.path,
        status: HttpStatus.badGateway,
        message: '站点未启动（502）',
      );
      await _writeHtml(
        req,
        HttpStatus.badGateway,
        '站点未启动',
        '请在 Vault 侧栏点启动打开「${route.name}」。',
      );
    }
  }

  Future<void> _proxyHtml(HttpRequest req, HttpClientResponse upstream) async {
    final builder = BytesBuilder(copy: false);
    var overLimit = false;
    await for (final chunk in upstream) {
      builder.add(chunk);
      if (builder.length > kSiteBrowserHtmlInjectMaxBytes) overLimit = true;
    }
    final bytes = builder.takeBytes();
    req.response.statusCode = upstream.statusCode;
    upstream.headers.forEach((name, values) {
      final lower = name.toLowerCase();
      if (_hopByHop.contains(lower)) return;
      if (lower == 'content-length' || lower == 'content-encoding') return;
      req.response.headers.set(name, values);
    });
    if (overLimit) {
      req.response.headers.contentLength = bytes.length;
      req.response.add(bytes);
      await req.response.close();
      return;
    }
    final html = injectVaultProbeScript(
      utf8.decode(bytes, allowMalformed: true),
    );
    final out = utf8.encode(html);
    req.response.headers.contentType =
        upstream.headers.contentType ?? ContentType.html;
    req.response.headers.contentLength = out.length;
    req.response.add(out);
    await req.response.close();
  }

  bool _isHtmlHeaders(HttpHeaders headers) {
    final ct = headers.contentType;
    if (ct != null) return ct.mimeType == 'text/html';
    final raw = headers.value(HttpHeaders.contentTypeHeader) ?? '';
    return raw.toLowerCase().contains('text/html');
  }

  Future<void> _writeDirectory(HttpRequest req, {String? missing}) async {
    final p = _port ?? 0;
    final items = _routes.map((r) {
      final href = sitePublicUrl(slug: r.slug, gatewayPort: p);
      return '<li><a href="$href">${_escape(r.name)}</a>'
          ' <span>（${_escape(r.projectName)}）</span></li>';
    }).join();
    final missingLine = missing == null
        ? ''
        : '<p>没有名为「${_escape(missing)}」的站点。</p>';
    final empty = _routes.isEmpty
        ? '<p>这个工作区还没有登记站点。让 Agent 做好网站后会出现在这里。</p>'
        : '<ul>$items</ul>';
    await _writeHtml(
      req,
      missing == null ? HttpStatus.ok : HttpStatus.notFound,
      '工作区站点',
      '$missingLine$empty',
    );
  }

  Future<void> _writeHtml(
    HttpRequest req,
    int status,
    String title,
    String body,
  ) async {
    if (req.response.headers.chunkedTransferEncoding) {
      // Response may already be in flight after a failed proxy.
    }
    req.response.statusCode = status;
    req.response.headers.contentType = ContentType.html;
    req.response.write(
      '<!doctype html><html lang="zh"><head><meta charset="utf-8">'
      '<title>${_escape(title)}</title></head><body>'
      '<h1>${_escape(title)}</h1>$body</body></html>',
    );
    await req.response.close();
  }
}

const _hopByHop = {
  'connection',
  'keep-alive',
  'proxy-authenticate',
  'proxy-authorization',
  'te',
  'trailers',
  'transfer-encoding',
  'upgrade',
  'host',
};

String _escape(String raw) {
  return const HtmlEscape().convert(raw);
}

/// Build gateway routes from the workspace project list.
List<SiteRoute> siteRoutesFromProjects(List<ProjectInfo> projects) {
  return [
    for (final project in projects)
      for (final entry in project.urls)
        if (entry.slug != null &&
            entry.slug!.trim().isNotEmpty &&
            portFromSiteUrl(entry.url) != null)
          SiteRoute(
            slug: entry.slug!.trim(),
            name: entry.name,
            projectName: project.name,
            backend: Uri.parse(entry.url.trim()),
          ),
  ];
}
