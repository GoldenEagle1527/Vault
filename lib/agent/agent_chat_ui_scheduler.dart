import 'package:flutter/scheduler.dart';

typedef AgentChatUiFrameScheduler = void Function(FrameCallback callback);

/// Coalesces chat transcript rebuilds so streaming deltas paint once per frame.
class AgentChatUiScheduler {
  AgentChatUiScheduler({required this.onFlush, this.scheduleFrame});

  final void Function() onFlush;
  final AgentChatUiFrameScheduler? scheduleFrame;

  int _generation = 0;
  bool _scheduled = false;
  bool _disposed = false;

  bool get isScheduled => _scheduled;

  void schedule() {
    if (_disposed || _scheduled) return;
    _scheduled = true;
    final generation = _generation;
    final custom = scheduleFrame;
    if (custom != null) {
      custom((elapsed) => _onFrame(elapsed, generation));
      return;
    }
    final binding = SchedulerBinding.instance;
    binding.scheduleFrameCallback((elapsed) => _onFrame(elapsed, generation));
    binding.ensureVisualUpdate();
  }

  void flushNow() {
    if (_disposed) return;
    _generation++;
    _scheduled = false;
    onFlush();
  }

  void cancel() {
    _generation++;
    _scheduled = false;
  }

  void dispose() {
    _disposed = true;
    cancel();
  }

  void _onFrame(Duration _, int generation) {
    if (_disposed || generation != _generation) {
      return;
    }
    _scheduled = false;
    onFlush();
  }
}
