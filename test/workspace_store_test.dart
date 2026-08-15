import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:vault/agent/vault_meta_db.dart';
import 'package:vault/agent/workspace_mode.dart';
import 'package:vault/agent/workspace_store.dart';

void main() {
  late Directory temp;
  late VaultMetaDb metaDb;
  late WorkspaceStore store;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('vault_ws_');
    metaDb = VaultMetaDb.at(p.join(temp.path, 'vault_meta.db'));
    store = WorkspaceStore(metaDb: metaDb);
  });

  tearDown(() async {
    if (await temp.exists()) {
      await temp.delete(recursive: true);
    }
  });

  test('allocateDisplayName uses 新工作区 then 新工作区(n)', () {
    expect(WorkspaceStore.allocateDisplayName(const []), kDefaultWorkspaceName);
    expect(WorkspaceStore.allocateDisplayName(const ['新工作区']), '新工作区(1)');
    expect(
      WorkspaceStore.allocateDisplayName(const ['新工作区', '新工作区(1)']),
      '新工作区(2)',
    );
    expect(
      WorkspaceStore.allocateDisplayName(const ['实验室'], base: '实验室'),
      '实验室(1)',
    );
  });

  test('setName / getName / listNames persist display names', () async {
    expect(await store.getName('ws1'), isNull);

    await store.setName('ws1', '  实验室  ');
    expect(await store.getName('ws1'), '实验室');

    await store.setName('ws2', '新工作区');
    expect(await store.listNames(), {'ws1': '实验室', 'ws2': '新工作区'});
  });

  test('setName rejects empty names', () async {
    expect(() => store.setName('ws1', '   '), throwsA(isA<ArgumentError>()));
    expect(await store.getName('ws1'), isNull);
  });

  test('setName and setMode do not wipe each other', () async {
    await store.setName('ws1', '实验室');
    await store.setMode('ws1', WorkspaceMode.dev);
    expect(await store.getName('ws1'), '实验室');
    expect(await store.getMode('ws1'), WorkspaceMode.dev);

    await store.setName('ws1', '工作室');
    expect(await store.getMode('ws1'), WorkspaceMode.dev);
    expect(await store.getName('ws1'), '工作室');
  });

  test('ensureSchema adds name column to existing workspace_state', () async {
    final dbPath = p.join(temp.path, 'legacy.db');
    final raw = sqlite3.open(dbPath);
    raw.execute('''
CREATE TABLE workspace_state (
  workspace_id TEXT PRIMARY KEY,
  active_project_path TEXT
);
''');
    raw.execute("INSERT INTO workspace_state (workspace_id) VALUES ('legacy')");
    raw.close();

    final legacy = WorkspaceStore(metaDb: VaultMetaDb.at(dbPath));
    expect(await legacy.getName('legacy'), isNull);
    await legacy.setName('legacy', '旧工作区');
    expect(await legacy.getName('legacy'), '旧工作区');
  });
}
