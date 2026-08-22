import 'package:flutter/material.dart';
import 'package:vault/agent/agent_settings.dart';

class ProfileController extends ChangeNotifier {
  ProfileController(this.store);

  final AgentSettingsStore store;
  final baseController = TextEditingController();
  final keyController = TextEditingController();
  final modelController = TextEditingController();

  List<AgentSettings> profiles = const [AgentSettings.defaults];
  String activeId = AgentSettings.defaultProfileId;
  bool loading = true;
  bool saving = false;
  bool obscureKey = true;
  String? error;
  String? hint;
  bool _disposed = false;
  int _generation = 0;

  AgentSettings get draft {
    final current = profiles.firstWhere(
      (profile) => profile.id == activeId,
      orElse: () => AgentSettings.defaults,
    );
    return current.copyWith(
      apiBaseUrl: baseController.text.trim().isEmpty
          ? AgentSettings.defaults.apiBaseUrl
          : baseController.text.trim(),
      apiKey: keyController.text.trim(),
      model: modelController.text.trim().isEmpty
          ? AgentSettings.defaults.model
          : modelController.text.trim(),
    );
  }

  Future<void> load() async {
    final generation = _beginOperation();
    if (generation == null) return;
    loading = true;
    error = null;
    _notifyIfCurrent(generation);
    try {
      final bundle = await store.loadBundle();
      if (_isCurrent(generation)) _apply(bundle);
    } catch (e) {
      if (_isCurrent(generation)) error = '加载设置失败：$e';
    } finally {
      if (_isCurrent(generation)) {
        loading = false;
        notifyListeners();
      }
    }
  }

  Future<void> save() => _run(
    action: () async {
      await store.save(draft);
      return store.loadBundle();
    },
    success: (_) => '已保存（密钥仅存于安全存储）',
    failure: '保存失败',
  );

  Future<void> switchTo(String? id) async {
    if (id == null || id == activeId || saving) return;
    await _run(
      action: () async {
        await store.save(draft);
        return store.selectProfile(id);
      },
      success: (bundle) => '已切换到「${bundle.active.displayName}」',
      failure: '切换失败',
    );
  }

  Future<void> add() => _run(
    action: () async {
      await store.save(draft);
      return store.addProfile();
    },
    success: (bundle) => '已新建「${bundle.active.displayName}」',
    failure: '新建失败',
  );

  Future<void> rename(String name) {
    final current = draft;
    return _run(
      action: () async {
        await store.save(current.copyWith(name: name));
        return store.renameProfile(current.id, name);
      },
      success: (bundle) => '已重命名为「${bundle.active.displayName}」',
      failure: '重命名失败',
    );
  }

  Future<void> delete() => _run(
    action: () => store.deleteProfile(draft.id),
    success: (bundle) => '已删除，当前为「${bundle.active.displayName}」',
    failure: '删除失败',
  );

  void toggleKeyVisibility() {
    if (_disposed) return;
    obscureKey = !obscureKey;
    notifyListeners();
  }

  Future<void> _run({
    required Future<AgentSettingsBundle> Function() action,
    required String Function(AgentSettingsBundle) success,
    required String failure,
  }) async {
    if (saving || _disposed) return;
    final generation = _beginOperation()!;
    saving = true;
    error = null;
    hint = null;
    _notifyIfCurrent(generation);
    try {
      final bundle = await action();
      if (_isCurrent(generation)) {
        _apply(bundle);
        hint = success(bundle);
      }
    } catch (e) {
      if (_isCurrent(generation)) error = '$failure：$e';
    } finally {
      if (_isCurrent(generation)) {
        saving = false;
        notifyListeners();
      }
    }
  }

  int? _beginOperation() {
    if (_disposed) return null;
    return _generation;
  }

  bool _isCurrent(int generation) => !_disposed && generation == _generation;

  void _notifyIfCurrent(int generation) {
    if (_isCurrent(generation)) notifyListeners();
  }

  void _apply(AgentSettingsBundle bundle) {
    profiles = bundle.profiles;
    activeId = bundle.active.id;
    baseController.text = bundle.active.apiBaseUrl;
    keyController.text = bundle.active.apiKey;
    modelController.text = bundle.active.model;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    baseController.dispose();
    keyController.dispose();
    modelController.dispose();
    super.dispose();
  }
}
