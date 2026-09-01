import 'dart:convert';

import 'package:vault/agent/agent_site_controller.dart';
import 'package:vault/agent/project_site_launcher.dart';
import 'package:vault/agent/project_store.dart';
import 'package:vault/agent/site_gateway.dart';
import 'package:vault/agent/site_port.dart';
import 'package:vault/agent/site_register.dart';
import 'package:vault/agent/site_scaffold.dart';
import 'package:vault/sandbox/sandbox_models.dart';
import 'package:vault_agent_core/vault_agent_core.dart';

const String kManageSiteToolName = 'manage_site';

const String _kCatalogActions =
    'start / stop / status / logs / list / adopt / update / unregister';

/// Start / stop / status / logs plus catalog actions for the project site.
Tool createManageSiteTool({
  required SandboxWorkspace workspace,
  required ProjectSiteLauncher launcher,
  required ProjectStore projectStore,
  required String workspaceId,
  required String projectPath,
  SiteGateway? gateway,
  AgentSiteController? siteController,
  void Function()? onChanged,
}) {
  Future<ProjectUrlEntry?> registeredSite() async {
    final project = await projectStore.getProject(workspaceId, projectPath);
    return project?.site;
  }

  String? publicUrlOf(ProjectUrlEntry entry) {
    final slug = entry.slug?.trim();
    if (gateway == null ||
        gateway.port == null ||
        slug == null ||
        slug.isEmpty) {
      return null;
    }
    return sitePublicUrl(slug: slug, gatewayPort: gateway.port!);
  }

  Map<String, dynamic> siteJson(ProjectUrlEntry entry) {
    return projectSiteJson(entry, gateway: gateway);
  }

  Future<Set<int>> takenPorts() async {
    final claims = await projectStore.listPortClaims(workspaceId);
    return {
      for (final claim in claims) claim.port,
      if (gateway?.port != null) gateway!.port!,
    };
  }

  Future<String> failIfUnregistered() async {
    return jsonEncode({
      'ok': false,
      'error': '当前项目还没有站点，请先 scaffold_site 或 manage_site action=adopt',
    });
  }

  return Tool(
    name: kManageSiteToolName,
    description:
        '管理当前项目站点：$_kCatalogActions。'
        'start 走与侧栏相同的启动器，等到端口监听后才算成功，返回 public_url；默认不打开浏览器。'
        '空项目先 scaffold_site；已有 app.py / index.html 未登记则 adopt。'
        'start_command 由工具按 kind 推导，不要自造。'
        '不要用 shell 起停网站。',
    parameterMode: ToolParameterMode.object,
    allowBackground: false,
    parameters: {
      'type': 'object',
      'properties': {
        'action': {'type': 'string', 'description': _kCatalogActions},
        'open_browser': {
          'type': 'boolean',
          'description': '仅 start：是否打开系统浏览器。默认 false。',
        },
        'lines': {
          'type': 'integer',
          'description': '仅 logs：返回末尾多少行。默认 $kSiteLogTailLines。',
        },
        'name': {'type': 'string', 'description': '仅 adopt / update：站点显示名。'},
        'port': {'type': 'integer', 'description': '仅 update：新的内部监听端口。'},
      },
      'required': ['action'],
    },
    executable: (Map<String, dynamic> args) async {
      final action = (args['action'] as String?)?.trim().toLowerCase() ?? '';
      if (action.isEmpty) {
        return jsonEncode({'ok': false, 'error': 'action 不能为空'});
      }

      switch (action) {
        case 'list':
          return _list(
            projectStore: projectStore,
            workspaceId: workspaceId,
            projectPath: projectPath,
            launcher: launcher,
            registeredSite: registeredSite,
            publicUrlOf: publicUrlOf,
            siteJson: siteJson,
          );
        case 'adopt':
          return _adopt(
            workspace: workspace,
            projectStore: projectStore,
            workspaceId: workspaceId,
            projectPath: projectPath,
            gateway: gateway,
            registeredSite: registeredSite,
            takenPorts: takenPorts,
            name: (args['name'] as String?)?.trim(),
            onChanged: onChanged,
          );
        case 'update':
          return _update(
            workspace: workspace,
            launcher: launcher,
            projectStore: projectStore,
            workspaceId: workspaceId,
            projectPath: projectPath,
            gateway: gateway,
            registeredSite: registeredSite,
            name: (args['name'] as String?)?.trim(),
            port: args.containsKey('port') ? args['port'] : null,
            onChanged: onChanged,
          );
        case 'unregister':
          return _unregister(
            launcher: launcher,
            projectStore: projectStore,
            workspaceId: workspaceId,
            projectPath: projectPath,
            gateway: gateway,
            registeredSite: registeredSite,
            siteJson: siteJson,
            onChanged: onChanged,
          );
      }

      final site = await registeredSite();
      if (site == null) {
        return failIfUnregistered();
      }

      switch (action) {
        case 'start':
          final openBrowser = args['open_browser'] == true;
          try {
            final result = siteController != null
                ? await siteController.start(
                    site,
                    projectPath: projectPath,
                    openInBrowser: openBrowser,
                    announce: false,
                  )
                : await launcher.start(
                    projectPath: projectPath,
                    entry: site,
                    openInBrowser: openBrowser,
                    openUrl: publicUrlOf(site),
                  );
            final ok = result.startedProcess || result.alreadyUp;
            if (ok) onChanged?.call();
            return jsonEncode({
              'ok': ok,
              'action': 'start',
              'startedProcess': result.startedProcess,
              'alreadyUp': result.alreadyUp,
              'openedUrl': result.openedUrl,
              'public_url': publicUrlOf(site),
              'site': siteJson(site),
              if (result.message != null) 'message': result.message,
              if (!ok) 'error': result.message ?? '启动失败',
              if (result.logTail != null) 'logTail': result.logTail,
            });
          } catch (e) {
            return jsonEncode({'ok': false, 'action': 'start', 'error': '$e'});
          }

        case 'stop':
          try {
            final result = siteController != null
                ? await siteController.stop(
                    site,
                    projectPath: projectPath,
                    announce: false,
                  )
                : await launcher.stop(
                    projectPath: projectPath,
                    entry: site,
                  );
            onChanged?.call();
            return jsonEncode({
              'ok': result.stopped,
              'action': 'stop',
              'stopped': result.stopped,
              if (result.message != null) 'message': result.message,
              if (!result.stopped) 'error': result.message ?? '终止失败',
              'site': siteJson(site),
            });
          } catch (e) {
            return jsonEncode({'ok': false, 'action': 'stop', 'error': '$e'});
          }

        case 'status':
          try {
            final up = await launcher.isProjectSiteUp(
              projectPath: projectPath,
              entry: site,
            );
            return jsonEncode({
              'ok': true,
              'action': 'status',
              'up': up,
              'public_url': publicUrlOf(site),
              'site': siteJson(site),
            });
          } catch (e) {
            return jsonEncode({'ok': false, 'action': 'status', 'error': '$e'});
          }

        case 'logs':
          final lines = _asPositiveInt(args['lines']) ?? kSiteLogTailLines;
          try {
            final tail = await launcher.readLogTail(
              projectPath: projectPath,
              entry: site,
              maxLines: lines,
            );
            return jsonEncode({
              'ok': true,
              'action': 'logs',
              'logTail': tail ?? '',
              if (tail == null || tail.isEmpty) 'hint': '还没有日志文件，站点可能尚未启动过',
              'site': siteJson(site),
            });
          } catch (e) {
            return jsonEncode({'ok': false, 'action': 'logs', 'error': '$e'});
          }

        default:
          return jsonEncode({
            'ok': false,
            'error': '未知 action：$action（$_kCatalogActions）',
          });
      }
    },
  );
}

