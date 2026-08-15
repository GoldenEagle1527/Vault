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
}
