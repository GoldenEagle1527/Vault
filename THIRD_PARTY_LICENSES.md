# Third-party licenses

Vault is licensed under the **GNU General Public License v3.0** (see `LICENSE`).
Bundling a patched proot makes the combined work GPL; that is intentional.

## Runtime / bundled components (planned or present)

| Component | License | Notes |
|-----------|---------|--------|
| Alpine Linux minirootfs | GPL / MIT / BSD (mixed) | Bundled under `assets/rootfs/` for WSL import |
| proot (oonid/pr fork, planned) | GPL-2.0 | Android sandbox binary (`libproot.so`) |
| talloc (via proot, planned) | LGPL-3.0 | Dependency of proot |
| proot-distro plugins (planned) | GPL-3.0 | Reference for 16 KB-aligned Alpine rootfs on Android |

## Dart / Flutter packages

See each package on [pub.dev](https://pub.dev) for its license. Notable ones:

| Package | Typical license |
|---------|-----------------|
| flutter_pty | MIT |
| xterm | MIT |
| path_provider | BSD-3-Clause |
| archive | MIT |
| uuid | MIT |

## Distribution

- **Android:** GitHub Releases sideload only (not Play Store). Play policy
  restricts downloading and executing arbitrary code (`apk add`, `npm install`).
- **Windows:** desktop binary; requires user-installed WSL2.