Future<String> _list({
  required ProjectStore projectStore,
  required String workspaceId,
  required String projectPath,
  required ProjectSiteLauncher launcher,
  required Future<ProjectUrlEntry?> Function() registeredSite,
  required String? Function(ProjectUrlEntry entry) publicUrlOf,
  required Map<String, dynamic> Function(ProjectUrlEntry entry) siteJson,
}) async {
  try {
    final site = await registeredSite();
    bool? up;
    if (site != null) {
      up = await launcher.isProjectSiteUp(
        projectPath: projectPath,
        entry: site,
      );
    }
    final all = await projectStore.list(workspaceId);
    final otherPorts = <Map<String, dynamic>>[];
    for (final project in all) {
      if (project.path == projectPath) continue;
      final other = project.site;
      if (other == null) continue;
      final port = portFromSiteUrl(other.url);
      otherPorts.add({
        'projectPath': project.path,
        'projectName': project.name,
        'siteName': other.name,
        if (port != null) 'port': port,
        if (other.slug != null && other.slug!.trim().isNotEmpty)
          'slug': other.slug,
      });
    }
    return jsonEncode({
      'ok': true,
      'action': 'list',
      'registered': site != null,
      'site': site == null ? null : siteJson(site),
      'public_url': site == null ? null : publicUrlOf(site),
      if (up != null) 'up': up,
      'other_ports': otherPorts,
    });
  } catch (e) {
    return jsonEncode({'ok': false, 'action': 'list', 'error': '$e'});
  }
}

