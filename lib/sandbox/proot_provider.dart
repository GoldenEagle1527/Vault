import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_pty/flutter_pty.dart';
import 'package:path/path.dart' as p;
import 'package:vault/sandbox/alpine_mirrors.dart';
import 'package:vault/sandbox/proot_host.dart';
import 'package:vault/sandbox/rootfs_extract.dart';
import 'package:vault/sandbox/sandbox_provider.dart';

/// 每个工作区一份独立 Alpine rootfs（proot-distro 系，16KB 友好）。
///
/// proot / loader 必须来自 [nativeLibraryDir]（jniLibs），不能放在 files/。
class ProotProvider implements SandboxProvider {
  static const _metaFileName = 'workspaces.json';
  static const rootfsAsset =
      'assets/rootfs/android/alpine-prootdistro-aarch64.tar.gz';

  /// Live interactive workspaces (for FGS refcount).
  static final _live = <String, ProotWorkspace>{};

  Future<Directory> _workspacesRoot() async {
    final files = await ProotHost.getFilesDir();
    final dir = Directory(p.join(files, 'workspaces'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<File> _metaFile() async {
    final root = await _workspacesRoot();
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

  Future<Directory> _workspaceDir(String workspaceId) async {
    final root = await _workspacesRoot();
    return Directory(p.join(root.path, workspaceId));
  }

  Future<Directory> _rootfsDir(String workspaceId) async {
    final workspace = await _workspaceDir(workspaceId);
    return Directory(p.join(workspace.path, 'rootfs'));
  }

  Future<({String proot, String loader})> _nativeBins() async {
    final native = await ProotHost.getNativeLibraryDir();
    final proot = p.join(native, 'libproot.so');
    final loader = p.join(native, 'libproot-loader.so');
    return (proot: proot, loader: loader);
  }

  Future<void> _refreshForegroundService() async {
    if (_live.isEmpty) {
      await ProotHost.stopForegroundService();
    } else {
      await ProotHost.startForegroundService();
    }
  }

  @override
  Future<SandboxCapabilities> probe() async {
    final notes = <String>[
      'Android 侧载分发（不上 Play）；GPLv3。',
      '每个工作区独立 rootfs；无真 PID/网络 namespace；proot 有约 20–30% 性能开销。',
      '长任务请允许通知与关闭电池优化，避免灭屏后被杀。',
      'rootfs 使用 proot-distro Alpine（16KB 页友好），与 Windows 上游包分离。',
      '初始化时会将 apk 源切换为国内镜像（$kDefaultAlpineApkMirror），无代理也可 apk update。',
    ];

    try {
      final abi = await ProotHost.getAbi();
      final pageSize = await ProotHost.getPageSize();
      final bins = await _nativeBins();
      final prootOk = await File(bins.proot).exists();
      final loaderOk = await File(bins.loader).exists();

      var assetOk = false;
      try {
        await rootBundle.load(rootfsAsset);
        assetOk = true;
      } catch (_) {
        assetOk = false;
      }

      final arm64 = abi.contains('arm64');
      final ready = arm64 && prootOk && loaderOk && assetOk;

      String? hint;
      if (!arm64) {
        hint = '当前 ABI 为 $abi；MVP 仅支持 arm64-v8a。';
      } else if (!prootOk || !loaderOk) {
        hint =
            '找不到 libproot.so / libproot-loader.so（nativeLibraryDir）。'
            '请确认 APK 含 jniLibs 且 extractNativeLibs=true。';
      } else if (!assetOk) {
        hint = '缺少 Android rootfs 资源：$rootfsAsset';
      }

      return SandboxCapabilities(
        available: ready,
        backend: SandboxBackend.proot,
        architecture: abi,
        pageSizeBytes: pageSize,
        hint: hint,
        notes: [
          ...notes,
          '页大小：$pageSize B；proot=${prootOk ? "就绪" : "缺失"}；'
              'loader=${loaderOk ? "就绪" : "缺失"}；rootfs 资源=${assetOk ? "就绪" : "缺失"}。',
        ],
      );
    } on MissingPluginException {
      return SandboxCapabilities(
        available: false,
        backend: SandboxBackend.proot,
        architecture: 'aarch64',
        hint: 'Proot MethodChannel 未注册（仅 Android 可用）。',
        notes: notes,
      );
    } on PlatformException catch (e) {
      return SandboxCapabilities(
        available: false,
        backend: SandboxBackend.proot,
        architecture: 'aarch64',
        hint: '探测失败：${e.message}',
        notes: notes,
      );
    }
  }

  Future<void> _extractRootfs(Directory dest) async {
    final cacheDir = Directory(p.join((await _workspacesRoot()).path, '_cache'));
    if (!await cacheDir.exists()) {
      await cacheDir.create(recursive: true);
    }
    final tarFile = File(p.join(cacheDir.path, p.basename(rootfsAsset)));
    if (!await tarFile.exists() || await tarFile.length() == 0) {
      final data = await rootBundle.load(rootfsAsset);
      await tarFile.writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        flush: true,
      );
    }

    // Custom extract: package:archive skips absolute guest symlinks like
    // /bin/sh → /bin/busybox; we rewrite them to relative links.
    await extractGuestRootfs(tarFile.path, dest.path);

    // Ensure writable temp + resolv for apk (AliDNS / DNSPod — usable in CN).
    await Directory(p.join(dest.path, 'tmp')).create(recursive: true);
    final resolv = File(p.join(dest.path, 'etc', 'resolv.conf'));
    if (!await resolv.exists()) {
      await resolv.parent.create(recursive: true);
      await resolv.writeAsString('nameserver 223.5.5.5\nnameserver 119.29.29.29\n');
    }

    // Official Alpine CDN is unreachable without a proxy in many CN networks.
    await applyAlpineApkMirrorOnHost(dest.path);

    if (!guestHasBinSh(dest.path)) {
      throw StateError(
        'rootfs 解压后仍缺少 /bin/sh（及 busybox）。请删除工作区后重试，'
        '或检查 $rootfsAsset 是否完整。',
      );
    }
  }

  List<String> _prootArgs(String rootfs, {List<String> command = const []}) {
    final args = <String>[
      '--link2symlink',
      '--kill-on-exit',
      '--change-id=0:0',
      '--rootfs=$rootfs',
      '--cwd=/root',
      '--bind=/dev',
      '--bind=/proc',
      '--bind=/sys',
      '--bind=$rootfs/tmp:/dev/shm',
    ];
    if (command.isEmpty) {
      args.addAll(['/bin/sh', '-l']);
    } else {
      args.addAll(command);
    }
    return args;
  }

  Map<String, String> _prootEnv(String loader, String rootfs) {
    final tmp = p.join(rootfs, 'tmp');
    return {
      'PROOT_LOADER': loader,
      'PROOT_NO_SECCOMP': '1',
      'PROOT_TMP_DIR': tmp,
      'TMPDIR': tmp,
      'PROOT_L2S_DIR': p.join(rootfs, '.l2s'),
      'PATH': '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin',
      'HOME': '/root',
      'USER': 'root',
      'TERM': 'xterm-256color',
      'LANG': 'C.UTF-8',
    };
  }

  @override
  Future<SandboxWorkspace> create(String workspaceId) async {
    if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(workspaceId)) {
      throw ArgumentError.value(
        workspaceId,
        'workspaceId',
        '只能包含字母、数字、下划线或连字符',
      );
    }

    final caps = await probe();
    if (!caps.available) {
      throw StateError(caps.hint ?? 'Android proot 不可用');
    }

    final rootfs = await _rootfsDir(workspaceId);
    await _extractRootfs(rootfs);

    final meta = await _readMeta();
    final workspaces = Map<String, dynamic>.from(meta['workspaces'] as Map);
    workspaces[workspaceId] = {
      'rootfs': rootfs.path,
      'createdAt': DateTime.now().toIso8601String(),
    };
    meta['workspaces'] = workspaces;
    await _writeMeta(meta);

    return attach(workspaceId);
  }

  @override
  Future<SandboxWorkspace> attach(String workspaceId) async {
    final rootfs = await _rootfsDir(workspaceId);
    if (!guestHasBinSh(rootfs.path)) {
      throw StateError(
        '工作区 $workspaceId 的 rootfs 不完整：缺少 /bin/sh。'
        '请删除该工作区后重新创建（需使用会保留 busybox 符号链接的解压逻辑）。',
      );
    }

    // Older workspaces may still point at dl-cdn; rewrite on attach.
    await applyAlpineApkMirrorOnHost(rootfs.path);

    final bins = await _nativeBins();
    final workspace = ProotWorkspace(
      workspaceId: workspaceId,
      prootPath: bins.proot,
      loaderPath: bins.loader,
      rootfsPath: rootfs.path,
      prootArgs: _prootArgs(rootfs.path),
      environment: _prootEnv(bins.loader, rootfs.path),
      onDisposed: () async {
        _live.remove(workspaceId);
        await _refreshForegroundService();
      },
    );
    _live[workspaceId] = workspace;
    await _refreshForegroundService();
    return workspace;
  }

  @override
  Future<void> destroy(String workspaceId) async {
    final live = _live.remove(workspaceId);
    await live?.dispose();
    await _refreshForegroundService();

    final workspaceDir = await _workspaceDir(workspaceId);
    if (await workspaceDir.exists()) {
      await workspaceDir.delete(recursive: true);
    }

    final meta = await _readMeta();
    final workspaces = Map<String, dynamic>.from(meta['workspaces'] as Map);
    workspaces.remove(workspaceId);
    meta['workspaces'] = workspaces;
    await _writeMeta(meta);
  }

  @override
  Future<List<WorkspaceInfo>> list() async {
    final meta = await _readMeta();
    final workspaces = Map<String, dynamic>.from(meta['workspaces'] as Map);
    final out = <WorkspaceInfo>[];

    for (final entry in workspaces.entries) {
      final id = entry.key;
      final data = Map<String, dynamic>.from(entry.value as Map);
      final rootfsPath = data['rootfs'] as String? ?? (await _rootfsDir(id)).path;
      final rootfs = Directory(rootfsPath);
      if (!await rootfs.exists()) continue;

      int? size;
      try {
        size = await _approxDirBytes(rootfs);
      } catch (_) {}

      out.add(
        WorkspaceInfo(
          workspaceId: id,
          displayName: 'proot_$id',
          createdAt: DateTime.tryParse(data['createdAt'] as String? ?? '') ??
              DateTime.fromMillisecondsSinceEpoch(0),
          diskPath: rootfsPath,
          approxDiskBytes: size,
        ),
      );
    }
    out.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return out;
  }

  Future<int> _approxDirBytes(Directory dir) async {
    var total = 0;
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is File) {
        total += await entity.length();
      }
    }
    return total;
  }

