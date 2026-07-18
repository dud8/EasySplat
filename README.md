# EasySplat

EasySplat turns video, photos, or both into a 3D Gaussian splat on an Apple Silicon Mac. Processing stays on the Mac. The result is a conventional PLY file.

The current milestone is `v0.2.0-beta.1`, an unsigned public beta for macOS 15 and later. It is not a production-signed release: there is no Developer ID signature, notarization, or Gatekeeper approval yet.

## Install the beta

1. Download `EasySplat-0.2.0-beta.1-unsigned.dmg` from [GitHub Releases](https://github.com/dud8/EasySplat/releases).
2. Drag EasySplat to Applications.
3. On first launch, Control-click EasySplat, choose **Open**, then confirm.
4. Let EasySplat download and verify the components required for the selected job.

The app is unsigned, but downloaded toolchain components are bound to a signed manifest and verified before use.

## Make a splat

1. Select **New Splat**.
2. Choose a video or a folder of photos.
3. Leave Options collapsed for the normal path.
4. Select **Create Splat**.

EasySplat prepares the input, reconstructs the cameras and scene, trains the splat with native Metal code, validates the result, and opens it in the built-in viewer.

One job runs at a time. You can stop safely and resume from the last durable stage. Training resumes only when a complete optimizer checkpoint was written and validated.

## Options that matter

Defaults are Automatic capture, Balanced detail, and Automatic for every other choice.

| Option | Use it when |
| --- | --- |
| Capture Path | Choose **Around a subject** for an object orbit, **Through a space** for an interior or property walkthrough, or **Across a large area** for a long exterior or drone route. |
| Detail | **Fast** favors turnaround and memory use. **Balanced** is the normal choice. **High Detail** uses a larger frame and training budget when the Mac can support it. |
| Camera Source | Choose **Mixed cameras or lenses** when the capture combines devices, zoom settings, or lenses. |
| Lens | Choose **Fisheye** for footage that is genuinely fisheye. Ordinary phone, mirrorless, and drone cameras should normally stay Automatic. |
| Input Order | Use **Continuous sequence** only for one verified continuous route. Use **Unordered** for a photo set with no meaningful sequence. |
| Resource Use | **Conserve Memory** lowers proactive budgets. **Maximum Performance** uses larger budgets within the Mac's memory tier. |
| Photo Use | **Use all valid photos** keeps a curated photo set when it fits the resolved frame budget. Unreadable files and exact duplicates are still rejected. |

### Capture advice

- Move steadily and keep neighboring views overlapping.
- Walk a property as connected rooms, not isolated clips.
- Circle an object at a consistent distance and include high and low angles.
- Close large exterior or drone loops when possible.
- Avoid motion blur, abrupt exposure changes, and long stretches with no texture.
- Mirrors, windows, water, foliage, moving people, and moving vehicles are hard cases. EasySplat treats motion as an outlier; it does not reconstruct dynamic 4D scenes.

If the overlap graph is disconnected, EasySplat stops and explains the capture problem. It does not combine unrelated spaces into a fake coordinate frame.

## Hardware

- macOS 15 or later
- Apple Silicon only
- 8 GB: Fast with Conserve Memory, selected automatically, for small objects or rooms
- 16 GB: Fast and Balanced
- 24 GB or more: Fast, Balanced, and High Detail, with room for larger captures

Memory budgets are proactive. EasySplat does not deliberately run out of memory to discover a limit.

## Privacy

EasySplat has no cloud processing, analytics, telemetry, advertising SDK, or crash SDK. Source media, notes, projects, checkpoints, and outputs remain local unless you explicitly export or share a result.

Diagnostics exclude source images and notes by default. They remove project identity and scrub local paths and URL credentials before preview, copy, or save.

## Projects and output

Projects live under:

```text
~/Documents/EasySplat Projects/
```

Stable paths inside a project are:

```text
SfM/colmap/sparse/0
SfM/geometry_manifest.json
Training/training_manifest.json
Output/splat.ply
```

Stored artifact paths are project-relative and resolved through the safe project-path resolver.

## Troubleshooting

- **The app will not open:** use Control-click → Open. This is expected for the unsigned beta.
- **Setup failed:** try again. A failed tool download does not create a bogus project and preserves the selected input.
- **The scene will not reconstruct:** capture more overlap, remove unrelated clips, or choose the correct Capture Path, Lens, and Input Order.
- **Memory pressure:** choose Fast and Conserve Memory, then reduce capture length if needed.
- **A result will not export:** EasySplat exports only a validated finished PLY.

Use **Copy Diagnostics** or **Save Diagnostics…** from a failed project when asking for help. Report reproducible bugs through [GitHub Issues](https://github.com/dud8/EasySplat/issues). Report security problems privately as described in [SECURITY.md](SECURITY.md).

## Build from source

Requirements:

- macOS 15+
- Apple Silicon
- Xcode 16.4 with the Metal toolchain
- Homebrew build dependencies for the native toolchain

Run the development app:

```bash
./scripts/run.sh
```

Useful variants:

```bash
./scripts/run.sh --fast
./scripts/run.sh --rebuild
./scripts/run.sh --toolchain-root /absolute/path/to/toolchain
```

The only supported development overrides are the local toolchain root, candidate route, stop-after stage, skip-training, and deterministic benchmark seed. Product policy lives in typed run options and resolved plans, not backend-specific environment variables.

## Architecture

```text
input
  → preflight and topology policy
  → bounded COLMAP feature matching and camera reconstruction
  → canonical COLMAP model
  → native msplat Metal training
  → validated Output/splat.ply
```

COLMAP is the automatic geometry route for this beta. It is not a user-facing backend choice. A single-batch DA3 initializer remains available only to the typed benchmark override until it clears the full quality corpus. MetalSplatter is the native result viewer.

The release toolchain is split into signed capabilities:

- `macos-arm64-core`
- `geometry-da3-base`
- `geometry-da3-small`

Normal runs install only the capabilities they need. The automatic route uses native COLMAP from the core component and does not download DA3 or its Python runtime. The optional Base component carries the DA3 runtime; Small adds only the fallback weights.

See [ONBOARDING.md](ONBOARDING.md) for maintainer architecture and [CONTRIBUTING.md](CONTRIBUTING.md) for change rules.

## Validation

```bash
./scripts/test.sh
swift test --package-path Tools/ManifestTool
./scripts/test_python_tools.sh
./scripts/ci/check_repo_health.sh
./scripts/ci/check_workflows.sh
./scripts/ci/test_release_scripts.sh
find scripts -type f -name '*.sh' -print0 | xargs -0 -n1 bash -n
./scripts/benchmark/run_suite.sh --profile release
shellcheck $(git ls-files 'scripts/*.sh' 'scripts/**/*.sh')
actionlint
gitleaks git --redact
```

The full release benchmark needs the external 26-scene corpus described by `scripts/benchmark/corpus.json`; large media is intentionally not stored in Git.
Native trainer changes also run `./scripts/ci/test_msplat_native_build.sh`. The protected Release App workflow supplies the signed toolchain, fixture, online/offline runners, and caches to `verify_beta.sh`, then runs `verify_ui.sh` from an isolated interactive macOS 15/Xcode 16.4 account. Printing either script's help is not a release check.

## Release modes

Build the unsigned beta only with the explicit mode:

```bash
./scripts/release/build_dmg.sh \
  --app-version 0.2.0-beta.1 \
  --toolchain-version 2.0.0 \
  --manifest-url https://github.com/dud8/EasySplat/releases/download/toolchain-v2.0.0/manifest.json \
  --core-artifact-url https://github.com/dud8/EasySplat/releases/download/toolchain-v2.0.0/toolchain-macos-arm64-2.0.0-core.zip \
  --da3-base-artifact-url https://github.com/dud8/EasySplat/releases/download/toolchain-v2.0.0/toolchain-geometry-da3-base-2.0.0.zip \
  --da3-small-artifact-url https://github.com/dud8/EasySplat/releases/download/toolchain-v2.0.0/toolchain-geometry-da3-small-2.0.0.zip \
  --use-existing-toolchain \
  --unsigned-beta
```

The signed manifest, public key, and component archives must already be present under `Toolchains/`. The protected Toolchain Build workflow creates that release closure; `./scripts/run.sh` owns local development builds.

Production packaging is intentionally disabled. `v1.0.0` remains blocked until Developer ID signing, hardened runtime, notarization, stapling, strict code-sign verification, Gatekeeper assessment, and a quarantined clean-Mac install all pass.

## License

EasySplat is released under the [MIT License](LICENSE). Redistributed source, runtime, and model components keep their own licenses; see [NOTICE.md](NOTICE.md) and each release's license bundle and SPDX SBOM.
