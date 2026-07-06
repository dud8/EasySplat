# Contributing to EasySplat

EasySplat is a macOS-only Apple Silicon project. Contributions should keep the app approachable for non-developers while preserving the reliability of a long-running reconstruction pipeline.

## Before you open a PR

1. Read `README.md` for the operational entry point and `ONBOARDING.md` for the deeper architecture map.
2. Keep product scope stable unless the change is explicitly requested.
3. Do not commit toolchain outputs, signing keys, local manifests, caches, or generated build artifacts.

## Local checks

Run the first-party checks that match your change:

```bash
./scripts/test.sh
./scripts/test_python_tools.sh
PYTHON_BIN=/opt/homebrew/bin/python3 ./scripts/test_python_tools.sh
swift test --package-path Tools/ManifestTool
```

Use `PYTHON_BIN` when your default `python3` is not the prepared interpreter for bridge tests.

If you touch public repo collateral, release scripts, or contributor workflow docs, also run:

```bash
./scripts/ci/check_repo_health.sh
```

If you touch shell scripts, also run:

```bash
find scripts -type f -name '*.sh' -print0 | xargs -0 -n1 bash -n
```

## Change guidelines

- Keep orchestration and pipeline behavior in `EasySplatCore`; keep `EasySplatApp` focused on UI state and presentation.
- Use `ProjectPaths`, `ProjectMetadataStore`, `ToolchainManager`, and `SubprocessRunner` instead of inventing parallel file layout or subprocess helpers.
- Preserve current script interfaces and the public `EasySplatCore` surface unless a breaking change is explicitly approved.
- Treat vendored code under `ThirdParty/` as frozen upstream unless a blocking security, license, or release issue requires a patch.
- Prefer targeted tests for bug fixes and structural refactors.
- Keep docs aligned when you add or change scripts, env vars, packaging behavior, or project-bundle semantics.
- `ProjectDiagnosticBundle.build` defaults to `includeNotes: false`, and the clipboard / save panel flow honors that default. Diagnostic bundles can still include project titles and sanitized log tails, so public destinations should keep notes opt-in and should not promise that every line is private.

## Pull requests

- Use a Conventional Commits title or squash title.
- Explain user-visible behavior changes, release/build implications, and any toolchain layout impact.
- Call out new environment variables, scripts, or contributor workflow changes.
- List the validation you ran, especially for tests, release scripts, and docs/repo health.
