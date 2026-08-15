import 'dart:convert';

import 'package:vault/agent/project_store.dart';
import 'package:vault/agent/site_browser_log.dart';
import 'package:vault/agent/site_gateway.dart';
import 'package:vault_agent_core/vault_agent_core.dart';

const String kInspectSiteToolName = 'inspect_site';

/// Pull browser / gateway errors for the conversation's bound project.
///
/// No model arguments: uses registered sites on the current project, probes
/// whether each service is listening, and either returns captured events or
/// says the service is down.
Tool createInspectSiteTool({
  required SiteGateway gateway,
  required Future<List<ProjectUrlEntry>> Function() projectSites,
  required Future<Map<String, bool>> Function(List<ProjectUrlEntry> sites)
  probeUp,
}) {
  return Tool(
    name: kInspectSiteToolName,
    description:
        '查看当前项目站点在用户浏览器里积累的控制台错误、未捕获异常和失败请求（以及网关 4xx/5xx）。'
        '用户说「不能用 / 坏了 / 打不开」时先用这个，不要让他们开 F12，也不用传站点名。'
        '会话已绑定项目：自动看该项目已登记的站点。服务没启动就直接告诉你；起来了则返回缓冲里的全部记录。',
    parameterMode: ToolParameterMode.object,
    parameters: {'type': 'object', 'properties': <String, dynamic>{}},
    executable: (Map<String, dynamic> args) async {
      final sites = await projectSites();
      if (sites.isEmpty) {
        return jsonEncode({'ok': false, 'error': '当前项目还没有登记站点'});
      }

      final upByName = await probeUp(sites);
      final reports = <Map<String, dynamic>>[];
      var anyUp = false;
      for (final site in sites) {
        final up = upByName[site.name] ?? false;
        final slug = site.slug?.trim();
        if (!up) {
          reports.add({
            'name': site.name,
            if (slug != null && slug.isNotEmpty) 'slug': slug,
            'up': false,
            'message': '服务没启动',
          });
          continue;
        }
        anyUp = true;
        final events = slug == null || slug.isEmpty
            ? const <Map<String, dynamic>>[]
            : browserEventsForTool(
                gateway.recentEvents(slug: slug, includeWarn: true),
              );
        reports.add({
          'name': site.name,
          if (slug != null && slug.isNotEmpty) 'slug': slug,
          'up': true,
          'events': events,
          if (events.isEmpty) 'hint': '用户可能还没打开侧栏站点，或页面尚未加载采集脚本',
        });
      }

      return jsonEncode({
        'ok': true,
        'sites': reports,
        if (!anyUp) 'hint': '服务没启动，请让用户在侧栏「站点」里启动后再试',
      });
    },
  );
}
