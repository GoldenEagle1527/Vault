import 'dart:async';

import 'package:vault/agent/project_site_launcher.dart';
import 'package:vault/agent/project_store.dart';
import 'package:vault/sandbox/sandbox_provider.dart';

class SiteProbeGenerationGuard {
  int _generation = 0;
  bool _inFlight = false;

  bool get inFlight => _inFlight;

  int? tryBegin() {
    if (_inFlight) return null;
    _inFlight = true;
    return _generation;
  }

  void invalidate() {
    _generation++;
    _inFlight = false;
  }

  bool canApply(int generation) => generation == _generation;

  void finish(int generation) {
    if (canApply(generation)) _inFlight = false;
  }
}

class AgentSiteMessage {
  const AgentSiteMessage(this.text, {this.isError = false});

  final String text;
  final bool isError;
}

class AgentSiteController {
  AgentSiteController({
    required SandboxWorkspace workspace,
    required this.projects,
    required this.isMounted,
    required this.onChanged,
    required this.publicUrl,
    required this.beforeStart,
    required this.syncKeepAlive,
    required this.onMessage,
    ProjectSiteLauncher? launcher,
  }) : _launcher = launcher ?? ProjectSiteLauncher(workspace);

  final List<ProjectInfo> Function() projects;
  final bool Function() isMounted;
  final void Function() onChanged;
  final String Function(ProjectUrlEntry entry) publicUrl;
  final Future<void> Function(ProjectUrlEntry entry) beforeStart;
  final Future<void> Function(ProjectUrlEntry? entry) syncKeepAlive;
  final void Function(AgentSiteMessage message) onMessage;
  final ProjectSiteLauncher _launcher;
  final SiteProbeGenerationGuard probeGuard = SiteProbeGenerationGuard();
  final Map<String, bool> siteUp = {};
  final Set<String> siteBusy = {};
  Timer? _pollTimer;
  String? status;

  List<(String, ProjectUrlEntry)> get runningPairs => [
    for (final project in projects())
      if (project.site != null && siteUp[project.path] == true)
        (project.path, project.site!),
  ];

  Iterable<String> get runningNames => runningPairs.map((pair) => pair.$2.name);

  void invalidateProbe() => probeGuard.invalidate();

  void syncPolling({required bool enabled}) {
    final shouldPoll =
        enabled && projects().any((project) => project.site != null);
    if (shouldPoll) {
      _pollTimer ??= Timer.periodic(const Duration(seconds: 4), (_) {
        unawaited(refreshStatus());
      });
      unawaited(refreshStatus());
    } else {
      _pollTimer?.cancel();
      _pollTimer = null;
    }
  }

  Future<void> refreshStatus() async {
    final generation = probeGuard.tryBegin();
    if (generation == null) return;
    final pairs = [
      for (final project in projects())
        if (project.site != null) (project.path, project.site!),
    ];
    if (pairs.isEmpty) {
      if (siteUp.isNotEmpty && isMounted()) {
        siteUp.clear();
        onChanged();
      }
      probeGuard.finish(generation);
      return;
    }
    try {
      final next = <String, bool>{};
      for (final pair in pairs) {
        next[pair.$1] = await _launcher.isProjectSiteUp(
          projectPath: pair.$1,
          entry: pair.$2,
        );
      }
      if (!isMounted() || !probeGuard.canApply(generation)) return;
      siteUp
        ..clear()
        ..addAll(next);
      onChanged();
      await syncKeepAlive(runningPairs.isEmpty ? null : runningPairs.first.$2);
    } catch (_) {
      // Keep the last known status.
    } finally {
      probeGuard.finish(generation);
    }
  }

  Future<void> start(
    ProjectUrlEntry entry, {
    required String projectPath,
  }) async {
    invalidateProbe();
    status = '正在启动「${entry.name}」…';
    siteBusy.add(projectPath);
    onChanged();
    await beforeStart(entry);
    var launched = false;
    try {
      final result = await _launcher.start(
        projectPath: projectPath,
        entry: entry,
        openUrl: publicUrl(entry),
      );
      if (!isMounted()) return;
      launched = result.startedProcess || result.alreadyUp;
      if (launched) {
        invalidateProbe();
        siteUp[projectPath] = true;
        await syncKeepAlive(entry);
      }
      final parts = <String>[
        if (result.alreadyUp) '服务已在运行',
        if (result.startedProcess) '已后台启动',
        if (result.openedUrl) '已打开浏览器',
        if (!result.openedUrl && publicUrl(entry).trim().isNotEmpty)
          '地址：${publicUrl(entry)}',
        if (result.message != null &&
            result.message != '服务已在运行' &&
            result.message != '已后台启动')
          result.message!,
      ];
      onMessage(
        AgentSiteMessage(
          parts.isEmpty ? '启动完成' : parts.join(' · '),
          isError:
              !result.startedProcess && !result.alreadyUp && !result.openedUrl,
        ),
      );
    } catch (error) {
      if (!isMounted()) return;
      onMessage(AgentSiteMessage('启动失败：$error', isError: true));
    } finally {
      if (isMounted()) {
        status = null;
        siteBusy.remove(projectPath);
        onChanged();
        if (!launched) unawaited(refreshStatus());
      }
    }
  }

  Future<void> stop(
    ProjectUrlEntry entry, {
    required String projectPath,
  }) async {
    invalidateProbe();
    status = '正在终止「${entry.name}」…';
    siteBusy.add(projectPath);
    onChanged();
    try {
      final result = await _launcher.stop(
        projectPath: projectPath,
        entry: entry,
      );
      if (!isMounted()) return;
      siteUp[projectPath] = !result.stopped;
      onMessage(
        AgentSiteMessage(
          result.message ?? (result.stopped ? '已终止' : '终止失败'),
          isError: !result.stopped,
        ),
      );
    } catch (error) {
      if (!isMounted()) return;
      onMessage(AgentSiteMessage('终止失败：$error', isError: true));
    } finally {
      if (isMounted()) {
        status = null;
        siteBusy.remove(projectPath);
        onChanged();
        unawaited(refreshStatus());
      }
    }
  }

  Future<void> stopAll() async {
    for (final pair in runningPairs.toList()) {
      if (!isMounted()) return;
      await stop(pair.$2, projectPath: pair.$1);
    }
  }

  void dispose() {
    _pollTimer?.cancel();
    _pollTimer = null;
    invalidateProbe();
  }
}
