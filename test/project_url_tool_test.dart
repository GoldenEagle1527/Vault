import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:vault/agent/conversation_store.dart';
import 'package:vault/agent/project_store.dart';
import 'package:vault/agent/tools/project_url_tool.dart';
import 'package:vault/agent/vault_meta_db.dart';
import 'package:vault_agent_core/vault_agent_core.dart';

void main() {
  late Directory temp;
  late ProjectStore projects;
  late ConversationStore conversations;
  late String projectPath;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('vault_url_tool_');
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

  Future<Map<String, dynamic>> runTool(
    Tool tool,
    Map<String, dynamic> args,
  ) async {
    final result = await Function.apply(tool.executable!, [args]);
    return jsonDecode(result as String) as Map<String, dynamic>;
  }

  test('register_project_url upserts by name', () async {
    final tools = createProjectUrlTools(
      projectStore: projects,
      workspaceId: 'ws1',
      projectPath: projectPath,
    );
    final register = tools.firstWhere((t) => t.name == 'register_project_url');
    final json = await runTool(register, {
      'name': '网站',
      'url': 'http://127.0.0.1:8080/',
      'start_command': 'python3 -m http.server 8080 --bind 127.0.0.1',
    });
    expect(json['ok'], isTrue);

    final json2 = await runTool(register, {
      'name': '网站',
      'url': 'http://127.0.0.1:9090/',
      'start_command': 'python3 -m http.server 9090 --bind 127.0.0.1',
    });
    expect(json2['ok'], isTrue);
    final urls = (json2['urls'] as List).cast<Map<String, dynamic>>();
    expect(urls, hasLength(1));
    expect(urls.first['url'], 'http://127.0.0.1:9090/');

    final project = await projects.getProject('ws1', projectPath);
    expect(project!.urls.single.name, '网站');
    expect(project.urls.single.startCommand, contains('9090'));
  });

  test('list_project_urls returns registered entries', () async {
    await projects.upsertUrl(
      'ws1',
      projectPath,
      const ProjectUrlEntry(
        name: 'API',
        url: 'http://127.0.0.1:8000/',
        startCommand: 'python3 app.py',
      ),
    );
    final tools = createProjectUrlTools(
      projectStore: projects,
      workspaceId: 'ws1',
      projectPath: projectPath,
    );
    final list = tools.firstWhere((t) => t.name == 'list_project_urls');
    final json = await runTool(list, {});
    expect(json['ok'], isTrue);
    expect(json['urls'], hasLength(1));
    expect((json['urls'] as List).first['name'], 'API');
  });
}
