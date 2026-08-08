#!/usr/bin/env bash
# Install patched proot into Vault Android jniLibs (arm64-v8a).
#
# oonid/pr ships prebuilt libproot.so + libproot-loader.so built with
# -Wl,-z,max-page-size=16384 (NDK r27c). The published source tree does not
# currently include src/proot/src/loader/, so the default mode copies those
# prebuilts. Use --from-source when loader sources are available locally.
#
# Usage:
#   ./scripts/build_android_proot.sh              # --use-prebuilt (default)
#   ./scripts/build_android_proot.sh --use-prebuilt
#   NDK_PATH=... ./scripts/build_android_proot.sh --from-source
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PR_ROOT="${REPO_ROOT}/third_party/oonid-pr"
OUT_JNILIBS="${REPO_ROOT}/android/app/src/main/jniLibs/arm64-v8a"
MODE="prebuilt"

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

for arg in "$@"; do
  case "$arg" in
    --use-prebuilt) MODE="prebuilt" ;;
    --from-source) MODE="source" ;;
    -h|--help)
      sed -n '2,16p' "$0"
      exit 0
      ;;
    *) die "Unknown option: $arg" ;;
  esac
done

[ -d "${PR_ROOT}" ] || die "Missing ${PR_ROOT}. Clone https://github.com/oonid/pr.git there."

install_bins() {
  local proot_bin="$1"
  local loader_bin="$2"
  [ -f "$proot_bin" ] || die "Missing $proot_bin"
  [ -f "$loader_bin" ] || die "Missing $loader_bin"
  mkdir -p "$OUT_JNILIBS"
  cp -f "$proot_bin" "${OUT_JNILIBS}/libproot.so"
  cp -f "$loader_bin" "${OUT_JNILIBS}/libproot-loader.so"
  chmod 755 "${OUT_JNILIBS}/libproot.so" "${OUT_JNILIBS}/libproot-loader.so"
  info "Installed:"
  ls -la "${OUT_JNILIBS}/libproot.so" "${OUT_JNILIBS}/libproot-loader.so"
  info "oonid/pr commit: $(cd "$PR_ROOT" && git rev-parse HEAD 2>/dev/null || echo unknown)"
}

if [ "$MODE" = "prebuilt" ]; then
  info "Using oonid/pr prebuilt jniLibs (16KB page-aligned, NDK r27c)"
  install_bins \
    "${PR_ROOT}/android/app/src/main/jniLibs/arm64-v8a/libproot.so" \
    "${PR_ROOT}/android/app/src/main/jniLibs/arm64-v8a/libproot-loader.so"
  info "M2a binary install complete (--use-prebuilt)."
  exit 0
fi

# ---- from-source path (requires loader/ present + NDK) ----
[ -f "${PR_ROOT}/src/proot/src/loader/script.h" ] || die \
  "loader sources missing under ${PR_ROOT}/src/proot/src/loader/. Use --use-prebuilt."
[ -f "${PR_ROOT}/vendor/samba/lib/talloc/talloc.c" ] || die \
  "Missing talloc. Checkout samba @ 2f8dfde into vendor/samba (sparse lib/talloc)."

NDK="${NDK_PATH:-${ANDROID_NDK_HOME:-}}"
[ -n "$NDK" ] && [ -d "$NDK" ] || die "Set NDK_PATH or ANDROID_NDK_HOME"

HOST_TAG=""
for tag in windows-x86_64 linux-x86_64 darwin-x86_64; do
  if [ -d "${NDK}/toolchains/llvm/prebuilt/${tag}/bin" ]; then
    HOST_TAG="$tag"
    break
  fi
done
[ -n "$HOST_TAG" ] || die "No NDK llvm prebuilt under ${NDK}"

info "NDK: ${NDK} (host ${HOST_TAG})"

BUILD_SH="${PR_ROOT}/scripts/build.sh"
TMP_BUILD="${PR_ROOT}/scripts/_build_host.sh"
trap 'rm -f "$TMP_BUILD"' EXIT

sed \
  -e "s|linux-x86_64|${HOST_TAG}|g" \
  -e 's|for cmd in make python3 readelf file curl; do|for cmd in make python3 curl; do|' \
  "$BUILD_SH" > "$TMP_BUILD"

if ! command -v readelf &>/dev/null; then
  NDK_BIN="${NDK}/toolchains/llvm/prebuilt/${HOST_TAG}/bin"
  mkdir -p "${PR_ROOT}/build/_shims"
  cat > "${PR_ROOT}/build/_shims/readelf" <<EOF
#!/usr/bin/env bash
exec "${NDK_BIN}/llvm-readelf" "\$@"
EOF
  chmod +x "${PR_ROOT}/build/_shims/readelf"
  export PATH="${PR_ROOT}/build/_shims:${PATH}"
fi
if ! command -v file &>/dev/null; then
  mkdir -p "${PR_ROOT}/build/_shims"
  printf '%s\n' '#!/usr/bin/env bash' 'echo "file: (shim) $*"' \
    > "${PR_ROOT}/build/_shims/file"
  chmod +x "${PR_ROOT}/build/_shims/file"
  export PATH="${PR_ROOT}/build/_shims:${PATH}"
fi

if [[ "$(uname -s)" == MINGW* || "$(uname -s)" == MSYS* ]]; then
  SHORT_BASH="$(powershell.exe -NoProfile -Command \
    "(New-Object -ComObject Scripting.FileSystemObject).GetFile('C:\\Program Files\\Git\\usr\\bin\\bash.exe').ShortPath" \
    2>/dev/null | tr -d '\r' || true)"
  if [ -n "$SHORT_BASH" ]; then
    export MAKE_SHELL="$(cygpath -m "$SHORT_BASH" 2>/dev/null || echo "$SHORT_BASH")"
    export PATH="$(cygpath -u "$(dirname "$SHORT_BASH")"):${PATH}"
    sed -i \
      -e 's|make -C "${SRC_DIR}/src"|make -C "${SRC_DIR}/src" SHELL="${MAKE_SHELL}" USE_BUILD_H="cli/cli.o cli/proot.o"|' \
      "$TMP_BUILD"
  fi
fi

chmod +x "$TMP_BUILD"
bash "$TMP_BUILD" --arch=arm64 --ndk-path="$NDK"
install_bins \
  "${PR_ROOT}/build/out/arm64/proot" \
  "${PR_ROOT}/build/out/arm64/loader"
info "M2a binary build complete (--from-source)."