Future<String> _adopt({
  required SandboxWorkspace workspace,
  required ProjectStore projectStore,
  required String workspaceId,
  required String projectPath,
  required SiteGateway? gateway,
  required Future<ProjectUrlEntry?> Function() registeredSite,
  required Future<Set<int>> Function() takenPorts,
  required String? name,
  required void Function()? onChanged,
}) async {
  final existing = await registeredSite();
  if (existing != null) {
    return jsonEncode({
      'ok': false,
      'action': 'adopt',
      'error': '当前项目已有登记，请用 manage_site action=update',
    });
  }

  final dir = guestProjectDir(projectPath);
  final hasAppPy =
      await workspace.readGuestFile('$dir/$kScaffoldFlaskMarker') != null;
  final hasIndexHtml =
      await workspace.readGuestFile('$dir/$kScaffoldStaticMarker') != null;
  final kind = inferSiteKind(
    hasAppPy: hasAppPy,
    hasRootIndexHtml: hasIndexHtml,
  );
  if (kind == null) {
    return jsonEncode({
      'ok': false,
      'action': 'adopt',
      'error': '当前项目没有 app.py 或 index.html，空项目请 scaffold_site',
    });
  }

  final taken = await takenPorts();
  var port = allocateSitePort(taken);
  var reusedConfigPort = false;
  var wroteConfig = false;

  if (kind == SiteScaffoldKind.flask) {
    final configBytes = await workspace.readGuestFile('$dir/config.py');
    final fromConfig = configBytes == null
        ? null
        : parseFlaskPortFromConfig(utf8.decode(configBytes));
    if (fromConfig != null && !taken.contains(fromConfig)) {
      port = fromConfig;
      reusedConfigPort = true;
    }
    if (!reusedConfigPort) {
      final next = applyFlaskPortToConfig(
        configBytes == null ? null : utf8.decode(configBytes),
        port,
      );
      await workspace.writeGuestFile('$dir/config.py', utf8.encode(next));
      wroteConfig = true;
    }
  }

  final displayName = (name == null || name.isEmpty) ? '网站' : name;
  try {
    final registered = await registerProjectSite(
      projectStore: projectStore,
      workspaceId: workspaceId,
      projectPath: projectPath,
      entry: ProjectUrlEntry(
        name: displayName,
        url: siteListenUrl(port),
        startCommand: startCommandForKind(kind, port),
      ),
      gateway: gateway,
    );
    onChanged?.call();
    final site = projectSiteJson(registered, gateway: gateway);
    return jsonEncode({
      'ok': true,
      'action': 'adopt',
      'kind': kind.name,
      'port': port,
      'reusedConfigPort': reusedConfigPort,
      if (wroteConfig) 'wroteConfig': true,
      'start_command': startCommandForKind(kind, port),
      'site': site,
      'public_url': site['public_url'],
      'hint': '已登记。下一步 manage_site action=start。不要用 shell 起网站。',
    });
  } on SitePortConflictException catch (e) {
    return jsonEncode({'ok': false, 'action': 'adopt', 'error': e.toString()});
  } catch (e) {
    return jsonEncode({'ok': false, 'action': 'adopt', 'error': '登记失败：$e'});
  }
}

