// Browser-side errors captured through SiteGateway in development mode.

const String kVaultProbePath = '/__vault/probe.js';
const String kVaultBrowserLogPath = '/__vault/browser-log';
const String kVaultProbeScriptTag = '<script src="$kVaultProbePath"></script>';

const int kSiteBrowserLogMaxPerSlug = 200;
const int kSiteBrowserLogMaxMessageLength = 2000;
const int kSiteBrowserHtmlInjectMaxBytes = 2 * 1024 * 1024;

/// Same-origin probe: console/error/network only (never console.log).
const String kVaultProbeJs = r'''
(function(){
  if (window.__vaultProbe) return;
  window.__vaultProbe = true;
  var ENDPOINT = '/__vault/browser-log';
  function ctorName(v) {
    try {
      if (v && v.constructor && v.constructor.name) return v.constructor.name;
    } catch (e) {}
    try {
      var tag = Object.prototype.toString.call(v);
      return tag.slice(8, -1);
    } catch (e2) { return 'Object'; }
  }
  function dump(v, depth, seen) {
    if (v == null) return String(v);
    var t = typeof v;
    if (t === 'string') return v.length > 500 ? v.slice(0, 500) + '…' : v;
    if (t === 'number' || t === 'boolean' || t === 'bigint') return String(v);
    if (t === 'symbol') return String(v);
    if (t === 'function') return '[function ' + (v.name || '') + ']';
    if (v instanceof Error) {
      return v.name + ': ' + v.message + (v.stack ? '\n' + v.stack : '');
    }
    if (typeof Element !== 'undefined' && v instanceof Element) {
      var id = v.id ? '#' + v.id : '';
      var cls = (v.className && typeof v.className === 'string')
        ? '.' + String(v.className).trim().split(/\s+/).slice(0, 3).join('.')
        : '';
      return '<' + String(v.tagName).toLowerCase() + id + cls + '>';
    }
    if (v instanceof Date) return v.toISOString();
    if (typeof URL !== 'undefined' && v instanceof URL) return v.href;
    if (v instanceof RegExp) return String(v);
    if (typeof ArrayBuffer !== 'undefined' && v instanceof ArrayBuffer) {
      return '[ArrayBuffer ' + v.byteLength + ']';
    }
    if (typeof ArrayBuffer !== 'undefined' && ArrayBuffer.isView && ArrayBuffer.isView(v)) {
      return '[' + ctorName(v) + ' length=' + v.length + ']';
    }
    if (seen.indexOf(v) >= 0) return '[Circular]';
    if (depth >= 2) return '[' + ctorName(v) + ']';
    seen.push(v);
    if (Array.isArray(v)) {
      var n = Math.min(v.length, 8);
      var items = [];
      for (var i = 0; i < n; i++) items.push(dump(v[i], depth + 1, seen));
      if (v.length > n) items.push('…+' + (v.length - n));
      return '[' + items.join(', ') + ']';
    }
    var keys;
    try { keys = Object.keys(v); } catch (e) { return '[' + ctorName(v) + ']'; }
    var out = {};
    var added = 0;
    var prefer = ['name', 'type', 'id', 'uuid', 'code', 'status', 'message', 'title', 'label', 'kind'];
    function take(k) {
      if (added >= 10 || Object.prototype.hasOwnProperty.call(out, k)) return;
      var val;
      try { val = v[k]; } catch (e) { return; }
      var vt = typeof val;
      if (vt === 'function' || vt === 'undefined') return;
      if (vt === 'object' && val !== null) {
        out[k] = depth >= 1 ? '[' + ctorName(val) + ']' : dump(val, depth + 1, seen);
      } else if (vt === 'number' && !isFinite(val)) {
        out[k] = String(val);
      } else {
        out[k] = val;
      }
      added++;
    }
    for (var p = 0; p < prefer.length; p++) {
      try { if (prefer[p] in v) take(prefer[p]); } catch (e) {}
    }
    for (var j = 0; j < keys.length && added < 10; j++) take(keys[j]);
    var json;
    try { json = JSON.stringify(out); } catch (e) { json = '{}'; }
    return ctorName(v) + ' ' + json;
  }
  function summarize(v) {
    try { return dump(v, 0, []); } catch (e) { return '[unserializable]'; }
  }
  function post(evt) {
    try {
      evt.t = evt.t || Date.now();
      evt.href = evt.href || location.href;
      var body = JSON.stringify(evt);
      fetch(ENDPOINT, {
        method: 'POST',
        headers: {'Content-Type': 'application/json'},
        body: body,
        keepalive: true
      }).catch(function(){});
    } catch (e) {}
  }
  function wrap(level) {
    var orig = console[level];
    console[level] = function() {
      var parts = [];
      for (var i = 0; i < arguments.length; i++) {
        try { parts.push(summarize(arguments[i])); } catch (e) { parts.push('[unserializable]'); }
      }
      post({type:'console', level: level, message: parts.join(' ')});
      return orig.apply(console, arguments);
    };
  }
  wrap('error');
  wrap('warn');
  window.addEventListener('error', function(e) {
    if (e.target && e.target !== window) {
      var src = e.target.src || e.target.href || '';
      post({type:'resource', level:'error', message: 'resource failed: ' + src, source: src});
      return;
    }
    post({
      type:'error',
      level:'error',
      message: e.message || 'error',
      source: e.filename,
      line: e.lineno
    });
  }, true);
  window.addEventListener('unhandledrejection', function(e) {
    post({type:'unhandledrejection', level:'error', message: summarize(e.reason)});
  });
  if (window.fetch) {
    var rawFetch = window.fetch;
    window.fetch = function(input, init) {
      var url = typeof input === 'string' ? input : (input && input.url) || '';
      if (String(url).indexOf(ENDPOINT) !== -1) {
        return rawFetch.apply(this, arguments);
      }
      return rawFetch.apply(this, arguments).then(function(res) {
        if (res.status >= 400) {
          post({
            type:'network',
            level:'error',
            message: ((init && init.method) || 'GET') + ' ' + url,
            status: res.status
          });
        }
        return res;
      });
    };
  }
  if (window.XMLHttpRequest) {
    var xhrOpen = XMLHttpRequest.prototype.open;
    var xhrSend = XMLHttpRequest.prototype.send;
    XMLHttpRequest.prototype.open = function(method, url) {
      this.__vaultMethod = method;
      this.__vaultUrl = url;
      return xhrOpen.apply(this, arguments);
    };
    XMLHttpRequest.prototype.send = function() {
      this.addEventListener('loadend', function() {
        if (this.status >= 400) {
          post({
            type:'network',
            level:'error',
            message: (this.__vaultMethod || 'GET') + ' ' + (this.__vaultUrl || ''),
            status: this.status
          });
        }
      });
      return xhrSend.apply(this, arguments);
    };
  }
})();
''';

