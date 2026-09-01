import 'dart:async';
import 'dart:convert';

import 'package:vault/agent/site_supervisor_script.dart';
import 'package:vault/sandbox/proot_workspace.dart';
import 'package:vault/sandbox/sandbox_models.dart';
import 'package:vault/sandbox/wsl_workspace.dart';

export 'package:vault/agent/site_supervisor_script.dart';

/// One line from the supervisor event log.
class SiteSupervisorEvent {
  const SiteSupervisorEvent({
    required this.id,
    required this.state,
    this.pid,
    this.reason,
  });

  final String id;
  final String state;
  final int? pid;
  final String? reason;

  bool get listening => state == 'listening';
  bool get down =>
      state == 'exited' || state == 'port_lost' || state == 'start_failed';

  static SiteSupervisorEvent? tryParse(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) return null;
    try {
      final json = jsonDecode(trimmed);
      if (json is! Map) return null;
      final id = (json['id'] as String?)?.trim() ?? '';
      final state = (json['state'] as String?)?.trim() ?? '';
      if (id.isEmpty || state.isEmpty) return null;
      return SiteSupervisorEvent(
        id: id,
        state: state,
        pid: json['pid'] is int ? json['pid'] as int : int.tryParse('${json['pid']}'),
        reason: json['reason'] as String?,
      );
    } catch (_) {
      return null;
    }
  }
}

class SiteSupervisorReply {
  const SiteSupervisorReply({
    required this.ok,
    this.state,
    this.id,
    this.pid,
    this.already = false,
    this.known = true,
    this.listening = false,
    this.processAlive = false,
    this.error,
    this.sites = const {},
  });

  final bool ok;
  final String? state;
  final String? id;
  final int? pid;
  final bool already;
  final bool known;
  final bool listening;
  final bool processAlive;
  final String? error;
  final Map<String, SiteSupervisorReply> sites;

  factory SiteSupervisorReply.fromJson(Map<String, dynamic> json) {
    final rawSites = json['sites'];
    final sites = <String, SiteSupervisorReply>{};
    if (rawSites is Map) {
      rawSites.forEach((key, value) {
        if (value is Map) {
          sites['$key'] = SiteSupervisorReply.fromJson(
            Map<String, dynamic>.from(value),
          );
        }
      });
    }
    return SiteSupervisorReply(
      ok: json['ok'] != false,
      state: json['state'] as String?,
      id: json['id'] as String?,
      pid: json['pid'] is int ? json['pid'] as int : int.tryParse('${json['pid']}'),
      already: json['already'] == true,
      known: json['known'] != false,
      listening: json['listening'] == true || json['state'] == 'listening',
      processAlive: json['processAlive'] == true,
      error: json['error'] as String?,
      sites: sites,
    );
  }

  static SiteSupervisorReply parseStdout(String stdout) {
    final line = stdout
        .trim()
        .split('\n')
        .reversed
        .map((l) => l.trim())
        .firstWhere((l) => l.startsWith('{'), orElse: () => '');
    if (line.isEmpty) {
      return const SiteSupervisorReply(ok: false, error: '看守没有返回 JSON');
    }
    try {
      final decoded = jsonDecode(line);
      if (decoded is! Map) {
        return const SiteSupervisorReply(ok: false, error: '看守返回格式错误');
      }
      return SiteSupervisorReply.fromJson(Map<String, dynamic>.from(decoded));
    } catch (e) {
      return SiteSupervisorReply(ok: false, error: '看守返回无法解析：$e');
    }
  }
}

abstract class SiteSupervisorClient {
  Stream<SiteSupervisorEvent> get events;

  Future<void> ensureReady();

  Future<SiteSupervisorReply> startSite({
    required String id,
    required String cwd,
    required String cmd,
    int? port,
    String? log,
    String? pidFile,
    Duration? timeout,
  });

  Future<SiteSupervisorReply> stopSite(String id);

  Future<SiteSupervisorReply> status(String id);

  Future<Map<String, SiteSupervisorReply>> snapshot();

  Future<void> shutdown();

  Future<void> dispose();
}

/// In-memory supervisor for tests (same protocol, no guest).
class MemorySiteSupervisorClient implements SiteSupervisorClient {
  MemorySiteSupervisorClient();

  final Map<String, SiteSupervisorReply> _sites = {};
  final StreamController<SiteSupervisorEvent> _events =
      StreamController<SiteSupervisorEvent>.broadcast();

  bool occupied = false;
  bool startFails = false;
  String startFailError = '启动超时：端口尚未监听';
  Object? throwOnStart;

  @override
  Stream<SiteSupervisorEvent> get events => _events.stream;

