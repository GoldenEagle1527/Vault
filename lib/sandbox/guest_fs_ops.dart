import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:vault/sandbox/guest_file_copy.dart';
import 'package:vault/sandbox/sandbox_provider.dart';
import 'package:vault/sandbox/wsl_provider.dart';

/// Stream [hostPath] into a guest file without buffering the whole file.
///
/// Uses the host-mapped path (proot rootfs / `\\wsl$\…`). [WslProvider] also
/// falls back to a raw `cat` stdin pipe when UNC writes fail.
Future<void> copyHostFileToGuest({
  required SandboxProvider provider,
  required String workspaceId,
  required String guestAbsolutePath,
  required String hostPath,
}) async {
  if (provider is WslProvider) {
    await provider.copyHostFileToGuest(
      workspaceId,
      guestAbsolutePath,
      hostPath,
    );
    return;
  }
  final guest = assertGuestPathUnderHome(guestAbsolutePath);
  final dest = await provider.resolveGuestHostPath(workspaceId, guest);
  await streamCopyHostFile(sourcePath: hostPath, destPath: dest);
}

/// Whether [guestAbsolutePath] exists in the guest (file or directory).
Future<bool> guestPathExists(
  SandboxProvider provider,
  String workspaceId,
  String guestAbsolutePath,
) async {
  final guest = assertGuestPathUnderHome(guestAbsolutePath);
  try {
    final host = await provider.resolveGuestHostPath(workspaceId, guest);
    final type = await FileSystemEntity.type(host, followLinks: false);
    if (type != FileSystemEntityType.notFound) return true;
  } catch (_) {
    // Fall through.
  }
  final result = await provider.runGuestCommand(
    workspaceId,
    'if [ -e ${shellSingleQuote(guest)} ]; then echo yes; else echo no; fi',
  );
  return result.success && result.stdout.trim().startsWith('yes');
}

/// Create a guest directory (and parents) under [kGuestHome].
Future<void> createGuestDirectory(
  SandboxProvider provider,
  String workspaceId,
  String guestAbsolutePath,
) async {
  final guest = assertGuestPathUnderHome(guestAbsolutePath);
  try {
    final host = await provider.resolveGuestHostPath(workspaceId, guest);
    await Directory(host).create(recursive: true);
    return;
  } catch (_) {
    // Fall through to guest mkdir.
  }
  final result = await provider.runGuestCommand(
    workspaceId,
    'mkdir -p -- ${shellSingleQuote(guest)}',
  );
  if (!result.success) {
    throw StateError('无法创建目录 $guest：${result.stderr}'.trim());
  }
}

/// Stream a host file into [guestDir]/basename], sanitizing the name.
///
/// Does not load the whole file into memory. Returns the guest absolute path
/// written. When [overwrite] is false and the target exists, picks
/// `name-2.ext`, `name-3.ext`, …
Future<String> importHostFileToGuest({
  required SandboxProvider provider,
  required String workspaceId,
  required String guestDir,
  required String hostPath,
  String? displayName,
  bool overwrite = false,
}) async {
  final dir = assertGuestPathUnderHome(guestDir);
  var name = sanitizeInboxFileName(displayName ?? p.basename(hostPath));
  var guestPath = guestPathJoin(dir, name);

  if (!overwrite && await guestPathExists(provider, workspaceId, guestPath)) {
    final stem = p.basenameWithoutExtension(name);
    final ext = p.extension(name);
    var i = 2;
    while (true) {
      final candidate = sanitizeInboxFileName('$stem-$i$ext');
      final path = guestPathJoin(dir, candidate);
      if (!await guestPathExists(provider, workspaceId, path)) {
        name = candidate;
        guestPath = path;
        break;
      }
      i++;
      if (i > 999) {
        throw StateError('无法为导入文件分配唯一名称：$name');
      }
    }
  }

  await copyHostFileToGuest(
    provider: provider,
    workspaceId: workspaceId,
    guestAbsolutePath: guestPath,
    hostPath: hostPath,
  );
  return guestPath;
}

/// Create an empty guest file under [guestDir].
Future<String> createGuestEmptyFile({
  required SandboxProvider provider,
  required String workspaceId,
  required String guestDir,
  required String fileName,
}) async {
  final name = sanitizeInboxFileName(fileName);
  final guestPath = guestPathJoin(guestDir, name);
  if (await guestPathExists(provider, workspaceId, guestPath)) {
    throw StateError('已存在：$guestPath');
  }
  await provider.writeGuestFile(workspaceId, guestPath, const []);
  return guestPath;
}

