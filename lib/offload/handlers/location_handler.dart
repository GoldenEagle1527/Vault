import 'dart:convert';
import 'dart:io';

import 'package:vault/offload/handlers/offload_handler.dart';
import 'package:vault/offload/offload_protocol.dart';

/// `vault-location` — best-effort Windows geolocation via PowerShell.
///
/// When Location services are off or the OS denies access, [smoke] still
/// returns exit 0 with `limited: true` so the bridge path can be exercised.
class LocationHandler implements OffloadHandler {
  @override
  String get permissionId => 'location';

  @override
  String get command => 'vault-location';

  @override
  Future<OffloadResponse> handle(OffloadRequest request) async {
    final args = request.args;
    final sub = args.isEmpty ? 'get' : args.first;

    switch (sub) {
      case 'smoke':
        return _smoke();
      case 'get':
        return _get();
      default:
        return OffloadResponse.error(
          2,
          'usage: vault-location get|smoke',
        );
    }
  }

  Future<OffloadResponse> _smoke() async {
    if (!Platform.isWindows) {
      return OffloadResponse.ok(
        jsonEncode({
          'ok': true,
          'limited': true,
          'note': 'Windows location API not available on ${Platform.operatingSystem}',
        }),
      );
    }
    final result = await _queryLocation();
    if (result['ok'] == true && result['limited'] != true) {
      return OffloadResponse.ok(
        jsonEncode({
          'ok': true,
          'lat': result['lat'],
          'lon': result['lon'],
        }),
      );
    }
    return OffloadResponse.ok(
      jsonEncode({
        'ok': true,
        'limited': true,
        'note': result['note'] ?? 'location unavailable',
      }),
    );
  }

  Future<OffloadResponse> _get() async {
    if (!Platform.isWindows) {
      return OffloadResponse.unsupported(
        'unsupported_platform: location requires Windows',
      );
    }
    final result = await _queryLocation();
    if (result['ok'] == true && result['limited'] != true) {
      return OffloadResponse.ok(jsonEncode(result));
    }
    // Structured error for callers; not 125 (feature exists, OS blocked).
    return OffloadResponse.error(
      1,
      jsonEncode({
        'ok': false,
        'error': result['note'] ?? 'location unavailable',
      }),
    );
  }

  /// Runs a short GeoCoordinateWatcher probe. Never throws.
  Future<Map<String, dynamic>> _queryLocation() async {
    const script = r'''
Add-Type -AssemblyName System.Device -ErrorAction SilentlyContinue
if (-not ([System.Management.Automation.PSTypeName]'System.Device.Location.GeoCoordinateWatcher').Type) {
  @{ ok = $false; note = 'System.Device.Location unavailable' } | ConvertTo-Json -Compress
  exit 0
}
$w = New-Object System.Device.Location.GeoCoordinateWatcher
try {
  $w.Start()
  $deadline = [DateTime]::UtcNow.AddSeconds(4)
  while ($w.Status -ne 'Ready' -and [DateTime]::UtcNow -lt $deadline) {
    Start-Sleep -Milliseconds 200
  }
  $loc = $w.Position.Location
  if ($null -eq $loc -or $loc.IsUnknown) {
    $perm = $w.Permission.ToString()
    $status = $w.Status.ToString()
    @{ ok = $false; note = "location unknown (status=$status permission=$perm)" } | ConvertTo-Json -Compress
  } else {
    @{ ok = $true; lat = $loc.Latitude; lon = $loc.Longitude; accuracy = $loc.HorizontalAccuracy } | ConvertTo-Json -Compress
  }
} catch {
  @{ ok = $false; note = $_.Exception.Message } | ConvertTo-Json -Compress
} finally {
  try { $w.Stop() } catch {}
  try { $w.Dispose() } catch {}
}
''';

    try {
      final proc = await Process.run(
        'powershell',
        ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', script],
        runInShell: false,
      ).timeout(const Duration(seconds: 8));
      final stdout = '${proc.stdout}'.trim();
      if (stdout.isEmpty) {
        return {
          'ok': false,
          'limited': true,
          'note': 'empty PowerShell location response (exit ${proc.exitCode})',
        };
      }
      final decoded = jsonDecode(stdout);
      if (decoded is Map) {
        final map = Map<String, dynamic>.from(decoded);
        if (map['ok'] == true) return map;
        return {
          'ok': false,
          'limited': true,
          'note': map['note']?.toString() ?? 'location unavailable',
        };
      }
      return {
        'ok': false,
        'limited': true,
        'note': 'unexpected location payload',
      };
    } catch (e) {
      return {
        'ok': false,
        'limited': true,
        'note': 'location probe failed: $e',
      };
    }
  }
}