  /// Non-interactive one-shot for spike / agent (does not open PTY).
  Future<CommandResult> runOnce(String workspaceId, String cmd) async {
    final rootfs = await _rootfsDir(workspaceId);
    final bins = await _nativeBins();
    final args = _prootArgs(
      rootfs.path,
      command: ['/bin/sh', '-c', cmd],
    );
    final result = await Process.run(
      bins.proot,
      args,
      environment: _prootEnv(bins.loader, rootfs.path),
      workingDirectory: rootfs.path,
    );
    return CommandResult(
      exitCode: result.exitCode,
      stdout: result.stdout is String
          ? result.stdout as String
          : utf8.decode(result.stdout as List<int>, allowMalformed: true),
      stderr: result.stderr is String
          ? result.stderr as String
          : utf8.decode(result.stderr as List<int>, allowMalformed: true),
    );
  }

  Future<File> _hostFileForGuest(
    String workspaceId,
    String guestAbsolutePath,
  ) async {
    final guest = assertGuestPathUnderHome(guestAbsolutePath);
    final rootfs = await _rootfsDir(workspaceId);
    return File(p.join(rootfs.path, guest.substring(1)));
  }

  @override
  Future<Uint8List?> readGuestFile(
    String workspaceId,
    String guestAbsolutePath,
  ) async {
    final file = await _hostFileForGuest(workspaceId, guestAbsolutePath);
    if (!await file.exists()) return null;
    return Uint8List.fromList(await file.readAsBytes());
  }

