import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:vault/agent/conversation_store.dart';
import 'package:vault/agent/project_store.dart';
import 'package:vault/agent/site_gateway.dart';
import 'package:vault/agent/site_port.dart';
import 'package:vault/agent/site_register.dart';
import 'package:vault/agent/vault_meta_db.dart';

void main() {
  late Directory temp;
  late ProjectStore projects;
  late ConversationStore conversations;
  late String projectPath;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('vault_site_register_');
    final metaPath = p.join(temp.path, 'vault_meta.db');
    projects = ProjectStore.local(
      metaDbPath: metaPath,
      guestRoot: p.join(temp.path, 'guest'),
    );
    conversations = ConversationStore(metaDb: VaultMetaDb.at(metaPath));
    final created = await projects.createProject(
      'ws1',
      conversationStore: conversations,
    );
    projectPath = created.path;
  });

  tearDown(() async {
    if (await temp.exists()) {
      await temp.delete(recursive: true);
    }
  });

  test('registerProjectSite upserts the single frontend entry', () async {
    await registerProjectSite(
      projectStore: projects,
      workspaceId: 'ws1',
      projectPath: projectPath,
      entry: const ProjectUrlEntry(
        name: '网站',
        url: 'http://127.0.0.1:8080/',
        startCommand: 'python3 -m http.server 8080 --bind 127.0.0.1',
      ),
    );
    final second = await registerProjectSite(
      projectStore: projects,
      workspaceId: 'ws1',
      projectPath: projectPath,
      entry: const ProjectUrlEntry(
        name: '网站',
        url: 'http://127.0.0.1:9090/',
        startCommand: 'python3 -m http.server 9090 --bind 127.0.0.1',
      ),
    );
    expect(second.url, 'http://127.0.0.1:9090/');
    final project = await projects.getProject('ws1', projectPath);
    expect(project!.urls, hasLength(1));
    expect(project.urls.single.startCommand, contains('9090'));
  });

  test(
    'registerProjectSite replaces a different name with one entry',
    () async {
      await registerProjectSite(
        projectStore: projects,
        workspaceId: 'ws1',
        projectPath: projectPath,
        entry: const ProjectUrlEntry(name: '网站', url: 'http://127.0.0.1:8080/'),
      );
      final replaced = await registerProjectSite(
        projectStore: projects,
        workspaceId: 'ws1',
        projectPath: projectPath,
        entry: const ProjectUrlEntry(
          name: '后台',
          url: 'http://127.0.0.1:9090/',
          startCommand: 'python3 -m http.server 9090 --bind 127.0.0.1',
        ),
      );
      expect(replaced.name, '后台');
      final project = await projects.getProject('ws1', projectPath);
      expect(project!.urls, hasLength(1));
      expect(project.site!.name, '后台');
    },
  );

  test('registerProjectSite rejects a port used by another project', () async {
    final other = await projects.createProject(
      'ws1',
      conversationStore: conversations,
    );
    await projects.upsertUrl(
      'ws1',
      other.path,
      const ProjectUrlEntry(name: '网站', url: 'http://127.0.0.1:8080/'),
    );
    expect(
      () => registerProjectSite(
        projectStore: projects,
        workspaceId: 'ws1',
        projectPath: projectPath,
        entry: const ProjectUrlEntry(name: '网站', url: 'http://127.0.0.1:8080/'),
      ),
      throwsA(isA<SitePortConflictException>()),
    );
  });

  test('projectSiteJson includes public_url from gateway', () async {
    final gateway = SiteGateway();
    addTearDown(gateway.stop);
    await gateway.start();
    final registered = await registerProjectSite(
      projectStore: projects,
      workspaceId: 'ws1',
      projectPath: projectPath,
      entry: const ProjectUrlEntry(name: '网站', url: 'http://127.0.0.1:8765/'),
      gateway: gateway,
    );
    final json = projectSiteJson(registered, gateway: gateway);
    expect(json['public_url'], contains('.localhost:${gateway.port}/'));
    expect(json['slug'], isNotEmpty);
  });
}
