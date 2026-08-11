import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:vault/sandbox/guest_code_highlight.dart';
import 'package:vault/sandbox/guest_fs_list.dart';
import 'package:vault/sandbox/guest_media_kind.dart';
import 'package:vault/sandbox/sandbox_models.dart';
import 'package:vault/sandbox/workspace_guest_fs.dart';

void main() {
  group('looksLikeTextBytes', () {
    test('accepts utf8 text', () {
      expect(looksLikeTextBytes('hello 世界\n'.codeUnits), isTrue);
    });

    test('rejects NUL in sample', () {
      expect(looksLikeTextBytes([0x68, 0x00, 0x69]), isFalse);
    });

    test('ignores NUL past sampleLimit', () {
      final bytes = List<int>.filled(100, 0x61, growable: true)..add(0);
      expect(looksLikeTextBytes(bytes, sampleLimit: 50), isTrue);
      expect(looksLikeTextBytes(bytes, sampleLimit: 200), isFalse);
    });
  });

  group('parseLsMinusOneAp', () {
    test('marks trailing slash as directory and sorts', () {
      final entries = parseLsMinusOneAp(
        'zebra.txt\nAlpha/\nbeta.md\n',
        '/root',
      );
      expect(entries.map((e) => e.name).toList(), [
        'Alpha',
        'beta.md',
        'zebra.txt',
      ]);
      expect(entries[0].isDirectory, isTrue);
      expect(entries[0].guestPath, '/root/Alpha');
      expect(entries[1].isDirectory, isFalse);
      expect(entries[2].guestPath, '/root/zebra.txt');
    });

    test('skips . and .. and path-like names', () {
      final entries = parseLsMinusOneAp(
        './\n../\nok.txt\nbad/name\n',
        '/root/inbox',
      );
      expect(entries.single.name, 'ok.txt');
      expect(entries.single.guestPath, '/root/inbox/ok.txt');
    });
  });

  group('LocalDirWorkspaceGuestFs.listDirectory', () {
    late Directory tmp;
    late LocalDirWorkspaceGuestFs fs;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('vault_guest_fs_');
      fs = LocalDirWorkspaceGuestFs(tmp.path);
      final root = Directory(p.join(tmp.path, 'ws1', 'root'));
      await root.create(recursive: true);
      await Directory(p.join(root.path, 'projects')).create();
      await File(p.join(root.path, 'readme.txt')).writeAsString('hi');
      await File(p.join(root.path, 'a.bin')).writeAsBytes([1, 2, 3]);
    });

    tearDown(() async {
      if (await tmp.exists()) {
        await tmp.delete(recursive: true);
      }
    });

    test('lists dirs first then files', () async {
      final entries = await fs.listDirectory('ws1', '/root');
      expect(entries.map((e) => e.name).toList(), [
        'projects',
        'a.bin',
        'readme.txt',
      ]);
      expect(entries[0].isDirectory, isTrue);
      expect(entries[0].guestPath, '/root/projects');
      expect(entries[1].isDirectory, isFalse);
      expect(entries[1].sizeBytes, 3);
      expect(entries[2].sizeBytes, 2);
    });

    test('rejects path escape', () async {
      expect(
        () => fs.listDirectory('ws1', '/etc'),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => fs.listDirectory('ws1', '/root/../etc'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('throws when directory missing', () async {
      expect(
        () => fs.listDirectory('ws1', '/root/missing'),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('guestPathJoin', () {
    test('joins under home', () {
      expect(guestPathJoin('/root', 'inbox'), '/root/inbox');
      expect(guestPathJoin('/root/inbox', 'a.txt'), '/root/inbox/a.txt');
    });

    test('rejects bad names', () {
      expect(() => guestPathJoin('/root', '..'), throwsArgumentError);
      expect(() => guestPathJoin('/root', 'a/b'), throwsArgumentError);
    });
  });

  group('highlightLanguageForPath', () {
    test('maps common extensions', () {
      expect(highlightLanguageForPath('/root/a.dart'), 'dart');
      expect(highlightLanguageForPath('/root/app.py'), 'python');
      expect(highlightLanguageForPath('/root/run.sh'), 'bash');
      expect(highlightLanguageForPath('/root/cfg.yaml'), 'yaml');
      expect(highlightLanguageForPath('/root/README.md'), 'markdown');
      expect(highlightLanguageForPath('/root/Dockerfile'), 'dockerfile');
      expect(highlightLanguageForPath('/root/Makefile'), 'makefile');
    });

    test('returns null for unknown', () {
      expect(highlightLanguageForPath('/root/notes.txt'), isNull);
      expect(highlightLanguageForPath('/root/noext'), isNull);
    });
  });

  group('guestMediaKindForPath', () {
    test('detects image video audio', () {
      expect(guestMediaKindForPath('/root/a.PNG'), GuestMediaKind.image);
      expect(guestMediaKindForPath('/root/clip.mp4'), GuestMediaKind.video);
      expect(guestMediaKindForPath('/root/song.mp3'), GuestMediaKind.audio);
      expect(guestMediaKindForPath('/root/pic.webp'), GuestMediaKind.image);
      expect(guestMediaKindForPath('/root/v.webm'), GuestMediaKind.video);
      expect(guestMediaKindForPath('/root/a.flac'), GuestMediaKind.audio);
    });

    test('detects text and unknown binary', () {
      expect(guestMediaKindForPath('/root/a.dart'), GuestMediaKind.text);
      expect(guestMediaKindForPath('/root/notes.txt'), GuestMediaKind.text);
      expect(guestMediaKindForPath('/root/a.bin'), GuestMediaKind.binary);
      expect(guestMediaKindForPath('/root/lib.so'), GuestMediaKind.binary);
    });
  });
}
