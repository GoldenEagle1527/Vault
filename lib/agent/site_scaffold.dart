/// Known-good guest layouts for [scaffold_site].
enum SiteScaffoldKind { flask, static }

/// Files + start recipe for one scaffold kind. Does not touch the guest.
class SiteScaffoldPlan {
  const SiteScaffoldPlan({
    required this.kind,
    required this.name,
    required this.port,
    required this.url,
    required this.startCommand,
    required this.files,
  });

  final SiteScaffoldKind kind;
  final String name;
  final int port;
  final String url;
  final String startCommand;

  /// Guest-relative paths (under the project dir) → UTF-8 text.
  final Map<String, String> files;
}

const String kScaffoldFlaskMarker = 'app.py';
const String kScaffoldStaticMarker = 'index.html';

SiteScaffoldKind? parseSiteScaffoldKind(String? raw) {
  switch ((raw ?? '').trim().toLowerCase()) {
    case 'flask':
      return SiteScaffoldKind.flask;
    case 'static':
      return SiteScaffoldKind.static;
    default:
      return null;
  }
}

/// Marker files that mean "this project already has a site skeleton".
const List<String> kScaffoldExistingMarkers = [
  kScaffoldFlaskMarker,
  kScaffoldStaticMarker,
];

const String kFlaskStartCommand = 'python3 app.py';

String siteListenUrl(int port) => 'http://127.0.0.1:$port/';

String staticStartCommand(int port) =>
    'python3 -m http.server $port --bind 127.0.0.1';

String flaskConfigPy(int port) =>
    'HOST = "127.0.0.1"\n'
    'PORT = $port\n';

String startCommandForKind(SiteScaffoldKind kind, int port) {
  return switch (kind) {
    SiteScaffoldKind.flask => kFlaskStartCommand,
    SiteScaffoldKind.static => staticStartCommand(port),
  };
}

int? parseFlaskPortFromConfig(String text) {
  final match = RegExp(
    r'^\s*PORT\s*=\s*(\d+)\s*$',
    multiLine: true,
  ).firstMatch(text);
  if (match == null) return null;
  final port = int.tryParse(match.group(1)!);
  if (port == null || port < 1 || port > 65535) return null;
  return port;
}

String applyFlaskPortToConfig(String? existing, int port) {
  if (existing == null || existing.trim().isEmpty) {
    return flaskConfigPy(port);
  }
  final portLine = RegExp(r'^(\s*PORT\s*=\s*)\d+(\s*)$', multiLine: true);
  if (portLine.hasMatch(existing)) {
    return existing.replaceFirstMapped(
      portLine,
      (match) => '${match[1]}$port${match[2]}',
    );
  }
  final suffix = existing.endsWith('\n') ? '' : '\n';
  return '$existing${suffix}PORT = $port\n';
}

/// Infer kind from marker files, then from a registered start command.
SiteScaffoldKind? inferSiteKind({
  required bool hasAppPy,
  required bool hasRootIndexHtml,
  String? startCommand,
}) {
  if (hasAppPy) return SiteScaffoldKind.flask;
  if (hasRootIndexHtml) return SiteScaffoldKind.static;
  final cmd = (startCommand ?? '').toLowerCase();
  if (cmd.contains('http.server')) return SiteScaffoldKind.static;
  if (cmd.contains('app.py')) return SiteScaffoldKind.flask;
  return null;
}

SiteScaffoldPlan buildSiteScaffold({
  required SiteScaffoldKind kind,
  required String name,
  required int port,
}) {
  final url = siteListenUrl(port);
  switch (kind) {
    case SiteScaffoldKind.flask:
      return SiteScaffoldPlan(
        kind: kind,
        name: name,
        port: port,
        url: url,
        startCommand: startCommandForKind(kind, port),
        files: _flaskFiles(port),
      );
    case SiteScaffoldKind.static:
      return SiteScaffoldPlan(
        kind: kind,
        name: name,
        port: port,
        url: url,
        startCommand: startCommandForKind(kind, port),
        files: _staticFiles(),
      );
  }
}

Map<String, String> _flaskFiles(int port) {
  return {
    'config.py': flaskConfigPy(port),
    'app.py':
        'from flask import Flask, render_template\n'
        '\n'
        'from config import HOST, PORT\n'
        '\n'
        'app = Flask(__name__)\n'
        '\n'
        '\n'
        '@app.route("/")\n'
        'def index():\n'
        '    return render_template("index.html")\n'
        '\n'
        '\n'
        'if __name__ == "__main__":\n'
        '    app.run(host=HOST, port=PORT)\n',
    'templates/base.html':
        '<!DOCTYPE html>\n'
        '<html lang="zh-CN">\n'
        '<head>\n'
        '  <meta charset="utf-8">\n'
        '  <meta name="viewport" content="width=device-width, initial-scale=1">\n'
        '  <title>{% block title %}网站{% endblock %}</title>\n'
        '</head>\n'
        '<body>\n'
        '  {% block body %}{% endblock %}\n'
        '</body>\n'
        '</html>\n',
    'templates/index.html':
        '{% extends "base.html" %}\n'
        '{% block title %}首页{% endblock %}\n'
        '{% block body %}\n'
        '<h1>首页</h1>\n'
        '<p>站点已就绪。在 modules/ 和 templates/ 上继续改。</p>\n'
        '{% endblock %}\n',
    'static/.gitkeep': '',
    'modules/.gitkeep': '',
    'data/.gitkeep': '',
  };
}

Map<String, String> _staticFiles() {
  return {
    'index.html':
        '<!DOCTYPE html>\n'
        '<html lang="zh-CN">\n'
        '<head>\n'
        '  <meta charset="utf-8">\n'
        '  <meta name="viewport" content="width=device-width, initial-scale=1">\n'
        '  <title>网站</title>\n'
        '</head>\n'
        '<body>\n'
        '  <h1>首页</h1>\n'
        '  <p>静态站点已就绪。</p>\n'
        '</body>\n'
        '</html>\n',
  };
}
