import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:vault/agent/project_store.dart';
import 'package:vault/agent/site_browser_log.dart';
import 'package:vault/agent/site_gateway.dart';
import 'package:vault/agent/tools/inspect_site_tool.dart';
import 'package:vault_agent_core/vault_agent_core.dart';

void main() {
  test('probe.js dumps any object safely, not library-specific hooks', () {
    expect(kVaultProbeJs, contains('function dump'));
    expect(kVaultProbeJs, contains('function ctorName'));
    expect(kVaultProbeJs, contains('[Circular]'));
    expect(kVaultProbeJs, isNot(contains('isBufferGeometry')));
    expect(kVaultProbeJs, isNot(contains('isObject3D')));
    expect(kVaultProbeJs, isNot(contains('String(arguments[i])')));
  });

  Future<Map<String, dynamic>> runTool(Tool tool) async {
    final result = await Function.apply(tool.executable!, [
      <String, dynamic>{},
    ]);
    return jsonDecode(result as String) as Map<String, dynamic>;
  }

  const shop = ProjectUrlEntry(
    name: '商店',
    url: 'http://127.0.0.1:8765/',
    slug: 'shop',
  );
  const other = ProjectUrlEntry(
    name: '其他',
    url: 'http://127.0.0.1:8766/',
    slug: 'other',
  );

  test('no registered sites', () async {
    final tool = createInspectSiteTool(
      gateway: SiteGateway()..captureEnabled = true,
      projectSites: () async => const [],
      probeUp: (_) async => {},
    );
    final json = await runTool(tool);
    expect(json['ok'], isFalse);
    expect(json['error'], contains('还没有登记站点'));
  });

  test('down site reports 服务没启动', () async {
    final tool = createInspectSiteTool(
      gateway: SiteGateway()..captureEnabled = true,
      projectSites: () async => [shop],
      probeUp: (_) async => {'商店': false},
    );
    final json = await runTool(tool);
    expect(json['ok'], isTrue);
    expect(json['hint'], contains('服务没启动'));
    final site = (json['sites'] as List).cast<Map<String, dynamic>>().single;
    expect(site['up'], isFalse);
    expect(site['message'], '服务没启动');
    expect(site['slug'], 'shop');
  });

  test('up site returns all buffered events including old ones', () async {
    final gateway = SiteGateway()..captureEnabled = true;
    gateway.recordEvent(
      SiteBrowserEvent(
        at: DateTime.now().subtract(const Duration(hours: 3)),
        slug: 'shop',
        type: 'error',
        level: 'error',
        message: 'old shop error',
      ),
    );
    gateway.recordEvent(
      SiteBrowserEvent(
        at: DateTime.now(),
        slug: 'shop',
        type: 'error',
        level: 'error',
        message: 'new shop error',
      ),
    );
    gateway.recordEvent(
      SiteBrowserEvent(
        at: DateTime.now(),
        slug: 'other',
        type: 'error',
        level: 'error',
        message: 'other broken',
      ),
    );
    gateway.recordEvent(
      SiteBrowserEvent(
        at: DateTime.now(),
        slug: 'shop',
        type: 'console',
        level: 'warn',
        message: 'deprecated',
      ),
    );

    final tool = createInspectSiteTool(
      gateway: gateway,
      projectSites: () async => [shop, other],
      probeUp: (_) async => {'商店': true, '其他': false},
    );
    final json = await runTool(tool);
    expect(json['ok'], isTrue);
    expect(json.containsKey('hint'), isFalse);

    final sites = (json['sites'] as List).cast<Map<String, dynamic>>();
    expect(sites, hasLength(2));

    final shopReport = sites.firstWhere((s) => s['slug'] == 'shop');
    expect(shopReport['up'], isTrue);
    final msgs = (shopReport['events'] as List)
        .cast<Map<String, dynamic>>()
        .map((e) => e['message'])
        .toList();
    expect(msgs, ['old shop error', 'new shop error', 'deprecated']);

    final otherReport = sites.firstWhere((s) => s['slug'] == 'other');
    expect(otherReport['up'], isFalse);
    expect(otherReport['message'], '服务没启动');
  });

  test('duplicate console errors collapse to one row with count', () async {
    final gateway = SiteGateway()..captureEnabled = true;
    final first = DateTime.now().subtract(const Duration(seconds: 2));
    for (var i = 0; i < 40; i++) {
      gateway.recordEvent(
        SiteBrowserEvent(
          at: first.add(Duration(milliseconds: i * 10)),
          slug: 'shop',
          type: 'console',
          level: 'error',
          message:
              'THREE.BufferGeometry.computeBoundingSphere(): Computed radius is NaN.',
        ),
      );
    }
    gateway.recordEvent(
      SiteBrowserEvent(
        at: DateTime.now(),
        slug: 'shop',
        type: 'error',
        level: 'error',
        message: 'Uncaught TypeError: x is not a function',
      ),
    );

    final tool = createInspectSiteTool(
      gateway: gateway,
      projectSites: () async => [shop],
      probeUp: (_) async => {'商店': true},
    );
    final json = await runTool(tool);
    expect(() => jsonEncode(json), returnsNormally);
    final events = ((json['sites'] as List).first['events'] as List)
        .cast<Map<String, dynamic>>();
    expect(events, hasLength(2));
    final nan = events.firstWhere(
      (e) => (e['message'] as String).contains('NaN'),
    );
    expect(nan['count'], 40);
    expect(nan['message'], isNot(contains('[object Object]')));
  });

  test('up site with empty buffer returns open-page hint', () async {
    final tool = createInspectSiteTool(
      gateway: SiteGateway()..captureEnabled = true,
      projectSites: () async => [shop],
      probeUp: (_) async => {'商店': true},
    );
    final json = await runTool(tool);
    final site = (json['sites'] as List).cast<Map<String, dynamic>>().single;
    expect(site['up'], isTrue);
    expect(site['events'], isEmpty);
    expect(site['hint'], contains('还没打开'));
  });
}
