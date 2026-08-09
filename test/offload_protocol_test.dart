import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vault/offload/handlers/device_info_handler.dart';
import 'package:vault/offload/handlers/host_files_handler.dart';
import 'package:vault/offload/handlers/photos_handler.dart';
import 'package:vault/offload/handlers/speak_handler.dart';
import 'package:vault/offload/offload_gate.dart';
import 'package:vault/offload/offload_host_server.dart';
import 'package:vault/offload/offload_protocol.dart';

void main() {
  group('OffloadRequest/Response', () {
    test('round-trip encode/decode', () {
      final req = OffloadRequest(
        argv: ['vault-clipboard', 'get'],
        cwd: '/root',
        env: {kVaultChatSessionIdEnv: 'sess-1'},
        sessionId: 'sess-1',
      );
      final decoded = OffloadRequest.decode(req.encode());
      expect(decoded.command, 'vault-clipboard');
      expect(decoded.args, ['get']);
      expect(decoded.effectiveSessionId, 'sess-1');

      final res = OffloadResponse.ok('hello');
      final res2 = OffloadResponse.decode(res.encode());
      expect(res2.exitCode, 0);
      expect(res2.stdout, 'hello');
    });

    test('command basename from path', () {
      final req = OffloadRequest(argv: ['/usr/local/bin/vault-device', 'info']);
      expect(req.command, 'vault-device');
    });

    test('exit helpers', () {
      expect(OffloadResponse.permissionDenied().exitCode, 126);
      expect(OffloadResponse.unsupported().exitCode, 125);
      expect(OffloadResponse.unknownCommand().exitCode, 127);
    });
  });

  group('OffloadGate Wave2 mapping', () {
    test('maps calendar/contacts/photos/location', () {
      expect(OffloadGate.permissionIdForCommand('vault-calendar'), 'calendar');
      expect(OffloadGate.permissionIdForCommand('vault-contacts'), 'contacts');
      expect(OffloadGate.permissionIdForCommand('vault-photos'), 'photos');
      expect(OffloadGate.permissionIdForCommand('vault-location'), 'location');
    });
  });

  group('OffloadGate Wave3 mapping', () {
    test('maps host-files/config/speak/speech', () {
      expect(
        OffloadGate.permissionIdForCommand('vault-host-files'),
        'host_files',
      );
      expect(OffloadGate.permissionIdForCommand('vault-config'), 'vault_config');
      expect(OffloadGate.permissionIdForCommand('vault-speak'), 'speak');
      expect(OffloadGate.permissionIdForCommand('vault-speech'), 'speech');
    });
  });

  group('OffloadGate Wave4 mapping', () {
    test('maps a11y/shizuku', () {
      expect(OffloadGate.permissionIdForCommand('vault-a11y'), 'a11y');
      expect(OffloadGate.permissionIdForCommand('vault-shizuku'), 'shizuku');
    });
  });

  group('OffloadHostServer.dispatch', () {
    test('vault-a11y / vault-shizuku → 125 on Windows host', () async {
      final server = OffloadHostServer(handlers: {});
      final a11y = await server.dispatch(
        const OffloadRequest(argv: ['vault-a11y', 'smoke'], sessionId: 's1'),
      );
      expect(a11y.exitCode, 125);
      final shizuku = await server.dispatch(
        const OffloadRequest(argv: ['vault-shizuku', 'smoke'], sessionId: 's1'),
      );
      expect(shizuku.exitCode, 125);
    });

    test('unknown command → 127', () async {
      OffloadGate.checker = ({
        required permissionId,
        required command,
        required sessionId,
      }) async =>
          null;
      addTearDown(() => OffloadGate.checker = null);

      final server = OffloadHostServer(handlers: {
        'vault-device': DeviceInfoHandler(),
      });
      final res = await server.dispatch(
        const OffloadRequest(argv: ['vault-nope'], sessionId: 's'),
      );
      expect(res.exitCode, 127);
    });

    test('device smoke → 0', () async {
      OffloadGate.checker = ({
        required permissionId,
        required command,
        required sessionId,
      }) async =>
          null;
      addTearDown(() => OffloadGate.checker = null);

      final server = OffloadHostServer(handlers: {
        'vault-device': DeviceInfoHandler(),
      });
      final res = await server.dispatch(
        const OffloadRequest(
          argv: ['vault-device', 'smoke'],
          sessionId: 'sess-test',
        ),
      );
      expect(res.exitCode, 0);
      expect(res.stdout, contains('ok device'));
    });

    test('photos smoke → 0 (mock gate allow)', () async {
      OffloadGate.checker = ({
        required permissionId,
        required command,
        required sessionId,
      }) async {
        expect(permissionId, 'photos');
        expect(command, 'vault-photos');
        return null;
      };
      addTearDown(() => OffloadGate.checker = null);

      final server = OffloadHostServer(handlers: {
        'vault-photos': PhotosHandler(),
      });
      final res = await server.dispatch(
        const OffloadRequest(
          argv: ['vault-photos', 'smoke'],
          sessionId: 'sess-test',
        ),
      );
      expect(res.exitCode, 0);
      final decoded = jsonDecode(res.stdout);
      expect(decoded, isA<Map>());
      expect(decoded['ok'], isTrue);
    });

    test('missing session → 126', () async {
      OffloadGate.checker = null;
      final server = OffloadHostServer(handlers: {
        'vault-device': DeviceInfoHandler(),
      });
      final res = await server.dispatch(
        const OffloadRequest(argv: ['vault-device', 'smoke']),
      );
      expect(res.exitCode, 126);
    });

    test('gate can deny with 126', () async {
      OffloadGate.checker = ({
        required String permissionId,
        required String command,
        required String? sessionId,
      }) async =>
          OffloadResponse.permissionDenied();
      addTearDown(() => OffloadGate.checker = null);

      final server = OffloadHostServer(handlers: {
        'vault-device': DeviceInfoHandler(),
      });
      final res = await server.dispatch(
        const OffloadRequest(
          argv: ['vault-device', 'smoke'],
          sessionId: 'sess-test',
        ),
      );
      expect(res.exitCode, 126);
    });

    test('host-files smoke → 0 (mock gate allow)', () async {
      OffloadGate.checker = ({
        required permissionId,
        required command,
        required sessionId,
      }) async {
        expect(permissionId, 'host_files');
        expect(command, 'vault-host-files');
        return null;
      };
      addTearDown(() => OffloadGate.checker = null);

      final tmp = await Directory.systemTemp.createTemp('vault_host_files_');
      addTearDown(() async {
        try {
          await tmp.delete(recursive: true);
        } catch (_) {}
      });

      final server = OffloadHostServer(handlers: {
        'vault-host-files': HostFilesHandler(root: tmp),
      });
      final res = await server.dispatch(
        const OffloadRequest(
          argv: ['vault-host-files', 'smoke'],
          sessionId: 'sess-test',
        ),
      );
      expect(res.exitCode, 0);
      final decoded = jsonDecode(res.stdout);
      expect(decoded, isA<Map>());
      expect(decoded['ok'], isTrue);
      expect(decoded['root'], tmp.path);

      final reject = await server.dispatch(
        const OffloadRequest(
          argv: ['vault-host-files', 'list', '../escape'],
          sessionId: 'sess-test',
        ),
      );
      expect(reject.exitCode, 2);
      expect(reject.stdout, contains('..'));
    });

    test('speak smoke → 0 (mock gate allow)', () async {
      OffloadGate.checker = ({
        required permissionId,
        required command,
        required sessionId,
      }) async {
        expect(permissionId, 'speak');
        expect(command, 'vault-speak');
        return null;
      };
      addTearDown(() => OffloadGate.checker = null);

      final server = OffloadHostServer(handlers: {
        'vault-speak': SpeakHandler(),
      });
      final res = await server.dispatch(
        const OffloadRequest(
          argv: ['vault-speak', 'smoke'],
          sessionId: 'sess-test',
        ),
      );
      expect(res.exitCode, 0);
      final decoded = jsonDecode(res.stdout);
      expect(decoded, isA<Map>());
      expect(decoded['ok'], isTrue);
    });
  });
}
