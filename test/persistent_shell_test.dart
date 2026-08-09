import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vault/sandbox/persistent_shell.dart';

void main() {
  group('marker protocol', () {
    test('wrapPersistentShellCommand frames echo with \$?', () {
      final wrapped = wrapPersistentShellCommand('echo hi', 'abcd1234');
      expect(wrapped, contains('echo hi\n'));
      expect(
        wrapped,
        contains('echo "__VAULT_DONE_abcd1234_EXIT_\$?__"'),
      );
    });

    test('tryParsePersistentShellMarker parses complete marker', () {
      const buf = 'hello\n__VAULT_DONE_deadbeef_EXIT_0__\n';
      final match = tryParsePersistentShellMarker(buf, 'deadbeef');
      expect(match, isNotNull);
      expect(match!.output, 'hello');
      expect(match.exitCode, 0);
    });

    test('tryParsePersistentShellMarker handles chunked marker', () {
      const part1 = 'out\n__VAULT_DONE_aa_EXIT_';
      expect(tryParsePersistentShellMarker(part1, 'aa'), isNull);
      const part2 = '${part1}7__\nextra';
      final match = tryParsePersistentShellMarker(part2, 'aa');
      expect(match, isNotNull);
      expect(match!.exitCode, 7);
      expect(match.output, 'out');
      expect(part2.substring(match.end), '\nextra');
    });

    test('non-zero exit codes parse', () {
      const buf = '__VAULT_DONE_x_EXIT_127__';
      final match = tryParsePersistentShellMarker(buf, 'x');
      expect(match!.exitCode, 127);
      expect(match.output, '');
    });
  });

  group('PersistentShell live', () {
    test('cwd and background job survive across run() calls', () async {
      // Prefer a real POSIX sh (Git Bash / WSL / *nix). Skip if unavailable.
      final sh = _findSh();
      if (sh == null) {
        return;
      }

      final shell = PersistentShell(
        executable: sh,
        arguments: const [],
        environment: const {'TERM': 'dumb', 'PS1': ''},
        includeParentEnvironment: true,
      );
      addTearDown(shell.stop);

      final mkdir = await shell.run(
        'mkdir -p /tmp/vault_ps_test && cd /tmp/vault_ps_test && pwd',
        timeout: const Duration(seconds: 15),
      );
      expect(mkdir.exitCode, 0);
      expect(mkdir.stdout.trim(), contains('vault_ps_test'));

      final pwd = await shell.run(
        'pwd',
        timeout: const Duration(seconds: 10),
      );
      expect(pwd.exitCode, 0);
      expect(pwd.stdout.trim(), contains('vault_ps_test'));

      final bg = await shell.run(
        'rm -f /tmp/vault_ps_alive; '
        '(sleep 2; echo alive > /tmp/vault_ps_alive) & '
        'echo started',
        timeout: const Duration(seconds: 10),
      );
      expect(bg.exitCode, 0);
      expect(bg.stdout, contains('started'));

      await Future<void>.delayed(const Duration(milliseconds: 2500));
      final check = await shell.run(
        'cat /tmp/vault_ps_alive',
        timeout: const Duration(seconds: 10),
      );
      expect(check.exitCode, 0);
      expect(check.stdout.trim(), 'alive');
    }, timeout: const Timeout(Duration(seconds: 60)));
  });
}

String? _findSh() {
  if (!Platform.isWindows) {
    final sh = File('/bin/sh');
    if (sh.existsSync()) return sh.path;
  }
  for (final candidate in [
    r'C:\Program Files\Git\bin\sh.exe',
    r'C:\Program Files\Git\usr\bin\sh.exe',
  ]) {
    if (File(candidate).existsSync()) return candidate;
  }
  return null;
}