  @override
  Future<void> writeGuestFile(
    String workspaceId,
    String guestAbsolutePath,
    List<int> bytes,
  ) async {
    final file = await _hostFileForGuest(workspaceId, guestAbsolutePath);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes, flush: true);
  }

  @override
  Future<void> deleteGuestPath(
    String workspaceId,
    String guestAbsolutePath, {
    bool recursive = false,
  }) async {
    final guest = assertGuestPathUnderHome(guestAbsolutePath);
    final rootfs = await _rootfsDir(workspaceId);
    final path = p.join(rootfs.path, guest.substring(1));
    final type = await FileSystemEntity.type(path);
    if (type == FileSystemEntityType.notFound) return;
    if (type == FileSystemEntityType.directory) {
      await Directory(path).delete(recursive: recursive);
    } else {
      await File(path).delete();
    }
  }
}

class ProotWorkspace implements SandboxWorkspace {
  ProotWorkspace({
    required this.workspaceId,
    required this.prootPath,
    required this.loaderPath,
    required this.rootfsPath,
    required List<String> prootArgs,
    required Map<String, String> environment,
    required this.onDisposed,
    int rows = 32,
    int columns = 100,
  }) {
    _pty = Pty.start(
      prootPath,
      arguments: prootArgs,
      environment: environment,
      workingDirectory: rootfsPath,
      rows: rows,
      columns: columns,
    );
  }