Future<String> _update({
  required SandboxWorkspace workspace,
  required ProjectSiteLauncher launcher,
  required ProjectStore projectStore,
  required String workspaceId,
  required String projectPath,
  required SiteGateway? gateway,
  required Future<ProjectUrlEntry?> Function() registeredSite,
  required String? name,
  required Object? port,
  required void Function()? onChanged,
}) async {
  final site = await registeredSite();
  if (site == null) {
    return jsonEncode({
      'ok': false,
      'action': 'update',
      'error': '当前项目还没有站点，请先 scaffold_site 或 manage_site action=adopt',
    });
  }

  final newName = (name == null || name.isEmpty) ? site.name : name;
  final wantsPort = port != null;
  final newPort = wantsPort ? _asPort(port) : portFromSiteUrl(site.url);
  if (wantsPort && newPort == null) {
    return jsonEncode({
      'ok': false,
      'action': 'update',
      'error': 'port 必须是 1–65535 的整数',
    });
  }
  if (!wantsPort && (name == null || name.isEmpty)) {
    return jsonEncode({
      'ok': false,
      'action': 'update',
      'error': 'update 需要 name 或 port',
    });
  }

  final currentPort = portFromSiteUrl(site.url);
  final portChanged = newPort != null && newPort != currentPort;

  if (portChanged) {
    if (gateway?.port == newPort) {
      return jsonEncode({
        'ok': false,
        'action': 'update',
        'error': '端口 $newPort 是网关端口，请换一个',
      });
    }
    final claims = await projectStore.listPortClaims(workspaceId);
    final conflict = findWorkspacePortConflict(
      claims: claims,
      port: newPort,
      ignoreProjectPath: projectPath,
    );
    if (conflict != null) {
      return jsonEncode({
        'ok': false,
        'action': 'update',
        'error':
            '端口 $newPort 已被「${conflict.projectName}」的「${conflict.siteName}」占用',
      });
    }

    final dir = guestProjectDir(projectPath);
    final hasAppPy =
        await workspace.readGuestFile('$dir/$kScaffoldFlaskMarker') != null;
    final hasIndexHtml =
        await workspace.readGuestFile('$dir/$kScaffoldStaticMarker') != null;
    final kind = inferSiteKind(
      hasAppPy: hasAppPy,
      hasRootIndexHtml: hasIndexHtml,
      startCommand: site.startCommand,
    );
    if (kind == null) {
      return jsonEncode({
        'ok': false,
        'action': 'update',
        'error': '无法判断站点类型，换端口需要 app.py、index.html 或已登记的启动命令',
      });
    }

    if (kind == SiteScaffoldKind.flask) {
      final configBytes = await workspace.readGuestFile('$dir/config.py');
      final next = applyFlaskPortToConfig(
        configBytes == null ? null : utf8.decode(configBytes),
        newPort,
      );
      await workspace.writeGuestFile('$dir/config.py', utf8.encode(next));
    }

    try {
      final up = await launcher.isProjectSiteUp(
        projectPath: projectPath,
        entry: site,
      );
      if (up) {
        await launcher.stop(projectPath: projectPath, entry: site);
      }
    } catch (_) {}
  }

  final resolvedPort = newPort ?? currentPort;
  if (resolvedPort == null) {
    return jsonEncode({
      'ok': false,
      'action': 'update',
      'error': '当前登记没有可解析的端口',
    });
  }

  final dir = guestProjectDir(projectPath);
  final hasAppPy =
      await workspace.readGuestFile('$dir/$kScaffoldFlaskMarker') != null;
  final hasIndexHtml =
      await workspace.readGuestFile('$dir/$kScaffoldStaticMarker') != null;
  final kind = inferSiteKind(
    hasAppPy: hasAppPy,
    hasRootIndexHtml: hasIndexHtml,
    startCommand: site.startCommand,
  );
  if (kind == null) {
    return jsonEncode({
      'ok': false,
      'action': 'update',
      'error': '无法判断站点类型，不能推导 start_command',
    });
  }

  try {
    final registered = await registerProjectSite(
      projectStore: projectStore,
      workspaceId: workspaceId,
      projectPath: projectPath,
      entry: ProjectUrlEntry(
        name: newName,
        url: siteListenUrl(resolvedPort),
        startCommand: startCommandForKind(kind, resolvedPort),
        slug: site.slug,
      ),
      gateway: gateway,
    );
    onChanged?.call();
    final json = projectSiteJson(registered, gateway: gateway);
    return jsonEncode({
      'ok': true,
      'action': 'update',
      'kind': kind.name,
      'port': resolvedPort,
      'start_command': startCommandForKind(kind, resolvedPort),
      'site': json,
      'public_url': json['public_url'],
      'slug': registered.slug,
      if (portChanged) 'hint': '端口已改，请 manage_site action=start 后生效',
    });
  } on SitePortConflictException catch (e) {
    return jsonEncode({'ok': false, 'action': 'update', 'error': e.toString()});
  } catch (e) {
    return jsonEncode({'ok': false, 'action': 'update', 'error': '更新失败：$e'});
  }
}

