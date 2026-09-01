import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vault/agent/site_gateway.dart';

void main() {
  test('binds a random port and proxies by Host', () async {
    final backend = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(backend.close);
    backend.listen((req) async {
      req.response.write('hello-from-backend');
      await req.response.close();
    });

    final gateway = SiteGateway();
    addTearDown(gateway.stop);
    final port = await gateway.start();
    expect(port, greaterThan(0));
    gateway.updateRoutes([
      SiteRoute(
        slug: 'demo',
        name: 'Demo',
        projectName: 'P',
        backend: Uri.parse('http://127.0.0.1:${backend.port}/'),
      ),
    ]);

    final client = HttpClient();
    addTearDown(client.close);
    final req = await client.getUrl(Uri.parse('http://127.0.0.1:$port/'));
    req.headers.set(HttpHeaders.hostHeader, 'demo.localhost:$port');
    final res = await req.close();
    final body = await utf8.decoder.bind(res).join();
    expect(res.statusCode, 200);
    expect(body, contains('hello-from-backend'));
  });

  test('directory page without slug Host', () async {
    final gateway = SiteGateway();
    addTearDown(gateway.stop);
    final port = await gateway.start();
    gateway.updateRoutes([
      SiteRoute(
        slug: 'demo',
        name: '演示',
        projectName: '项目甲',
        backend: Uri.parse('http://127.0.0.1:9/'),
      ),
    ]);

    final client = HttpClient();
    addTearDown(client.close);
    final req = await client.getUrl(Uri.parse('http://127.0.0.1:$port/'));
    final res = await req.close();
    final body = await utf8.decoder.bind(res).join();
    expect(res.statusCode, 200);
    expect(body, contains('工作区站点'));
    expect(body, contains('演示'));
    expect(body, contains('demo.localhost:$port'));
  });

  test('502 when backend is down', () async {
    final gateway = SiteGateway();
    addTearDown(gateway.stop);
    final port = await gateway.start();
    gateway.updateRoutes([
      SiteRoute(
        slug: 'down',
        name: '挂了',
        projectName: 'P',
        backend: Uri.parse('http://127.0.0.1:1/'),
      ),
    ]);

    final client = HttpClient();
    addTearDown(client.close);
    final req = await client.getUrl(Uri.parse('http://127.0.0.1:$port/'));
    req.headers.set(HttpHeaders.hostHeader, 'down.localhost:$port');
    final res = await req.close();
    final body = await utf8.decoder.bind(res).join();
    expect(res.statusCode, 502);
    expect(body, contains('站点未启动'));
    expect(body, contains('挂了'));
  });

  test('injects probe.js into HTML when capture is on', () async {
    final backend = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(backend.close);
    backend.listen((req) async {
      req.response.headers.contentType = ContentType.html;
      req.response.write(
        '<!doctype html><html><head><title>t</title></head>'
        '<body>hello-html</body></html>',
      );
      await req.response.close();
    });

    final gateway = SiteGateway()..captureEnabled = true;
    addTearDown(gateway.stop);
    final port = await gateway.start();
    gateway.updateRoutes([
      SiteRoute(
        slug: 'demo',
        name: 'Demo',
        projectName: 'P',
        backend: Uri.parse('http://127.0.0.1:${backend.port}/'),
      ),
    ]);

    final client = HttpClient();
    addTearDown(client.close);
    final req = await client.getUrl(Uri.parse('http://127.0.0.1:$port/'));
    req.headers.set(HttpHeaders.hostHeader, 'demo.localhost:$port');
    final res = await req.close();
    final body = await utf8.decoder.bind(res).join();
    expect(res.statusCode, 200);
    expect(body, contains('hello-html'));
    expect(body, contains('/__vault/probe.js'));
    expect(body, contains('<head><script src="/__vault/probe.js"></script>'));
  });

  test('does not rewrite JS or JSON when capture is on', () async {
    final backend = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(backend.close);
    backend.listen((req) async {
      if (req.uri.path.endsWith('.js')) {
        req.response.headers.contentType = ContentType(
          'application',
          'javascript',
        );
        req.response.write('console.log("app")');
      } else {
        req.response.headers.contentType = ContentType.json;
        req.response.write('{"ok":true}');
      }
      await req.response.close();
    });

    final gateway = SiteGateway()..captureEnabled = true;
    addTearDown(gateway.stop);
    final port = await gateway.start();
    gateway.updateRoutes([
      SiteRoute(
        slug: 'demo',
        name: 'Demo',
        projectName: 'P',
        backend: Uri.parse('http://127.0.0.1:${backend.port}/'),
      ),
    ]);

    final client = HttpClient();
    addTearDown(client.close);

    Future<String> get(String path, String typeHint) async {
      final req = await client.getUrl(Uri.parse('http://127.0.0.1:$port$path'));
      req.headers.set(HttpHeaders.hostHeader, 'demo.localhost:$port');
      final res = await req.close();
      expect(res.statusCode, 200, reason: typeHint);
      return utf8.decoder.bind(res).join();
    }

    expect(await get('/app.js', 'js'), 'console.log("app")');
    expect(await get('/data.json', 'json'), '{"ok":true}');
  });

  test('serves probe.js and records POST /__vault/browser-log', () async {
    final backend = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(backend.close);
    var backendHits = 0;
    backend.listen((req) async {
      backendHits++;
      req.response.statusCode = 500;
      await req.response.close();
    });

    final gateway = SiteGateway()..captureEnabled = true;
    addTearDown(gateway.stop);
    final port = await gateway.start();
    gateway.updateRoutes([
      SiteRoute(
        slug: 'demo',
        name: 'Demo',
        projectName: 'P',
        backend: Uri.parse('http://127.0.0.1:${backend.port}/'),
      ),
    ]);

    final client = HttpClient();
    addTearDown(client.close);

    final jsReq = await client.getUrl(
      Uri.parse('http://127.0.0.1:$port/__vault/probe.js'),
    );
    jsReq.headers.set(HttpHeaders.hostHeader, 'demo.localhost:$port');
    final jsRes = await jsReq.close();
    final jsBody = await utf8.decoder.bind(jsRes).join();
    expect(jsRes.statusCode, 200);
    expect(jsBody, contains('__vaultProbe'));
    expect(jsBody, contains('/__vault/browser-log'));
    expect(backendHits, 0);

    final post = await client.postUrl(
      Uri.parse('http://127.0.0.1:$port/__vault/browser-log'),
    );
    post.headers.set(HttpHeaders.hostHeader, 'demo.localhost:$port');
    post.headers.contentType = ContentType.json;
    post.write(
      jsonEncode({
        'type': 'error',
        'level': 'error',
        'message': 'Uncaught TypeError: x is not a function',
        'source': 'app.js',
        'line': 12,
      }),
    );
    final postRes = await post.close();
    await postRes.drain<void>();
    expect(postRes.statusCode, 204);
    expect(backendHits, 0);

    final events = gateway.recentEvents(slug: 'demo');
    expect(events, hasLength(1));
    expect(events.single.message, contains('TypeError'));
    expect(events.single.source, 'app.js');
    expect(events.single.line, 12);
  });

  test('records upstream 500 and gateway 502 when capture is on', () async {
    final backend = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(backend.close);
    backend.listen((req) async {
      req.response.statusCode = 500;
      req.response.write('boom');
      await req.response.close();
    });

    final gateway = SiteGateway()..captureEnabled = true;
    addTearDown(gateway.stop);
    final port = await gateway.start();
    gateway.updateRoutes([
      SiteRoute(
        slug: 'demo',
        name: 'Demo',
        projectName: 'P',
        backend: Uri.parse('http://127.0.0.1:${backend.port}/'),
      ),
      SiteRoute(
        slug: 'down',
        name: '挂了',
        projectName: 'P',
        backend: Uri.parse('http://127.0.0.1:1/'),
      ),
    ]);

    final client = HttpClient();
    addTearDown(client.close);

    final up = await client.getUrl(Uri.parse('http://127.0.0.1:$port/fail'));
    up.headers.set(HttpHeaders.hostHeader, 'demo.localhost:$port');
    final upRes = await up.close();
    await upRes.drain<void>();
    expect(upRes.statusCode, 500);

    final down = await client.getUrl(Uri.parse('http://127.0.0.1:$port/'));
    down.headers.set(HttpHeaders.hostHeader, 'down.localhost:$port');
    final downRes = await down.close();
    await downRes.drain<void>();
    expect(downRes.statusCode, 502);

    final demo = gateway.recentEvents(slug: 'demo');
    expect(demo.any((e) => e.type == 'gateway' && e.status == 500), isTrue);
    final dead = gateway.recentEvents(slug: 'down');
    expect(dead.any((e) => e.type == 'gateway' && e.status == 502), isTrue);
  });

  test('notifies onBackendUnreachable when proxy cannot connect', () async {
    final gateway = SiteGateway();
    addTearDown(gateway.stop);
    final slugs = <String>[];
    gateway.onBackendUnreachable = slugs.add;
    final port = await gateway.start();
    gateway.updateRoutes([
      SiteRoute(
        slug: 'down',
        name: '挂了',
        projectName: 'P',
        backend: Uri.parse('http://127.0.0.1:1/'),
      ),
    ]);
    final client = HttpClient();
    addTearDown(client.close);
    final req = await client.getUrl(Uri.parse('http://127.0.0.1:$port/'));
    req.headers.set(HttpHeaders.hostHeader, 'down.localhost:$port');
    final res = await req.close();
    await res.drain<void>();
    expect(res.statusCode, 502);
    expect(slugs, ['down']);
  });

  test('rejects WebSocket upgrade with 501 and records a gateway event', () async {
    final gateway = SiteGateway()..captureEnabled = true;
    addTearDown(gateway.stop);
    final port = await gateway.start();
    gateway.updateRoutes([
      SiteRoute(
        slug: 'demo',
        name: 'Demo',
        projectName: 'P',
        backend: Uri.parse('http://127.0.0.1:9/'),
      ),
    ]);

    final client = HttpClient();
    addTearDown(client.close);
    final req = await client.getUrl(Uri.parse('http://127.0.0.1:$port/socket'));
    req.headers.set(HttpHeaders.hostHeader, 'demo.localhost:$port');
    req.headers.set(HttpHeaders.upgradeHeader, 'websocket');
    final res = await req.close();
    final body = await utf8.decoder.bind(res).join();
    expect(res.statusCode, HttpStatus.notImplemented);
    expect(body, contains('不支持 WebSocket'));
    expect(body, contains(kSiteGatewayHttpOnlyCaption));

    final events = gateway.recentEvents(slug: 'demo');
    expect(events, isNotEmpty);
    expect(events.single.type, 'gateway');
    expect(events.single.status, HttpStatus.notImplemented);
    expect(events.single.message, contains('WebSocket'));
  });
}
