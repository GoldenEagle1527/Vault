import 'dart:io';

import 'package:path/path.dart' as p;

/// Guest CLI names installed under `/usr/local/bin`.
const List<String> kOffloadStubCommands = [
  'vault-clipboard',
  'vault-device',
  'vault-open',
  'vault-notification',
  'vault-calendar',
  'vault-contacts',
  'vault-photos',
  'vault-location',
  'vault-host-files',
  'vault-config',
  'vault-speak',
  'vault-speech',
  // Wave4 Android integrations (Windows WSL install list stays Wave1–3 only)
  'vault-a11y',
  'vault-shizuku',
];

/// Shared invoke helper path inside guest rootfs.
const String kOffloadInvokeGuestPath = '/usr/local/lib/vault/offload-invoke';

/// Port file written into each workspace rootfs.
const String kOffloadPortGuestPath = '/etc/vault-offload.port';

/// Install Wave1–4 guest stubs + port file into [rootfsPath] (host path).
Future<void> installOffloadStubs(String rootfsPath, int port) async {
  final portFile = File(p.join(rootfsPath, 'etc', 'vault-offload.port'));
  await portFile.parent.create(recursive: true);
  await portFile.writeAsString('$port\n', flush: true);

  final invokeHost = p.join(rootfsPath, 'usr', 'local', 'lib', 'vault', 'offload-invoke');
  await File(invokeHost).parent.create(recursive: true);
  await File(invokeHost).writeAsString(_kOffloadInvokeScript, flush: true);
  await _chmod755(invokeHost);

  final binDir = Directory(p.join(rootfsPath, 'usr', 'local', 'bin'));
  await binDir.create(recursive: true);
  for (final name in kOffloadStubCommands) {
    final path = p.join(binDir.path, name);
    await File(path).writeAsString(_kOffloadWrapperScript, flush: true);
    await _chmod755(path);
  }
}

Future<void> writeOffloadPortFile(String rootfsPath, int port) async {
  final portFile = File(p.join(rootfsPath, 'etc', 'vault-offload.port'));
  await portFile.parent.create(recursive: true);
  await portFile.writeAsString('$port\n', flush: true);
}

Future<void> _chmod755(String path) async {
  try {
    await Process.run('chmod', ['755', path], runInShell: false);
  } catch (_) {}
}

/// Thin wrappers: basename becomes argv[0] for the host dispatcher.
const String _kOffloadWrapperScript = r'''#!/bin/sh
exec /usr/local/lib/vault/offload-invoke "$(basename "$0")" "$@"
''';

/// POSIX helper: JSON line → nc/wget → print stdout, exit with host exitCode.
///
/// Port: $VAULT_OFFLOAD_PORT or /etc/vault-offload.port
const String _kOffloadInvokeScript = r'''#!/bin/sh
# Vault host offload invoke (stock proot; TCP to 127.0.0.1)
set +e
CMD="$1"
shift

PORT="${VAULT_OFFLOAD_PORT:-}"
if [ -z "$PORT" ] && [ -f /etc/vault-offload.port ]; then
  PORT=$(tr -d ' \n\r\t' </etc/vault-offload.port)
fi
if [ -z "$PORT" ]; then
  echo "vault-offload: no port (host bridge not running?)" >&2
  exit 125
fi

json_escape() {
  # Escape \ and " for JSON string
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

ARGS_JSON="\"$(json_escape "$CMD")\""
for a in "$@"; do
  ARGS_JSON="${ARGS_JSON},\"$(json_escape "$a")\""
done

CWD=$(pwd 2>/dev/null || echo /)
SESSION="${VAULT_CHAT_SESSION_ID:-}"

REQ=$(printf '{"argv":[%s],"cwd":"%s","env":{"VAULT_CHAT_SESSION_ID":"%s"},"sessionId":"%s"}' \
  "$ARGS_JSON" "$(json_escape "$CWD")" "$(json_escape "$SESSION")" "$(json_escape "$SESSION")")

RESP=""
if command -v nc >/dev/null 2>&1; then
  RESP=$(printf '%s\n' "$REQ" | nc -w 8 127.0.0.1 "$PORT" 2>/dev/null)
elif [ -x /bin/busybox ]; then
  RESP=$(printf '%s\n' "$REQ" | /bin/busybox nc -w 8 127.0.0.1 "$PORT" 2>/dev/null)
fi
if [ -z "$RESP" ] && command -v wget >/dev/null 2>&1; then
  RESP=$(wget -q -O - --header="Content-Type: application/json" \
    --post-data="$REQ" "http://127.0.0.1:${PORT}/" 2>/dev/null)
fi
if [ -z "$RESP" ]; then
  echo "vault-offload: empty response (need nc/wget; is host bridge up on :$PORT?)" >&2
  exit 125
fi

# Take last non-empty line (HTTP body or line protocol)
RESP=$(printf '%s\n' "$RESP" | sed '/^$/d' | tail -n 1)

CODE=$(printf '%s' "$RESP" | sed -n 's/.*"exitCode"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -n 1)
[ -z "$CODE" ] && CODE=1

B64=$(printf '%s' "$RESP" | sed -n 's/.*"stdoutB64"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
if [ -n "$B64" ]; then
  if command -v base64 >/dev/null 2>&1; then
    printf '%s' "$B64" | base64 -d 2>/dev/null
  elif command -v busybox >/dev/null 2>&1; then
    printf '%s' "$B64" | busybox base64 -d 2>/dev/null
  fi
else
  # Fallback: crude stdout extract (no escapes)
  printf '%s' "$RESP" | sed -n 's/.*"stdout"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | sed 's/\\n/\n/g; s/\\t/\t/g; s/\\"/"/g; s/\\\\/\\/g'
fi

exit "$CODE"
''';
