import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:vault/agent/conversation_store.dart';
import 'package:vault/agent/project_store.dart';
import 'package:vault/agent/site_scaffold.dart';
import 'package:vault/agent/tools/scaffold_site_tool.dart';
import 'package:vault/agent/vault_meta_db.dart';
import 'package:vault/sandbox/sandbox_models.dart';
import 'package:vault_agent_core/vault_agent_core.dart';

class _FakeWorkspace implements SandboxWorkspace {
  _FakeWorkspace({this.runHandler});

  final Map<String, List<int>> files = {};
  final List<String> commands = [];
  final Future<CommandResult> Function(String cmd)? runHandler;

  @override
  String get workspaceId => 'ws1';

  @override
  Stream<Uint8List> get output => const Stream.empty();

  @override
  void write(String data) {}

  @override
  void writeBytes(Uint8List data) {}

  @override
  void resize(int cols, int rows) {}

  @override
  Future<int> get exitCode => Future.value(0);

  @override
  Future<CommandResult> run(
    String cmd, {
    Map<String, String>? environment,
    Duration? timeout,
  }) async {
    commands.add(cmd);
    if (runHandler != null) return runHandler!(cmd);
    return const CommandResult(exitCode: 0, stdout: 'flask_ok', stderr: '');
  }

  @override
  Future<void> writeGuestFile(String guestAbsolutePath, List<int> bytes) async {
    files[guestAbsolutePath] = bytes;
  }

  @override
  Future<Uint8List?> readGuestFile(String guestAbsolutePath) async {
    final data = files[guestAbsolutePath];
    return data == null ? null : Uint8List.fromList(data);
  }

  @override
  Future<List<GuestFsEntry>> listGuestDirectory(
    String guestAbsolutePath,
  ) async => const [];

  @override
  Future<void> dispose() async {}
}

void main() {
  late Directory temp;
  late ProjectStore projects;
  late ConversationStore conversations;
  late String projectPath;
  late _FakeWorkspace workspace;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('vault_scaffold_');
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
    workspace = _FakeWorkspace();
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

  Tool tool() => createScaffoldSiteTool(
    workspace: workspace,
    projectStore: projects,
    workspaceId: 'ws1',
    projectPath: projectPath,
  );

  test('flask scaffold writes files and allocates 8765', () async {
    final json = await runTool(tool(), {'kind': 'flask'});
    expect(json['ok'], isTrue);
    expect(json['kind'], 'flask');
    expect(json['name'], '网站');
    expect(json['port'], 8765);
    expect(json['url'], 'http://127.0.0.1:8765/');
    expect(json['start_command'], 'python3 app.py');
    expect(json['files'], contains('app.py'));
    expect(json['files'], contains('templates/base.html'));
    expect(
      workspace.files.containsKey('/root/projects/$projectPath/app.py'),
      isTrue,
    );

    final project = await projects.getProject('ws1', projectPath);
    expect(project!.urls, hasLength(1));
    expect(project.site!.url, 'http://127.0.0.1:8765/');
    expect(project.site!.startCommand, 'python3 app.py');
    expect(
      workspace.commands.any(
        (c) => c.contains('py3-flask') || c.contains('import flask'),
      ),
      isTrue,
    );
  });

  test(
    'flask scaffold fails before writing when flask cannot be installed',
    () async {
      workspace = _FakeWorkspace(
        runHandler: (_) async =>
            const CommandResult(exitCode: 1, stdout: '', stderr: 'apk failed'),
      );
      final json = await runTool(tool(), {'kind': 'flask'});
      expect(json['ok'], isFalse);
      expect(json['error'], contains('无法安装 Flask'));
      expect(
        workspace.files.containsKey('/root/projects/$projectPath/app.py'),
        isFalse,
      );
    },
  );

  test('static scaffold writes index.html and http.server command', () async {
    final json = await runTool(tool(), {'kind': 'static', 'name': '文档'});
    expect(json['ok'], isTrue);
    expect(json['kind'], 'static');
    expect(json['name'], '文档');
    expect(json['start_command'], contains('http.server 8765'));
    expect(
      workspace.files.containsKey('/root/projects/$projectPath/index.html'),
      isTrue,
    );
    expect(workspace.commands.any((c) => c.contains('py3-flask')), isFalse);
  });

  test('rejects when app.py already exists', () async {
    workspace.files['/root/projects/$projectPath/app.py'] = utf8.encode(
      'already',
    );
    final json = await runTool(tool(), {'kind': 'flask'});
    expect(json['ok'], isFalse);
    expect(json['error'], contains('已有 app.py'));
  });

  test('skips claimed ports', () async {
    await projects.upsertUrl(
      'ws1',
      projectPath,
      const ProjectUrlEntry(
        name: '旧站',
        url: 'http://127.0.0.1:8765/',
        startCommand: 'python3 app.py',
      ),
    );
    final other = await projects.createProject(
      'ws1',
      conversationStore: conversations,
    );
    final otherTool = createScaffoldSiteTool(
      workspace: workspace,
      projectStore: projects,
      workspaceId: 'ws1',
      projectPath: other.path,
    );
    final json = await runTool(otherTool, {'kind': 'static'});
    expect(json['ok'], isTrue);
    expect(json['port'], 8766);
  });

  test('rejects unknown kind', () async {
    final json = await runTool(tool(), {'kind': 'node'});
    expect(json['ok'], isFalse);
    expect(json['error'], contains('flask 或 static'));
  });

  test('buildSiteScaffold flask plan is self-contained', () {
    final plan = buildSiteScaffold(
      kind: SiteScaffoldKind.flask,
      name: '网站',
      port: 9000,
    );
    expect(plan.files['config.py'], contains('PORT = 9000'));
    expect(plan.files['app.py'], contains('render_template'));
    expect(plan.startCommand, 'python3 app.py');
  });
}
