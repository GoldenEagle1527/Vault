import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:vault/agent/agent_site_controller.dart';
import 'package:vault/agent/conversation_store.dart';
import 'package:vault/agent/project_site_launcher.dart';
import 'package:vault/agent/project_store.dart';
import 'package:vault/agent/site_supervisor.dart';
import 'package:vault/agent/tools/manage_site_tool.dart';
import 'package:vault/agent/vault_meta_db.dart';
import 'package:vault/sandbox/sandbox_models.dart';
import 'package:vault_agent_core/vault_agent_core.dart';

class _FakeWorkspace implements SandboxWorkspace {
  _FakeWorkspace(this._handler);

  final Future<CommandResult> Function(String cmd) _handler;
  final Map<String, List<int>> files = {};

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
    return _handler(cmd);
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

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('vault_manage_site_');
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

  Future<void> registerSite() async {
    await projects.upsertUrl(
      'ws1',
      projectPath,
      const ProjectUrlEntry(
        name: '网站',
        url: 'http://127.0.0.1:8080/',
        startCommand: 'python3 -m http.server 8080 --bind 127.0.0.1',
      ),
    );
  }

  Tool makeTool(
    _FakeWorkspace ws, {
    void Function()? onChanged,
    MemorySiteSupervisorClient? supervisor,
  }) {
    return createManageSiteTool(
      workspace: ws,
      launcher: ProjectSiteLauncher(
        ws,
        readyTimeout: const Duration(milliseconds: 40),
        readyPollInterval: Duration.zero,
        supervisor: supervisor ?? MemorySiteSupervisorClient(),
      ),
      projectStore: projects,
      workspaceId: 'ws1',
      projectPath: projectPath,
      onChanged: onChanged,
    );
  }

  test('errors when no site is registered', () async {
    final ws = _FakeWorkspace(
      (_) async => const CommandResult(exitCode: 0, stdout: '', stderr: ''),
    );
    final json = await runTool(makeTool(ws), {'action': 'start'});
    expect(json['ok'], isFalse);
    expect(json['error'], contains('还没有站点'));
  });

  test('start waits until supervisor reports listening', () async {
    await registerSite();
    var changed = 0;
    final ws = _FakeWorkspace((cmd) async {
      return const CommandResult(exitCode: 0, stdout: 'ok', stderr: '');
    });
    final json = await runTool(makeTool(ws, onChanged: () => changed++), {
      'action': 'start',
    });
    expect(json['ok'], isTrue);
    expect(json['startedProcess'], isTrue);
    expect(json['openedUrl'], isFalse);
    expect(changed, 1);
  });

  test('start timeout returns log tail and does not notify', () async {
    await registerSite();
    var changed = 0;
    final ws = _FakeWorkspace((cmd) async {
      return const CommandResult(exitCode: 0, stdout: 'ok', stderr: '');
    });
    ws.files['/root/projects/$projectPath/vault_site_网站_8080.log'] = utf8
        .encode('Address already in use\n');
    final json = await runTool(
      makeTool(
        ws,
        onChanged: () => changed++,
        supervisor: MemorySiteSupervisorClient()..startFails = true,
      ),
      {'action': 'start'},
    );
    expect(json['ok'], isFalse);
    expect(json['startedProcess'], isFalse);
    expect(json['message'], contains('启动超时'));
    expect(json['error'], contains('启动超时'));
    expect(json['logTail'], contains('Address already in use'));
    expect(changed, 0);
  });

  test(
    'start through controller surfaces swallowed supervisor errors',
    () async {
      await registerSite();
      final ws = _FakeWorkspace((cmd) async {
        return const CommandResult(exitCode: 0, stdout: 'ok', stderr: '');
      });
      final supervisor = MemorySiteSupervisorClient()
        ..throwOnStart = StateError('无法启动站点看守');
      final controller = AgentSiteController(
        workspace: ws,
        projects: () => const [],
        isMounted: () => true,
        onChanged: () {},
        publicUrl: (entry) => entry.url,
        beforeStart: (_) async {},
        syncKeepAlive: (_) async {},
        onMessage: (_) {},
        supervisor: supervisor,
      );
      addTearDown(controller.dispose);
      final tool = createManageSiteTool(
        workspace: ws,
        launcher: controller.launcher,
        projectStore: projects,
        workspaceId: 'ws1',
        projectPath: projectPath,
        siteController: controller,
      );
      final json = await runTool(tool, {'action': 'start'});
      expect(json['ok'], isFalse);
      expect(json['error'], contains('无法启动站点看守'));
      expect(json['startedProcess'], isFalse);
    },
  );

  test('logs returns tail of the site log', () async {
    await registerSite();
    final ws = _FakeWorkspace(
      (_) async => const CommandResult(exitCode: 0, stdout: '', stderr: ''),
    );
    ws.files['/root/projects/$projectPath/vault_site_网站_8080.log'] = utf8
        .encode('line-a\nline-b\nline-c\n');
    final json = await runTool(makeTool(ws), {'action': 'logs', 'lines': 2});
    expect(json['ok'], isTrue);
    expect(json['logTail'], 'line-b\nline-c');
  });