/// One captured console / network / gateway event.
class SiteBrowserEvent {
  const SiteBrowserEvent({
    required this.at,
    required this.slug,
    required this.type,
    required this.level,
    required this.message,
    this.href,
    this.source,
    this.line,
    this.status,
    this.count = 1,
  });

  final DateTime at;
  final String slug;
  final String type;
  final String level;
  final String message;
  final String? href;
  final String? source;
  final int? line;
  final int? status;
  final int count;

  String get _dedupeKey => '$type\x1f$level\x1f$message';

  Map<String, dynamic> toJson() => {
    'at': at.toIso8601String(),
    'slug': slug,
    'type': type,
    'level': level,
    'message': message,
    if (href != null && href!.isNotEmpty) 'href': href,
    if (source != null && source!.isNotEmpty) 'source': source,
    if (line != null) 'line': line,
    if (status != null) 'status': status,
    if (count > 1) 'count': count,
  };

  factory SiteBrowserEvent.fromJson(Map<String, dynamic> json) {
    final atRaw = json['at']?.toString();
    return SiteBrowserEvent(
      at: atRaw == null
          ? DateTime.now()
          : DateTime.tryParse(atRaw) ?? DateTime.now(),
      slug: json['slug']?.toString() ?? '',
      type: json['type']?.toString() ?? 'console',
      level: json['level']?.toString() ?? 'error',
      message: json['message']?.toString() ?? '',
      href: json['href']?.toString(),
      source: json['source']?.toString(),
      line: _asInt(json['line']),
      status: _asInt(json['status']),
      count: _asInt(json['count']) ?? 1,
    );
  }
}

int? _asInt(Object? raw) {
  if (raw is int) return raw;
  if (raw is num) return raw.toInt();
  return int.tryParse('$raw');
}

String clipSiteBrowserMessage(String raw) {
  if (raw.length <= kSiteBrowserLogMaxMessageLength) return raw;
  return raw.substring(0, kSiteBrowserLogMaxMessageLength);
}

/// Per-slug ring buffer of browser / gateway events.
class SiteBrowserLog {
  final Map<String, List<SiteBrowserEvent>> _bySlug = {};

