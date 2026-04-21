# EasySplat

EasySplat is a macOS-only Apple Silicon app that turns videos, photo folders, or mixed inputs into 3D Gaussian splats.

The default reconstruction path is MapAnything-first, with COLMAP refinement and `global_mapper` / mapper fallback when the job or hardware needs a safer route. The heavy lifting lives in a signed downloadable toolchain, not in the app bundle.

This OSS build keeps distribution simple on purpose: the app itself is currently unsigned and not notarized, while the toolchain remains the signed trust boundary.

## Quick start

1. Download the latest `EasySplat-<version>.dmg` from GitHub Releases.
2. Drag `EasySplat.app` into `/Applications`.
3. First launch: right-click the app and choose `Open` because the app is currently unsigned.
4. Let the app download the signed toolchain on first run.

Each run creates a `.easysplatproj` bundle under `~/Documents/EasySplat Projects/`. The final viewer opens the exported `.ply` from that project bundle's `Output/` folder.

## What each project stores

EasySplat treats each run like a durable project bundle:

- `project.json` stores input choices, preset, pipeline state, checkpoints, recovery flags, and persisted share metrics.
- `Logs/pipeline.log` stores the human-readable pipeline log.
- `Logs/events.jsonl` stores structured pipeline events.
- `Logs/app_events.jsonl` stores app-level events such as sharing activity.
- interrupted runs keep checkpoint data plus `lastRunStartedAt`, which lets the app offer recovery on relaunch.

## Repository map

- `EasySplatApp/`: SwiftUI app target, app model, viewer shell, and bundled resource defaults.
- `EasySplatCore/`: pipeline orchestration, project persistence, toolchain management, subprocess helpers, and SfM runners.
- `EasySplatCore/Tests/EasySplatCoreTests/`: core unit and integration tests.
- `EasySplatAppTests/`: app-model tests.
- `EasySplatUITests/`: placeholder SwiftPM UI-test target.
- `Tools/ManifestTool/`: Swift CLI for Ed25519 key generation and manifest signing.
- `Tools/MapAnythingSfm/`: MapAnything to COLMAP bridge shipped in the toolchain.
- `Tools/VggtSfm/`: VGGT to COLMAP bridge shipped in the toolchain.
- `Tools/FastVggtSfm/`: FastVGGT seed-export bridge shipped in the toolchain.
- `ThirdParty/MetalSplatter/`: vendored viewer dependency.
- `Toolchains/`: local toolchain build outputs, manifests, and dev-only signing keys.
- `scripts/`: dev, test, packaging, benchmarking, and release automation.

## Developer quick start

Preferred local entry point:

```bash
./scripts/run.sh
```

Useful variants:

```bash
./scripts/run.sh --fast
./scripts/run.sh --rebuild
./scripts/run.sh --version 0.1.0
./scripts/run.sh --toolchain-root /absolute/path/to/toolchain
./scripts/run.sh --port 8000
```

What `./scripts/run.sh` does:

- reuses a valid installed toolchain when possible;
- rebuilds and re-packages toolchain artifacts when inputs changed or `--rebuild` is set;
- generates a signed local `Toolchains/manifest.json`;
- serves a temporary public directory containing only the manifest and zip artifacts on `127.0.0.1`;
- exports `EASYSPLAT_TOOLCHAIN_MANIFEST_URL` and `EASYSPLAT_TOOLCHAIN_PUBLIC_KEY_BASE64` for the app run.

Backward-compatible aliases still exist:

- `./scripts/dev_run.sh`
- `./scripts/run_dev.sh`
- `./scripts/run_fast.sh`

Other useful commands:

```bash
./scripts/test.sh
./scripts/test_python_tools.sh
swift test --package-path Tools/ManifestTool
./scripts/benchmark_mapanything.sh --video /absolute/path/to/input.mp4
```

## Runtime configuration

`AppConfig` resolves app-facing URLs and trust inputs in this order:

- project home URL: `EASYSPLAT_PROJECT_HOME_URL`, then `EasySplatApp/Resources/project_home_url.txt`, then `https://github.com/EasySplat/EasySplat`
- toolchain manifest URL: `EASYSPLAT_TOOLCHAIN_MANIFEST_URL`, then `EasySplatApp/Resources/toolchain_manifest_url.txt`, then `<projectHomeURL>/releases/latest/download/manifest.json`
- toolchain public key: `EASYSPLAT_TOOLCHAIN_PUBLIC_KEY_BASE64`, then `EasySplatApp/Resources/public_key_ed25519.txt`

