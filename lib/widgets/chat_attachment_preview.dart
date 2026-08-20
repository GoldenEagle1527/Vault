import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:vault/sandbox/guest_media_kind.dart';
import 'package:vault/sandbox/guest_media_source.dart';
import 'package:vault/sandbox/sandbox_provider.dart';
import 'package:vault/widgets/guest_media_preview.dart';

/// Thumbnail / filename chip for composer pending files and chat bubbles.
class ChatAttachmentTile extends StatefulWidget {
  const ChatAttachmentTile({
    super.key,
    required this.displayName,
    required this.kind,
    this.bytes,
    this.hostPath,
    this.guestPath,
    this.provider,
    this.workspaceId,
    this.onRemove,
    this.size = 80,
  });

  final String displayName;
  final GuestMediaKind kind;
  final Uint8List? bytes;
  final String? hostPath;
  final String? guestPath;
  final SandboxProvider? provider;
  final String? workspaceId;
  final VoidCallback? onRemove;
  final double size;

  bool get isMedia =>
      kind == GuestMediaKind.image ||
      kind == GuestMediaKind.video ||
      kind == GuestMediaKind.audio;

  @override
  State<ChatAttachmentTile> createState() => _ChatAttachmentTileState();
}

class _ChatAttachmentTileState extends State<ChatAttachmentTile> {
  Uint8List? _loadedBytes;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _maybeLoadGuest();
  }

  @override
  void didUpdateWidget(covariant ChatAttachmentTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.guestPath != widget.guestPath ||
        oldWidget.bytes != widget.bytes) {
      _loadedBytes = null;
      _maybeLoadGuest();
    }
  }

  Future<void> _maybeLoadGuest() async {
    if (widget.bytes != null || widget.hostPath != null) return;
    if (!widget.isMedia) return;
    final provider = widget.provider;
    final workspaceId = widget.workspaceId;
    final guestPath = widget.guestPath;
    if (provider == null || workspaceId == null || guestPath == null) return;
    setState(() => _loading = true);
    try {
      final bytes = await provider.readGuestFile(workspaceId, guestPath);
      if (!mounted) return;
      setState(() {
        _loadedBytes = bytes;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  Uint8List? get _bytes => widget.bytes ?? _loadedBytes;

  Future<void> _open() async {
    if (!widget.isMedia) return;
    final kind = widget.kind;
    if (kind == GuestMediaKind.image) {
      final bytes = _bytes;
      ImageProvider? image;
      if (bytes != null) {
        image = MemoryImage(bytes);
      } else if (widget.hostPath != null) {
        image = FileImage(File(widget.hostPath!));
      }
      if (image == null) return;
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) {
          return Dialog(
            insetPadding: const EdgeInsets.all(16),
            child: SizedBox(
              width: MediaQuery.sizeOf(context).width * 0.92,
              height: MediaQuery.sizeOf(context).height * 0.8,
              child: InteractiveViewer(
                minScale: 0.5,
                maxScale: 8,
                child: Center(
                  child: Image(image: image!, fit: BoxFit.contain),
                ),
              ),
            ),
          );
        },
      );
      return;
    }

    final provider = widget.provider;
    final workspaceId = widget.workspaceId;
    final guestPath = widget.guestPath;
    if (provider != null && workspaceId != null && guestPath != null) {
      final source = await openGuestMediaSource(
        provider: provider,
        workspaceId: workspaceId,
        guestAbsolutePath: guestPath,
        loadBytes: kind == GuestMediaKind.audio,
      );
      if (!mounted) {
        await source.dispose();
        return;
      }
      await _openMediaSource(source, kind);
      await source.dispose();
      return;
    }

    final host = widget.hostPath;
    if (host == null) return;
    final source = GuestMediaSource.hostFile(File(host));
    await _openMediaSource(source, kind);
  }

  Future<void> _openMediaSource(
    GuestMediaSource source,
    GuestMediaKind kind,
  ) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) {
        return Dialog(
          insetPadding: const EdgeInsets.all(8),
          child: SizedBox(
            width: MediaQuery.sizeOf(context).width * 0.94,
            height: MediaQuery.sizeOf(context).height * 0.82,
            child: kind == GuestMediaKind.video
                ? GuestVideoPreview(
                    source: source,
                    title: widget.displayName,
                    onClose: () => Navigator.of(context).pop(),
                  )
                : GuestAudioPreview(source: source, title: widget.displayName),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (!widget.isMedia) {
      return InputChip(
        label: Text(widget.displayName),
        onDeleted: widget.onRemove,
        onPressed: null,
      );
    }

    final bytes = _bytes;
    Widget thumb;
    if (_loading) {
      thumb = const Center(
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    } else if (widget.kind == GuestMediaKind.image &&
        (bytes != null || widget.hostPath != null)) {
      final ImageProvider image = bytes != null
          ? MemoryImage(bytes)
          : FileImage(File(widget.hostPath!));
      thumb = Image(
        image: image,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) =>
            Icon(Icons.broken_image_outlined, color: scheme.onSurfaceVariant),
      );
    } else {
      thumb = Icon(
        widget.kind == GuestMediaKind.video
            ? Icons.videocam_outlined
            : Icons.audiotrack_outlined,
        color: scheme.onSurfaceVariant,
      );
    }

    return Stack(
      clipBehavior: Clip.none,
      children: [
        Material(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(10),
          child: InkWell(
            onTap: _open,
            borderRadius: BorderRadius.circular(10),
            child: Ink(
              width: widget.size,
              height: widget.size,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: scheme.outlineVariant),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(9),
                child: thumb,
              ),
            ),
          ),
        ),
        if (widget.onRemove != null)
          Positioned(
            top: -8,
            right: -8,
            child: IconButton.filledTonal(
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              padding: EdgeInsets.zero,
              iconSize: 16,
              onPressed: widget.onRemove,
              icon: const Icon(Icons.close),
            ),
          ),
      ],
    );
  }
}
