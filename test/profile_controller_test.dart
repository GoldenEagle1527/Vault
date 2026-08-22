import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:vault/agent/agent_settings.dart';
import 'package:vault/screens/settings/profile_controller.dart';

class _DelayedSettingsStore extends AgentSettingsStore {
  _DelayedSettingsStore() : super(kv: MemoryAgentSettingsKv());

  final loadCompleter = Completer<AgentSettingsBundle>();
  final deleteCompleter = Completer<AgentSettingsBundle>();

  @override
  Future<AgentSettingsBundle> loadBundle() => loadCompleter.future;

  @override
  Future<AgentSettingsBundle> deleteProfile(String id) =>
      deleteCompleter.future;
}

void main() {
  test('profile controller loads, edits, and saves active profile', () async {
    final store = AgentSettingsStore(kv: MemoryAgentSettingsKv());
    final controller = ProfileController(store);
    addTearDown(controller.dispose);

    await controller.load();
    expect(controller.loading, isFalse);
    expect(controller.activeId, AgentSettings.defaultProfileId);

    controller.baseController.text = 'https://example.test/v1';
    controller.keyController.text = 'secret';
    controller.modelController.text = 'test-model';
    await controller.save();

    final saved = await store.load();
    expect(saved.apiBaseUrl, 'https://example.test/v1');
    expect(saved.apiKey, 'secret');
    expect(saved.model, 'test-model');
    expect(controller.hint, contains('已保存'));
  });

  test('profile controller coordinates add, rename, switch, delete', () async {
    final store = AgentSettingsStore(kv: MemoryAgentSettingsKv());
    final controller = ProfileController(store);
    addTearDown(controller.dispose);
    await controller.load();

    await controller.add();
    final addedId = controller.activeId;
    expect(controller.profiles, hasLength(2));

    await controller.rename('团队网关');
    expect(controller.draft.displayName, '团队网关');

    await controller.switchTo(AgentSettings.defaultProfileId);
    expect(controller.activeId, AgentSettings.defaultProfileId);

    await controller.switchTo(addedId);
    await controller.delete();
    expect(controller.profiles, hasLength(1));
    expect(controller.activeId, AgentSettings.defaultProfileId);
  });

  test('dispose during load does not apply bundle or notify', () async {
    final store = _DelayedSettingsStore();
    final controller = ProfileController(store);
    var notifications = 0;
    controller.addListener(() => notifications++);

    final load = controller.load();
    expect(notifications, 1);
    controller.dispose();
    store.loadCompleter.complete(AgentSettingsBundle.empty);

    await load;
    expect(notifications, 1);
  });

  test('dispose during mutation does not touch disposed text fields', () async {
    final store = _DelayedSettingsStore();
    final controller = ProfileController(store);
    var notifications = 0;
    controller.addListener(() => notifications++);

    final deletion = controller.delete();
    expect(notifications, 1);
    controller.dispose();
    store.deleteCompleter.complete(AgentSettingsBundle.empty);

    await deletion;
    expect(notifications, 1);
  });
}
