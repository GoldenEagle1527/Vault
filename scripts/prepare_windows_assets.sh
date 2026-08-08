#!/usr/bin/env bash
# Download Alpine minirootfs tarballs used by WslProvider.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/assets/rootfs"
VER="${ALPINE_VERSION:-3.21.3}"
SERIES="${VER%.*}"
mkdir -p "$OUT"
for arch in x86_64 aarch64; do
  url="https://dl-cdn.alpinelinux.org/alpine/v${SERIES}/releases/${arch}/alpine-minirootfs-${VER}-${arch}.tar.gz"
  dest="$OUT/alpine-minirootfs-${arch}.tar.gz"
  echo "Fetching $url"
  curl -L --fail -o "$dest" "$url"
done
ls -lh "$OUT"