  test('status reports up from supervisor listening', () async {
    await registerSite();
    final ws = _FakeWorkspace((cmd) async {
      return const CommandResult(exitCode: 0, stdout: 'ok', stderr: '');
    });
    final supervisor = MemorySiteSupervisorClient();
    await supervisor.startSite(
      id: projectPath,
      cwd: '/root/projects/$projectPath',
      cmd: 'python3 app.py',
    );
    final json = await runTool(makeTool(ws, supervisor: supervisor), {
      'action': 'status',
    });
    expect(json['ok'], isTrue);
    expect(json['up'], isTrue);
  });

  test('list includes current site and other project ports', () async {
    await registerSite();
    final other = await projects.createProject(
      'ws1',
      conversationStore: conversations,
    );
    await projects.upsertUrl(
      'ws1',
      other.path,
      const ProjectUrlEntry(
        name: '别的站',
        url: 'http://127.0.0.1:9001/',
        startCommand: 'python3 -m http.server 9001 --bind 127.0.0.1',
      ),
    );
    final ws = _FakeWorkspace((cmd) async {
      return const CommandResult(exitCode: 0, stdout: 'ok', stderr: '');
    });
    final supervisor = MemorySiteSupervisorClient();
    await supervisor.startSite(
      id: projectPath,
      cwd: '/root/projects/$projectPath',
      cmd: 'python3 app.py',
    );
    final json = await runTool(makeTool(ws, supervisor: supervisor), {
      'action': 'list',
    });
    expect(json['ok'], isTrue);
    expect(json['registered'], isTrue);
    expect(json['up'], isTrue);
    expect((json['site'] as Map)['name'], '网站');
    final others = (json['other_ports'] as List).cast<Map<String, dynamic>>();
    expect(others, hasLength(1));
    expect(others.single['port'], 9001);
    expect(others.single['siteName'], '别的站');
  });

  test('adopt registers unregistered flask project', () async {
    final ws = _FakeWorkspace(
      (_) async => const CommandResult(exitCode: 0, stdout: '', stderr: ''),
    );
    final dir = '/root/projects/$projectPath';
    ws.files['$dir/app.py'] = utf8.encode('from config import HOST, PORT\n');
    ws.files['$dir/config.py'] = utf8.encode(
      'HOST = "127.0.0.1"\nPORT = 8765\n',
    );
    final json = await runTool(makeTool(ws), {'action': 'adopt'});
    expect(json['ok'], isTrue);
    expect(json['kind'], 'flask');
    expect(json['port'], 8765);
    expect(json['reusedConfigPort'], isTrue);
    expect(json['start_command'], 'python3 app.py');
    final project = await projects.getProject('ws1', projectPath);
    expect(project?.site?.url, 'http://127.0.0.1:8765/');
    expect(project?.site?.startCommand, 'python3 app.py');
  });

  test('adopt refuses when already registered', () async {
    await registerSite();
    final ws = _FakeWorkspace(
      (_) async => const CommandResult(exitCode: 0, stdout: '', stderr: ''),
    );
    final dir = '/root/projects/$projectPath';
    ws.files['$dir/app.py'] = utf8.encode('x');
    final json = await runTool(makeTool(ws), {'action': 'adopt'});
    expect(json['ok'], isFalse);
    expect(json['error'], contains('update'));
  });

  test('update changes port and rewrites flask config', () async {
    await projects.upsertUrl(
      'ws1',
      projectPath,
      const ProjectUrlEntry(
        name: '网站',
        url: 'http://127.0.0.1:8765/',
        startCommand: 'python3 app.py',
      ),
    );
    final before = await projects.getProject('ws1', projectPath);
    final slug = before!.site!.slug;
    final ws = _FakeWorkspace((cmd) async {
      if (cmd.contains('vault_site_own_pid')) {
        return const CommandResult(exitCode: 0, stdout: '0', stderr: '');
      }
      return const CommandResult(exitCode: 0, stdout: '0', stderr: '');
    });
    final dir = '/root/projects/$projectPath';
    ws.files['$dir/app.py'] = utf8.encode('from config import HOST, PORT\n');
    ws.files['$dir/config.py'] = utf8.encode(
      'HOST = "127.0.0.1"\nPORT = 8765\n',
    );
    final json = await runTool(makeTool(ws), {
      'action': 'update',
      'port': 9000,
    });
    expect(json['ok'], isTrue);
    expect(json['port'], 9000);
    expect(json['start_command'], 'python3 app.py');
    expect(json['slug'], slug);
    expect(utf8.decode(ws.files['$dir/config.py']!), contains('PORT = 9000'));
    final after = await projects.getProject('ws1', projectPath);
    expect(after?.site?.url, 'http://127.0.0.1:9000/');
    expect(after?.site?.slug, slug);
  });

  test('unregister then status reports missing site', () async {
    await registerSite();
    final ws = _FakeWorkspace((cmd) async {
      if (cmd.contains('vault_site_own_pid')) {
        return const CommandResult(exitCode: 0, stdout: '0', stderr: '');
      }
      return const CommandResult(exitCode: 0, stdout: '0', stderr: '');
    });
    final dir = '/root/projects/$projectPath';
    ws.files['$dir/index.html'] = utf8.encode('<html></html>');
    final gone = await runTool(makeTool(ws), {'action': 'unregister'});
    expect(gone['ok'], isTrue);
    expect(gone['files_kept'], isTrue);
    expect(ws.files['$dir/index.html'], isNotNull);
    final status = await runTool(makeTool(ws), {'action': 'status'});
    expect(status['ok'], isFalse);
    expect(status['error'], contains('还没有站点'));
  });
}
