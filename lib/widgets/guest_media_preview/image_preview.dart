import 'package:flutter/material.dart';
import 'package:vault/sandbox/guest_media_source.dart';

/// Interactive image preview (pinch-ish via InteractiveViewer).
class GuestImagePreview extends StatelessWidget {
  const GuestImagePreview({super.key, required this.source});

  final GuestMediaSource source;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bytes = source.bytes;
    final ImageProvider provider = bytes != null
        ? MemoryImage(bytes)
        : FileImage(source.hostFile);

    return ColoredBox(
      color: scheme.surfaceContainerLowest,
      child: InteractiveViewer(
        minScale: 0.5,
        maxScale: 8,
        child: Center(
          child: Image(
            image: provider,
            fit: BoxFit.contain,
            errorBuilder: (context, error, stack) {
              return Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  '无法解码图片：$error',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: scheme.error),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