Future<String> _unregister({
  required ProjectSiteLauncher launcher,
  required ProjectStore projectStore,
  required String workspaceId,
  required String projectPath,
  required SiteGateway? gateway,
  required Future<ProjectUrlEntry?> Function() registeredSite,
  required Map<String, dynamic> Function(ProjectUrlEntry entry) siteJson,
  required void Function()? onChanged,
}) async {
  final site = await registeredSite();
  if (site == null) {
    return jsonEncode({
      'ok': false,
      'action': 'unregister',
      'error': '当前项目还没有站点',
    });
  }

  try {
    final up = await launcher.isProjectSiteUp(
      projectPath: projectPath,
      entry: site,
    );
    if (up) {
      await launcher.stop(projectPath: projectPath, entry: site);
    }
  } catch (e) {
    return jsonEncode({
      'ok': false,
      'action': 'unregister',
      'error': '停止站点失败：$e',
    });
  }

  try {
    await unregisterProjectSite(
      projectStore: projectStore,
      workspaceId: workspaceId,
      projectPath: projectPath,
      name: site.name,
      gateway: gateway,
    );
    onChanged?.call();
    return jsonEncode({
      'ok': true,
      'action': 'unregister',
      'files_kept': true,
      'site': siteJson(site),
      'hint': '已注销登记，项目文件还在。',
    });
  } catch (e) {
    return jsonEncode({
      'ok': false,
      'action': 'unregister',
      'error': '注销失败：$e',
    });
  }
}

int? _asPositiveInt(Object? raw) {
  if (raw is int && raw > 0) return raw;
  if (raw is num && raw > 0) return raw.toInt();
  if (raw is String) {
    final n = int.tryParse(raw.trim());
    if (n != null && n > 0) return n;
  }
  return null;
}

int? _asPort(Object? raw) {
  int? n;
  if (raw is int) {
    n = raw;
  } else if (raw is num) {
    n = raw.toInt();
  } else if (raw is String) {
    n = int.tryParse(raw.trim());
  }
  if (n == null || n < 1 || n > 65535) return null;
  return n;
}
