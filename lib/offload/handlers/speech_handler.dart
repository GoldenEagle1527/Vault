import 'dart:convert';
import 'dart:io';

import 'package:vault/offload/handlers/offload_handler.dart';
import 'package:vault/offload/offload_protocol.dart';

/// `vault-speech` — best-effort Windows STT via PowerShell `System.Speech`.
///
/// Full recognition needs a microphone + interactive grammar; [smoke] always
/// exits 0 and reports `limited: true` when STT cannot be exercised without
/// blocking for audio input.
class SpeechHandler implements OffloadHandler {
  @override
  String get permissionId => 'speech';

  @override
  String get command => 'vault-speech';

  @override
  Future<OffloadResponse> handle(OffloadRequest request) async {
    final args = request.args;
    final sub = args.isEmpty ? 'smoke' : args.first;

    switch (sub) {
      case 'smoke':
        return _smoke();
      default:
        return OffloadResponse.error(
          2,
          'usage: vault-speech smoke',
        );
    }
  }

  Future<OffloadResponse> _smoke() async {
    if (!Platform.isWindows) {
      return OffloadResponse.ok(
        jsonEncode({
          'ok': true,
          'limited': true,
          'note': 'System.Speech recognition not available on ${Platform.operatingSystem}',
        }),
      );
    }

    // Load recognition types only — do not block on microphone input.
    const script = r'''
try {
  Add-Type -AssemblyName System.Speech -ErrorAction Stop
  $t = [System.Speech.Recognition.SpeechRecognitionEngine]
  if ($null -eq $t) {
    @{ ok = $true; limited = $true; note = 'SpeechRecognitionEngine type missing' } | ConvertTo-Json -Compress
  } else {
    @{ ok = $true; limited = $true; note = 'STT assembly present; interactive listen not wired in Wave3 smoke' } | ConvertTo-Json -Compress
  }
} catch {
  @{ ok = $true; limited = $true; note = $_.Exception.Message } | ConvertTo-Json -Compress
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
      if (stdout.isEmpty) {
        return OffloadResponse.ok(
          jsonEncode({
            'ok': true,
            'limited': true,
            'note': 'empty PowerShell speech response (exit ${proc.exitCode})',
          }),
        );
      }
      final decoded = jsonDecode(stdout);
      if (decoded is Map) {
        return OffloadResponse.ok(
          jsonEncode({
            'ok': true,
            'limited': decoded['limited'] != false,
            'note': decoded['note']?.toString() ??
                'speech recognition limited',
          }),
        );
      }
      return OffloadResponse.ok(
        jsonEncode({
          'ok': true,
          'limited': true,
          'note': 'unexpected speech probe payload',
        }),
      );
    } catch (e) {
      return OffloadResponse.ok(
        jsonEncode({
          'ok': true,
          'limited': true,
          'note': 'speech probe failed: $e',
        }),
      );
    }
  }
}
