import 'dart:async';

import 'package:flutter/material.dart';
import 'package:vault/agent/site_browser_log.dart';
import 'package:vault/agent/site_gateway.dart';

const Duration kSiteLogPagePollInterval = Duration(seconds: 2);

const kSiteLogEmptyProcessHint = '还没有日志，站点可能尚未启动过';
const kSiteLogEmptyEventsHint = '页面尚未加载采集脚本，或用户还没打开站点';

String formatSiteLogEvent(SiteBrowserEvent event) {
  final local = event.at.toLocal();
  final hh = local.hour.toString().padLeft(2, '0');
  final mm = local.minute.toString().padLeft(2, '0');
  final ss = local.second.toString().padLeft(2, '0');
  final count = event.count > 1 ? ' ×${event.count}' : '';
  return '$hh:$mm:$ss  ${event.level}  ${event.type}$count  ${event.message}';
}

class SiteLogsScreen extends StatefulWidget {
  const SiteLogsScreen({
    super.key,
    required this.title,
    required this.loadProcessLog,
    required this.loadEvents,
    this.pollInterval = kSiteLogPagePollInterval,
  });

  final String title;
  final Future<String?> Function() loadProcessLog;
  final Future<List<SiteBrowserEvent>> Function() loadEvents;
  final Duration pollInterval;

  @override
  State<SiteLogsScreen> createState() => _SiteLogsScreenState();
}

class _SiteLogsScreenState extends State<SiteLogsScreen> {
  Timer? _pollTimer;
  bool _loading = true;
  String? _error;
  String? _processLog;
  List<SiteBrowserEvent> _events = const [];

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
    if (widget.pollInterval > Duration.zero) {
      _pollTimer = Timer.periodic(widget.pollInterval, (_) {
        unawaited(_refresh());
      });
    }
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final log = await widget.loadProcessLog();
      final events = await widget.loadEvents();
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = null;
        _processLog = log;
        _events = events;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '站点日志',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              Text(
                widget.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          bottom: const TabBar(
            tabs: [
              Tab(text: '进程日志'),
              Tab(text: '浏览器 / 网关'),
            ],
          ),
        ),
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : TabBarView(
                      children: [
                        _LogPane(
                          text: _processBody(),
                          empty: _processLog == null || _processLog!.isEmpty,
                        ),
                        _LogPane(
                          text: _eventsBody(),
                          empty: _events.isEmpty,
                        ),
                      ],
                    ),
            ),
            Material(
              color: scheme.surfaceContainerHighest,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
                child: Text(
                  kSiteGatewayHttpOnlyCaption,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _processBody() {
    if (_error != null) return _error!;
    final log = _processLog?.trim();
    if (log == null || log.isEmpty) return kSiteLogEmptyProcessHint;
    return log;
  }

  String _eventsBody() {
    if (_error != null) return _error!;
    if (_events.isEmpty) return kSiteLogEmptyEventsHint;
    return _events.map(formatSiteLogEvent).join('\n');
  }
}

class _LogPane extends StatelessWidget {
  const _LogPane({required this.text, required this.empty});

  final String text;
  final bool empty;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scrollbar(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: SelectableText(
          text,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            fontFamily: 'monospace',
            color: empty ? scheme.onSurfaceVariant : scheme.onSurface,
          ),
        ),
      ),
    );
  }
}
