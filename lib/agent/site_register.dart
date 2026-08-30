import 'package:vault/agent/project_store.dart';
import 'package:vault/agent/site_gateway.dart';
import 'package:vault/agent/site_port.dart';

/// Host-side site catalog write. Not an Agent tool — scaffold/adopt/update call this.
Future<ProjectUrlEntry> registerProjectSite({
  required ProjectStore projectStore,
  required String workspaceId,
  required String projectPath,
  required ProjectUrlEntry entry,
  SiteGateway? gateway,
}) async {
  final urls = await projectStore.upsertUrl(workspaceId, projectPath, entry);
  if (gateway != null) {
    await refreshSiteGateway(projectStore, workspaceId, gateway);
  }
  return urls.firstWhere((u) => u.name == entry.name);
}

/// Drop the project's registered site and refresh gateway routes. Files stay.
Future<void> unregisterProjectSite({
  required ProjectStore projectStore,
  required String workspaceId,
  required String projectPath,
  required String name,
  SiteGateway? gateway,
}) async {
  await projectStore.removeUrl(workspaceId, projectPath, name);
  if (gateway != null) {
    await refreshSiteGateway(projectStore, workspaceId, gateway);
  }
}

Future<void> refreshSiteGateway(
  ProjectStore projectStore,
  String workspaceId,
  SiteGateway gateway,
) async {
  final all = await projectStore.list(workspaceId);
  gateway.updateRoutes(siteRoutesFromProjects(all));
}

/// JSON for a registered entry, including gateway [public_url] when known.
Map<String, dynamic> projectSiteJson(
  ProjectUrlEntry entry, {
  SiteGateway? gateway,
}) {
  final json = entry.toJson();
  final slug = entry.slug?.trim();
  if (gateway != null &&
      gateway.port != null &&
      slug != null &&
      slug.isNotEmpty) {
    json['public_url'] = sitePublicUrl(slug: slug, gatewayPort: gateway.port!);
  }
  return json;
}
