import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:vault/sandbox/guest_media_source.dart';

/// Audio player with play/pause + progress.
class GuestAudioPreview extends StatefulWidget {
  const GuestAudioPreview({super.key, required this.source, this.title});

  final GuestMediaSource source;
  final String? title;

  @override
  State<GuestAudioPreview> createState() => _GuestAudioPreviewState();
}

class _GuestAudioPreviewState extends State<GuestAudioPreview> {
  late final AudioPlayer _player;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _ready = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _player = AudioPlayer();
    _player.onPositionChanged.listen((d) {
      if (mounted) setState(() => _position = d);
    });
    _player.onDurationChanged.listen((d) {
      if (mounted) setState(() => _duration = d);
    });
    _player.onPlayerStateChanged.listen((_) {
      if (mounted) setState(() {});
    });
    _open();
  }

  Future<void> _open() async {
    try {
      final bytes = widget.source.bytes;
      if (bytes != null) {
        await _player.setSourceBytes(bytes);
      } else {
        await _player.setSourceDeviceFile(widget.source.hostFile.path);
      }
      final duration = await _player.getDuration();
      if (!mounted) return;
      setState(() {
        _duration = duration ?? Duration.zero;
        _ready = true;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            '无法播放音频：$_error',
            textAlign: TextAlign.center,
            style: TextStyle(color: scheme.error),
          ),
        ),
      );
    }
    if (!_ready) return const Center(child: CircularProgressIndicator());

    final playing = _player.state == PlayerState.playing;
    final maxMilliseconds = _duration.inMilliseconds <= 0
        ? 1.0
        : _duration.inMilliseconds.toDouble();
    final fallbackTitle = widget.source.hostFile.uri.pathSegments.isEmpty
        ? widget.source.hostFile.path
        : widget.source.hostFile.uri.pathSegments.last;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.audiotrack, size: 72, color: scheme.primary),
              const SizedBox(height: 16),
              Text(
                widget.title ?? fallbackTitle,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton.filled(
                    tooltip: playing ? '暂停' : '播放',
                    iconSize: 36,
                    onPressed: () async {
                      if (playing) {
                        await _player.pause();
                      } else {
                        await _player.resume();
                      }
                    },
                    icon: Icon(playing ? Icons.pause : Icons.play_arrow),
                  ),
                  const SizedBox(width: 12),
                  IconButton(
                    tooltip: '停止',
                    onPressed: () async {
                      await _player.stop();
                      await _player.seek(Duration.zero);
                    },
                    icon: const Icon(Icons.stop),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                '${_formatDuration(_position)} / '
                '${_formatDuration(_duration)}',
                style: Theme.of(context).textTheme.labelMedium,
              ),
              Slider(
                value: _position.inMilliseconds
                    .clamp(0, maxMilliseconds.toInt())
                    .toDouble(),
                max: maxMilliseconds,
                onChanged: (value) async {
                  await _player.seek(Duration(milliseconds: value.round()));
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}
