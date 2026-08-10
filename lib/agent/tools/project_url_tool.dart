import 'dart:convert';

import 'package:vault/agent/project_store.dart';
import 'package:vault_agent_core/vault_agent_core.dart';

/// Tools for the agent to register local site URLs into the host project DB.
List<Tool> createProjectUrlTools({
  required ProjectStore projectStore,
  required String workspaceId,
  required String projectPath,
}) {
  return [
    Tool(
      name: 'register_project_url',
      description:
          '把当前项目做好的本地网站登记到 Vault 项目数据（主机侧数据库，不在 Linux 内）。'
          '网站可用后必须调用本工具，用户才能在 UI 里看到并一键启动。'
          '同名条目会覆盖；多服务按多次调用登记，sort 顺序为调用先后。'
          'url 建议 http://127.0.0.1:端口/ ；start_command 为在项目目录下可重复执行的启动命令'
          '（如 python3 -m http.server 8080 --bind 127.0.0.1）。',
      parameterMode: ToolParameterMode.object,
      parameters: {
        'type': 'object',
        'properties': {
          'name': {
            'type': 'string',
            'description': '站点/服务显示名，如「网站」「API」',
          },
          'url': {
            'type': 'string',
            'description': '可访问地址，如 http://127.0.0.1:8080/',
          },
          'start_command': {
            'type': 'string',
            'description':
                '可选。在项目根目录执行即可启动服务的命令（后台由 App 负责）。'
                '示例：python3 -m http.server 8080 --bind 127.0.0.1',
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
          return jsonEncode({
            'ok': false,
            'error': 'name 与 url 不能为空',
          });
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
          return jsonEncode({
            'ok': true,
            'projectPath': projectPath,
            'registered': {
              'name': name,
              'url': url,
              if (start != null && start.isNotEmpty) 'start_command': start,
            },
            'urls': urls.map((u) => u.toJson()).toList(),
          });
        } catch (e) {
          return jsonEncode({'ok': false, 'error': e.toString()});
        }
      },
    ),
    Tool(
      name: 'list_project_urls',
      description: '列出当前项目已登记的网址与启动命令（主机侧项目数据）。',
      parameterMode: ToolParameterMode.object,
      parameters: {
        'type': 'object',
        'properties': <String, dynamic>{},
      },
      executable: (Map<String, dynamic> args) async {
        try {
          final project =
              await projectStore.getProject(workspaceId, projectPath);
          if (project == null) {
            return jsonEncode({
              'ok': false,
              'error': '项目不存在：$projectPath',
            });
          }
          return jsonEncode({
            'ok': true,
            'projectPath': projectPath,
            'projectName': project.name,
            'urls': project.urls.map((u) => u.toJson()).toList(),
          });
        } catch (e) {
          return jsonEncode({'ok': false, 'error': e.toString()});
        }
      },
    ),
  ];
}
