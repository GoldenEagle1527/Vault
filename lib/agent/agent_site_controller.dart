import 'dart:async';

import 'package:vault/agent/project_site_launcher.dart';
import 'package:vault/agent/project_store.dart';
import 'package:vault/agent/site_supervisor.dart';
import 'package:vault/sandbox/sandbox_provider.dart';

class SiteProbeGenerationGuard {
  int _generation = 0;
  bool _inFlight = false;
  bool _dirty = false;

  bool get inFlight => _inFlight;

  int? tryBegin() {
    if (_inFlight) {
      _dirty = true;
      return null;
    }
    _inFlight = true;
    _dirty = false;
    return _generation;
  }

  void invalidate() {
    _generation++;
    _inFlight = false;
    _dirty = false;
  }

  bool canApply(int generation) => generation == _generation;

  bool finish(int generation) {
    if (!canApply(generation)) return _dirty;
    _inFlight = false;
    final again = _dirty;
    _dirty = false;
    return again;
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
    required List<ProjectInfo> Function() projects,
    required bool Function() isMounted,
    required void Function() onChanged,
    required String Function(ProjectUrlEntry entry) publicUrl,
    required Future<void> Function(ProjectUrlEntry entry) beforeStart,
    required Future<void> Function(List<String> names) syncKeepAlive,
    required void Function(AgentSiteMessage message) onMessage,
    SiteSupervisorClient? supervisor,
    ProjectSiteLauncher? launcher,
  }) : this._(
         workspace: workspace,
         projects: projects,
         isMounted: isMounted,
         onChanged: onChanged,
         publicUrl: publicUrl,
         beforeStart: beforeStart,
         syncKeepAlive: syncKeepAlive,
         onMessage: onMessage,
         supervisor:
             supervisor ??
             launcher?.supervisor ??
             GuestSiteSupervisorClient(workspace),
         launcher: launcher,
       );

  AgentSiteController._({
    required SandboxWorkspace workspace,
    required this.projects,
    required this.isMounted,
    required this.onChanged,
    required this.publicUrl,
    required this.beforeStart,
    required this.syncKeepAlive,
    required this.onMessage,
    required SiteSupervisorClient supervisor,
    ProjectSiteLauncher? launcher,
  }) : _supervisor = supervisor,
       _launcher =
           launcher ??
           ProjectSiteLauncher(workspace, supervisor: supervisor) {
    _eventSub = _supervisor.events.listen(_onSupervisorEvent);
  }

  final List<ProjectInfo> Function() projects;
  final bool Function() isMounted;
  final void Function() onChanged;
  final String Function(ProjectUrlEntry entry) publicUrl;
  final Future<void> Function(ProjectUrlEntry entry) beforeStart;
  final Future<void> Function(List<String> names) syncKeepAlive;
  final void Function(AgentSiteMessage message) onMessage;
  final SiteSupervisorClient _supervisor;
  final ProjectSiteLauncher _launcher;
  StreamSubscription<SiteSupervisorEvent>? _eventSub;

  ProjectSiteLauncher get launcher => _launcher;
  SiteSupervisorClient get supervisor => _supervisor;
  final SiteProbeGenerationGuard probeGuard = SiteProbeGenerationGuard();
  final Map<String, bool> siteUp = {};
  final Set<String> siteBusy = {};
  String? status;

  List<(String, ProjectUrlEntry)> get runningPairs => [
    for (final project in projects())
      if (project.site != null && siteUp[project.path] == true)
        (project.path, project.site!),
  ];

  Iterable<String> get runningNames => runningPairs.map((pair) => pair.$2.name);

  void invalidateProbe() => probeGuard.invalidate();

  void syncPolling({required bool enabled}) {
    if (enabled) {
      unawaited(refreshStatus());
    }
  }

  void _onSupervisorEvent(SiteSupervisorEvent event) {
    if (!isMounted()) return;
    if (event.listening) {
      siteUp[event.id] = true;
    } else if (event.down) {
      siteUp[event.id] = false;
    } else {
      return;
    }
    onChanged();
    unawaited(syncKeepAlive(runningNames.toList()));
  }

  /// Gateway could not reach this slug's backend (502).
  void noteUnreachable(String slug) {
    final want = slug.trim();
    if (want.isEmpty) return;
    var changed = false;
    for (final project in projects()) {
      final site = project.site;
      if (site == null) continue;
      if ((site.slug ?? '').trim() != want) continue;
      if (siteUp[project.path] == true) {
        siteUp[project.path] = false;
        changed = true;
      }
    }
    if (!changed || !isMounted()) return;
    onChanged();
    unawaited(syncKeepAlive(runningNames.toList()));
  }

  Future<void> refreshStatus() async {
    final generation = probeGuard.tryBegin();
    if (generation == null) return;
    try {
      final registered = [
        for (final project in projects())
          if (project.site != null) project.path,
      ];
      if (registered.isEmpty) {
        if (siteUp.isNotEmpty && isMounted() && probeGuard.canApply(generation)) {
          siteUp.clear();
          onChanged();
        }
        return;
      }
      await _supervisor.ensureReady();
      final snap = await _supervisor.snapshot();
      if (!isMounted() || !probeGuard.canApply(generation)) return;
      final next = <String, bool>{};
      for (final project in projects()) {
        if (project.site == null) continue;
        next[project.path] = snap[project.path]?.listening == true;
      }
      siteUp
        ..clear()
        ..addAll(next);
      onChanged();
      await syncKeepAlive(runningNames.toList());
    } catch (_) {
      // Keep the last known status.
    } finally {
      final again = probeGuard.finish(generation);
      if (again && isMounted()) {
        unawaited(refreshStatus());
      }
    }
  }

  Future<ProjectSiteStartResult> start(
    ProjectUrlEntry entry, {
    required String projectPath,
    bool openInBrowser = true,
    bool announce = true,
  }) async {
    invalidateProbe();
    status = '正在启动「${entry.name}」…';
    siteBusy.add(projectPath);
    onChanged();
    await beforeStart(entry);
    var launched = false;
    var result = const ProjectSiteStartResult(
      startedProcess: false,
      alreadyUp: false,
      openedUrl: false,
    );
    try {
      result = await _launcher.start(
        projectPath: projectPath,
        entry: entry,
        openInBrowser: openInBrowser,
        openUrl: publicUrl(entry),
      );
      if (!isMounted()) return result;
      launched = result.startedProcess || result.alreadyUp;
      if (launched) {
        invalidateProbe();
        siteUp[projectPath] = true;
        await syncKeepAlive(runningNames.toList());
      }
      if (announce) {
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
      }
    } catch (error) {
      result = ProjectSiteStartResult(
        startedProcess: false,
        alreadyUp: false,
        openedUrl: false,
        message: '启动失败：$error',
      );
      if (isMounted() && announce) {
        onMessage(AgentSiteMessage(result.message!, isError: true));
      }
    } finally {
      if (isMounted()) {
        status = null;
        siteBusy.remove(projectPath);
        onChanged();
        if (!launched) unawaited(refreshStatus());
      }
    }
    return result;
  }

  Future<ProjectSiteStopResult> stop(
    ProjectUrlEntry entry, {
    required String projectPath,
    bool announce = true,
  }) async {
    invalidateProbe();
    status = '正在终止「${entry.name}」…';
    siteBusy.add(projectPath);
    onChanged();
    var result = const ProjectSiteStopResult(stopped: false);
    try {
      result = await _launcher.stop(projectPath: projectPath, entry: entry);
      if (!isMounted()) return result;
      siteUp[projectPath] = !result.stopped;
      if (announce) {
        onMessage(
          AgentSiteMessage(
            result.message ?? (result.stopped ? '已终止' : '终止失败'),
            isError: !result.stopped,
          ),
        );
      }
    } catch (error) {
      result = ProjectSiteStopResult(stopped: false, message: '终止失败：$error');
      if (isMounted() && announce) {
        onMessage(AgentSiteMessage(result.message!, isError: true));
      }
    } finally {
      if (isMounted()) {
        status = null;
        siteBusy.remove(projectPath);
        onChanged();
        unawaited(refreshStatus());
        unawaited(syncKeepAlive(runningNames.toList()));
      }
    }
    return result;
  }

  Future<void> stopAll() async {
    for (final pair in runningPairs.toList()) {
      if (!isMounted()) return;
      await stop(pair.$2, projectPath: pair.$1);
    }
  }

  void dispose() {
    unawaited(_eventSub?.cancel());
    _eventSub = null;
    invalidateProbe();
    unawaited(_supervisor.dispose());
  }
}
