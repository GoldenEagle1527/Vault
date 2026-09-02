import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vault/sandbox/guest_media_source.dart';
import 'package:video_player/video_player.dart';

/// Immersive video player with overlay chrome + keyboard shortcuts.
///
/// Shortcuts: Space/K play/pause · ←/→ or J/L ±5s · Esc close.
class GuestVideoPreview extends StatefulWidget {
  const GuestVideoPreview({
    super.key,
    required this.source,
    this.title,
    this.subtitle,
    this.onClose,
  });

  final GuestMediaSource source;
  final String? title;
  final String? subtitle;
  final VoidCallback? onClose;

  @override
  State<GuestVideoPreview> createState() => _GuestVideoPreviewState();
}

class _GuestVideoPreviewState extends State<GuestVideoPreview> {
  static const _seekStep = Duration(seconds: 5);
  static const _chromeHideDelay = Duration(seconds: 2);
  static const _tickMinInterval = Duration(milliseconds: 250);

  late final VideoPlayerController _controller;
  late final FocusNode _focusNode;
  Timer? _hideTimer;
  DateTime? _lastUiTick;
  bool? _lastPlaying;
  bool _ready = false;
  bool _showChrome = true;
  bool _dragging = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode(debugLabel: 'GuestVideoPreview');
    _controller = VideoPlayerController.file(widget.source.hostFile)
      ..setLooping(true);
    _controller
        .initialize()
        .then((_) {
          if (!mounted) return;
          setState(() => _ready = true);
          _controller.play();
          _scheduleHideChrome();
        })
        .catchError((Object error) {
          if (mounted) setState(() => _error = error.toString());
        });
    _controller.addListener(_onControllerTick);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  void _onControllerTick() {
    if (!mounted) return;
    final playing = _controller.value.isPlaying;
    final playingChanged = _lastPlaying != playing;
    _lastPlaying = playing;
    if (!_showChrome && !playingChanged && !_dragging) return;
    final now = DateTime.now();
    if (!playingChanged &&
        !_dragging &&
        _lastUiTick != null &&
        now.difference(_lastUiTick!) < _tickMinInterval) {
      return;
    }
    _lastUiTick = now;
    setState(() {});
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _controller.removeListener(_onControllerTick);
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _revealChrome({bool autoHide = true}) {
    setState(() => _showChrome = true);
    if (autoHide) {
      _scheduleHideChrome();
    } else {
      _hideTimer?.cancel();
    }
  }

  void _scheduleHideChrome() {
    _hideTimer?.cancel();
    if (!_controller.value.isPlaying || _dragging) return;
    _hideTimer = Timer(_chromeHideDelay, () {
      if (!mounted || !_controller.value.isPlaying || _dragging) return;
      setState(() => _showChrome = false);
    });
  }

  Future<void> _togglePlay() async {
    if (!_ready) return;
    if (_controller.value.isPlaying) {
      await _controller.pause();
      _revealChrome(autoHide: false);
    } else {
      await _controller.play();
      _revealChrome();
    }
  }

  Future<void> _seekBy(Duration delta) async {
    if (!_ready) return;
    final value = _controller.value;
    final next = value.position + delta;
    final clamped = next < Duration.zero
        ? Duration.zero
        : (next > value.duration ? value.duration : next);
    await _controller.seekTo(clamped);
    _revealChrome();
  }

  void _close() {
    if (widget.onClose != null) {
      widget.onClose!();
    } else {
      Navigator.of(context).maybePop();
    }
  }

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (duration.inHours > 0) {
      return '${duration.inHours}:$minutes:$seconds';
    }
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (_error != null) {
      return ColoredBox(
        color: Colors.black,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              '无法播放视频：$_error',
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.error),
            ),
          ),
        ),
      );
    }
    if (!_ready) {
      return const ColoredBox(
        color: Colors.black,
        child: Center(child: CircularProgressIndicator()),
      );
    }

    final value = _controller.value;
    final maxMilliseconds = value.duration.inMilliseconds <= 0
        ? 1.0
        : value.duration.inMilliseconds.toDouble();
    final progress = value.position.inMilliseconds
        .clamp(0, maxMilliseconds.toInt())
        .toDouble();

    return ExcludeSemantics(
      child: CallbackShortcuts(
        bindings: <ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.space): _togglePlay,
          const SingleActivator(LogicalKeyboardKey.keyK): _togglePlay,
          const SingleActivator(LogicalKeyboardKey.escape): _close,
          const SingleActivator(LogicalKeyboardKey.arrowLeft): () {
            unawaited(_seekBy(-_seekStep));
          },
          const SingleActivator(LogicalKeyboardKey.arrowRight): () {
            unawaited(_seekBy(_seekStep));
          },
          const SingleActivator(LogicalKeyboardKey.keyJ): () {
            unawaited(_seekBy(-_seekStep));
          },
          const SingleActivator(LogicalKeyboardKey.keyL): () {
            unawaited(_seekBy(_seekStep));
          },
        },
        child: Focus(
          focusNode: _focusNode,
          autofocus: true,
          child: MouseRegion(
            onHover: (_) {
              if (!_focusNode.hasFocus) _focusNode.requestFocus();
              _revealChrome();
            },
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                if (_showChrome) {
                  unawaited(_togglePlay());
                } else {
                  _revealChrome();
                }
              },
              child: ColoredBox(
                color: Colors.black,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Center(
                      child: AspectRatio(
                        aspectRatio: value.aspectRatio == 0
                            ? 16 / 9
                            : value.aspectRatio,
                        child: VideoPlayer(_controller),
                      ),
                    ),
                    if (!value.isPlaying)
                      Center(
                        child: IgnorePointer(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.45),
                              shape: BoxShape.circle,
                            ),
                            child: const Padding(
                              padding: EdgeInsets.all(18),
                              child: Icon(
                                Icons.play_arrow_rounded,
                                size: 56,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ),
                      ),
                    AnimatedOpacity(
                      opacity: _showChrome ? 1 : 0,
                      duration: const Duration(milliseconds: 180),
                      child: IgnorePointer(
                        ignoring: !_showChrome,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            _buildHeader(context),
                            _buildControls(
                              context,
                              value,
                              progress,
                              maxMilliseconds,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    final topPadding = MediaQuery.paddingOf(context).top;
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.black.withValues(alpha: 0.72), Colors.transparent],
          ),
        ),
        child: SafeArea(
          bottom: false,
          child: Padding(
            padding: EdgeInsets.fromLTRB(4, topPadding > 0 ? 0 : 4, 8, 28),
            child: Row(
              children: [
                IconButton(
                  onPressed: _close,
                  icon: const Icon(Icons.arrow_back, color: Colors.white),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.title ?? '视频',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                          fontVariations: [FontVariation.weight(600)],
                          fontSize: 15,
                        ),
                      ),
                      if (widget.subtitle != null)
                        Text(
                          widget.subtitle!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.65),
                            fontSize: 11,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildControls(
    BuildContext context,
    VideoPlayerValue value,
    double progress,
    double maxMilliseconds,
  ) {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [Colors.black.withValues(alpha: 0.78), Colors.transparent],
          ),
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 36, 12, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 3,
                    thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 7,
                    ),
                    overlayShape: const RoundSliderOverlayShape(
                      overlayRadius: 14,
                    ),
                    activeTrackColor: Colors.white,
                    inactiveTrackColor: Colors.white24,
                    thumbColor: Colors.white,
                    overlayColor: Colors.white24,
                  ),
                  child: Slider(
                    value: progress,
                    max: maxMilliseconds,
                    onChangeStart: (_) {
                      _dragging = true;
                      _revealChrome(autoHide: false);
                    },
                    onChanged: (position) {
                      unawaited(
                        _controller.seekTo(
                          Duration(milliseconds: position.round()),
                        ),
                      );
                    },
                    onChangeEnd: (_) {
                      _dragging = false;
                      _scheduleHideChrome();
                    },
                  ),
                ),
                Row(
                  children: [
                    IconButton(
                      onPressed: () => unawaited(_togglePlay()),
                      icon: Icon(
                        value.isPlaying
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                        color: Colors.white,
                        size: 28,
                      ),
                    ),
                    IconButton(
                      onPressed: () => unawaited(_seekBy(-_seekStep)),
                      icon: const Icon(
                        Icons.replay_5_rounded,
                        color: Colors.white70,
                      ),
                    ),
                    IconButton(
                      onPressed: () => unawaited(_seekBy(_seekStep)),
                      icon: const Icon(
                        Icons.forward_5_rounded,
                        color: Colors.white70,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '${_formatDuration(value.position)} / '
                      '${_formatDuration(value.duration)}',
                      style: const TextStyle(
                        color: Colors.white70,
                        fontFeatures: [FontFeature.tabularFigures()],
                        fontSize: 13,
                      ),
                    ),
                    const Spacer(),
                    if (MediaQuery.sizeOf(context).width > 560)
                      Text(
                        '空格 播放 · ←→ 快进 · Esc 返回',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.45),
                          fontSize: 11,
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