Most useful runtime overrides:

| Variable | Purpose |
| --- | --- |
| `EASYSPLAT_PROJECT_HOME_URL` | Override the project homepage used for derived release URLs and share captions. |
| `EASYSPLAT_TOOLCHAIN_MANIFEST_URL` | Override the manifest URL directly. |
| `EASYSPLAT_TOOLCHAIN_PUBLIC_KEY_BASE64` | Override the embedded public key. |
| `EASYSPLAT_LOCAL_TOOLCHAIN_ROOT` | Skip download/install and validate an already-present local toolchain. |
| `EASYSPLAT_SFM_BACKEND` | Force `mapanything`, `colmap`, `glomap`, `global_mapper`, `vggt`, or `fastvggt`. |
| `EASYSPLAT_SFM_MAPPER` | Steer mapper fallback inside the integrated path: `glomap` means COLMAP `global_mapper`; `colmap` means classic COLMAP `mapper`. |
| `EASYSPLAT_STOP_AFTER_SFM` | Stop the pipeline after reconstruction. |
| `EASYSPLAT_SKIP_TRAINING` | Skip Brush training. |
| `EASYSPLAT_AUTOTUNE` | Enable or disable hardware-based parameter tuning. |
| `EASYSPLAT_COLMAP_USE_GPU` | Toggle GPU use in COLMAP where supported. |
| `EASYSPLAT_COLMAP_FORCE_CPU` / `EASYSPLAT_COLMAP_FORCE_GPU` | Override COLMAP device choice. |

Common MapAnything tuning knobs:

- `EASYSPLAT_MAPANYTHING_DEVICE=mps|cpu`
- `EASYSPLAT_MAPANYTHING_CHECKPOINT=map-anything-apache`
- `EASYSPLAT_MAPANYTHING_RESOLUTION=512|518`
- `EASYSPLAT_MAPANYTHING_MEMORY_EFFICIENT=0|1`
- `EASYSPLAT_MAPANYTHING_MINIBATCH_SIZE=<n>`
- `EASYSPLAT_MAPANYTHING_MAX_POINTS=<n>`
- `EASYSPLAT_MAPANYTHING_CAMERA_TYPE=SIMPLE_RADIAL|SIMPLE_PINHOLE|PINHOLE|OPENCV`
- `EASYSPLAT_MAPANYTHING_SHARED_CAMERA=0|1`
- `EASYSPLAT_MAPANYTHING_ANCHOR_MAX_VIEWS=<n>`
- `EASYSPLAT_MAPANYTHING_WINDOW_SIZE=<n>`
- `EASYSPLAT_MAPANYTHING_WINDOW_OVERLAP=<n>`
- `EASYSPLAT_MAPANYTHING_DIRECT_MIN_TRACK_LENGTH=<n>`

Common global-mapper tuning knobs:

- `EASYSPLAT_GLOBAL_MAPPER_THREADS=<n>`
- `EASYSPLAT_GLOBAL_MAPPER_GP_USE_GPU=0|1`
- `EASYSPLAT_GLOBAL_MAPPER_BA_USE_GPU=0|1`
- `EASYSPLAT_GLOBAL_MAPPER_GPU_INDEX=<idx or -1>`
- `EASYSPLAT_GLOBAL_MAPPER_GP_GPU_INDEX=<idx>`
- `EASYSPLAT_GLOBAL_MAPPER_BA_GPU_INDEX=<idx>`
- `EASYSPLAT_GLOBAL_MAPPER_MIN_NUM_MATCHES=<n>`
- `EASYSPLAT_GLOBAL_MAPPER_BA_NUM_ITERATIONS=<n>`

Common Brush overrides:

- `EASYSPLAT_BRUSH_TOTAL_STEPS=<n>`
- `EASYSPLAT_BRUSH_EXPORT_EVERY=<n>`
- `EASYSPLAT_BRUSH_RUST_LOG=<level>`
- `EASYSPLAT_BRUSH_SNAPSHOT_MIN_STEPS=<n>`
- `EASYSPLAT_BRUSH_SNAPSHOT_MAX_STEPS=<n>`
- `EASYSPLAT_BRUSH_SNAPSHOT_MIN_SECONDS=<n>`
- `EASYSPLAT_BRUSH_SNAPSHOT_MAX_SECONDS=<n>`
- `EASYSPLAT_BRUSH_SNAPSHOT_DEFAULT_SECONDS=<n>`