/// Create an empty guest directory under [guestDir].
Future<String> createGuestEmptyDirectory({
  required SandboxProvider provider,
  required String workspaceId,
  required String guestDir,
  required String dirName,
}) async {
  final name = sanitizeInboxFileName(dirName);
  final guestPath = guestPathJoin(guestDir, name);
  if (await guestPathExists(provider, workspaceId, guestPath)) {
    throw StateError('已存在：$guestPath');
  }
  await createGuestDirectory(provider, workspaceId, guestPath);
  return guestPath;
}

/// Ensure a child directory exists under [guestDir], renaming on conflict when
/// [unique] is true; otherwise reuses an existing directory of the same name.
Future<String> ensureGuestChildDirectory({
  required SandboxProvider provider,
  required String workspaceId,
  required String guestDir,
  required String dirName,
  bool unique = false,
}) async {
  final dir = assertGuestPathUnderHome(guestDir);
  var name = sanitizeInboxFileName(dirName);
  var guestPath = guestPathJoin(dir, name);

  if (await guestPathExists(provider, workspaceId, guestPath)) {
    if (!unique) return guestPath;
    final stem = name;
    var i = 2;
    while (true) {
      final candidate = sanitizeInboxFileName('$stem-$i');
      final path = guestPathJoin(dir, candidate);
      if (!await guestPathExists(provider, workspaceId, path)) {
        name = candidate;
        guestPath = path;
        break;
      }
      i++;
      if (i > 999) {
        throw StateError('无法为导入目录分配唯一名称：$name');
      }
    }
  }

  await createGuestDirectory(provider, workspaceId, guestPath);
  return guestPath;
}

/// Pick a non-colliding path under [guestDir] for [fileName].
Future<String> allocateUniqueGuestPath({
  required SandboxProvider provider,
  required String workspaceId,
  required String guestDir,
  required String fileName,
}) async {
  final dir = assertGuestPathUnderHome(guestDir);
  var name = sanitizeInboxFileName(fileName);
  var guestPath = guestPathJoin(dir, name);
  if (!await guestPathExists(provider, workspaceId, guestPath)) {
    return guestPath;
  }
  final stem = p.basenameWithoutExtension(name);
  final ext = p.extension(name);
  var i = 2;
  while (true) {
    final candidate = sanitizeInboxFileName('$stem-$i$ext');
    final path = guestPathJoin(dir, candidate);
    if (!await guestPathExists(provider, workspaceId, path)) {
      return path;
    }
    i++;
    if (i > 999) {
      throw StateError('无法分配唯一名称：$name');
    }
  }
}

/// Rename / move [fromPath] to [toPath] (both under [kGuestHome]).
Future<void> renameGuestPath({
  required SandboxProvider provider,
  required String workspaceId,
  required String fromPath,
  required String toPath,
}) async {
  final from = assertGuestPathUnderHome(fromPath);
  final to = assertGuestPathUnderHome(toPath);
  if (from == to) return;
  if (await guestPathExists(provider, workspaceId, to)) {
    throw StateError('目标已存在：$to');
  }
  try {
    final fromHost = await provider.resolveGuestHostPath(workspaceId, from);
    final toHost = await provider.resolveGuestHostPath(workspaceId, to);
    await Directory(p.dirname(toHost)).create(recursive: true);
    final type = await FileSystemEntity.type(fromHost, followLinks: false);
    if (type == FileSystemEntityType.directory) {
      await Directory(fromHost).rename(toHost);
    } else {
      await File(fromHost).rename(toHost);
    }
    return;
  } catch (_) {
    // Fall through to guest mv.
  }
  final result = await provider.runGuestCommand(
    workspaceId,
    'mv -- ${shellSingleQuote(from)} ${shellSingleQuote(to)}',
  );
  if (!result.success) {
    throw StateError('重命名失败：${result.stderr}'.trim());
  }
}

/// Copy [fromPath] to [toPath] (recursive for directories).
Future<void> copyGuestPath({
  required SandboxProvider provider,
  required String workspaceId,
  required String fromPath,
  required String toPath,
}) async {
  final from = assertGuestPathUnderHome(fromPath);
  final to = assertGuestPathUnderHome(toPath);
  if (from == to || to.startsWith('$from/')) {
    throw StateError('不能复制到自身或其子目录');
  }
  try {
    final fromHost = await provider.resolveGuestHostPath(workspaceId, from);
    final toHost = await provider.resolveGuestHostPath(workspaceId, to);
    final type = await FileSystemEntity.type(fromHost, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      throw StateError('源不存在：$from');
    }
    await Directory(p.dirname(toHost)).create(recursive: true);
    if (type == FileSystemEntityType.directory) {
      await copyHostDirectoryTree(Directory(fromHost), Directory(toHost));
    } else {
      await File(fromHost).copy(toHost);
    }
    return;
  } catch (e) {
    if (e is StateError) rethrow;
  }
  final result = await provider.runGuestCommand(
    workspaceId,
    'cp -a -- ${shellSingleQuote(from)} ${shellSingleQuote(to)}',
  );
  if (!result.success) {
    throw StateError('复制失败：${result.stderr}'.trim());
  }
}

