import 'dart:convert';

import 'package:vault/agent/project_store.dart';
import 'package:vault/agent/site_gateway.dart';
import 'package:vault/agent/site_port.dart';
import 'package:vault/agent/site_register.dart';
import 'package:vault/agent/site_scaffold.dart';
import 'package:vault/sandbox/sandbox_models.dart';
import 'package:vault_agent_core/vault_agent_core.dart';

const String kScaffoldSiteToolName = 'scaffold_site';

/// Install Flask in the guest if missing. Must succeed before files are written.
const String kEnsureFlaskGuestCommand = r'''
if python3 -c "import flask" >/dev/null 2>&1; then
  printf '%s\n' flask_ok
  exit 0
fi
apk add --no-cache py3-flask
python3 -c "import flask"
''';

const Duration kEnsureFlaskTimeout = Duration(minutes: 3);

/// Write a known-good Flask or static skeleton and register it on the host.
///
/// Allocates a free port. Does not start the site.
Tool createScaffoldSiteTool({
  required SandboxWorkspace workspace,
  required ProjectStore projectStore,
  required String workspaceId,
  required String projectPath,
  SiteGateway? gateway,
}) {
  return Tool(
    name: kScaffoldSiteToolName,
    description:
        '在当前项目目录写入已知可用的网站骨架（flask 或 static），分配空闲内部端口，并登记到侧栏。'
        '返回 public_url、url、start_command、files。下一步用 manage_site action=start。'
        '已有 app.py 或 index.html 时拒绝，请在现有站上改（再 manage_site start），或让用户新建项目。'
        '不要自己发明目录、端口或启动命令，不要用 shell 起网站。',
    parameterMode: ToolParameterMode.object,
    allowBackground: false,
    parameters: {
      'type': 'object',
      'properties': {
        'kind': {
          'type': 'string',
          'description': 'flask（动态页，默认）或 static（静态文件 + http.server）',
        },
        'name': {'type': 'string', 'description': '站点显示名，默认「网站」'},
      },
      'required': ['kind'],
    },
    executable: (Map<String, dynamic> args) async {
      final kind = parseSiteScaffoldKind(args['kind'] as String?);
      if (kind == null) {
        return jsonEncode({'ok': false, 'error': 'kind 必须是 flask 或 static'});
      }
      final name = (args['name'] as String?)?.trim();
      final displayName = (name == null || name.isEmpty) ? '网站' : name;

      final dir = guestProjectDir(projectPath);
      for (final marker in kScaffoldExistingMarkers) {
        final existing = await workspace.readGuestFile('$dir/$marker');
        if (existing != null) {
          return jsonEncode({
            'ok': false,
            'error': '当前项目已有 $marker。请在现有站上改，或让用户在 App 点「新建项目」。',
            'existing': marker,
          });
        }
      }

      final claims = await projectStore.listPortClaims(workspaceId);
      final taken = <int>{
        for (final c in claims) c.port,
        if (gateway?.port != null) gateway!.port!,
      };

      late final int port;
      try {
        port = allocateSitePort(taken);
      } catch (e) {
        return jsonEncode({'ok': false, 'error': e.toString()});
      }

      if (kind == SiteScaffoldKind.flask) {
        try {
          final ready = await workspace.run(
            kEnsureFlaskGuestCommand,
            timeout: kEnsureFlaskTimeout,
          );
          if (!ready.success) {
            return jsonEncode({
              'ok': false,
              'error': '无法安装 Flask：${ready.stderr}\n${ready.stdout}',
            });
          }
        } catch (e) {
          return jsonEncode({'ok': false, 'error': '无法安装 Flask：$e'});
        }
      }

      final plan = buildSiteScaffold(kind: kind, name: displayName, port: port);
      final written = <String>[];
      try {
        for (final entry in plan.files.entries) {
          final path = '$dir/${entry.key}';
          await workspace.writeGuestFile(path, utf8.encode(entry.value));
          written.add(entry.key);
        }
      } catch (e) {
        return jsonEncode({
          'ok': false,
          'error': '写入骨架失败：$e',
          'files': written,
        });
      }

      try {
        final registered = await registerProjectSite(
          projectStore: projectStore,
          workspaceId: workspaceId,
          projectPath: projectPath,
          entry: ProjectUrlEntry(
            name: plan.name,
            url: plan.url,
            startCommand: plan.startCommand,
          ),
          gateway: gateway,
        );
        final site = projectSiteJson(registered, gateway: gateway);
        return jsonEncode({
          'ok': true,
          'kind': plan.kind.name,
          'name': plan.name,
          'port': plan.port,
          'url': plan.url,
          'start_command': plan.startCommand,
          'files': written,
          'projectPath': projectPath,
          'registered': site,
          'public_url': site['public_url'],
          'hint': '已登记。下一步 manage_site action=start。不要用 shell 起网站。',
        });
      } on SitePortConflictException catch (e) {
        return jsonEncode({
          'ok': false,
          'error': e.toString(),
          'files': written,
        });
      } catch (e) {
        return jsonEncode({'ok': false, 'error': '登记失败：$e', 'files': written});
      }
    },
  );
}
