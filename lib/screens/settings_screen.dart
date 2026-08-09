import 'package:flutter/material.dart';
import 'package:vault/agent/agent_settings.dart';

class SettingsScreen extends StatefulWidget {
  SettingsScreen({super.key, AgentSettingsStore? store, this.embedded = false})
    : store = store ?? AgentSettingsStore();

  final AgentSettingsStore store;

  /// When true, omit the scaffold AppBar (used as a home nav destination).
  final bool embedded;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _baseCtrl = TextEditingController();
  final _keyCtrl = TextEditingController();
  final _modelCtrl = TextEditingController();
  bool _loading = true;
  bool _saving = false;
  bool _obscureKey = true;
  String? _error;
  String? _savedHint;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final s = await widget.store.load();
      if (!mounted) return;
      _baseCtrl.text = s.apiBaseUrl;
      _keyCtrl.text = s.apiKey;
      _modelCtrl.text = s.model;
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '加载设置失败：$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
      _savedHint = null;
    });
    try {
      final settings = AgentSettings(
        apiBaseUrl: _baseCtrl.text.trim().isEmpty
            ? AgentSettings.defaults.apiBaseUrl
            : _baseCtrl.text.trim(),
        apiKey: _keyCtrl.text.trim(),
        model: _modelCtrl.text.trim().isEmpty
            ? AgentSettings.defaults.model
            : _modelCtrl.text.trim(),
      );
      await widget.store.save(settings);
      if (!mounted) return;
      setState(() => _savedHint = '已保存（密钥仅存于安全存储）');
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '保存失败：$e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  void dispose() {
    _baseCtrl.dispose();
    _keyCtrl.dispose();
    _modelCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final body = _loading
        ? const Center(child: CircularProgressIndicator())
        : ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (widget.embedded) ...[
                Text('设置', style: Theme.of(context).textTheme.headlineSmall),
                const SizedBox(height: 8),
              ],
              Text(
                'OpenAI 兼容 API（BYO Key）。Base 需带 /v1，例如 https://apihub.example.com/v1。'
                '密钥不会写入 workspaces.json。',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _baseCtrl,
                decoration: const InputDecoration(
                  labelText: 'API Base URL',
                  hintText: 'https://api.openai.com/v1',
                ),
                keyboardType: TextInputType.url,
                autocorrect: false,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _keyCtrl,
                decoration: InputDecoration(
                  labelText: 'API Key',
                  suffixIcon: IconButton(
                    tooltip: _obscureKey ? '显示' : '隐藏',
                    onPressed: () => setState(() => _obscureKey = !_obscureKey),
                    icon: Icon(
                      _obscureKey ? Icons.visibility : Icons.visibility_off,
                    ),
                  ),
                ),
                obscureText: _obscureKey,
                autocorrect: false,
                enableSuggestions: false,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _modelCtrl,
                decoration: const InputDecoration(
                  labelText: '模型',
                  hintText: 'gpt-4o-mini',
                ),
                autocorrect: false,
              ),
              const SizedBox(height: 20),
              if (_error != null) ...[
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
                const SizedBox(height: 8),
              ],
              if (_savedHint != null) ...[
                Text(
                  _savedHint!,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
                const SizedBox(height: 8),
              ],
              FilledButton.icon(
                onPressed: _saving ? null : _save,
                icon: _saving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.save),
                label: Text(_saving ? '保存中…' : '保存'),
              ),
            ],
          );

    if (widget.embedded) return body;

    return Scaffold(
      appBar: AppBar(title: const Text('Agent 设置')),
      body: body,
    );
  }
}