  void emit(SiteSupervisorEvent event) {
    if (event.down) {
      _sites[event.id] = SiteSupervisorReply(
        ok: true,
        id: event.id,
        state: event.state,
        listening: false,
        processAlive: false,
        known: true,
      );
    } else if (event.listening) {
      _sites[event.id] = SiteSupervisorReply(
        ok: true,
        id: event.id,
        state: 'listening',
        listening: true,
        processAlive: true,
        known: true,
      );
    }
    _events.add(event);
  }

  @override
  Future<void> ensureReady() async {}

  @override
  Future<SiteSupervisorReply> startSite({
    required String id,
    required String cwd,
    required String cmd,
    int? port,
    String? log,
    String? pidFile,
    Duration? timeout,
  }) async {
    final thrown = throwOnStart;
    if (thrown != null) throw thrown;
    final existing = _sites[id];
    if (existing?.listening == true) {
      return SiteSupervisorReply(
        ok: true,
        id: id,
        state: 'listening',
        already: true,
        listening: true,
        processAlive: true,
      );
    }
    if (occupied) {
      return const SiteSupervisorReply(
        ok: false,
        state: 'occupied',
        error: '端口已被其他进程占用，无法启动',
      );
    }
    if (startFails) {
      return SiteSupervisorReply(
        ok: false,
        state: 'start_failed',
        id: id,
        error: startFailError,
      );
    }
    final reply = SiteSupervisorReply(
      ok: true,
      id: id,
      state: 'listening',
      already: false,
      listening: true,
      processAlive: true,
    );
    _sites[id] = reply;
    emit(SiteSupervisorEvent(id: id, state: 'listening'));
    return reply;
  }

  @override
  Future<SiteSupervisorReply> stopSite(String id) async {
    _sites[id] = SiteSupervisorReply(
      ok: true,
      id: id,
      state: 'exited',
      listening: false,
      processAlive: false,
    );
    emit(SiteSupervisorEvent(id: id, state: 'exited'));
    return SiteSupervisorReply(ok: true, id: id, state: 'exited');
  }

  @override
  Future<SiteSupervisorReply> status(String id) async {
    return _sites[id] ??
        SiteSupervisorReply(
          ok: true,
          id: id,
          known: false,
          state: 'unknown',
          listening: false,
          processAlive: false,
        );
  }

  @override
  Future<Map<String, SiteSupervisorReply>> snapshot() async =>
      Map<String, SiteSupervisorReply>.from(_sites);

  @override
  Future<void> shutdown() async {
    _sites.clear();
  }

  @override
  Future<void> dispose() async {
    if (!_events.isClosed) {
      await _events.close();
    }
  }
}

/// Guest daemon + short RPC + dedicated `tail -F` follow.
class GuestSiteSupervisorClient implements SiteSupervisorClient {
  GuestSiteSupervisorClient(
    this.workspace, {
    this.rpcTimeout = const Duration(seconds: 25),
    Future<GuestStreamSession?> Function(String cmd)? spawnDetached,
  }) : _spawnDetached = spawnDetached ?? _spawnOnWorkspace(workspace);

  final SandboxWorkspace workspace;
  final Duration rpcTimeout;
  final Future<GuestStreamSession?> Function(String cmd) _spawnDetached;

  final StreamController<SiteSupervisorEvent> _events =
      StreamController<SiteSupervisorEvent>.broadcast();
  GuestStreamSession? _follow;
  StreamSubscription<String>? _followSub;
  bool _installed = false;

  @override
  Stream<SiteSupervisorEvent> get events => _events.stream;

  static Future<GuestStreamSession?> Function(String cmd) _spawnOnWorkspace(
    SandboxWorkspace workspace,
  ) {
    return (cmd) async {
      if (workspace is WslWorkspace) {
        return workspace.spawnDetached(cmd);
      }
      if (workspace is ProotWorkspace) {
        return workspace.spawnDetached(cmd);
      }
      return null;
    };
  }

  @override
  Future<void> ensureReady() async {
    await _install();
    final result = await workspace.run(
      siteSupervisorEnsureCommand(),
      timeout: const Duration(seconds: 12),
    );
    if (result.exitCode != 0 || !result.stdout.contains('ready')) {
      throw StateError(
        '无法启动站点看守：${result.stderr}\n${result.stdout}',
      );
    }
    await _ensureFollow();
  }

  Future<void> _install() async {
    if (_installed) return;
    await workspace.writeGuestFile(
      kSiteSupervisorPyGuestPath,
      utf8.encode(kSiteSupervisorPySource),
    );
    _installed = true;
  }

