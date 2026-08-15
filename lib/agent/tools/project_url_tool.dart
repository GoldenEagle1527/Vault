import 'dart:convert';

import 'package:vault/agent/project_site_launcher.dart';
import 'package:vault/agent/project_store.dart';
import 'package:vault/agent/site_gateway.dart';
import 'package:vault/agent/site_port.dart';
import 'package:vault/sandbox/sandbox_models.dart';
import 'package:vault_agent_core/vault_agent_core.dart';

/// Tools for the agent to register local site URLs into the host project DB.
List<Tool> createProjectUrlTools({
  required ProjectStore projectStore,
  required String workspaceId,
  required String projectPath,
  SandboxWorkspace? workspace,
  SiteGateway? gateway,
}) {
  Future<List<Map<String, dynamic>>> workspacePorts() async {
    final claims = await projectStore.listPortClaims(workspaceId);
    return [
      for (final c in claims)
        {
          'port': c.port,
          'projectName': c.projectName,
          'siteName': c.siteName,
          'projectPath': c.projectPath,
        },
    ];
  }

  Map<String, dynamic> entryJson(ProjectUrlEntry u) {
    final json = u.toJson();
    final slug = u.slug?.trim();
    final public =
        (gateway != null &&
            gateway.port != null &&
            slug != null &&
            slug.isNotEmpty)
        ? sitePublicUrl(slug: slug, gatewayPort: gateway.port!)
        : null;
    if (public != null) json['public_url'] = public;
    return json;
  }

  Future<void> refreshGateway() async {
    if (gateway == null) return;
    final all = await projectStore.list(workspaceId);
    gateway.updateRoutes(siteRoutesFromProjects(all));
  }

  return [
    Tool(
      name: 'register_project_url',
      description:
          '把当前项目做好的本地网站登记到 Vault 项目数据（主机侧数据库，不在 Linux 内）。'
          '网站可用后必须调用本工具，用户才能在 UI 里看到并一键启动。'
          '同名条目会覆盖；多服务按多次调用登记，sort 顺序为调用先后。'
          'url 是内部监听地址（http://127.0.0.1:端口/），必须换工作区内未被占用、'
          '且当前没有其他进程在听的端口。登记前先 list_project_urls 看 workspace_ports_in_use。'
          '用户打开的是返回的 public_url，不是内部端口。'
          'start_command 为在项目目录下可重复执行的启动命令'
          '（如 python3 -m http.server 8765 --bind 127.0.0.1）。',
      parameterMode: ToolParameterMode.object,
      parameters: {
        'type': 'object',
        'properties': {
          'name': {'type': 'string', 'description': '站点/服务显示名，如「网站」「API」'},
          'url': {
            'type': 'string',
            'description': '内部监听地址，如 http://127.0.0.1:8765/',
          },
          'start_command': {
            'type': 'string',
            'description':
                '可选。在项目根目录执行即可启动服务的命令（后台由 App 负责）。'
                '示例：python3 -m http.server 8765 --bind 127.0.0.1',
          },
          'replace_all': {
            'type': 'boolean',
            'description': '若为 true，清空本项目其它网址，只保留这一条。默认 false。',
          },
        },
        'required': ['name', 'url'],
      },
      executable: (Map<String, dynamic> args) async {
        final name = (args['name'] as String?)?.trim() ?? '';
        final url = (args['url'] as String?)?.trim() ?? '';
        final start = (args['start_command'] as String?)?.trim();
        final replaceAll = args['replace_all'] == true;
        if (name.isEmpty || url.isEmpty) {
          return jsonEncode({'ok': false, 'error': 'name 与 url 不能为空'});
        }
        final port = portFromSiteUrl(url);
        if (port == null) {
          return jsonEncode({
            'ok': false,
            'error': 'url 必须包含可解析的主机与端口，例如 http://127.0.0.1:8765/',
          });
        }
        if (gateway != null && gateway.port != null && gateway.port == port) {
          return jsonEncode({
            'ok': false,
            'error': '端口 $port 是工作区网关端口，请换一个内部监听端口',
            'workspace_ports_in_use': await workspacePorts(),
          });
        }
        if (workspace != null) {
          final listening = await _isPortListening(workspace, port);
          if (listening) {
            final own = await _isOwnSitePidAlive(
              workspace: workspace,
              projectPath: projectPath,
              name: name,
              url: url,
            );
            if (!own) {
              return jsonEncode({
                'ok': false,
                'error': '端口 $port 当前已有进程在监听，且不是本站点，请换一个端口',
                'workspace_ports_in_use': await workspacePorts(),
              });
            }
          }
        }
        try {
          final urls = await projectStore.upsertUrl(
            workspaceId,
            projectPath,
            ProjectUrlEntry(
              name: name,
              url: url,
              startCommand: (start == null || start.isEmpty) ? null : start,
            ),
            replaceAll: replaceAll,
          );
          await refreshGateway();
          final registered = urls.firstWhere((u) => u.name == name);
          return jsonEncode({
            'ok': true,
            'projectPath': projectPath,
            'registered': entryJson(registered),
            'public_url': entryJson(registered)['public_url'],
            'urls': urls.map(entryJson).toList(),
            'workspace_ports_in_use': await workspacePorts(),
            if (gateway?.port != null) 'gateway_port': gateway!.port,
          });
        } on SitePortConflictException catch (e) {
          return jsonEncode({
            'ok': false,
            'error': e.toString(),
            'workspace_ports_in_use': await workspacePorts(),
          });
        } catch (e) {
          return jsonEncode({'ok': false, 'error': e.toString()});
        }
      },
    ),
    Tool(
      name: 'list_project_urls',
      description:
          '列出当前项目已登记的网址与启动命令，以及整个工作区已占用的内部端口。'
          '选端口前先看 workspace_ports_in_use，避免和其它项目冲突。'
          '用户打开的是 public_url。',
      parameterMode: ToolParameterMode.object,
      parameters: {'type': 'object', 'properties': <String, dynamic>{}},
      executable: (Map<String, dynamic> args) async {
        try {
          final project = await projectStore.getProject(
            workspaceId,
            projectPath,
          );
          if (project == null) {
            return jsonEncode({'ok': false, 'error': '项目不存在：$projectPath'});
          }
          return jsonEncode({
            'ok': true,
            'projectPath': projectPath,
            'projectName': project.name,
            'urls': project.urls.map(entryJson).toList(),
            'workspace_ports_in_use': await workspacePorts(),
            if (gateway?.port != null) 'gateway_port': gateway!.port,
          });
        } catch (e) {
          return jsonEncode({'ok': false, 'error': e.toString()});
        }
      },
    ),
  ];
}

Future<bool> _isPortListening(SandboxWorkspace workspace, int port) async {
  final probe = await workspace.run(
    siteProbeShellCommand(['http://127.0.0.1:$port/']),
    timeout: const Duration(seconds: 15),
  );
  final code = probe.stdout.trim().split(RegExp(r'\s+')).first;
  return isHttpServiceResponding(code);
}

Future<bool> _isOwnSitePidAlive({
  required SandboxWorkspace workspace,
  required String projectPath,
  required String name,
  required String url,
}) async {
  final dir = guestProjectDir(projectPath);
  final stem = siteRuntimeStem(name, url: url);
  final result = await workspace.run(
    siteOwnPidAliveShellCommand(projectDir: dir, pidFileName: '$stem.pid'),
    timeout: const Duration(seconds: 10),
  );
  return result.stdout.trim() == '1';
}
