import 'package:vault/agent/site_port.dart';
import 'package:vault/sandbox/sandbox_models.dart';

/// Default display name for a newly created project.
const kDefaultProjectName = '新项目';

/// The single frontend URL/start entry for a project.
class ProjectUrlEntry {
  const ProjectUrlEntry({
    required this.name,
    required this.url,
    this.startCommand,
    this.slug,
  });

  final String name;
  final String url;
  final String? startCommand;

  /// ASCII Host label for the workspace gateway (`{slug}.localhost`).
  final String? slug;

  Map<String, dynamic> toJson() => {
    'name': name,
    'url': url,
    if (startCommand != null && startCommand!.trim().isNotEmpty)
      'startCommand': startCommand,
    if (slug != null && slug!.trim().isNotEmpty) 'slug': slug,
  };

  factory ProjectUrlEntry.fromJson(Map<String, dynamic> json) {
    return ProjectUrlEntry(
      name: (json['name'] as String?)?.trim() ?? '',
      url: (json['url'] as String?)?.trim() ?? '',
      startCommand: (json['startCommand'] as String?)?.trim(),
      slug: (json['slug'] as String?)?.trim(),
    );
  }
}

/// Metadata for one project inside a workspace.
class ProjectInfo {
  const ProjectInfo({
    required this.path,
    required this.name,
    required this.createdAt,
    required this.updatedAt,
    this.urls = const [],
  });

  /// Timestamp folder name under [kGuestProjectsDir].
  final String path;
  final String name;
  final DateTime createdAt;
  final DateTime updatedAt;
  final List<ProjectUrlEntry> urls;

  ProjectUrlEntry? get site => urls.isEmpty ? null : urls.first;

  String get guestDir => guestProjectDir(path);
}

/// Flatten registered URLs into workspace port claims.
List<SitePortClaim> portClaimsFromProjects(List<ProjectInfo> projects) {
  return [
    for (final project in projects)
      for (final entry in project.urls)
        if (portFromSiteUrl(entry.url) != null)
          SitePortClaim(
            projectPath: project.path,
            projectName: project.name,
            siteName: entry.name,
            port: portFromSiteUrl(entry.url)!,
            slug: entry.slug,
          ),
  ];
}
