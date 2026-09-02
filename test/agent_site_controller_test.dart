import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vault/agent/agent_site_controller.dart';
import 'package:vault/agent/project_store.dart';
import 'package:vault/agent/site_supervisor.dart';
import 'package:vault/sandbox/sandbox_provider.dart';

class _FakeWorkspace implements SandboxWorkspace {
  @override
  String get workspaceId => 'workspace';

  @override
  Stream<Uint8List> get output => const Stream.empty();

  @override
  Future<int> get exitCode async => 0;

  @override
  void resize(int cols, int rows) {}

  @override
  Future<CommandResult> run(
    String cmd, {
    Map<String, String>? environment,
    Duration? timeout,
  }) async {
    return const CommandResult(exitCode: 0, stdout: '', stderr: '');
  }

  @override
  void write(String data) {}

  @override
  void writeBytes(Uint8List data) {}

  @override
  Future<void> writeGuestFile(
    String guestAbsolutePath,
    List<int> bytes,
  ) async {}

  @override
  Future<Uint8List?> readGuestFile(String guestAbsolutePath) async => null;

  @override
  Future<List<GuestFsEntry>> listGuestDirectory(
    String guestAbsolutePath,
  ) async => const [];

  @override
  Future<void> dispose() async {}
}

void main() {
  test('refresh clears stale status when no project has a site', () async {
    var changed = 0;
    final controller = AgentSiteController(
      workspace: _FakeWorkspace(),
      projects: () => const [],
      isMounted: () => true,
      onChanged: () => changed++,
      publicUrl: (entry) => entry.url,
      beforeStart: (_) async {},
      syncKeepAlive: (_) async {},
      onMessage: (_) {},
    );
    controller.siteUp['old-project'] = true;

    await controller.refreshStatus();

    expect(controller.siteUp, isEmpty);
    expect(changed, 1);
    expect(controller.probeGuard.inFlight, isFalse);
    controller.dispose();
  });

  test('supervisor events and 502 flip siteUp without polling', () async {
    final supervisor = MemorySiteSupervisorClient();
    addTearDown(supervisor.dispose);
    final names = <List<String>>[];
    final controller = AgentSiteController(
      workspace: _FakeWorkspace(),
      projects: () => [
        ProjectInfo(
          path: 'p1',
          name: '项目',
          createdAt: DateTime.utc(2026),
          updatedAt: DateTime.utc(2026),
          urls: const [
            ProjectUrlEntry(
              name: '网站',
              url: 'http://127.0.0.1:8765/',
              slug: 'demo',
            ),
          ],
        ),
      ],
      isMounted: () => true,
      onChanged: () {},
      publicUrl: (entry) => entry.url,
      beforeStart: (_) async {},
      syncKeepAlive: (n) async => names.add(List<String>.from(n)),
      onMessage: (_) {},
      supervisor: supervisor,
    );
    addTearDown(controller.dispose);

    supervisor.emit(const SiteSupervisorEvent(id: 'p1', state: 'listening'));
    await Future<void>.delayed(Duration.zero);
    expect(controller.siteUp['p1'], isTrue);
    expect(names.last, ['网站']);

    controller.noteUnreachable('demo');
    expect(controller.siteUp['p1'], isFalse);

    supervisor.emit(const SiteSupervisorEvent(id: 'p1', state: 'listening'));
    await Future<void>.delayed(Duration.zero);
    supervisor.emit(const SiteSupervisorEvent(id: 'p1', state: 'port_lost'));
    await Future<void>.delayed(Duration.zero);
    expect(controller.siteUp['p1'], isFalse);
  });

  test('start returns failure message when supervisor throws', () async {
    final supervisor = MemorySiteSupervisorClient()
      ..throwOnStart = StateError('无法启动站点看守');
    addTearDown(supervisor.dispose);
    final controller = AgentSiteController(
      workspace: _FakeWorkspace(),
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

    final result = await controller.start(
      const ProjectUrlEntry(
        name: '网站',
        url: 'http://127.0.0.1:8765/',
        startCommand: 'python3 app.py',
      ),
      projectPath: 'p1',
      openInBrowser: false,
      announce: false,
    );
    expect(result.startedProcess, isFalse);
    expect(result.message, contains('无法启动站点看守'));
  });

  test('probe guard reruns when a refresh is requested mid-flight', () {
    final guard = SiteProbeGenerationGuard();
    final first = guard.tryBegin();
    expect(first, isNotNull);
    expect(guard.tryBegin(), isNull);
    expect(guard.finish(first!), isTrue);
    expect(guard.inFlight, isFalse);
  });
}
