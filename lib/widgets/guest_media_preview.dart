import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:vault/sandbox/guest_media_source.dart';
import 'package:video_player/video_player.dart';

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

/// Video player with play/pause + progress.
class GuestVideoPreview extends StatefulWidget {
  const GuestVideoPreview({super.key, required this.source});

  final GuestMediaSource source;

  @override
  State<GuestVideoPreview> createState() => _GuestVideoPreviewState();
}

class _GuestVideoPreviewState extends State<GuestVideoPreview> {
  late final VideoPlayerController _controller;
  bool _ready = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.file(widget.source.hostFile)
      ..setLooping(true);
    _controller
        .initialize()
        .then((_) {
          if (!mounted) return;
          setState(() => _ready = true);
          _controller.play();
        })
        .catchError((Object e) {
          if (!mounted) return;
          setState(() => _error = e.toString());
        });
    _controller.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    final h = d.inHours;
    if (h > 0) return '$h:$m:$s';
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            '无法播放视频：$_error',
            textAlign: TextAlign.center,
            style: TextStyle(color: scheme.error),
          ),
        ),
      );
    }
    if (!_ready) {
      return const Center(child: CircularProgressIndicator());
    }

    final value = _controller.value;
    final pos = value.position;
    final dur = value.duration;
    final maxMs = dur.inMilliseconds <= 0 ? 1.0 : dur.inMilliseconds.toDouble();

    return ColoredBox(
      color: Colors.black,
      child: Column(
        children: [
          Expanded(
            child: Center(
              child: AspectRatio(
                aspectRatio: value.aspectRatio == 0 ? 16 / 9 : value.aspectRatio,
                child: VideoPlayer(_controller),
              ),
            ),
          ),
          Material(
            color: scheme.surfaceContainerHigh,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
              child: Column(
                children: [
                  Row(
                    children: [
                      IconButton(
                        tooltip: value.isPlaying ? '暂停' : '播放',
                        onPressed: () {
                          if (value.isPlaying) {
                            _controller.pause();
                          } else {
                            _controller.play();
                          }
                        },
                        icon: Icon(
                          value.isPlaying ? Icons.pause : Icons.play_arrow,
                        ),
                      ),
                      Text(
                        '${_fmt(pos)} / ${_fmt(dur)}',
                        style: Theme.of(context).textTheme.labelMedium,
                      ),
                    ],
                  ),
                  Slider(
                    value: pos.inMilliseconds.clamp(0, maxMs.toInt()).toDouble(),
                    max: maxMs,
                    onChanged: (v) {
                      _controller.seekTo(Duration(milliseconds: v.round()));
                    },
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Audio player with play/pause + progress.
class GuestAudioPreview extends StatefulWidget {
  const GuestAudioPreview({
    super.key,
    required this.source,
    this.title,
  });

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
      final dur = await _player.getDuration();
      if (!mounted) return;
      setState(() {
        _duration = dur ?? Duration.zero;
        _ready = true;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    }
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
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
    if (!_ready) {
      return const Center(child: CircularProgressIndicator());
    }

    final playing = _player.state == PlayerState.playing;
    final maxMs =
        _duration.inMilliseconds <= 0 ? 1.0 : _duration.inMilliseconds.toDouble();

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
                widget.title ??
                    (widget.source.hostFile.uri.pathSegments.isEmpty
                        ? widget.source.hostFile.path
                        : widget.source.hostFile.uri.pathSegments.last),
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
                '${_fmt(_position)} / ${_fmt(_duration)}',
                style: Theme.of(context).textTheme.labelMedium,
              ),
              Slider(
                value: _position.inMilliseconds
                    .clamp(0, maxMs.toInt())
                    .toDouble(),
                max: maxMs,
                onChanged: (v) async {
                  await _player.seek(Duration(milliseconds: v.round()));
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}