import 'package:flutter_test/flutter_test.dart';
import 'package:vault/agent/agent_settings.dart';

void main() {
  late MemoryAgentSettingsKv kv;
  late AgentSettingsStore store;

  setUp(() {
    kv = MemoryAgentSettingsKv();
    store = AgentSettingsStore(kv: kv);
  });

  test('load returns defaults when storage is empty', () async {
    final s = await store.load();
    expect(s.id, AgentSettings.defaultProfileId);
    expect(s.name, AgentSettings.defaultProfileName);
    expect(s.apiBaseUrl, AgentSettings.defaults.apiBaseUrl);
    expect(s.apiKey, isEmpty);
    expect(s.model, AgentSettings.defaults.model);
    expect(s.isConfigured, isFalse);
  });

  test('migrates legacy single-profile keys into 默认', () async {
    kv = MemoryAgentSettingsKv({
      'vault.agent.api_base_url': 'https://example.com/v1',
      'vault.agent.api_key': 'sk-legacy',
      'vault.agent.model': 'gpt-test',
    });
    store = AgentSettingsStore(kv: kv);

    final bundle = await store.loadBundle();
    expect(bundle.profiles, hasLength(1));
    expect(bundle.active.name, '默认');
    expect(bundle.active.apiBaseUrl, 'https://example.com/v1');
    expect(bundle.active.apiKey, 'sk-legacy');
    expect(bundle.active.model, 'gpt-test');
    expect(kv.snapshot.containsKey('vault.agent.profiles'), isTrue);
  });

  test('save and load round-trip the active profile', () async {
    await store.save(
      const AgentSettings(
        apiBaseUrl: 'https://api.openai.com/v1',
        apiKey: 'sk-1',
        model: 'gpt-4o',
      ),
    );
    final loaded = await store.load();
    expect(loaded.apiKey, 'sk-1');
    expect(loaded.model, 'gpt-4o');
    expect(loaded.displayName, '默认');
  });

  test('addProfile creates a new active config and keeps the old one', () async {
    await store.save(
      const AgentSettings(
        apiBaseUrl: 'https://a.example/v1',
        apiKey: 'aaa',
        model: 'model-a',
      ),
    );
    final added = await store.addProfile(name: 'Claude');
    expect(added.profiles, hasLength(2));
    expect(added.active.displayName, 'Claude');
    expect(added.active.apiKey, isEmpty);
    expect(added.active.id, isNot(AgentSettings.defaultProfileId));

    final original = added.profiles.firstWhere(
      (p) => p.id == AgentSettings.defaultProfileId,
    );
    expect(original.apiKey, 'aaa');
    expect(original.model, 'model-a');
  });

  test('selectProfile switches load() to the chosen config', () async {
    await store.save(
      const AgentSettings(
        apiBaseUrl: 'https://a.example/v1',
        apiKey: 'aaa',
        model: 'model-a',
      ),
    );
    final added = await store.addProfile(name: 'B');
    await store.save(
      added.active.copyWith(
        apiBaseUrl: 'https://b.example/v1',
        apiKey: 'bbb',
        model: 'model-b',
      ),
    );

    await store.selectProfile(AgentSettings.defaultProfileId);
    final active = await store.load();
    expect(active.apiKey, 'aaa');
    expect(active.model, 'model-a');

    await store.selectProfile(added.active.id);
    final switched = await store.load();
    expect(switched.apiKey, 'bbb');
    expect(switched.model, 'model-b');
    expect(switched.displayName, 'B');
  });

  test('renameProfile updates the display name', () async {
    await store.save(AgentSettings.defaults);
    final renamed = await store.renameProfile(
      AgentSettings.defaultProfileId,
      '  家里的网关  ',
    );
    expect(renamed.active.displayName, '家里的网关');
  });

  test('deleteProfile refuses to remove the last config', () async {
    final after = await store.deleteProfile(AgentSettings.defaultProfileId);
    expect(after.profiles, hasLength(1));
  });

  test('deleteProfile removes a config and falls back to another', () async {
    await store.save(
      const AgentSettings(
        apiBaseUrl: 'https://a.example/v1',
        apiKey: 'aaa',
        model: 'model-a',
      ),
    );
    final added = await store.addProfile(name: 'B');
    await store.save(added.active.copyWith(apiKey: 'bbb', model: 'model-b'));

    final after = await store.deleteProfile(added.active.id);
    expect(after.profiles, hasLength(1));
    expect(after.active.apiKey, 'aaa');
    expect(after.active.displayName, '默认');
  });

  test('addProfile allocates unique names', () async {
    final first = await store.addProfile();
    final second = await store.addProfile();
    expect(first.active.displayName, isNot(second.active.displayName));
    expect(
      {for (final p in second.profiles) p.displayName}.length,
      second.profiles.length,
    );
  });
}
