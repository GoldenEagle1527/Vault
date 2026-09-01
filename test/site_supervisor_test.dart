import 'package:flutter_test/flutter_test.dart';
import 'package:vault/agent/site_supervisor.dart';
import 'package:vault/sandbox/sandbox_models.dart';

void main() {
  test('parses supervisor event lines', () {
    final listening = SiteSupervisorEvent.tryParse(
      '{"v":1,"id":"p1","state":"listening","pid":42}',
    );
    expect(listening, isNotNull);
    expect(listening!.id, 'p1');
    expect(listening.listening, isTrue);
    expect(listening.pid, 42);

    final lost = SiteSupervisorEvent.tryParse(
      '{"id":"p1","state":"port_lost","reason":"inode"}',
    );
    expect(lost!.down, isTrue);
    expect(lost.reason, 'inode');
    expect(SiteSupervisorEvent.tryParse('not-json'), isNull);
    expect(SiteSupervisorEvent.tryParse('{}'), isNull);
  });

  test('parses rpc stdout even with chatter before JSON', () {
    final reply = SiteSupervisorReply.parseStdout(
      'ready\n{"ok":true,"state":"listening","already":false,"listening":true}\n',
    );
    expect(reply.ok, isTrue);
    expect(reply.listening, isTrue);
    expect(reply.state, 'listening');
  });

  test('memory supervisor start/stop/status and push events', () async {
    final client = MemorySiteSupervisorClient();
    addTearDown(client.dispose);
    final events = <String>[];
    final sub = client.events.listen((e) => events.add(e.state));
    addTearDown(sub.cancel);

    final started = await client.startSite(
      id: 'p1',
      cwd: '/root/projects/p1',
      cmd: 'python3 app.py',
      port: 8765,
    );
    expect(started.listening, isTrue);
    expect(started.already, isFalse);
    expect((await client.status('p1')).listening, isTrue);

    client.emit(const SiteSupervisorEvent(id: 'p1', state: 'port_lost'));
    expect((await client.status('p1')).listening, isFalse);

    final stopped = await client.stopSite('p1');
    expect(stopped.state, 'exited');
    expect(events, containsAll(['listening', 'port_lost', 'exited']));
  });

  test('memory supervisor reports occupied and start_failed', () async {
    final occupied = MemorySiteSupervisorClient()..occupied = true;
    final fail = await occupied.startSite(
      id: 'p1',
      cwd: '/x',
      cmd: 'python3 app.py',
    );
    expect(fail.ok, isFalse);
    expect(fail.state, 'occupied');

    final broken = MemorySiteSupervisorClient()..startFails = true;
    final timeout = await broken.startSite(
      id: 'p1',
      cwd: '/x',
      cmd: 'python3 app.py',
    );
    expect(timeout.state, 'start_failed');
    expect(timeout.error, contains('超时'));
  });

  test('formatRunningSiteNames joins every running site', () {
    expect(formatRunningSiteNames(const []), '');
    expect(formatRunningSiteNames(const ['网站']), '网站');
    expect(formatRunningSiteNames(const ['甲', ' 乙 ']), '甲、乙');
  });

  test('supervisor script path is writable via writeGuestFile', () {
    expect(
      assertGuestPathUnderHome(kSiteSupervisorPyGuestPath),
      kSiteSupervisorPyGuestPath,
    );
    expect(kSiteSupervisorPyGuestPath, startsWith('$kGuestVaultDir/'));
  });

  test('rpc and follow commands target the guest supervisor paths', () {
    final rpc = siteSupervisorRpcCommand({'op': 'status', 'id': 'p1'});
    expect(rpc, contains('site_supervisor.py'));
    expect(rpc, contains('rpc'));
    expect(rpc, contains('status'));
    expect(siteSupervisorFollowCommand(), contains('site-supervisor.events.jsonl'));
    expect(siteSupervisorEnsureCommand(), contains('python3'));
    expect(kSiteSupervisorPySource, contains('def port_owned_by'));
    expect(kSiteSupervisorPySource, contains('socket:['));
    expect(kSiteSupervisorPySource, contains('op == "start"'));
  });
}
