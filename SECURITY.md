# Security Policy

## Scope

This repository contains:

- the macOS app and shared first-party source,
- release and packaging automation,
- manifest-signing utilities,
- bundled Python bridge code,
- vendored third-party source preserved under its original licenses.

Signing keys, local toolchain bundles, manifests, and large downloaded model artifacts are intentionally excluded from version control and must never be committed.

## Reporting a vulnerability

Do not open a public issue for security-sensitive bugs.

Use GitHub's private vulnerability reporting flow if it is enabled for the repository. If private reporting is unavailable, contact the maintainers directly before making details public and include:

- affected component and version or commit,
- reproduction steps,
- expected impact,
- any suggested mitigation or workaround.

## Response expectations

Maintainers should acknowledge a report quickly, validate whether it affects released artifacts or source only, and coordinate a fix before public disclosure when practical.
