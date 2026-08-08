import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import 'package:vault/sandbox/sandbox_provider.dart';
import 'package:vault/screens/terminal_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.provider});

  final SandboxProvider provider;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  SandboxCapabilities? _caps;
  List<SandboxInfo> _sessions = const [];
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final caps = await widget.provider.probe();
      final sessions = caps.available
          ? await widget.provider.list()
          : const <SandboxInfo>[];
      if (!mounted) return;
      setState(() {
        _caps = caps;
        _sessions = sessions;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _createSession() async {
    if (_caps?.available != true) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final id = const Uuid().v4().replaceAll('-', '').substring(0, 12);
    try {
      final session = await widget.provider.create(id);
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => TerminalScreen(
            title: '会话 $id',
            session: session,
          ),
        ),
      );
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openSession(SandboxInfo info) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final session = await widget.provider.attach(info.sessionId);
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => TerminalScreen(
            title: info.displayName,
            session: session,
          ),
        ),
      );
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _destroySession(SandboxInfo info) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除会话？'),
        content: Text(
          '将执行 wsl --unregister 注销 ${info.displayName}，并删除其磁盘文件。'
          '通常可回收约 1 GB 空间。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.provider.destroy(info.sessionId);
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _formatBytes(int? bytes) {
    if (bytes == null) return '大小未知';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  @override
  Widget build(BuildContext context) {
    final caps = _caps;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Vault'),
        actions: [
          IconButton(
            onPressed: _busy ? null : _refresh,
            icon: const Icon(Icons.refresh),
            tooltip: '刷新',
          ),
        ],
      ),
      floatingActionButton: caps?.available == true
          ? FloatingActionButton.extended(
              onPressed: _busy ? null : _createSession,
              icon: const Icon(Icons.add),
              label: const Text('新建会话'),
            )
          : null,
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_busy) const LinearProgressIndicator(),
          if (_error != null) ...[
            MaterialBanner(
              content: Text(_error!),
              actions: [
                TextButton(
                  onPressed: () => setState(() => _error = null),
                  child: const Text('关闭'),
                ),
              ],
            ),
            const SizedBox(height: 8),
          ],
          if (caps != null) _CapabilitiesCard(caps: caps),
          const SizedBox(height: 16),
          Text('会话列表', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          if (_sessions.isEmpty)
            const Text('暂无会话。')
          else
            ..._sessions.map(
              (s) => Card(
                child: ListTile(
                  title: Text(s.displayName),
                  subtitle: Text(
                    '${s.createdAt.toLocal()} · ${_formatBytes(s.approxDiskBytes)}',
                  ),
                  onTap: _busy ? null : () => _openSession(s),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline),
                    tooltip: '删除',
                    onPressed: _busy ? null : () => _destroySession(s),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _CapabilitiesCard extends StatelessWidget {
  const _CapabilitiesCard({required this.caps});

  final SandboxCapabilities caps;

  String get _backendLabel => switch (caps.backend) {
        SandboxBackend.wsl => 'WSL',
        SandboxBackend.proot => 'proot',
        SandboxBackend.unsupported => '不支持',
      };

  @override
  Widget build(BuildContext context) {
    final color = caps.available
        ? Theme.of(context).colorScheme.primaryContainer
        : Theme.of(context).colorScheme.errorContainer;
    return Card(
      color: color,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              caps.available
                  ? '沙箱就绪（$_backendLabel，${caps.architecture}）'
                  : '沙箱不可用',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            if (caps.hint != null) ...[
              const SizedBox(height: 8),
              Text(caps.hint!),
            ],
            for (final note in caps.notes) ...[
              const SizedBox(height: 6),
              Text('• $note'),
            ],
          ],
        ),
      ),
    );
  }
}