## SfM behavior

Default behavior when `EASYSPLAT_SFM_BACKEND` is unset:

- EasySplat starts with MapAnything.
- Smaller jobs may export sparse structure directly.
- Larger or tighter-memory jobs use MapAnything seed export plus COLMAP refinement.
- If refinement still is not good enough, EasySplat falls back through COLMAP `global_mapper` and then COLMAP `mapper` when needed.

Compatibility notes:

- `EASYSPLAT_SFM_BACKEND=glomap` and `EASYSPLAT_SFM_BACKEND=global_mapper` are compatibility aliases for COLMAP's integrated `global_mapper` flow.
- `vggt` and `fastvggt` are still available as explicit override paths, but they are no longer the default product story.

## Toolchain model

The app validates a signed `manifest.json` with an embedded Ed25519 public key, then downloads either:

- a split toolchain: `macos-arm64-core` and `macos-arm64-models`
- or an older monolithic `macos-arm64` artifact

The current split layout keeps binaries and Python runtimes in a smaller core zip while large model weights ship separately. Each packaged Python SfM bundle also includes `build_info.json` so releases can be traced back to the source snapshot, runtime, and model metadata used to build it.

Installed toolchains live under:

```text
~/Library/Application Support/EasySplat/Toolchains/<version>/
```

Local development scripts usually emit `Toolchains/manifest.json`. The GitHub toolchain release workflow publishes `Toolchains/out/manifest.json` as the release asset named `manifest.json`.

## Development requirements

- macOS 15+ on Apple Silicon
- Xcode 16+ with the full XCTest toolchain
- Homebrew
- Rust toolchain for Brush (`cargo`)
- network access and enough disk space for large model downloads
- optional: `ffmpeg` / `ffprobe` if you use `scripts/benchmark_mapanything.sh`

To mirror the current GitHub Actions toolchain runner, install:

```bash
brew install cmake ninja boost eigen freeimage glog gflags suitesparse ceres-solver qt glew cgal libomp openimageio create-dmg
```

If this is a fresh Xcode install:

```bash
sudo xcodebuild -license accept
xcodebuild -downloadComponent MetalToolchain
```

`build_app.sh` and `build_dmg.sh` compile the vendored `MetalSplatter` shaders. If release builds fail with `cannot execute tool 'metal'`, the Metal Toolchain component is missing.

## Release packaging

Build only the app bundle:

```bash
./scripts/release/build_app.sh \
  --manifest-url "https://example.com/releases/latest/download/manifest.json" \
  --public-key-path /absolute/path/to/public_key_ed25519.txt \
  --project-url "https://github.com/EasySplat/EasySplat" \
  --version 0.1.0
```

`build_app.sh` requires:

- `--manifest-url`: the manifest URL the shipped app should use
- `--public-key-path`: the public key file copied into the built bundle
- `--version`: bundle version
- `--project-url`: optional project homepage override copied into the built bundle

Build the full toolchain, app bundle, and DMG:

```bash
./scripts/release/build_dmg.sh --version 0.1.0
```

`build_dmg.sh` supports:

- `--version <semver>`
- `--manifest-url <url>`
- `--core-artifact-url <url>`
- `--models-artifact-url <url>`
- `--project-url <url>`
- `--port <port>`

Hosted manifest/artifact example:

```bash
./scripts/release/build_dmg.sh \
  --version 0.1.0 \
  --manifest-url "https://your-host/manifest.json" \
  --core-artifact-url "https://your-host/toolchain-macos-arm64-0.1.0-core.zip" \
  --models-artifact-url "https://your-host/toolchain-macos-arm64-0.1.0-models.zip" \
  --project-url "https://github.com/EasySplat/EasySplat"
```

Dev-only smoke test against a locally served manifest:

```bash
./scripts/release/build_dmg.sh \
  --version 0.1.0 \
  --manifest-url "http://localhost:8000/manifest.json" \
  --core-artifact-url "http://localhost:8000/out/toolchain-macos-arm64-0.1.0-core.zip" \
  --models-artifact-url "http://localhost:8000/out/toolchain-macos-arm64-0.1.0-models.zip"
```

Then serve only the public manifest and artifact files:

```bash
mkdir -p Toolchains/public/out
cp Toolchains/manifest.json Toolchains/public/manifest.json
ln -sf ../../out/toolchain-macos-arm64-0.1.0-core.zip Toolchains/public/out/
ln -sf ../../out/toolchain-macos-arm64-0.1.0-models.zip Toolchains/public/out/
python3 -m http.server --bind 127.0.0.1 8000 --directory Toolchains/public
```

Output paths:

- app bundle: `build/Export/EasySplat.app`
- DMG: `release/DMG/EasySplat-<version>.dmg`

If `create-dmg` fails to unmount with `Resource busy`, retry with:

```bash
EASYSPLAT_DMG_SKIP_JENKINS=1 ./scripts/release/build_dmg.sh --version 0.1.0
```

Other DMG knobs:

- `EASYSPLAT_DMG_HDIUTIL_RETRIES=<n>`
- `EASYSPLAT_DMG_SANDBOX_SAFE=1`

## Manual toolchain workflow

Build the local toolchain pieces:

```bash
./scripts/toolchain/build_openssl.sh
./scripts/toolchain/build_colmap.sh
./scripts/toolchain/build_brush.sh
./scripts/toolchain/build_mapanything_mps.sh
./scripts/toolchain/build_vggt_mps.sh
./scripts/toolchain/build_fastvggt_mps.sh
./scripts/toolchain/package_toolchain.sh --version 0.1.0
```

`scripts/toolchain/build_glomap.sh` is available for direct `glomap` work, but the packaged app path uses COLMAP's integrated `global_mapper` rather than a separately shipped `glomap` binary.

Generate a dev keypair:

```bash
swift run --package-path Tools/ManifestTool ManifestTool generate-keypair \
  --public-key-out Toolchains/public_key_ed25519.txt \
  --private-key-out Toolchains/private_key_ed25519.txt
```

Generate a signed local manifest:

```bash
swift run --package-path Tools/ManifestTool ManifestTool \
  --core-zip Toolchains/out/toolchain-macos-arm64-0.1.0-core.zip \
  --core-url http://localhost:8000/out/toolchain-macos-arm64-0.1.0-core.zip \
  --models-zip Toolchains/out/toolchain-macos-arm64-0.1.0-models.zip \
  --models-url http://localhost:8000/out/toolchain-macos-arm64-0.1.0-models.zip \
  --version 0.1.0 \
  --published-at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --private-key "$(cat Toolchains/private_key_ed25519.txt)" \
  --manifest-out Toolchains/manifest.json
```

Serve only the public manifest and artifact files locally:

```bash
mkdir -p Toolchains/public
cp Toolchains/manifest.json Toolchains/public/manifest.json
rm -rf Toolchains/public/out
mkdir -p Toolchains/public/out
ln -s ../../out/toolchain-macos-arm64-0.1.0-core.zip Toolchains/public/out/
ln -s ../../out/toolchain-macos-arm64-0.1.0-models.zip Toolchains/public/out/
python3 -m http.server --bind 127.0.0.1 8000 --directory Toolchains/public
```

Run the app against that manifest:

```bash
EASYSPLAT_TOOLCHAIN_MANIFEST_URL=http://localhost:8000/manifest.json \
EASYSPLAT_TOOLCHAIN_PUBLIC_KEY_BASE64="$(cat Toolchains/public_key_ed25519.txt)" \
swift run EasySplatApp
```

Or skip manifest download entirely and validate a local install in place:

```bash
EASYSPLAT_LOCAL_TOOLCHAIN_ROOT="/absolute/path/to/toolchain" \
swift run EasySplatApp
```

## Tests

Run all Swift tests:

```bash
./scripts/test.sh
```

Notes:

- `./scripts/test.sh` uses `xcrun swift test --disable-swift-testing --enable-xctest` when Xcode is available.
- It caches SwiftPM artifacts under `build/.swiftpm`.
- `EasySplatUITests/` is only a SwiftPM placeholder; real XCUITest would require an Xcode project.

Run the manifest tool tests:

```bash
swift test --package-path Tools/ManifestTool
```

Run the Python bridge tests for MapAnything, FastVGGT, and VGGT:

```bash
./scripts/test_python_tools.sh
```

## More docs

- `ONBOARDING.md`: maintainer-level architecture, pipeline, persistence, and release context
- `CONTRIBUTING.md`: contributor workflow and PR expectations
- `SECURITY.md`: private disclosure guidance
- `NOTICE.md`: bundled third-party attribution
- `CODE_OF_CONDUCT.md`: community standards
