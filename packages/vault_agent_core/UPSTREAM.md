# Upstream provenance

Vault owns this tree as a **vendored fork**. Do **not** add `dart_agent_core` from pub.dev.

| Field | Value |
|-------|--------|
| Upstream | https://github.com/memex-lab/dart_agent_core |
| Upstream commit | `683d942ea175c4a5be6cd52c609f4116a48c9b3c` |
| Vendored date | 2026-08-08 |
| Local package name | `vault_agent_core` |
| Upstream license | MIT (Memex Lab) — see `LICENSE` |

## Maintenance

- Treat this directory as first-party Vault code. Edit freely for product needs.
- Do **not** auto-sync with upstream. If a useful fix appears upstream, cherry-pick manually and record the new SHA here.
- Keep `publish_to: none`. This package is not published.

## Rename notes

Upstream package/import name `dart_agent_core` was rewritten to `vault_agent_core` (library entrypoint `lib/vault_agent_core.dart`).