  @override
  final String workspaceId;

  final String prootPath;
  final String loaderPath;
  final String rootfsPath;
  final Future<void> Function() onDisposed;
  late final Pty _pty;
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

  @override
  Future<CommandResult> run(String cmd) async {
    final args = <String>[
      '--link2symlink',
      '--kill-on-exit',
      '--change-id=0:0',
      '--rootfs=$rootfsPath',
      '--cwd=$kGuestHome',
      '--bind=/dev',
      '--bind=/proc',
      '--bind=/sys',
      '--bind=$rootfsPath/tmp:/dev/shm',
      '/bin/sh',
      '-c',
      cmd,
    ];
    final result = await Process.run(
      prootPath,
      args,
      environment: {
        'PROOT_LOADER': loaderPath,
        'PROOT_NO_SECCOMP': '1',
        'PROOT_TMP_DIR': p.join(rootfsPath, 'tmp'),
        'TMPDIR': p.join(rootfsPath, 'tmp'),
        'PATH': '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin',
        'HOME': kGuestHome,
        'USER': 'root',
        'LANG': 'C.UTF-8',
      },
      workingDirectory: rootfsPath,
    );
    return CommandResult(
      exitCode: result.exitCode,
      stdout: result.stdout is String
          ? result.stdout as String
          : utf8.decode(result.stdout as List<int>, allowMalformed: true),
      stderr: result.stderr is String
          ? result.stderr as String
          : utf8.decode(result.stderr as List<int>, allowMalformed: true),
    );
  }

  @override
  Future<void> writeGuestFile(String guestAbsolutePath, List<int> bytes) async {
    final guestPath = assertGuestPathUnderHome(guestAbsolutePath);
    final relative = guestPath.substring(1); // drop leading /
    final hostPath = p.join(rootfsPath, relative);
    final file = File(hostPath);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes, flush: true);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _pty.kill();
    await onDisposed();
  }
}
