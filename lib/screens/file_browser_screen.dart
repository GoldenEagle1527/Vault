import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:vault/sandbox/guest_code_highlight.dart';
import 'package:vault/sandbox/guest_fs_ops.dart';
import 'package:vault/sandbox/guest_media_kind.dart';
import 'package:vault/sandbox/guest_media_source.dart';
import 'package:vault/sandbox/sandbox_provider.dart';
import 'package:vault/util/host_file_picker.dart';
import 'package:vault/widgets/guest_media_preview.dart';

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

class _FileBrowserScreenState extends State<FileBrowserScreen> {
  late String _cwd;
  String? _projectPath;
  List<GuestFsEntry> _entries = const [];
  final Set<String> _selected = {};
  _GuestClipboard? _clipboard;
  bool _loading = true;
  bool _busy = false;
  bool _dragging = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _cwd = assertGuestPathUnderHome(widget.initialPath);
    final project = widget.projectGuestPath;
    if (project != null && project.isNotEmpty) {
      try {
        _projectPath = assertGuestPathUnderHome(project);
      } catch (_) {
        _projectPath = null;
      }
    }
    _load();
  }

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

  bool get _canGoUp => _cwd != kGuestHome && _cwd.startsWith('$kGuestHome/');

  String get _relativeLabel {
    if (_cwd == kGuestHome) return '/root';
    return _cwd;
  }

  void _clearSelection() {
    if (_selected.isEmpty) return;
    setState(() => _selected.clear());
  }

  Future<void> _goUp() async {
    if (!_canGoUp) return;
    final parent = _cwd.substring(0, _cwd.lastIndexOf('/'));
    final next = parent.isEmpty || parent == '/' ? kGuestHome : parent;
    setState(() {
      _cwd = assertGuestPathUnderHome(next);
      _selected.clear();
    });
    await _load();
  }

  Future<void> _openDir(GuestFsEntry entry) async {
    setState(() {
      _cwd = entry.guestPath;
      _selected.clear();
    });
    await _load();
  }

  Future<void> _openFile(GuestFsEntry entry) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _FilePreviewScreen(
          provider: widget.provider,
          workspaceId: widget.workspaceId,
          guestPath: entry.guestPath,
        ),
      ),
    );
  }

  Future<void> _jumpToProject() async {
    final path = _projectPath;
    if (path == null) return;
    setState(() => _cwd = path);
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

  Future<void> _importHostPaths(List<({String path, String name})> files) async {
    if (files.isEmpty) return;
    setState(() => _busy = true);
    var ok = 0;
    var failed = 0;
    try {
      for (final f in files) {
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
    // Android: category sheet → MIME → FileType so system media pickers show.
    final result = await pickHostFilesForUi(
      context,
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
      final name =
          item.name.trim().isEmpty ? p.basename(item.path) : item.name.trim();
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
    setState(() {
      if (_selected.contains(path)) {
        _selected.remove(path);
      } else {
        _selected.add(path);
      }
    });
  }

  void _selectOnly(String path) {
    setState(() {
      _selected
        ..clear()
        ..add(path);
    });
  }

  void _selectAll() {
    setState(() {
      _selected
        ..clear()
        ..addAll(_entries.map((e) => e.guestPath));
    });
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

    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        globalPosition & const Size(1, 1),
        Offset.zero & overlay.size,
      ),
      items: [
        if (single != null)
          PopupMenuItem(
            value: 'open',
            child: Text(single.isDirectory ? '打开' : '打开'),
          ),
        if (single != null)
          const PopupMenuItem(value: 'rename', child: Text('重命名')),
        if (hasSelection)
          const PopupMenuItem(value: 'copy', child: Text('复制')),
        if (hasSelection) const PopupMenuItem(value: 'cut', child: Text('剪切')),
        if (canPaste) const PopupMenuItem(value: 'paste', child: Text('粘贴')),
        if (hasSelection)
          const PopupMenuItem(value: 'delete', child: Text('删除')),
        if (_entries.isNotEmpty)
          const PopupMenuItem(value: 'select_all', child: Text('全选')),
        if (hasSelection)
          const PopupMenuItem(value: 'clear', child: Text('取消选择')),
      ],
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'open':
        if (single != null) {
          if (single.isDirectory) {
            await _openDir(single);
          } else {
            await _openFile(single);
          }
        }
      case 'rename':
        await _renameSelected();
      case 'copy':
        _copySelected(cut: false);
      case 'cut':
        _copySelected(cut: true);
      case 'paste':
        await _pasteClipboard();
      case 'delete':
        await _deleteSelected();
      case 'select_all':
        _selectAll();
      case 'clear':
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
      _selected
        ..clear()
        ..add(dest);
      await _load();
      _snack('已重命名为 ${sanitizeInboxFileName(name)}');
    } catch (e) {
      _snack('重命名失败：$e', error: true);
    } finally {
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
      _selected.clear();
      final clip = _clipboard;
      if (clip != null) {
        final remain =
            clip.paths.where((p) => !paths.contains(p)).toList(growable: false);
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
      _selected.clear();
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
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
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
              onPressed:
                  _actionsEnabled ? () => _copySelected(cut: true) : null,
              icon: const Icon(Icons.content_cut),
            ),
            IconButton(
              tooltip: '删除',
              onPressed: _actionsEnabled ? _deleteSelected : null,
              icon: const Icon(Icons.delete_outline),
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
            icon: const Icon(Icons.create_new_folder_outlined),
          ),
          if (showProjectJump)
            IconButton(
              tooltip: '跳到当前项目',
              onPressed: _actionsEnabled ? _jumpToProject : null,
              icon: const Icon(Icons.folder_special_outlined),
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
                Material(
                  color: scheme.surfaceContainerHigh,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    child: Row(
                      children: [
                        IconButton(
                          tooltip: '上一级',
                          onPressed:
                              !_actionsEnabled || !_canGoUp ? null : _goUp,
                          icon: const Icon(Icons.arrow_upward),
                        ),
                        Expanded(
                          child: SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: Text(
                              _relativeLabel,
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(fontFamily: 'monospace'),
                            ),
                          ),
                        ),
                        if (dropEnabled)
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: Text(
                              '可拖拽导入',
                              style: Theme.of(context).textTheme.labelSmall
                                  ?.copyWith(color: scheme.onSurfaceVariant),
                            ),
                          ),
                      ],
                    ),
                  ),
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
              Text(
                '无法打开目录',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
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
        final sizeLabel =
            entry.isDirectory ? null : _formatSize(entry.sizeBytes);
        final kind = entry.isDirectory
            ? null
            : guestMediaKindForPath(entry.guestPath);
        return GestureDetector(
          onSecondaryTapDown: (details) {
            unawaited(
              _showContextMenu(details.globalPosition, entry: entry),
            );
          },
          onLongPressStart: (details) {
            unawaited(
              _showContextMenu(details.globalPosition, entry: entry),
            );
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

class _FilePreviewScreen extends StatefulWidget {
  const _FilePreviewScreen({
    required this.provider,
    required this.workspaceId,
    required this.guestPath,
  });

  final SandboxProvider provider;
  final String workspaceId;
  final String guestPath;

  @override
  State<_FilePreviewScreen> createState() => _FilePreviewScreenState();
}

class _FilePreviewScreenState extends State<_FilePreviewScreen> {
  bool _loading = true;
  bool _editing = false;
  bool _saving = false;
  GuestMediaKind _kind = GuestMediaKind.binary;
  String? _error;
  String? _text;
  GuestMediaSource? _media;
  late final TextEditingController _editCtrl;

  @override
  void initState() {
    super.initState();
    _editCtrl = TextEditingController();
    _load();
  }

  @override
  void dispose() {
    _editCtrl.dispose();
    unawaited(_media?.dispose() ?? Future<void>.value());
    super.dispose();
  }

  String get _fileName {
    final parts = widget.guestPath.split('/');
    return parts.isEmpty ? widget.guestPath : parts.last;
  }

  bool get _isText => _kind == GuestMediaKind.text;
  bool get _isMedia =>
      _kind == GuestMediaKind.image ||
      _kind == GuestMediaKind.video ||
      _kind == GuestMediaKind.audio;

  Future<void> _load() async {
    final previous = _media;
    _media = null;
    unawaited(previous?.dispose() ?? Future<void>.value());

    setState(() {
      _loading = true;
      _error = null;
      _editing = false;
      _text = null;
      _kind = guestMediaKindForPath(widget.guestPath);
    });

    try {
      if (_isMedia) {
        final source = await openGuestMediaSource(
          provider: widget.provider,
          workspaceId: widget.workspaceId,
          guestAbsolutePath: widget.guestPath,
          loadBytes: _kind == GuestMediaKind.image ||
              _kind == GuestMediaKind.audio,
        );
        if (!mounted) {
          await source.dispose();
          return;
        }
        setState(() {
          _media = source;
          _loading = false;
        });
        return;
      }

      final bytes = await widget.provider.readGuestFile(
        widget.workspaceId,
        widget.guestPath,
      );
      if (!mounted) return;
      if (bytes == null) {
        setState(() {
          _loading = false;
          _error = '文件不存在或无法读取';
        });
        return;
      }

      final treatAsText =
          _kind == GuestMediaKind.text || looksLikeTextBytes(bytes);
      if (!treatAsText) {
        setState(() {
          _loading = false;
          _kind = GuestMediaKind.binary;
        });
        return;
      }

      final text = utf8.decode(bytes, allowMalformed: true);
      _editCtrl.text = text;
      setState(() {
        _loading = false;
        _kind = GuestMediaKind.text;
        _text = text;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await widget.provider.writeGuestFile(
        widget.workspaceId,
        widget.guestPath,
        utf8.encode(_editCtrl.text),
      );
      if (!mounted) return;
      setState(() {
        _text = _editCtrl.text;
        _editing = false;
        _saving = false;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('已保存')));
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('保存失败：$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_fileName, maxLines: 1, overflow: TextOverflow.ellipsis),
            Text(
              widget.guestPath,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        actions: [
          if (!_loading && _isText && _error == null && _text != null) ...[
            if (_editing) ...[
              IconButton(
                tooltip: '取消',
                onPressed: _saving
                    ? null
                    : () {
                        _editCtrl.text = _text ?? '';
                        setState(() => _editing = false);
                      },
                icon: const Icon(Icons.close),
              ),
              IconButton(
                tooltip: '保存',
                onPressed: _saving ? null : _save,
                icon: _saving
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.save_outlined),
              ),
            ] else
              IconButton(
                tooltip: '编辑',
                onPressed: () => setState(() => _editing = true),
                icon: const Icon(Icons.edit_outlined),
              ),
          ],
          IconButton(
            tooltip: '刷新',
            onPressed: _loading || _saving ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _buildBody(scheme),
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
          child: Text(
            _error!,
            textAlign: TextAlign.center,
            style: TextStyle(color: scheme.error),
          ),
        ),
      );
    }

    final media = _media;
    if (_isMedia && media != null) {
      switch (_kind) {
        case GuestMediaKind.image:
          return GuestImagePreview(source: media);
        case GuestMediaKind.video:
          return GuestVideoPreview(source: media);
        case GuestMediaKind.audio:
          return GuestAudioPreview(source: media, title: _fileName);
        case GuestMediaKind.text:
        case GuestMediaKind.binary:
          break;
      }
    }

    if (_kind == GuestMediaKind.binary) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            '暂不支持预览此类型文件',
            style: Theme.of(
              context,
            ).textTheme.bodyLarge?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ),
      );
    }

    if (_editing) {
      return Padding(
        padding: const EdgeInsets.all(12),
        child: TextField(
          controller: _editCtrl,
          maxLines: null,
          expands: true,
          textAlignVertical: TextAlignVertical.top,
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(fontFamily: 'monospace'),
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            contentPadding: EdgeInsets.all(12),
          ),
        ),
      );
    }
    final language = highlightLanguageForPath(widget.guestPath);
    final theme = highlightThemeForBrightness(scheme.brightness);
    return SelectableHighlightView(
      source: _text ?? '',
      language: language,
      theme: theme,
    );
  }
}
