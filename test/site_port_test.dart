import 'package:flutter_test/flutter_test.dart';
import 'package:vault/agent/site_port.dart';

void main() {
  test('allocateSiteSlug sanitizes and increments', () {
    expect(allocateSiteSlug('API', const []), 'api');
    expect(allocateSiteSlug('My Site!', const []), 'my-site');
    expect(allocateSiteSlug('网站', const []), 'site');
    expect(allocateSiteSlug('网站', const ['site']), 'site-2');
    expect(allocateSiteSlug('网站', const ['site', 'site-2']), 'site-3');
  });

  test('sitePublicUrl and siteSlugFromHost', () {
    expect(
      sitePublicUrl(slug: 'demo', gatewayPort: 38471),
      'http://demo.localhost:38471/',
    );
    expect(siteSlugFromHost('demo.localhost'), 'demo');
    expect(siteSlugFromHost('demo.localhost:38471'), 'demo');
    expect(siteSlugFromHost('DEMO.localhost:38471'), 'demo');
    expect(siteSlugFromHost('localhost'), isNull);
    expect(siteSlugFromHost('localhost:38471'), isNull);
    expect(siteSlugFromHost('127.0.0.1'), isNull);
    expect(siteSlugFromHost('127.0.0.1:38471'), isNull);
    expect(siteSlugFromHost('a.b.localhost'), isNull);
  });

  test('findWorkspacePortConflict ignores one project', () {
    const claims = [
      SitePortClaim(
        projectPath: 'p1',
        projectName: '项目1',
        siteName: '网站',
        port: 8080,
        slug: 'site',
      ),
      SitePortClaim(
        projectPath: 'p2',
        projectName: '项目2',
        siteName: 'API',
        port: 9000,
        slug: 'api',
      ),
    ];
    expect(
      findWorkspacePortConflict(claims: claims, port: 8080)?.projectPath,
      'p1',
    );
    expect(
      findWorkspacePortConflict(
        claims: claims,
        port: 8080,
        ignoreProjectPath: 'p1',
      ),
      isNull,
    );
    expect(
      findWorkspacePortConflict(
        claims: claims,
        port: 8080,
        ignoreProjectPath: 'p2',
      )?.siteName,
      '网站',
    );
  });
}
