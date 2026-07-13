# Security policy

## Supported release

Security fixes currently target the latest `0.2.x` public beta. The beta app is unsigned and not notarized; that limitation is stated in the DMG filename, app metadata, release notes, and provenance.

## Report privately

Do not open a public issue for a vulnerability. Use GitHub private vulnerability reporting for [dud8/EasySplat](https://github.com/dud8/EasySplat/security/advisories/new). If that form is unavailable, contact the maintainer privately before disclosure.

Public-beta packaging independently validates the generated SPDX 2.3 SBOM and blocks fixed High or Critical vulnerabilities before creating a draft release.

Include the affected version or commit, reproduction steps, impact, and any known mitigation. Do not attach private source media, project notes, credentials, or signing keys.

## Trust boundaries

- Processing is local. EasySplat has no analytics, telemetry, advertising SDK, or crash SDK.
- Toolchain manifests are Ed25519-signed. Components are fetched over HTTPS, size-checked, SHA-256 verified, safely extracted, and bound to signed receipts and critical-file hashes.
- HTTP is accepted only for explicit loopback development.
- Archive traversal, absolute paths, and escaping symlinks are rejected.
- Stored project paths are relative and pass the project-root resolver.
- Private signing keys must remain in protected release environments or owner-only local files. They must never appear in arguments, logs, commits, or artifacts.
- Production packaging is disabled until the full signing, notarization, stapling, Gatekeeper, and clean-Mac installation gates exist. It never falls back to an unsigned production artifact.

## Diagnostics

Diagnostics omit source images and notes by default, remove project title and UUID, scrub local/removable-volume paths and URL credentials, and show a preview before copy or save. Review that preview before sharing it.

## Release response

Maintainers should confirm receipt, reproduce the issue, determine whether released artifacts are affected, rotate compromised keys or credentials immediately, and coordinate a fix before disclosure when practical.