/// Move [fromPath] to [toPath].
Future<void> moveGuestPath({
  required SandboxProvider provider,
  required String workspaceId,
  required String fromPath,
  required String toPath,
}) async {
  final from = assertGuestPathUnderHome(fromPath);
  final to = assertGuestPathUnderHome(toPath);
  if (to == from || to.startsWith('$from/')) {
    throw StateError('不能移动到自身或其子目录');
  }
  await renameGuestPath(
    provider: provider,
    workspaceId: workspaceId,
    fromPath: from,
    toPath: to,
  );
}

/// Probe whether [guestAbsolutePath] is a file, directory, or missing.
Future<FileSystemEntityType> guestEntityType(
  SandboxProvider provider,
  String workspaceId,
  String guestAbsolutePath,
) async {
  final guest = assertGuestPathUnderHome(guestAbsolutePath);
  try {
    final host = await provider.resolveGuestHostPath(workspaceId, guest);
    final type = await FileSystemEntity.type(host, followLinks: false);
    if (type != FileSystemEntityType.notFound) return type;
  } catch (_) {
    // Fall through.
  }
  final result = await provider.runGuestCommand(
    workspaceId,
    'if [ -d ${shellSingleQuote(guest)} ]; then echo dir; '
    'elif [ -f ${shellSingleQuote(guest)} ]; then echo file; '
    'elif [ -e ${shellSingleQuote(guest)} ]; then echo other; '
    'else echo missing; fi',
  );
  return switch (result.stdout.trim()) {
    'dir' => FileSystemEntityType.directory,
    'file' => FileSystemEntityType.file,
    'other' => FileSystemEntityType.link,
    _ => FileSystemEntityType.notFound,
  };
}

/// Byte size of a guest file, or null if missing / not a file.
Future<int?> guestFileByteSize(
  SandboxProvider provider,
  String workspaceId,
  String guestAbsolutePath,
) async {
  final guest = assertGuestPathUnderHome(guestAbsolutePath);
  try {
    final host = await provider.resolveGuestHostPath(workspaceId, guest);
    final file = File(host);
    if (await file.exists()) return await file.length();
  } catch (_) {
    // Fall through.
  }
  final result = await provider.runGuestCommand(
    workspaceId,
    'if [ -f ${shellSingleQuote(guest)} ]; then wc -c < ${shellSingleQuote(guest)}; fi',
  );
  if (!result.success) return null;
  return int.tryParse(result.stdout.trim());
}

/// Stream a guest file onto [hostPath] without buffering the whole file.
Future<void> exportGuestFileToHost({
  required SandboxProvider provider,
  required String workspaceId,
  required String guestAbsolutePath,
  required String hostPath,
}) async {
  if (provider is WslProvider) {
    await provider.copyGuestFileToHost(
      workspaceId,
      guestAbsolutePath,
      hostPath,
    );
    return;
  }
  final guest = assertGuestPathUnderHome(guestAbsolutePath);
  final source = await provider.resolveGuestHostPath(workspaceId, guest);
  await streamCopyHostFile(sourcePath: source, destPath: hostPath);
}

/// Recursively copy a guest directory onto [hostDir] (created).
Future<void> exportGuestDirectoryToHost({
  required SandboxProvider provider,
  required String workspaceId,
  required String guestAbsolutePath,
  required String hostDir,
}) async {
  if (provider is WslProvider) {
    await provider.copyGuestDirectoryToHost(
      workspaceId,
      guestAbsolutePath,
      hostDir,
    );
    return;
  }
  final guest = assertGuestPathUnderHome(guestAbsolutePath);
  final source = await provider.resolveGuestHostPath(workspaceId, guest);
  await copyHostDirectoryTree(Directory(source), Directory(hostDir));
}

/// Export a guest file or directory onto a host destination path.
Future<void> exportGuestPathToHost({
  required SandboxProvider provider,
  required String workspaceId,
  required String guestAbsolutePath,
  required String hostPath,
}) async {
  final type = await guestEntityType(provider, workspaceId, guestAbsolutePath);
  if (type == FileSystemEntityType.notFound) {
    throw StateError('源不存在：$guestAbsolutePath');
  }
  if (type == FileSystemEntityType.directory) {
    await exportGuestDirectoryToHost(
      provider: provider,
      workspaceId: workspaceId,
      guestAbsolutePath: guestAbsolutePath,
      hostDir: hostPath,
    );
    return;
  }
  await exportGuestFileToHost(
    provider: provider,
    workspaceId: workspaceId,
    guestAbsolutePath: guestAbsolutePath,
    hostPath: hostPath,
  );
}
