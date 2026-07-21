# Security policy

## Supported versions

Security fixes target the stable `0.2.x` line. Update to the latest published `0.2.x` release before reporting a problem that may already be fixed.

## Report privately

Do not open a public issue for a vulnerability. Use GitHub private vulnerability reporting for [dud8/EasySplat](https://github.com/dud8/EasySplat/security/advisories/new). If that form is unavailable, contact the maintainer privately before disclosure.

Release packaging independently validates the generated SPDX 2.3 SBOM and blocks fixed High or Critical vulnerabilities before creating a draft release.

Include the affected version or commit, reproduction steps, impact, and any known mitigation. Do not attach private source media, project notes, credentials, or signing keys.

## Trust boundaries

- Processing is local. EasySplat has no analytics, telemetry, advertising SDK, or crash SDK.
- Toolchain manifests are Ed25519-signed. Components are fetched over HTTPS, size-checked, SHA-256 verified, safely extracted, and bound to signed receipts and critical-file hashes.
- HTTP is accepted only for explicit loopback development.
- Archive traversal, absolute paths, and escaping symlinks are rejected.
- Stored project paths are relative and pass the project-root resolver.
- Private signing keys must remain in protected release environments or owner-only local files. They must never appear in arguments, logs, commits, or artifacts.
- Direct GitHub releases are Developer ID signed with the hardened runtime, notarized, and stapled. Release verification checks nested code, notarization receipts, Gatekeeper assessment, and a quarantined clean installation. Production packaging never falls back to an unsigned artifact.

## Diagnostics

Diagnostics omit source images and notes by default, remove project title and UUID, scrub local/removable-volume paths and URL credentials, and show a preview before copy or save. Review that preview before sharing it.

## Release response

Maintainers should confirm receipt, reproduce the issue, determine whether released artifacts are affected, rotate compromised keys or credentials immediately, and coordinate a fix before disclosure when practical.
