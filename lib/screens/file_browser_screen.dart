import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:vault/sandbox/guest_fs_ops.dart';
import 'package:vault/sandbox/guest_media_kind.dart';
import 'package:vault/sandbox/sandbox_provider.dart';
import 'package:vault/screens/file_browser/file_browser_controller.dart';
import 'package:vault/screens/file_browser/file_browser_operation_menu.dart';
import 'package:vault/screens/file_browser/file_browser_path_navigation.dart';
import 'package:vault/screens/file_browser/file_preview_screen.dart';
import 'package:vault/util/guest_export.dart';
import 'package:vault/util/host_file_picker.dart';

export 'package:vault/screens/file_browser/file_browser_controller.dart';
export 'package:vault/screens/file_browser/file_preview_screen.dart';

/// Browse / preview / edit text files under guest [kGuestHome].
class FileBrowserScreen extends StatefulWidget {
  const FileBrowserScreen({
    super.key,
    required this.provider,
    required this.workspaceId,
    this.title,
    this.initialPath = kGuestHome,
    this.projectGuestPath,
  });

  final SandboxProvider provider;
  final String workspaceId;
  final String? title;
  final String initialPath;

  /// Optional shortcut target (e.g. active project dir under `/root/projects`).
  final String? projectGuestPath;

  @override
  State<FileBrowserScreen> createState() => _FileBrowserScreenState();
}

class _GuestClipboard {
  const _GuestClipboard({required this.paths, required this.isCut});

  final List<String> paths;
  final bool isCut;
}

class _ImportProgress {
  const _ImportProgress({
    required this.current,
    required this.total,
    required this.name,
  });

  final int current;
  final int total;
  final String name;
}

class _FileBrowserScreenState extends State<FileBrowserScreen> {
  late final FileBrowserController _controller;
  List<GuestFsEntry> _entries = const [];
  _GuestClipboard? _clipboard;
  bool _loading = true;
  bool _busy = false;
  bool _dragging = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = FileBrowserController(
      initialPath: widget.initialPath,
      projectGuestPath: widget.projectGuestPath,
    );
    _load();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String get _cwd => _controller.currentPath;
  String? get _projectPath => _controller.projectPath;
  Set<String> get _selected => _controller.selected;