  Future<void> _ensureFollow() async {
    if (_follow != null) return;
    final session = await _spawnDetached(siteSupervisorFollowCommand());
    if (session == null) return;
    _follow = session;
    _followSub = session.lines.listen((line) {
      final event = SiteSupervisorEvent.tryParse(line);
      if (event != null && !_events.isClosed) {
        _events.add(event);
      }
    }, onDone: () {
      _follow = null;
      _followSub = null;
    });
  }

  Future<SiteSupervisorReply> _rpc(Map<String, Object?> cmd) async {
    await ensureReady();
    final result = await workspace.run(
      siteSupervisorRpcCommand(cmd),
      timeout: rpcTimeout,
    );
    if (result.exitCode != 0 && result.stdout.trim().isEmpty) {
      return SiteSupervisorReply(
        ok: false,
        error: '看守 RPC 失败：${result.stderr}\n${result.stdout}',
      );
    }
    return SiteSupervisorReply.parseStdout(result.stdout);
  }

  @override
  Future<SiteSupervisorReply> startSite({
    required String id,
    required String cwd,
    required String cmd,
    int? port,
    String? log,
    String? pidFile,
    Duration? timeout,
  }) {
    return _rpc({
      'op': 'start',
      'id': id,
      'cwd': cwd,
      'cmd': cmd,
      if (port != null) 'port': port,
      if (log != null) 'log': log,
      if (pidFile != null) 'pid_file': pidFile,
      if (timeout != null) 'timeout': timeout.inMilliseconds / 1000.0,
    });
  }

  @override
  Future<SiteSupervisorReply> stopSite(String id) =>
      _rpc({'op': 'stop', 'id': id});

  @override
  Future<SiteSupervisorReply> status(String id) =>
      _rpc({'op': 'status', 'id': id});

  @override
  Future<Map<String, SiteSupervisorReply>> snapshot() async {
    try {
      final bytes = await workspace.readGuestFile(kSiteSupervisorStateGuestPath);
      if (bytes != null && bytes.isNotEmpty) {
        final decoded = jsonDecode(utf8.decode(bytes, allowMalformed: true));
        if (decoded is Map && decoded['sites'] is Map) {
          final sites = <String, SiteSupervisorReply>{};
          (decoded['sites'] as Map).forEach((key, value) {
            if (value is Map) {
              sites['$key'] = SiteSupervisorReply.fromJson(
                Map<String, dynamic>.from(value),
              );
            }
          });
          return sites;
        }
      }
    } catch (_) {}
    final reply = await _rpc({'op': 'status'});
    return reply.sites;
  }

  @override
  Future<void> shutdown() async {
    try {
      await _rpc({'op': 'shutdown'});
    } catch (_) {}
  }

  @override
  Future<void> dispose() async {
    await _followSub?.cancel();
    _followSub = null;
    try {
      await _follow?.kill();
    } catch (_) {}
    _follow = null;
    if (!_events.isClosed) {
      await _events.close();
    }
  }
}

String siteSupervisorEnsureCommand() {
  return '''
mkdir -p ${shellSingleQuote(kGuestVaultDir)}
touch ${shellSingleQuote(kSiteSupervisorEventsGuestPath)}
pidfile=${shellSingleQuote(kSiteSupervisorPidGuestPath)}
sock=${shellSingleQuote(kSiteSupervisorSockGuestPath)}
if [ -f "\$pidfile" ]; then
  pid=\$(cat "\$pidfile" 2>/dev/null || true)
  if [ -n "\$pid" ] && [ -d "/proc/\$pid" ] && [ -S "\$sock" ]; then
    echo ready
    exit 0
  fi
fi
rm -f "\$sock"
nohup python3 ${shellSingleQuote(kSiteSupervisorPyGuestPath)} serve \\
  >>${shellSingleQuote(kSiteSupervisorLogGuestPath)} 2>&1 &
echo \$! > "\$pidfile"
i=0
while [ "\$i" -lt 50 ]; do
  if [ -S "\$sock" ]; then
    echo ready
    exit 0
  fi
  sleep 0.1
  i=\$((i+1))
done
echo not_ready
exit 1
''';
}

String siteSupervisorRpcCommand(Map<String, Object?> cmd) {
  return 'python3 ${shellSingleQuote(kSiteSupervisorPyGuestPath)} rpc ${shellSingleQuote(jsonEncode(cmd))}';
}

String siteSupervisorFollowCommand() {
  return 'tail -n0 -F ${shellSingleQuote(kSiteSupervisorEventsGuestPath)}';
}

/// Join site names for tray / notification copy (`A` or `A、B`).
String formatRunningSiteNames(Iterable<String> names) {
  return names
      .map((n) => n.trim())
      .where((n) => n.isNotEmpty)
      .join('、');
}
