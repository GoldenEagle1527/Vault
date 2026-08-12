import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_pty/flutter_pty.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:vault/offload/offload_host_server.dart';
import 'package:vault/offload/wsl_offload_install.dart';
import 'package:vault/sandbox/alpine_mirrors.dart';
import 'package:vault/sandbox/guest_fs_list.dart';
import 'package:vault/sandbox/persistent_shell.dart';
import 'package:vault/sandbox/sandbox_provider.dart';
import 'package:vault/sandbox/workspace_bootstrap.dart';
import 'package:vault/sandbox/wsl_output.dart';

/// 每个工作区对应一个独立的 WSL2 发行版。
///
/// 发行版名：`vault_<workspaceId>`。每次 import 会生成独立的 ext4.vhdx
///（实际占用常接近约 1 GB）。所有 WSL2 发行版共享同一 VM / 内核 / 网络。
class WslProvider implements SandboxProvider {
  static const distroPrefix = 'vault_';
  static const _metaFileName = 'workspaces.json';

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
      return {'workspaces': <String, dynamic>{}};
    }
    final raw = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    raw.putIfAbsent('workspaces', () => <String, dynamic>{});
    return raw;
  }

  Future<void> _writeMeta(Map<String, dynamic> meta) async {
    final file = await _metaFile();
    await file.writeAsString(const JsonEncoder.withIndent('  ').convert(meta));
  }

  String distroName(String workspaceId) => '$distroPrefix$workspaceId';

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
    final out = File(p.join(root.path, '_cache', p.basename(assetPath)));
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
      '每个工作区会导入独立的 WSL2 发行版；稀疏 ext4.vhdx 实际占用通常接近约 1 GB。',
      '所有 WSL2 发行版共享同一虚拟机、内核与网络命名空间——仅有文件系统与进程隔离。',
      '初始化时会将 apk / pip 源切换为国内镜像（apk: $kDefaultAlpineApkMirror；'
          'pip: $kDefaultPipIndexUrl），'
          '并安装 ${kDefaultAlpinePackages.join('、')}（python3 为 3.12.x）。',
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
  Future<SandboxWorkspace> create(
    String workspaceId, {
    WorkspaceInitProgressCallback? onProgress,
  }) async {
    if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(workspaceId)) {
      throw ArgumentError.value(
        workspaceId,
        'workspaceId',
        '只能包含字母、数字、下划线或连字符',
      );
    }

    const totalSteps = 6;
    void report(int step, String label) {
      onProgress?.call(
        WorkspaceInitProgress(
          step: step,
          totalSteps: totalSteps,
          label: label,
        ),
      );
    }

    final name = distroName(workspaceId);
    final existing = await _registeredDistros();
    if (existing.contains(name)) {
      throw StateError('发行版已存在：$name');
    }

    final root = await _rootDir();
    final installDir = Directory(p.join(root.path, workspaceId));
    if (await installDir.exists()) {
      await installDir.delete(recursive: true);
    }
    await installDir.create(recursive: true);

    report(1, '正在准备 rootfs 镜像…');
    final tarPath = await _materializeRootfsTar();
    report(2, '正在导入 WSL 发行版…');
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
    report(3, '正在配置发行版…');
    await _configureDistro(name);
    report(
      4,
      '正在安装 ${kDefaultAlpinePackages.join('、')}…',
    );
    await _installDefaultPackages(name);
    report(5, '正在初始化工作区…');
    await _installOffloadBridge(name);
    await bootstrapWorkspaceGuest(this, workspaceId);
    await _wsl(['--terminate', name]);
    // terminate 后稍等，避免立刻 attach 撞到服务未就绪。
    await Future<void>.delayed(const Duration(milliseconds: 800));

    final meta = await _readMeta();
    final workspaces = Map<String, dynamic>.from(meta['workspaces'] as Map);
    workspaces[workspaceId] = {
      'distro': name,
      'path': installDir.path,
      'createdAt': DateTime.now().toIso8601String(),
    };
    meta['workspaces'] = workspaces;
    await _writeMeta(meta);

    report(6, '正在启动工作区…');
    return attach(workspaceId);
  }

  /// Start host offload server (if needed) and write guest `vault-*` stubs.
  Future<void> _installOffloadBridge(String distroName) async {
    try {
      final port = await ensureOffloadHostServer();
      await installWslOffloadStubs(
        distroName: distroName,
        port: port,
        wslHostEnv: _wslHostEnv,
      );
    } catch (e, st) {
      // Non-fatal: workspace still usable without host offload.
      stderr.writeln('安装 offload bridge 失败：$e\n$st');
    }
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
    await _configureApkMirrors(name);
  }

  /// Switch apk to the Tsinghua mirror so `apk update` works without a proxy.
  Future<void> _configureApkMirrors(String name) async {
    final result = await _wsl([
      '-d',
      name,
      '-u',
      'root',
      '-e',
      '/bin/sh',
      '-c',
      alpineApkMirrorShellScript(),
    ]);
    if (result.exitCode != 0) {
      stderr.writeln('配置 apk 国内镜像失败：${result.stderr}');
    }
  }

  /// Install [kDefaultAlpinePackages] into a freshly imported distro.
  Future<void> _installDefaultPackages(String name) async {
    final result = await _wsl([
      '-d',
      name,
      '-u',
      'root',
      '-e',
      '/bin/sh',
      '-c',
      alpineApkInstallPackagesShellScript(),
    ]);
    if (result.exitCode != 0) {
      throw StateError(
        '安装默认软件包（${kDefaultAlpinePackages.join(', ')}）失败'
        '（${result.exitCode}）：${result.stderr}\n${result.stdout}',
      );
    }
  }

  @override
  Future<SandboxWorkspace> attach(String workspaceId) async {
    final name = distroName(workspaceId);
    final existing = await _registeredDistros();
    if (!existing.contains(name)) {
      throw StateError('工作区 $workspaceId 没有对应的 WSL 发行版（$name）');
    }
    await _ensureHardened(name);
    await _ensureApkMirrors(name);
    await _ensurePipMirror(name);
    // Refresh stubs + port each attach (host port may change across restarts).
    await _installOffloadBridge(name);
    // Older workspaces may lack project dirs / global git config.
    try {
      await bootstrapWorkspaceGuest(this, workspaceId);
    } catch (e, st) {
      stderr.writeln('工作区 bootstrap 失败（非致命）：$e\n$st');
    }
    return WslWorkspace(workspaceId: workspaceId, distroName: name);
  }

  @override
  Future<String> resolveGuestHostPath(
    String workspaceId,
    String guestAbsolutePath,
  ) async {
    return _wslUncFor(workspaceId, guestAbsolutePath);
  }

  @override
  Future<CommandResult> runGuestCommand(String workspaceId, String cmd) {
    return _runInDistro(workspaceId, cmd);
  }

  /// Idempotent: rewrite non-default apk hosts (CDN / Aliyun / …) to Tsinghua.
  Future<void> _ensureApkMirrors(String name) async {
    final host = Uri.parse(kDefaultAlpineApkMirror).host;
    final check = await _wsl([
      '-d',
      name,
      '-u',
      'root',
      '-e',
      '/bin/sh',
      '-c',
      'grep -Fq ${shellSingleQuote(host)} /etc/apk/repositories',
    ]);
    if (check.exitCode == 0) return;
    await _configureApkMirrors(name);
  }

  /// Idempotent: ensure guest `/etc/pip.conf` uses the China PyPI mirror.
  Future<void> _ensurePipMirror(String name) async {
    final check = await _wsl([
      '-d',
      name,
      '-u',
      'root',
      '-e',
      '/bin/sh',
      '-c',
      'grep -Fq ${shellSingleQuote(kDefaultPipTrustedHost)} /etc/pip.conf',
    ]);
    if (check.exitCode == 0) return;
    final result = await _wsl([
      '-d',
      name,
      '-u',
      'root',
      '-e',
      '/bin/sh',
      '-c',
      alpinePipMirrorShellScript(),
    ]);
    if (result.exitCode != 0) {
      stderr.writeln('配置 pip 国内镜像失败：${result.stderr}');
    }
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
  Future<void> stopRunningGuests() async {
    final names = <String>{};
    try {
      final registered = await _registeredDistros();
      names.addAll(registered.where((n) => n.startsWith(distroPrefix)));
    } catch (e, st) {
      stderr.writeln('列举 WSL 发行版失败：$e\n$st');
    }
    try {
      final meta = await _readMeta();
      final workspaces = Map<String, dynamic>.from(
        meta['workspaces'] as Map? ?? {},
      );
      for (final entry in workspaces.entries) {
        final data = Map<String, dynamic>.from(entry.value as Map);
        final distro = data['distro'] as String? ?? distroName(entry.key);
        if (distro.startsWith(distroPrefix)) names.add(distro);
      }
    } catch (e, st) {
      stderr.writeln('读取工作区元数据失败：$e\n$st');
    }

    // Per-distro terminate only — never `wsl --shutdown` (would kill
    // the user's other distros sharing the same WSL2 VM).
    for (final name in names) {
      try {
        await _wsl(['--terminate', name]);
      } catch (e, st) {
        stderr.writeln('wsl --terminate $name 失败：$e\n$st');
      }
    }
  }

  @override
  Future<void> destroy(String workspaceId) async {
    final name = distroName(workspaceId);
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
    final installDir = Directory(p.join(root.path, workspaceId));
    if (await installDir.exists()) {
      await installDir.delete(recursive: true);
    }

    final meta = await _readMeta();
    final workspaces = Map<String, dynamic>.from(meta['workspaces'] as Map);
    workspaces.remove(workspaceId);
    meta['workspaces'] = workspaces;
    await _writeMeta(meta);
  }

  String _wslUncFor(String workspaceId, String guestAbsolutePath) {
    final guest = assertGuestPathUnderHome(guestAbsolutePath);
    final relative = guest.startsWith('/') ? guest.substring(1) : guest;
    return '\\\\wsl\$\\${distroName(workspaceId)}\\'
        '${relative.replaceAll('/', '\\')}';
  }

  Future<bool> _distroRegistered(String workspaceId) async {
    final existing = await _registeredDistros();
    return existing.contains(distroName(workspaceId));
  }

  Future<CommandResult> _runInDistro(String workspaceId, String cmd) async {
    final result = await Process.run(
      'wsl.exe',
      [
        '-d',
        distroName(workspaceId),
        '-u',
        'root',
        '--cd',
        kGuestHome,
        '-e',
        '/bin/sh',
        '-c',
        cmd,
      ],
      environment: _wslHostEnv,
      includeParentEnvironment: false,
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
  Future<Uint8List?> readGuestFile(
    String workspaceId,
    String guestAbsolutePath,
  ) async {
    if (!await _distroRegistered(workspaceId)) return null;
    final guest = assertGuestPathUnderHome(guestAbsolutePath);
    try {
      final file = File(_wslUncFor(workspaceId, guest));
      if (await file.exists()) {
        return Uint8List.fromList(await file.readAsBytes());
      }
    } catch (_) {
      // Fall through to wsl base64.
    }
    final result = await _runInDistro(
      workspaceId,
      'if [ -f ${shellSingleQuote(guest)} ]; then base64 ${shellSingleQuote(guest)}; else exit 2; fi',
    );
    if (result.exitCode == 2 || result.exitCode != 0) return null;
    try {
      final b64 = result.stdout.replaceAll(RegExp(r'\s+'), '');
      if (b64.isEmpty) return null;
      return Uint8List.fromList(base64Decode(b64));
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> writeGuestFile(
    String workspaceId,
    String guestAbsolutePath,
    List<int> bytes,
  ) async {
    if (!await _distroRegistered(workspaceId)) {
      throw StateError('工作区 $workspaceId 的 WSL 发行版不存在');
    }
    final guest = assertGuestPathUnderHome(guestAbsolutePath);
    final parent = p.posix.dirname(guest);
    final mkdir = await _runInDistro(
      workspaceId,
      'mkdir -p ${shellSingleQuote(parent)}',
    );
    if (!mkdir.success) {
      throw StateError('无法在沙箱内创建目录 $parent：${mkdir.stderr}');
    }
    try {
      final file = File(_wslUncFor(workspaceId, guest));
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes, flush: true);
      return;
    } catch (_) {
      // Fall through.
    }
    final proc = await Process.start(
      'wsl.exe',
      [
        '-d',
        distroName(workspaceId),
        '-u',
        'root',
        '--cd',
        kGuestHome,
        '-e',
        '/bin/sh',
        '-c',
        'base64 -d > ${shellSingleQuote(guest)}',
      ],
      environment: _wslHostEnv,
      includeParentEnvironment: false,
    );
    proc.stdin.add(utf8.encode(base64Encode(bytes)));
    await proc.stdin.close();
    final exit = await proc.exitCode;
    if (exit != 0) {
      final err = await proc.stderr.transform(utf8.decoder).join();
      throw StateError('写入沙箱文件失败（exit $exit）：$err');
    }
  }

  @override
  Future<void> deleteGuestPath(
    String workspaceId,
    String guestAbsolutePath, {
    bool recursive = false,
  }) async {
    if (!await _distroRegistered(workspaceId)) return;
    final guest = assertGuestPathUnderHome(guestAbsolutePath);
    final flag = recursive ? '-rf' : '-f';
    await _runInDistro(workspaceId, 'rm $flag -- ${shellSingleQuote(guest)}');
  }

  @override
  Future<List<GuestFsEntry>> listGuestDirectory(
    String workspaceId,
    String guestAbsolutePath,
  ) async {
    if (!await _distroRegistered(workspaceId)) {
      throw StateError('工作区 $workspaceId 的 WSL 发行版不存在');
    }
    final guest = assertGuestPathUnderHome(guestAbsolutePath);
    try {
      final hostPath = _wslUncFor(workspaceId, guest);
      return await listGuestDirectoryOnHost(
        hostPath: hostPath,
        guestDir: guest,
      );
    } catch (_) {
      // Fall through to guest ls.
    }
    final result = await _runInDistro(
      workspaceId,
      'if [ -d ${shellSingleQuote(guest)} ]; then '
      'ls -1Ap -- ${shellSingleQuote(guest)}; '
      'else exit 2; fi',
    );
    if (result.exitCode == 2) {
      throw StateError('目录不存在：$guest');
    }
    if (!result.success) {
      throw StateError(
        '无法列出沙箱目录 $guest：${result.stderr}'.trim(),
      );
    }
    return parseLsMinusOneAp(result.stdout, guest);
  }

  @override
  Future<List<WorkspaceInfo>> list() async {
    final meta = await _readMeta();
    final workspaces = Map<String, dynamic>.from(meta['workspaces'] as Map);
    final registered = await _registeredDistros();
    final out = <WorkspaceInfo>[];

    for (final entry in workspaces.entries) {
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
        WorkspaceInfo(
          workspaceId: id,
          displayName: distro,
          createdAt:
              DateTime.tryParse(data['createdAt'] as String? ?? '') ??
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

class WslWorkspace implements SandboxWorkspace {
  WslWorkspace({
    required this.workspaceId,
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
  final String workspaceId;

  final String distroName;
  late final Pty _pty;
  PersistentShell? _agentShell;
  bool _disposed = false;

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

  Future<PersistentShell> _ensureAgentShell() async {
    final existing = _agentShell;
    if (existing != null && existing.running) return existing;
    if (existing != null) await existing.stop();
    final shell = PersistentShell(
      executable: 'wsl.exe',
      arguments: [
        '-d',
        distroName,
        '-u',
        'root',
        '--cd',
        kGuestHome,
        '-e',
        '/bin/sh',
      ],
      environment: WslProvider._wslHostEnv,
      includeParentEnvironment: false,
    );
    _agentShell = shell;
    return shell;
  }

  @override
  Future<CommandResult> run(
    String cmd, {
    Map<String, String>? environment,
    Duration? timeout,
  }) async {
    final shell = await _ensureAgentShell();
    return shell.run(
      cmd,
      environment: environment,
      timeout: timeout,
    );
  }

  @override
  Future<void> writeGuestFile(String guestAbsolutePath, List<int> bytes) async {
    final guestPath = assertGuestPathUnderHome(guestAbsolutePath);
    final parent = p.posix.dirname(guestPath);
    final mkdir = await run('mkdir -p ${shellSingleQuote(parent)}');
    if (!mkdir.success) {
      throw StateError('无法在沙箱内创建目录 $parent：${mkdir.stderr}');
    }

    // Prefer \\wsl$\ UNC (no size limit from argv); fall back to base64 pipe.
    final unc = _wslUncPath(guestPath);
    try {
      final file = File(unc);
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes, flush: true);
      return;
    } catch (_) {
      // Fall through.
    }

    final proc = await Process.start('wsl.exe', [
      '-d',
      distroName,
      '-u',
      'root',
      '--cd',
      kGuestHome,
      '-e',
      '/bin/sh',
      '-c',
      'base64 -d > ${shellSingleQuote(guestPath)}',
    ]);
    proc.stdin.add(utf8.encode(base64Encode(bytes)));
    await proc.stdin.close();
    final exit = await proc.exitCode;
    if (exit != 0) {
      final err = await proc.stderr.transform(utf8.decoder).join();
      throw StateError('写入沙箱文件失败（exit $exit）：$err');
    }
  }

  String _wslUncPath(String guestAbsolutePath) {
    final relative = guestAbsolutePath.startsWith('/')
        ? guestAbsolutePath.substring(1)
        : guestAbsolutePath;
    return '\\\\wsl\$\\$distroName\\${relative.replaceAll('/', '\\')}';
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _agentShell?.stop();
    _agentShell = null;
    _pty.kill();
  }
}

// shellSingleQuote lives in sandbox_models.dart (shared with proot / smoke).
