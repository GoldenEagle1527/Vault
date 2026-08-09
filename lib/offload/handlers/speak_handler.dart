import 'dart:convert';
import 'dart:io';

import 'package:vault/offload/handlers/offload_handler.dart';
import 'package:vault/offload/offload_protocol.dart';

/// `vault-speak` — Windows TTS via PowerShell `System.Speech.Synthesis`.
class SpeakHandler implements OffloadHandler {
  @override
  String get permissionId => 'speak';

  @override
  String get command => 'vault-speak';

  @override
  Future<OffloadResponse> handle(OffloadRequest request) async {
    final args = request.args;
    final sub = args.isEmpty ? 'smoke' : args.first;

    switch (sub) {
      case 'smoke':
        return _smoke();
      case 'say':
        final text = args.length > 1 ? args.sublist(1).join(' ') : '';
        return _say(text);
      default:
        return OffloadResponse.error(
          2,
          'usage: vault-speak say <text>|smoke',
        );
    }
  }

  Future<OffloadResponse> _smoke() async {
    if (!Platform.isWindows) {
      return OffloadResponse.ok(
        jsonEncode({
          'ok': true,
          'limited': true,
          'note': 'System.Speech TTS not available on ${Platform.operatingSystem}',
        }),
      );
    }
    // Probe synthesizer availability without speaking aloud.
    const script = r'''
Add-Type -AssemblyName System.Speech -ErrorAction Stop
$s = New-Object System.Speech.Synthesis.SpeechSynthesizer
try {
  $null = $s.GetInstalledVoices().Count
  @{ ok = $true; voices = $s.GetInstalledVoices().Count } | ConvertTo-Json -Compress
} finally {
  try { $s.Dispose() } catch {}
}
''';
    try {
      final proc = await Process.run(
        'powershell',
        [
          '-NoProfile',
          '-NonInteractive',
          '-ExecutionPolicy',
          'Bypass',
          '-Command',
          script,
        ],
        runInShell: false,
      ).timeout(const Duration(seconds: 10));
      final stdout = '${proc.stdout}'.trim();
      if (proc.exitCode != 0 || stdout.isEmpty) {
        final err = '${proc.stderr}'.trim();
        return OffloadResponse.ok(
          jsonEncode({
            'ok': true,
            'limited': true,
            'note': err.isEmpty
                ? 'TTS probe failed (exit ${proc.exitCode})'
                : err,
          }),
        );
      }
      final decoded = jsonDecode(stdout);
      if (decoded is Map && decoded['ok'] == true) {
        return OffloadResponse.ok(
          jsonEncode({
            'ok': true,
            'voices': decoded['voices'],
          }),
        );
      }
      return OffloadResponse.ok(
        jsonEncode({
          'ok': true,
          'limited': true,
          'note': 'unexpected TTS probe payload',
        }),
      );
    } catch (e) {
      return OffloadResponse.ok(
        jsonEncode({
          'ok': true,
          'limited': true,
          'note': 'TTS probe failed: $e',
        }),
      );
    }
  }

  Future<OffloadResponse> _say(String text) async {
    if (text.trim().isEmpty) {
      return OffloadResponse.error(2, 'usage: vault-speak say <text>');
    }
    if (!Platform.isWindows) {
      return OffloadResponse.unsupported(
        'unsupported_platform: speak requires Windows',
      );
    }

    // Escape for single-quoted PowerShell string: ' → ''
    final escaped = text.replaceAll("'", "''");
    final script = '''
Add-Type -AssemblyName System.Speech -ErrorAction Stop
\$s = New-Object System.Speech.Synthesis.SpeechSynthesizer
try {
  \$s.Speak('$escaped')
  @{ ok = \$true } | ConvertTo-Json -Compress
} catch {
  @{ ok = \$false; note = \$_.Exception.Message } | ConvertTo-Json -Compress
  exit 1
} finally {
  try { \$s.Dispose() } catch {}
}
''';

    try {
      final proc = await Process.run(
        'powershell',
        [
          '-NoProfile',
          '-NonInteractive',
          '-ExecutionPolicy',
          'Bypass',
          '-Command',
          script,
        ],
        runInShell: false,
      ).timeout(const Duration(seconds: 60));
      final stdout = '${proc.stdout}'.trim();
      if (proc.exitCode != 0) {
        final err = '${proc.stderr}'.trim();
        return OffloadResponse.error(
          1,
          err.isEmpty
              ? (stdout.isEmpty ? 'speak failed' : stdout)
              : err,
        );
      }
      return OffloadResponse.ok(
        jsonEncode({'ok': true, 'said': text}),
      );
    } catch (e) {
      return OffloadResponse.error(1, 'speak failed: $e');
    }
  }
}
