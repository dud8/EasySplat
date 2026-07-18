# Contributing to EasySplat

EasySplat targets macOS 15 and later on Apple Silicon. Contributions should keep the app approachable for non-developers without hiding useful controls from working photographers and videographers.

## Before you open a PR

1. Read `README.md` for the operational entry point and `ONBOARDING.md` for the deeper architecture map.
2. Keep product scope stable unless the change is explicitly requested.
3. Do not commit toolchain outputs, signing keys, local manifests, caches, or generated build artifacts.

## Local checks

Run the first-party checks that match your change:

```bash
./scripts/test.sh
./scripts/test_python_tools.sh
swift test --package-path Tools/ManifestTool
```

Use `PYTHON_BIN` when your default `python3` is not the prepared interpreter for bridge tests.

If you touch public repo collateral, release scripts, or contributor workflow docs, also run:

```bash
./scripts/ci/check_repo_health.sh
./scripts/ci/test_release_scripts.sh
```

If you touch shell or workflow files, also run:

```bash
find scripts -type f -name '*.sh' -print0 | xargs -0 -n1 bash -n
shellcheck $(git ls-files 'scripts/*.sh' 'scripts/**/*.sh')
./scripts/ci/check_workflows.sh
actionlint
```

Native trainer or packaging changes also require `./scripts/ci/test_msplat_native_build.sh`. Packaged-app release changes must pass the full `verify_beta.sh` and isolated `verify_ui.sh` jobs in the Release App workflow.

## Change guidelines

- Keep orchestration and pipeline behavior in `EasySplatCore`; keep `EasySplatApp` focused on UI state and presentation.
- Use `ProjectPaths`, `ProjectMetadataStore`, `ToolchainManager`, and `SubprocessRunner` instead of inventing parallel file layout or subprocess helpers.
- Keep `./scripts/run.sh` as the one development launcher. Do not add compatibility aliases.
- Preserve the current project artifact contract. Private experimental environment flags are not a compatibility surface.
- Treat vendored code under `ThirdParty/` as frozen upstream unless a blocking security, license, or release issue requires a patch.
- Prefer targeted tests for bug fixes and structural refactors.
- Keep docs aligned when you add or change scripts, env vars, packaging behavior, or project-bundle semantics.
- `ProjectDiagnosticBundle.build` defaults to `includeNotes: false`. Diagnostics must remove project identity, scrub local paths and credentials, and show a preview before sharing.

## Pull requests

- Use a Conventional Commits title or squash title.
- Explain user-visible behavior changes, release/build implications, and any toolchain layout impact.
- Call out new environment variables, scripts, or contributor workflow changes.
- List the validation you ran, especially for tests, release scripts, and docs/repo health.
