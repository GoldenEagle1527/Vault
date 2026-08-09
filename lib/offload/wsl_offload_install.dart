import 'dart:convert';
import 'dart:io';

import 'package:vault/offload/offload_host_server.dart';
import 'package:vault/offload/offload_protocol.dart';

/// How the WSL guest finds the Windows offload host:
///
/// 1. **Preferred (WSL2 localhostForwarding, default on):**
///    Host binds `127.0.0.1:<port>`. Guest reads `/etc/vault-offload.host`
///    (`127.0.0.1`) and `/etc/vault-offload.port`, then HTTP POSTs to
///    `http://127.0.0.1:<port>/`. WSL forwards localhost to the Windows host.
///
/// 2. **Fallback (NAT without localhost forwarding):**
///    Guest may set host to the Windows side of the default route:
///    `$(ip route | awk '/default/{print $3; exit}')` or the first
///    `nameserver` in `/etc/resolv.conf`. Host must then listen on
///    `0.0.0.0` (not the default — prefer localhostForwarding / mirrored).
///
/// Stubs also re-resolve at runtime if `/etc/vault-offload.host` contains
/// `auto`.

const _offloadCliNames = [
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
];

/// Shared guest helper written to `/usr/local/lib/vault/offload-call`
/// (and copied to each `vault-*` name so `$0` basename is correct).
String vaultOffloadCallScript() => r'''#!/bin/sh
# vault offload client — POST JSON to Windows host bridge
set -eu

HOST_FILE=/etc/vault-offload.host
PORT_FILE=/etc/vault-offload.port

resolve_host() {
  if [ -f "$HOST_FILE" ]; then
    h=$(cat "$HOST_FILE" | tr -d '\r\n' | tr -d ' ')
    if [ -n "$h" ] && [ "$h" != "auto" ]; then
      printf '%s\n' "$h"
      return 0
    fi
  fi
  # WSL2 → Windows host IP (NAT gateway) when localhost forwarding is off
  h=$(ip route 2>/dev/null | awk '/default/{print $3; exit}')
  if [ -n "${h:-}" ]; then
    printf '%s\n' "$h"
    return 0
  fi
  h=$(awk '/^nameserver/{print $2; exit}' /etc/resolv.conf 2>/dev/null | tr -d '\r')
  if [ -n "${h:-}" ]; then
    printf '%s\n' "$h"
    return 0
  fi
  printf '127.0.0.1\n'
}

if [ ! -f "$PORT_FILE" ]; then
  echo "vault-offload: missing $PORT_FILE (is Vault host running?)" >&2
  exit 1
fi
PORT=$(cat "$PORT_FILE" | tr -d '\r\n' | tr -d ' ')
if [ -z "$PORT" ]; then
  echo "vault-offload: empty port file" >&2
  exit 1
fi
HOST=$(resolve_host)

CMD=$(basename "$0")
json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

ARGV='['
first=1
for a in "$CMD" "$@"; do
  if [ "$first" -eq 1 ]; then
    first=0
  else
    ARGV="$ARGV,"
  fi
  esc=$(json_escape "$a")
  ARGV="$ARGV\"$esc\""
done
ARGV="$ARGV]"

CWD=$(pwd 2>/dev/null || echo /)
SESSION="${VAULT_CHAT_SESSION_ID:-}"
SESSION_ESC=$(json_escape "$SESSION")
CWD_ESC=$(json_escape "$CWD")

BODY=$(printf '{"argv":%s,"cwd":"%s","env":{"VAULT_CHAT_SESSION_ID":"%s"},"sessionId":"%s"}' \
  "$ARGV" "$CWD_ESC" "$SESSION_ESC" "$SESSION_ESC")

URL="http://${HOST}:${PORT}/?raw=1"
HDR=$(mktemp)
BODYFILE=$(mktemp)
trap 'rm -f "$HDR" "$BODYFILE"' EXIT

post() {
  if command -v curl >/dev/null 2>&1; then
    curl -sS -D "$HDR" -o "$BODYFILE" -X POST \
      -H 'Content-Type: application/json' \
      -H 'Accept: application/vnd.vault.raw' \
      --data-binary "$BODY" \
      "$URL"
    return $?
  fi
  if command -v wget >/dev/null 2>&1; then
    # BusyBox wget: headers on stderr with --server-response
    wget -q -O "$BODYFILE" --server-response \
      --header='Content-Type: application/json' \
      --header='Accept: application/vnd.vault.raw' \
      --post-data="$BODY" \
      "$URL" 2>"$HDR"
    return $?
  fi
  echo "vault-offload: need curl or wget in guest" >&2
  exit 1
}

if ! post; then
  echo "vault-offload: request failed (host=$HOST port=$PORT)" >&2
  exit 1
fi

EXIT=$(awk 'BEGIN{c=1} {
  line=$0
  sub(/\r/,"",line)
  if (tolower(line) ~ /^[[:space:]]*x-vault-exit-code:/) {
    sub(/^[^:]*:[[:space:]]*/,"",line)
    c=line+0
  }
} END{print c+0}' "$HDR" 2>/dev/null || echo 1)
EXIT=$(printf '%s' "$EXIT" | tr -d '\r')
cat "$BODYFILE"
exit "$EXIT"
''';

/// Install Wave1–3 `vault-*` stubs + host/port files into a WSL distro.
///
/// Uses `wsl.exe` directly — paths under `/etc` and `/usr` are outside
/// guest home, so [SandboxProvider.writeGuestFile] cannot target them.
Future<void> installWslOffloadStubs({
  required String distroName,
  required int port,
  String host = '127.0.0.1',
  Map<String, String> wslHostEnv = const {
    'PATH': r'C:\Windows\System32;C:\Windows',
    'SystemRoot': r'C:\Windows',
    'WINDIR': r'C:\Windows',
  },
}) async {
  await ensureOffloadHostServer();

  final callB64 = base64Encode(utf8.encode(vaultOffloadCallScript()));
  final hostB64 = base64Encode(utf8.encode('$host\n'));
  final portB64 = base64Encode(utf8.encode('$port\n'));

  final cliCopies = _offloadCliNames
      .map(
        (name) =>
            'cp /usr/local/lib/vault/offload-call /usr/local/bin/$name && '
            'chmod 755 /usr/local/bin/$name',
      )
      .join('\n');

  final script = '''
set -e
mkdir -p /usr/local/lib/vault /usr/local/bin /etc
printf '%s' '$callB64' | base64 -d > /usr/local/lib/vault/offload-call
chmod 755 /usr/local/lib/vault/offload-call
$cliCopies
printf '%s' '$hostB64' | base64 -d > $kOffloadGuestHostFile
printf '%s' '$portB64' | base64 -d > $kOffloadGuestPortFile
# Optional: curl makes response headers easier; ignore failure on offline hosts.
apk add --no-cache curl >/dev/null 2>&1 || true
''';

  final result = await Process.run(
    'wsl.exe',
    [
      '-d',
      distroName,
      '-u',
      'root',
      '-e',
      '/bin/sh',
      '-c',
      script,
    ],
    environment: wslHostEnv,
    includeParentEnvironment: false,
  );
  if (result.exitCode != 0) {
    throw StateError(
      '安装 WSL offload stubs 失败（${result.exitCode}）：'
      '${result.stderr}\n${result.stdout}',
    );
  }
}
