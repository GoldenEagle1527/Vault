import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:vault/agent/project_store.dart';
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

  int? get port => _port;
  bool get isRunning => _server != null;
  List<SiteRoute> get routes => _routes;

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

  Future<void> _proxy(HttpRequest req, SiteRoute route) async {
    final client = _client;
    if (client == null) {
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
      req.response.statusCode = upstream.statusCode;
      upstream.headers.forEach((name, values) {
        if (_hopByHop.contains(name.toLowerCase())) return;
        req.response.headers.set(name, values);
      });
      await req.response.addStream(upstream);
      await req.response.close();
    } catch (_) {
      await _writeHtml(
        req,
        HttpStatus.badGateway,
        '站点未启动',
        '请在 Vault 侧栏「站点」里启动「${route.name}」。',
      );
    }
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
