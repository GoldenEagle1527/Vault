import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_pty/flutter_pty.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:vault/sandbox/sandbox_provider.dart';
import 'package:vault/sandbox/wsl_output.dart';

/// 每个会话对应一个独立的 WSL2 发行版。
///
/// 发行版名：`vault_<sessionId>`。每次 import 会生成独立的 ext4.vhdx
///（实际占用常接近约 1 GB）。所有 WSL2 发行版共享同一 VM / 内核 / 网络。
class WslProvider implements SandboxProvider {
  static const distroPrefix = 'vault_';
  static const _metaFileName = 'sessions.json';

  Future<Directory> _rootDir() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory(p.join(base.path, 'wsl_distros'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<File> _metaFile() async {
    final root = await _rootDir();
    return File(p.join(root.path, _metaFileName));
  }

  Future<Map<String, dynamic>> _readMeta() async {
    final file = await _metaFile();
    if (!await file.exists()) {
      return {'sessions': <String, dynamic>{}};
    }
    final raw = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    raw.putIfAbsent('sessions', () => <String, dynamic>{});
    return raw;
  }

  Future<void> _writeMeta(Map<String, dynamic> meta) async {
    final file = await _metaFile();
    await file.writeAsString(const JsonEncoder.withIndent('  ').convert(meta));
  }

  String distroName(String sessionId) => '$distroPrefix$sessionId';

  String _hostArchAsset() {
    final arch = Platform.environment['PROCESSOR_ARCHITECTURE']?.toUpperCase();
    if (arch == 'ARM64') {
      return 'assets/rootfs/alpine-minirootfs-aarch64.tar.gz';
    }
    return 'assets/rootfs/alpine-minirootfs-x86_64.tar.gz';
  }

  Future<String> _materializeRootfsTar() async {
    final root = await _rootDir();
    final assetPath = _hostArchAsset();
    final out = File(
      p.join(root.path, '_cache', p.basename(assetPath)),
    );
    if (await out.exists() && await out.length() > 0) {
      return out.path;
    }
    await out.parent.create(recursive: true);
    final data = await rootBundle.load(assetPath);
    await out.writeAsBytes(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      flush: true,
    );
    return out.path;
  }

  /// 精简传给 wsl.exe 的环境，避免宿主超长 PATH 在 automount=false 时被翻译失败。
  static const _wslHostEnv = {
    'PATH': r'C:\Windows\System32;C:\Windows',
    'SystemRoot': r'C:\Windows',
    'WINDIR': r'C:\Windows',
  };

  Future<({int exitCode, String stdout, String stderr})> _wsl(
    List<String> args,
  ) async {
    final result = await Process.run(
      'wsl.exe',
      args,
      environment: _wslHostEnv,
      includeParentEnvironment: false,
      stdoutEncoding: null,
      stderrEncoding: null,
      runInShell: false,
    );
    return (
      exitCode: result.exitCode,
      stdout: decodeWslOutput(result.stdout as List<int>),
      stderr: decodeWslOutput(result.stderr as List<int>),
    );
  }

  Future<Set<String>> _registeredDistros() async {
    final result = await _wsl(['--list', '--quiet']);
    return result.stdout
        .split(RegExp(r'\r?\n'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toSet();
  }

  @override
  Future<SandboxCapabilities> probe() async {
    final arch =
        Platform.environment['PROCESSOR_ARCHITECTURE']?.toLowerCase() ??
            'unknown';
    final notes = <String>[
      '每个会话会导入独立的 WSL2 发行版；稀疏 ext4.vhdx 实际占用通常接近约 1 GB。',
      '所有 WSL2 发行版共享同一虚拟机、内核与网络命名空间——仅有文件系统与进程隔离。',
      '若终端出现 localhost 代理提示：系统代理在 NAT 模式下无法直接进 WSL，'
          '可在 %UserProfile%\\.wslconfig 设置 networkingMode=mirrored，或忽略该警告。',
    ];

    try {
      final status = await _wsl(['--status']);
      final list = await _wsl(['--list', '--quiet']);
      final installed = status.exitCode == 0 || list.exitCode == 0;
      if (!installed) {
        return SandboxCapabilities(
          available: false,
          backend: SandboxBackend.wsl,
          architecture: arch,
          hint: '未检测到 WSL2。请以管理员身份打开 PowerShell 并执行：wsl --install',
          notes: notes,
        );
      }
      return SandboxCapabilities(
        available: true,
        backend: SandboxBackend.wsl,
        architecture: arch,
        notes: notes,
      );
    } on ProcessException {
      return SandboxCapabilities(
        available: false,
        backend: SandboxBackend.wsl,
        architecture: arch,
        hint: '找不到 wsl.exe。请安装 WSL2：wsl --install',
        notes: notes,
      );
    }
  }

  @override
  Future<SandboxSession> create(String sessionId) async {
    if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(sessionId)) {
      throw ArgumentError.value(
        sessionId,
        'sessionId',
        '只能包含字母、数字、下划线或连字符',
      );
    }

    final name = distroName(sessionId);
    final existing = await _registeredDistros();
    if (existing.contains(name)) {
      throw StateError('发行版已存在：$name');
    }

    final root = await _rootDir();
    final installDir = Directory(p.join(root.path, sessionId));
    if (await installDir.exists()) {
      await installDir.delete(recursive: true);
    }
    await installDir.create(recursive: true);

    final tarPath = await _materializeRootfsTar();
    final import = await _wsl([
      '--import',
      name,
      installDir.path,
      tarPath,
      '--version',
      '2',
    ]);
    if (import.exitCode != 0) {
      throw StateError(
        'wsl --import 失败（${import.exitCode}）：'
        '${import.stderr}\n${import.stdout}',
      );
    }

    // 硬化：不自动挂载 Windows 盘；也不把 Windows PATH 拼进 Linux
    // （automount=false 时翻译 Windows PATH 会失败，交互启动常因此 RPC 报错）。
    await _configureDistro(name);
    await _wsl(['--terminate', name]);
    // terminate 后稍等，避免立刻 attach 撞到服务未就绪。
    await Future<void>.delayed(const Duration(milliseconds: 800));

    final meta = await _readMeta();
    final sessions = Map<String, dynamic>.from(meta['sessions'] as Map);
    sessions[sessionId] = {
      'distro': name,
      'path': installDir.path,
      'createdAt': DateTime.now().toIso8601String(),
    };
    meta['sessions'] = sessions;
    await _writeMeta(meta);

    return attach(sessionId);
  }

  Future<void> _configureDistro(String name) async {
    final conf = await _wsl([
      '-d',
      name,
      '-u',
      'root',
      '-e',
      '/bin/sh',
      '-c',
      r'''cat > /etc/wsl.conf <<'EOF'
[automount]
enabled=false
mountFsTab=false

[interop]
enabled=true
appendWindowsPath=false

[network]
generateResolvConf=true

[user]
default=root
EOF
''',
    ]);
    if (conf.exitCode != 0) {
      stderr.writeln('写入 wsl.conf 失败：${conf.stderr}');
    }
  }

  @override
  Future<SandboxSession> attach(String sessionId) async {
    final name = distroName(sessionId);
    final existing = await _registeredDistros();
    if (!existing.contains(name)) {
      throw StateError('会话 $sessionId 没有对应的 WSL 发行版（$name）');
    }
    await _ensureHardened(name);
    return WslSession(sessionId: sessionId, distroName: name);
  }

  /// 确保发行版已关闭 Windows PATH 注入；若刚写入配置则 terminate 使其生效。
  Future<void> _ensureHardened(String name) async {
    final check = await _wsl([
      '-d',
      name,
      '-u',
      'root',
      '-e',
      '/bin/sh',
      '-c',
      'grep -q "appendWindowsPath=false" /etc/wsl.conf 2>/dev/null',
    ]);
    if (check.exitCode == 0) return;

    await _configureDistro(name);
    await _wsl(['--terminate', name]);
    await Future<void>.delayed(const Duration(milliseconds: 800));
  }

  @override
  Future<void> destroy(String sessionId) async {
    final name = distroName(sessionId);
    final existing = await _registeredDistros();
    if (existing.contains(name)) {
      final result = await _wsl(['--unregister', name]);
      if (result.exitCode != 0) {
        throw StateError(
          'wsl --unregister 失败：${result.stderr}\n${result.stdout}',
        );
      }
    }

    final root = await _rootDir();
    final installDir = Directory(p.join(root.path, sessionId));
    if (await installDir.exists()) {
      await installDir.delete(recursive: true);
    }

    final meta = await _readMeta();
    final sessions = Map<String, dynamic>.from(meta['sessions'] as Map);
    sessions.remove(sessionId);
    meta['sessions'] = sessions;
    await _writeMeta(meta);
  }

  @override
  Future<List<SandboxInfo>> list() async {
    final meta = await _readMeta();
    final sessions = Map<String, dynamic>.from(meta['sessions'] as Map);
    final registered = await _registeredDistros();
    final out = <SandboxInfo>[];

    for (final entry in sessions.entries) {
      final id = entry.key;
      final data = Map<String, dynamic>.from(entry.value as Map);
      final distro = data['distro'] as String? ?? distroName(id);
      if (!registered.contains(distro)) {
        continue;
      }
      final path = data['path'] as String?;
      int? size;
      if (path != null) {
        final vhdx = File(p.join(path, 'ext4.vhdx'));
        if (await vhdx.exists()) {
          size = await vhdx.length();
        }
      }
      out.add(
        SandboxInfo(
          sessionId: id,
          displayName: distro,
          createdAt: DateTime.tryParse(data['createdAt'] as String? ?? '') ??
              DateTime.fromMillisecondsSinceEpoch(0),
          diskPath: path,
          approxDiskBytes: size,
        ),
      );
    }
    out.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return out;
  }
}

class WslSession implements SandboxSession {
  WslSession({
    required this.sessionId,
    required this.distroName,
    int rows = 32,
    int columns = 100,
  }) {
    // 显式启动 /bin/sh，并覆盖 PATH，避免把宿主超长 Windows PATH 传给 wsl.exe。
    _pty = Pty.start(
      'wsl.exe',
      arguments: [
        '-d',
        distroName,
        '-u',
        'root',
        '--cd',
        '/root',
        '-e',
        '/bin/sh',
        '-l',
      ],
      environment: WslProvider._wslHostEnv,
      rows: rows,
      columns: columns,
    );
  }

  @override
  final String sessionId;

  final String distroName;
  late final Pty _pty;

  @override
  Stream<Uint8List> get output => _pty.output;

  @override
  void write(String data) {
    writeBytes(Uint8List.fromList(utf8.encode(data)));
  }

  @override
  void writeBytes(Uint8List data) {
    _pty.write(data);
  }

  @override
  void resize(int cols, int rows) {
    _pty.resize(rows, cols);
  }

  @override
  Future<int> get exitCode => _pty.exitCode;

  @override
  Future<CommandResult> run(String cmd) async {
    final result = await Process.run(
      'wsl.exe',
      ['-d', distroName, '-u', 'root', '-e', '/bin/sh', '-c', cmd],
      stdoutEncoding: null,
      stderrEncoding: null,
    );
    return CommandResult(
      exitCode: result.exitCode,
      stdout: decodeWslOutput(result.stdout as List<int>),
      stderr: decodeWslOutput(result.stderr as List<int>),
    );
  }

  @override
  Future<void> dispose() async {
    _pty.kill();
  }
}
