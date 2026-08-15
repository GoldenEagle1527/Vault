import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:vault/agent/conversation_store.dart';
import 'package:vault/agent/project_store.dart';
import 'package:vault/agent/vault_meta_db.dart';

void main() {
  late Directory temp;
  late String metaDbPath;
  late String guestRoot;
  late ProjectStore projects;
  late ConversationStore conversations;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('vault_proj_');
    metaDbPath = p.join(temp.path, 'vault_meta.db');
    guestRoot = p.join(temp.path, 'guest');
    projects = ProjectStore.local(metaDbPath: metaDbPath, guestRoot: guestRoot);
    conversations = ConversationStore(metaDb: VaultMetaDb.at(metaDbPath));
  });

  tearDown(() async {
    if (await temp.exists()) {
      await temp.delete(recursive: true);
    }
  });

  test('allocateDisplayName uses 新项目 then 新项目(n)', () {
    expect(ProjectStore.allocateDisplayName(const []), kDefaultProjectName);
    expect(ProjectStore.allocateDisplayName(const ['新项目']), '新项目(1)');
    expect(ProjectStore.allocateDisplayName(const ['新项目', '新项目(1)']), '新项目(2)');
  });

  test('createProject makes guest dir + host DB row, not guest db', () async {
    final created = await projects.createProject(
      'ws1',
      conversationStore: conversations,
    );
    expect(created.name, kDefaultProjectName);
    expect(created.path, matches(RegExp(r'^\d{14}')));
    expect(await projects.activePath('ws1'), created.path);

    final hostProject = Directory(
      p.join(guestRoot, 'ws1', 'root', 'projects', created.path),
    );
    expect(await hostProject.exists(), isTrue);
    expect(await Directory(p.join(hostProject.path, '.git')).exists(), isTrue);

    // Metadata is on the host, not inside the guest projects tree.
    expect(await File(metaDbPath).exists(), isTrue);
    expect(
      await File(
        p.join(guestRoot, 'ws1', 'root', 'projects', 'projects.db'),
      ).exists(),
      isFalse,
    );

    final index = await conversations.list('ws1', created.path);
    expect(index.conversations, hasLength(1));
  });

  test('second project gets 新项目(1) and switching active works', () async {
    final a = await projects.createProject(
      'ws1',
      conversationStore: conversations,
    );
    final b = await projects.createProject(
      'ws1',
      conversationStore: conversations,
    );
    expect(b.name, '新项目(1)');
    expect(await projects.activePath('ws1'), b.path);

    await projects.setActive('ws1', a.path);
    expect(await projects.activePath('ws1'), a.path);

    final list = await projects.list('ws1');
    expect(list.map((p) => p.name), containsAll([a.name, b.name]));
  });

  test('createProject keeps only the first url', () async {
    final created = await projects.createProject(
      'ws1',
      urls: const [
        ProjectUrlEntry(
          name: 'api',
          url: 'http://127.0.0.1:8000',
          startCommand: 'uvicorn app:app',
        ),
        ProjectUrlEntry(name: 'web', url: 'http://127.0.0.1:5173'),
      ],
      conversationStore: conversations,
    );
    final listed = await projects.list('ws1');
    final info = listed.firstWhere((p) => p.path == created.path);
    expect(info.urls, hasLength(1));
    expect(info.site!.name, 'api');
    expect(info.site!.startCommand, 'uvicorn app:app');
    expect(info.site!.slug, isNotEmpty);
  });

  test('upsertUrl replaces the only frontend entry', () async {
    final created = await projects.createProject(
      'ws1',
      conversationStore: conversations,
    );
    await projects.upsertUrl(
      'ws1',
      created.path,
      const ProjectUrlEntry(name: '网站', url: 'http://127.0.0.1:8080/'),
    );
    await projects.upsertUrl(
      'ws1',
      created.path,
      const ProjectUrlEntry(name: '后台', url: 'http://127.0.0.1:9090/'),
    );
    final project = await projects.getProject('ws1', created.path);
    expect(project!.urls, hasLength(1));
    expect(project.site!.name, '后台');
    expect(project.site!.url, 'http://127.0.0.1:9090/');
  });

  test('upsertUrl rejects port already used in another project', () async {
    final a = await projects.createProject(
      'ws1',
      conversationStore: conversations,
    );
    final b = await projects.createProject(
      'ws1',
      conversationStore: conversations,
    );
    await projects.upsertUrl(
      'ws1',
      a.path,
      const ProjectUrlEntry(name: '网站', url: 'http://127.0.0.1:8080/'),
    );
    expect(
      () => projects.upsertUrl(
        'ws1',
        b.path,
        const ProjectUrlEntry(name: '网站', url: 'http://127.0.0.1:8080/'),
      ),
      throwsA(
        isA<Exception>().having(
          (e) => e.toString(),
          'message',
          contains('8080'),
        ),
      ),
    );
  });
}
