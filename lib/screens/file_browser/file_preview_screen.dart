import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:vault/sandbox/guest_code_highlight.dart';
import 'package:vault/sandbox/guest_media_kind.dart';
import 'package:vault/sandbox/guest_media_source.dart';
import 'package:vault/sandbox/sandbox_provider.dart';
import 'package:vault/util/guest_export.dart';
import 'package:vault/widgets/guest_media_preview.dart';

class FilePreviewScreen extends StatefulWidget {
  const FilePreviewScreen({
    super.key,
    required this.provider,
    required this.workspaceId,
    required this.guestPath,
  });

  final SandboxProvider provider;
  final String workspaceId;
  final String guestPath;

  @override
  State<FilePreviewScreen> createState() => _FilePreviewScreenState();
}

class _FilePreviewScreenState extends State<FilePreviewScreen> {
  bool _loading = true;
  bool _editing = false;
  bool _saving = false;
  GuestMediaKind _kind = GuestMediaKind.binary;
  String? _error;
  String? _text;
  GuestMediaSource? _media;
  late final TextEditingController _editController;

  @override
  void initState() {
    super.initState();
    _editController = TextEditingController();
    _load();
  }

  @override
  void dispose() {
    _editController.dispose();
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
          loadBytes:
              _kind == GuestMediaKind.image || _kind == GuestMediaKind.audio,
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
      _editController.text = text;
      setState(() {
        _loading = false;
        _kind = GuestMediaKind.text;
        _text = text;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  Future<void> _export(GuestExportMode mode) async {
    try {
      final result = await GuestExport(
        provider: widget.provider,
        workspaceId: widget.workspaceId,
      ).run(mode: mode, guestPaths: [widget.guestPath]);
      if (!mounted || result.cancelled) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(result.message ?? '已导出'),
          backgroundColor: result.failed > 0
              ? Theme.of(context).colorScheme.error
              : null,
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('导出失败：$error')));
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await widget.provider.writeGuestFile(
        widget.workspaceId,
        widget.guestPath,
        utf8.encode(_editController.text),
      );
      if (!mounted) return;
      setState(() {
        _text = _editController.text;
        _editing = false;
        _saving = false;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('已保存')));
    } catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('保存失败：$error')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final immersiveVideo =
        !_loading &&
        _error == null &&
        _kind == GuestMediaKind.video &&
        _media != null;
    if (immersiveVideo) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: GuestVideoPreview(
          source: _media!,
          title: _fileName,
          subtitle: widget.guestPath,
          onClose: () => Navigator.of(context).maybePop(),
        ),
      );
    }

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
              style: Theme.of(
                context,
              ).textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
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
                        _editController.text = _text ?? '';
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
            tooltip: '导出',
            onPressed: _loading || _saving
                ? null
                : () => unawaited(_export(GuestExportMode.saveAs)),
            icon: const Icon(Icons.download_outlined),
          ),
          IconButton(
            tooltip: '分享',
            onPressed: _loading || _saving
                ? null
                : () => unawaited(_export(GuestExportMode.share)),
            icon: const Icon(Icons.share_outlined),
          ),
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
    if (_loading) return const Center(child: CircularProgressIndicator());
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
          return GuestVideoPreview(
            source: media,
            title: _fileName,
            subtitle: widget.guestPath,
            onClose: () => Navigator.of(context).maybePop(),
          );
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
          controller: _editController,
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
    return SelectableHighlightView(
      source: _text ?? '',
      language: highlightLanguageForPath(widget.guestPath),
      theme: highlightThemeForBrightness(scheme.brightness),
    );
  }
}
