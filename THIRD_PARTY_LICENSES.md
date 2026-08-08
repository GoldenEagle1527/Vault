# Third-party licenses

Vault is licensed under the **GNU General Public License v3.0** (see `LICENSE`).
Bundling a patched proot makes the combined work GPL; that is intentional.

## Runtime / bundled components

| Component | License | Notes |
|-----------|---------|--------|
| Alpine Linux minirootfs (Windows) | GPL / MIT / BSD (mixed) | `assets/rootfs/alpine-minirootfs-*.tar.gz` for WSL import |
| Alpine Linux (proot-distro, Android) | GPL / MIT / BSD (mixed) | `assets/rootfs/android/alpine-prootdistro-aarch64.tar.gz` — pd-v4.37.0 aarch64；16KB 页友好 |
| proot (oonid/pr fork) | GPL-2.0-or-later | `android/.../jniLibs/arm64-v8a/libproot.so` + `libproot-loader.so`；源见 `third_party/oonid-pr`（commit `1f6b10f`） |
| talloc | LGPL-3.0 | 静态链入 proot |
| proot-distro plugins（参考） | GPL-3.0 | oonid/pr / termux 同源插件说明 |

## Dart / Flutter packages

See each package on [pub.dev](https://pub.dev) for its license. Notable ones:

| Package | Typical license |
|---------|-----------------|
| flutter_pty | MIT |
| xterm | MIT |
| path_provider | BSD-3-Clause |
| archive | MIT |
| uuid | MIT |
| flutter_secure_storage | BSD-3-Clause |
| vault_agent_core (vendored) | MIT (Memex Lab) — fork of [dart_agent_core](https://github.com/memex-lab/dart_agent_core) at `683d942`; sources in `packages/vault_agent_core/` (not from pub.dev) |

## Distribution

- **Android:** GitHub Releases sideload only (not Play Store). Play policy
  restricts downloading and executing arbitrary code (`apk add`, `npm install`).
- **Windows:** desktop binary; requires user-installed WSL2.