  bool get _actionsEnabled => !_loading && !_busy;

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final entries = await widget.provider.listGuestDirectory(
        widget.workspaceId,
        _cwd,
      );
      if (!mounted) return;
      setState(() {
        _entries = entries;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _entries = const [];
        _loading = false;
        _error = e.toString();
      });
    }
  }

  bool get _canGoUp => _controller.canGoUp;

  String get _relativeLabel => _controller.pathLabel;

  void _clearSelection() {
    setState(_controller.clearSelection);
  }

  Future<void> _goUp() async {
    if (!_controller.goUp()) return;
    setState(() {});
    await _load();
  }

  Future<void> _openDir(GuestFsEntry entry) async {
    _controller.openPath(entry.guestPath);
    setState(() {});
    await _load();
  }

  Future<void> _openFile(GuestFsEntry entry) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => FilePreviewScreen(
          provider: widget.provider,
          workspaceId: widget.workspaceId,
          guestPath: entry.guestPath,
        ),
      ),
    );
  }

  Future<void> _jumpToProject() async {
    if (!_controller.jumpToProject()) return;
    setState(() {});
    await _load();
  }

  String _formatSize(int? bytes) {
    if (bytes == null) return '';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  void _snack(String message, {bool error = false}) {
    if (!mounted) return;
    final scheme = Theme.of(context).colorScheme;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: error ? scheme.error : null,
      ),
    );
  }

  Future<String?> _promptName({
    required String title,
    required String hint,
    String initial = '',
  }) async {
    final ctrl = TextEditingController(text: initial);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: Text(title),
          content: TextField(
            controller: ctrl,
            autofocus: true,
            decoration: InputDecoration(
              hintText: hint,
              border: const OutlineInputBorder(),
            ),
            onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()),
              child: const Text('确定'),
            ),
          ],
        );
      },
    );
    ctrl.dispose();
    if (result == null || result.isEmpty) return null;
    return result;
  }

  Future<void> _importHostPaths(
    List<({String path, String name})> files,
  ) async {
    if (files.isEmpty) return;
    setState(() => _busy = true);

    final progress = ValueNotifier<_ImportProgress>(
      _ImportProgress(current: 0, total: files.length, name: files.first.name),
    );
    var dialogOpen = true;
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        useRootNavigator: true,
        builder: (ctx) {
          return PopScope(
            canPop: false,
            child: AlertDialog(
              title: const Text('正在导入'),
              content: ValueListenableBuilder<_ImportProgress>(
                valueListenable: progress,
                builder: (context, value, _) {
                  final label = value.total <= 0
                      ? '准备中…'
                      : '${value.current.clamp(0, value.total)} / ${value.total}';
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Center(child: CircularProgressIndicator()),
                      const SizedBox(height: 20),
                      Text(
                        label,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        value.name.isEmpty ? '请稍候…' : value.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          );
        },
      ).whenComplete(() => dialogOpen = false),
    );

    // Let the dialog paint before heavy IO.
    await Future<void>.delayed(Duration.zero);

    var ok = 0;
    var failed = 0;
    try {
      for (var i = 0; i < files.length; i++) {
        final f = files[i];
        progress.value = _ImportProgress(
          current: i + 1,
          total: files.length,
          name: f.name,
        );
        try {
          final type = await FileSystemEntity.type(f.path, followLinks: false);
          if (type == FileSystemEntityType.directory) {
            await _importHostDirectory(f.path, f.name, _cwd);
            ok++;
          } else if (type == FileSystemEntityType.file) {
            await importHostFileToGuest(
              provider: widget.provider,
              workspaceId: widget.workspaceId,
              guestDir: _cwd,
              hostPath: f.path,
              displayName: f.name,
            );
            ok++;
          }
        } catch (e) {
          failed++;
          debugPrint('import failed ${f.path}: $e');
        }
      }
      await _load();
      if (failed == 0) {
        _snack('已导入 $ok 项到 $_cwd');
      } else {
        _snack('导入完成：成功 $ok，失败 $failed', error: failed == files.length);
      }
    } finally {
      if (mounted && dialogOpen) {
        Navigator.of(context, rootNavigator: true).pop();
      }
      progress.dispose();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _importHostDirectory(
    String hostDir,
    String displayName,
    String guestParent, {
    bool uniqueTopLevel = true,
  }) async {
    final guestDir = await ensureGuestChildDirectory(
      provider: widget.provider,
      workspaceId: widget.workspaceId,
      guestDir: guestParent,
      dirName: displayName,
      unique: uniqueTopLevel,
    );
    final entities = Directory(hostDir).list(followLinks: false);
    await for (final entity in entities) {
      final name = entity.uri.pathSegments.isEmpty
          ? entity.path.split(Platform.pathSeparator).last
          : entity.uri.pathSegments.last;
      if (name.isEmpty || name == '.' || name == '..') continue;
      if (entity is Directory) {
        await _importHostDirectory(
          entity.path,
          name,
          guestDir,
          uniqueTopLevel: false,
        );
      } else if (entity is File) {
        await importHostFileToGuest(
          provider: widget.provider,
          workspaceId: widget.workspaceId,
          guestDir: guestDir,
          hostPath: entity.path,
          displayName: name,
        );
      }
    }
  }

  Future<void> _pickAndImport() async {
    // Same unrestricted picker as the agent paperclip (FileType.any).
    final result = await pickHostFilesForUi(
      allowMultiple: true,
      withData: false,
    );
    if (result == null || !mounted) return;
    final files = <({String path, String name})>[];
    for (final f in result.files) {
      final path = f.path;
      if (path == null || path.isEmpty) continue;
      files.add((path: path, name: f.name));
    }
    await _importHostPaths(files);
  }

  Future<void> _onDropDone(DropDoneDetails details) async {
    setState(() => _dragging = false);
    final files = <({String path, String name})>[];
    Future<void> collect(DropItem item) async {
      if (item.path.isEmpty) return;
      final name = item.name.trim().isEmpty
          ? p.basename(item.path)
          : item.name.trim();
      files.add((path: item.path, name: name));
    }

    for (final item in details.files) {
      await collect(item);
    }
    await _importHostPaths(files);
  }

  Future<void> _createFile() async {
    final name = await _promptName(
      title: '新建文件',
      hint: '例如 notes.txt',
      initial: 'untitled.txt',
    );
    if (name == null) return;
    setState(() => _busy = true);
    try {
      final path = await createGuestEmptyFile(
        provider: widget.provider,
        workspaceId: widget.workspaceId,
        guestDir: _cwd,
        fileName: name,
      );
      await _load();
      _snack('已创建 $path');
    } catch (e) {
      _snack('创建失败：$e', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _createFolder() async {
    final name = await _promptName(
      title: '新建文件夹',
      hint: '例如 docs',
      initial: 'new-folder',
    );
    if (name == null) return;
    setState(() => _busy = true);
    try {
      final path = await createGuestEmptyDirectory(
        provider: widget.provider,
        workspaceId: widget.workspaceId,
        guestDir: _cwd,
        dirName: name,
      );
      await _load();
      _snack('已创建 $path');
    } catch (e) {
      _snack('创建失败：$e', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  GuestFsEntry? _entryByPath(String path) {
    for (final e in _entries) {
      if (e.guestPath == path) return e;
    }
    return null;
  }

  void _toggleSelected(String path) {
    setState(() => _controller.toggleSelection(path));
  }

  void _selectOnly(String path) {
    setState(() => _controller.selectOnly(path));
  }

  void _selectAll() {
    setState(
      () => _controller.selectAll(_entries.map((entry) => entry.guestPath)),
    );
  }

  void _onEntryTap(GuestFsEntry entry) {
    final multi =
        HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed;
    if (multi) {
      _toggleSelected(entry.guestPath);
      return;
    }
    if (_selected.isNotEmpty) {
      _toggleSelected(entry.guestPath);
      return;
    }
    if (entry.isDirectory) {
      unawaited(_openDir(entry));
    } else {
      unawaited(_openFile(entry));
    }
  }

  Future<void> _showContextMenu(
    Offset globalPosition, {
    GuestFsEntry? entry,
  }) async {
    if (!_actionsEnabled) return;
    if (entry != null && !_selected.contains(entry.guestPath)) {
      _selectOnly(entry.guestPath);
    }

    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final hasSelection = _selected.isNotEmpty;
    final single = _selected.length == 1
        ? _entryByPath(_selected.first) ?? entry
        : null;
    final canPaste = _clipboard != null && _clipboard!.paths.isNotEmpty;

    final action = await showMenu<FileBrowserOperation>(
      context: context,
      position: RelativeRect.fromRect(
        globalPosition & const Size(1, 1),
        Offset.zero & overlay.size,
      ),
      items: buildFileBrowserOperationItems(
        hasSingleSelection: single != null,
        hasSelection: hasSelection,
        canPaste: canPaste,
        hasEntries: _entries.isNotEmpty,
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case FileBrowserOperation.open:
        if (single != null) {
          if (single.isDirectory) {
            await _openDir(single);
          } else {
            await _openFile(single);
          }
        }
      case FileBrowserOperation.rename:
        await _renameSelected();
      case FileBrowserOperation.copy:
        _copySelected(cut: false);
      case FileBrowserOperation.cut:
        _copySelected(cut: true);
      case FileBrowserOperation.paste:
        await _pasteClipboard();
      case FileBrowserOperation.delete:
        await _deleteSelected();
      case FileBrowserOperation.export:
        await _exportSelected(GuestExportMode.saveAs);
      case FileBrowserOperation.share:
        await _exportSelected(GuestExportMode.share);
      case FileBrowserOperation.pack:
        await _exportSelected(GuestExportMode.pack);
      case FileBrowserOperation.selectAll:
        _selectAll();
      case FileBrowserOperation.clear:
        _clearSelection();
    }
  }

  void _copySelected({required bool cut}) {
    if (_selected.isEmpty) return;
    setState(() {
      _clipboard = _GuestClipboard(
        paths: _selected.toList(growable: false),
        isCut: cut,
      );
    });
    _snack(cut ? '已剪切 ${_selected.length} 项' : '已复制 ${_selected.length} 项');
  }

  Future<void> _renameSelected() async {
    if (_selected.length != 1) return;
    final path = _selected.first;
    final entry = _entryByPath(path);
    if (entry == null) return;
    final name = await _promptName(
      title: '重命名',
      hint: entry.isDirectory ? '文件夹名' : '文件名',
      initial: entry.name,
    );
    if (name == null || name == entry.name) return;
    setState(() => _busy = true);
    try {
      final dest = guestPathJoin(_cwd, sanitizeInboxFileName(name));
      await renameGuestPath(
        provider: widget.provider,
        workspaceId: widget.workspaceId,
        fromPath: path,
        toPath: dest,
      );
      _controller.replaceSelection(dest);
      await _load();
      _snack('已重命名为 ${sanitizeInboxFileName(name)}');
    } catch (e) {
      _snack('重命名失败：$e', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _exportSelected(GuestExportMode mode) async {
    if (_selected.isEmpty) return;
    final paths = _selected.toList(growable: false);
    setState(() => _busy = true);
    final progress = ValueNotifier<GuestExportProgress?>(null);
    var dialogOpen = false;
    void ensureDialog() {
      if (dialogOpen || !mounted) return;
      dialogOpen = true;
      unawaited(
        showDialog<void>(
          context: context,
          barrierDismissible: false,
          useRootNavigator: true,
          builder: (ctx) {
            return PopScope(
              canPop: false,
              child: AlertDialog(
                title: Text(switch (mode) {
                  GuestExportMode.saveAs => '正在导出',
                  GuestExportMode.share => '正在准备分享',
                  GuestExportMode.pack => '正在打包',
                }),
                content: ValueListenableBuilder<GuestExportProgress?>(
                  valueListenable: progress,
                  builder: (context, value, _) {
                    final current = value?.current ?? 0;
                    final total = value?.total ?? 0;
                    final name = value?.name ?? '';
                    final label = total <= 0
                        ? '准备中…'
                        : '${current.clamp(0, total)} / $total';
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Center(child: CircularProgressIndicator()),
                        const SizedBox(height: 20),
                        Text(
                          label,
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          name.isEmpty ? '请稍候…' : name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                              ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            );
          },
        ).whenComplete(() => dialogOpen = false),
      );
    }

    try {
      final result = await GuestExport(
        provider: widget.provider,
        workspaceId: widget.workspaceId,
      ).run(
        mode: mode,
        guestPaths: paths,
        onProgress: (value) {
          progress.value = value;
          ensureDialog();
        },
      );
      if (result.cancelled) return;
      if (result.failed == 0) {
        _snack(result.message ?? '已导出');
      } else {
        _snack(result.message ?? '导出失败', error: true);
      }
    } catch (e) {
      _snack('导出失败：$e', error: true);
    } finally {
      if (mounted && dialogOpen) {
        Navigator.of(context, rootNavigator: true).pop();
      }
      progress.dispose();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _deleteSelected() async {
    if (_selected.isEmpty) return;
    final paths = _selected.toList(growable: false);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除'),
        content: Text(
          paths.length == 1
              ? '确定删除「${p.basename(paths.first)}」？'
              : '确定删除选中的 ${paths.length} 项？此操作不可撤销。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    var failed = 0;
    try {
      for (final path in paths) {
        try {
          await widget.provider.deleteGuestPath(
            widget.workspaceId,
            path,
            recursive: true,
          );
        } catch (e) {
          failed++;
          debugPrint('delete failed $path: $e');
        }
      }
      _controller.clearSelection();
      final clip = _clipboard;
      if (clip != null) {
        final remain = clip.paths
            .where((p) => !paths.contains(p))
            .toList(growable: false);
        _clipboard = remain.isEmpty
            ? null
            : _GuestClipboard(paths: remain, isCut: clip.isCut);
      }
      await _load();
      if (failed == 0) {
        _snack('已删除 ${paths.length} 项');
      } else {
        _snack('删除完成：失败 $failed 项', error: true);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pasteClipboard() async {
    final clip = _clipboard;
    if (clip == null || clip.paths.isEmpty) return;
    setState(() => _busy = true);
    var ok = 0;
    var failed = 0;
    try {
      for (final src in clip.paths) {
        try {
          final base = p.basename(src);
          final dest = await allocateUniqueGuestPath(
            provider: widget.provider,
            workspaceId: widget.workspaceId,
            guestDir: _cwd,
            fileName: base,
          );
          if (clip.isCut) {
            await moveGuestPath(
              provider: widget.provider,
              workspaceId: widget.workspaceId,
              fromPath: src,
              toPath: dest,
            );
          } else {
            await copyGuestPath(
              provider: widget.provider,
              workspaceId: widget.workspaceId,
              fromPath: src,
              toPath: dest,
            );
          }
          ok++;
        } catch (e) {
          failed++;
          debugPrint('paste failed $src: $e');
        }
      }
      if (clip.isCut) {
        _clipboard = null;
      }
      _controller.clearSelection();
      await _load();
      if (failed == 0) {
        _snack(clip.isCut ? '已移动 $ok 项' : '已粘贴 $ok 项');
      } else {
        _snack('粘贴完成：成功 $ok，失败 $failed', error: failed == clip.paths.length);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final projectPath = _projectPath;
    final showProjectJump = projectPath != null && _cwd != projectPath;
    final dropEnabled =
        !kIsWeb &&
        (Platform.isWindows || Platform.isLinux || Platform.isMacOS) &&
        (ModalRoute.of(context)?.isCurrent ?? true);

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('文件浏览器'),
            Text(
              widget.title == null
                  ? _relativeLabel
                  : '${widget.title} · $_relativeLabel',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
        actions: [
          if (_selected.isNotEmpty) ...[
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(
                  '已选 ${_selected.length}',
                  style: Theme.of(context).textTheme.labelLarge,
                ),
              ),
            ),
            IconButton(
              tooltip: '取消选择',
              onPressed: _clearSelection,
              icon: const Icon(Icons.close),
            ),
            IconButton(
              tooltip: '复制',
              onPressed: _actionsEnabled
                  ? () => _copySelected(cut: false)
                  : null,
              icon: const Icon(Icons.copy_outlined),
            ),
            IconButton(
              tooltip: '剪切',
              onPressed: _actionsEnabled
                  ? () => _copySelected(cut: true)
                  : null,
              icon: const Icon(Icons.content_cut),
            ),
            IconButton(
              tooltip: '删除',
              onPressed: _actionsEnabled ? _deleteSelected : null,
              icon: const Icon(Icons.delete_outline),
            ),
            IconButton(
              tooltip: '导出',
              onPressed: _actionsEnabled
                  ? () => unawaited(_exportSelected(GuestExportMode.saveAs))
                  : null,
              icon: const Icon(Icons.download_outlined),
            ),
          ],
          if (_clipboard != null)
            IconButton(
              tooltip: _clipboard!.isCut ? '粘贴（移动）' : '粘贴',
              onPressed: _actionsEnabled ? _pasteClipboard : null,
              icon: const Icon(Icons.content_paste),
            ),
          IconButton(
            tooltip: '导入文件',
            onPressed: _actionsEnabled ? _pickAndImport : null,
            icon: const Icon(Icons.upload_file_outlined),
          ),
          PopupMenuButton<String>(
            tooltip: '新建',
            enabled: _actionsEnabled,
            onSelected: (value) {
              if (value == 'file') unawaited(_createFile());
              if (value == 'folder') unawaited(_createFolder());
            },
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'file', child: Text('新建文件')),
              PopupMenuItem(value: 'folder', child: Text('新建文件夹')),
            ],
            icon: const Icon(Icons.add_outlined),
          ),
          IconButton(
            tooltip: '刷新',
            onPressed: _actionsEnabled ? _load : null,
            icon: _busy
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
          ),
          if (_projectPath != null)
            IconButton(
              tooltip: '回到当前项目',
              onPressed: !_actionsEnabled || !showProjectJump
                  ? null
                  : _jumpToProject,
              icon: const Icon(Icons.my_location_outlined),
            ),
        ],
      ),
      body: DropTarget(
        enable: dropEnabled && _actionsEnabled,
        onDragEntered: (_) => setState(() => _dragging = true),
        onDragExited: (_) => setState(() => _dragging = false),
        onDragDone: (details) => unawaited(_onDropDone(details)),
        child: Stack(
          children: [
            Column(
              children: [
                FileBrowserPathNavigation(
                  pathLabel: _relativeLabel,
                  canGoUp: _canGoUp,
                  enabled: _actionsEnabled,
                  dropEnabled: dropEnabled,
                  onGoUp: () => unawaited(_goUp()),
                ),
                Expanded(child: _buildBody(scheme)),
              ],
            ),
            if (_dragging)
              Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: scheme.primary.withValues(alpha: 0.12),
                      border: Border.all(color: scheme.primary, width: 2),
                    ),
                    child: Center(
                      child: Material(
                        color: scheme.surface,
                        borderRadius: BorderRadius.circular(12),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 14,
                          ),
                          child: Text(
                            '释放以导入到 $_cwd',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(ColorScheme scheme) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline, color: scheme.error, size: 40),
              const SizedBox(height: 12),
              Text('无法打开目录', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 16),
              FilledButton.tonal(onPressed: _load, child: const Text('重试')),
            ],
          ),
        ),
      );
    }

    if (_entries.isEmpty) {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onSecondaryTapDown: (details) {
          unawaited(_showContextMenu(details.globalPosition));
        },
        onLongPressStart: (details) {
          unawaited(_showContextMenu(details.globalPosition));
        },
        child: Center(
          child: Text(
            '此目录为空\n右键或长按可粘贴',
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ),
      );
    }

    return ListView.builder(
      itemCount: _entries.length,
      itemBuilder: (context, index) {
        final entry = _entries[index];
        final selected = _selected.contains(entry.guestPath);
        final cutHere =
            _clipboard?.isCut == true &&
            _clipboard!.paths.contains(entry.guestPath);
        final sizeLabel = entry.isDirectory
            ? null
            : _formatSize(entry.sizeBytes);
        final kind = entry.isDirectory
            ? null
            : guestMediaKindForPath(entry.guestPath);
        return GestureDetector(
          onSecondaryTapDown: (details) {
            unawaited(_showContextMenu(details.globalPosition, entry: entry));
          },
          onLongPressStart: (details) {
            unawaited(_showContextMenu(details.globalPosition, entry: entry));
          },
          child: ListTile(
            selected: selected,
            leading: Icon(
              entry.isDirectory
                  ? Icons.folder_outlined
                  : _iconForMediaKind(kind ?? GuestMediaKind.binary),
              color: cutHere ? scheme.onSurfaceVariant : null,
            ),
            title: Text(
              entry.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: cutHere
                  ? TextStyle(
                      color: scheme.onSurfaceVariant,
                      fontStyle: FontStyle.italic,
                    )
                  : null,
            ),
            subtitle: sizeLabel == null || sizeLabel.isEmpty
                ? null
                : Text(sizeLabel),
            trailing: selected
                ? Icon(Icons.check_circle, color: scheme.primary)
                : null,
            onTap: () => _onEntryTap(entry),
          ),
        );
      },
    );
  }
}

IconData _iconForMediaKind(GuestMediaKind kind) {
  switch (kind) {
    case GuestMediaKind.image:
      return Icons.image_outlined;
    case GuestMediaKind.video:
      return Icons.movie_outlined;
    case GuestMediaKind.audio:
      return Icons.audiotrack_outlined;
    case GuestMediaKind.text:
      return Icons.description_outlined;
    case GuestMediaKind.binary:
      return Icons.insert_drive_file_outlined;
  }
}