  void add(SiteBrowserEvent event) {
    final slug = event.slug.trim().isEmpty ? 'unknown' : event.slug.trim();
    final stored = SiteBrowserEvent(
      at: event.at,
      slug: slug,
      type: event.type,
      level: event.level,
      message: clipSiteBrowserMessage(event.message),
      href: event.href,
      source: event.source,
      line: event.line,
      status: event.status,
      count: event.count,
    );
    final list = _bySlug.putIfAbsent(slug, () => <SiteBrowserEvent>[]);
    for (var i = list.length - 1; i >= 0; i--) {
      if (list[i]._dedupeKey != stored._dedupeKey) continue;
      list[i] = SiteBrowserEvent(
        at: stored.at,
        slug: slug,
        type: stored.type,
        level: stored.level,
        message: stored.message,
        href: stored.href ?? list[i].href,
        source: stored.source ?? list[i].source,
        line: stored.line ?? list[i].line,
        status: stored.status ?? list[i].status,
        count: list[i].count + stored.count,
      );
      return;
    }
    list.add(stored);
    if (list.length > kSiteBrowserLogMaxPerSlug) {
      list.removeRange(0, list.length - kSiteBrowserLogMaxPerSlug);
    }
  }

  List<SiteBrowserEvent> forSlug(String slug) =>
      List.unmodifiable(_bySlug[slug] ?? const []);

  List<SiteBrowserEvent> get all => [
    for (final list in _bySlug.values) ...list,
  ];

  List<SiteBrowserEvent> recent({
    String? slug,
    DateTime? since,
    bool includeWarn = true,
    Iterable<String>? slugs,
  }) {
    Iterable<SiteBrowserEvent> events;
    final one = slug?.trim();
    if (one != null && one.isNotEmpty) {
      events = forSlug(one);
    } else if (slugs != null) {
      events = slugs.expand(forSlug);
    } else {
      events = all;
    }
    if (since != null) {
      events = events.where((e) => !e.at.isBefore(since));
    }
    if (!includeWarn) {
      events = events.where((e) => e.level != 'warn');
    }
    final list = events.toList()..sort((a, b) => a.at.compareTo(b.at));
    return list;
  }

  void clear() => _bySlug.clear();
}

/// Insert the probe script after `<head>` (or at the top if there is no head).
String injectVaultProbeScript(String html) {
  if (html.contains(kVaultProbePath)) return html;
  final head = RegExp(r'<head[^>]*>', caseSensitive: false).firstMatch(html);
  if (head != null) {
    return html.replaceRange(head.end, head.end, kVaultProbeScriptTag);
  }
  final htmlTag = RegExp(r'<html[^>]*>', caseSensitive: false).firstMatch(html);
  if (htmlTag != null) {
    return html.replaceRange(
      htmlTag.end,
      htmlTag.end,
      '<head>$kVaultProbeScriptTag</head>',
    );
  }
  return '$kVaultProbeScriptTag$html';
}

bool isNoisyBrowserPath(String path) {
  final p = path.toLowerCase();
  return p.endsWith('/favicon.ico') ||
      p.endsWith('/robots.txt') ||
      p.endsWith('/apple-touch-icon.png') ||
      p.endsWith('/apple-touch-icon-precomposed.png');
}

/// Collapse identical messages so the tool result stays small JSON.
List<Map<String, dynamic>> browserEventsForTool(List<SiteBrowserEvent> events) {
  final out = <String, Map<String, dynamic>>{};
  final order = <String>[];
  for (final e in events) {
    final key = e._dedupeKey;
    final prev = out[key];
    if (prev == null) {
      out[key] = e.toJson();
      out[key]!['count'] = e.count;
      order.add(key);
    } else {
      prev['count'] = (prev['count'] as int) + e.count;
      prev['last_at'] = e.at.toIso8601String();
    }
  }
  return [for (final k in order) out[k]!];
}

SiteBrowserEvent? siteBrowserEventFromPayload(
  Map<String, dynamic> map, {
  required String fallbackSlug,
}) {
  final level = (map['level']?.toString() ?? 'error').trim();
  if (level != 'error' && level != 'warn') return null;
  var message = map['message']?.toString() ?? '';
  final args = map['args'];
  if (message.isEmpty && args is List) {
    message = args.map((e) => '$e').join(' ');
  }
  message = clipSiteBrowserMessage(message.trim());
  if (message.isEmpty) return null;
  final slug = (map['slug']?.toString() ?? '').trim();
  final t = _asInt(map['t']);
  return SiteBrowserEvent(
    at: t == null
        ? DateTime.now()
        : DateTime.fromMillisecondsSinceEpoch(t, isUtc: false),
    slug: slug.isEmpty ? fallbackSlug : slug,
    type: (map['type']?.toString() ?? 'console').trim(),
    level: level,
    message: message,
    href: map['href']?.toString(),
    source: map['source']?.toString(),
    line: _asInt(map['line']),
    status: _asInt(map['status']),
  );
}
