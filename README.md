# EasySplat

EasySplat is a macOS-only (Apple Silicon) desktop app that turns videos or image folders into 3D Gaussian splats using a bundled toolchain (primarily VGGT-MPS + Brush), with a beginner-friendly UI and progress tracking.

COLMAP/GLOMAP support remains in the toolchain as a fallback / legacy path.

The app downloads a signed `manifest.json` that lists toolchain artifacts (typically split into a smaller “core” zip and a large “models” zip).

## Quick start (recommended)

1) Download the latest `EasySplat-<version>.dmg` from GitHub Releases.
2) Drag `EasySplat.app` into Applications.
3) First launch: right‑click → Open (unsigned app).
4) The app auto-downloads the toolchain on first run (this can be a large download).

## Repo layout (for contributors)

- `EasySplatApp/`: SwiftUI app.
- `EasySplatCore/`: core library (pipeline + toolchain integration).
- `Tools/ManifestTool/`: Swift CLI to generate keypairs and sign manifests.
- `Tools/VggtSfm/`: Python package shipped in the toolchain (VGGT → COLMAP bridge).
- `ThirdParty/MetalSplatter/`: vendored SwiftPM dependency.
- `Toolchains/`: local toolchain build outputs (`build/`, `out/`), plus dev-only keys/manifest (gitignored).
- `scripts/`: development, testing, and release automation.

## Developer one‑liner

The unified dev runner chooses the fast path when a valid toolchain is already installed, and only rebuilds when needed:

```
./scripts/run.sh
```

Common options:
- `--fast`: force the cached-toolchain path (no rebuild/download).
- `--rebuild`: force a toolchain rebuild (preserves models when possible).
- `--version <semver>`: select a toolchain version (default `0.1.0`).

Note: VGGT downloads a large (multi-GB) model the first time the toolchain is built.

Backward-compatible wrappers are still available (`./scripts/dev_run.sh`, `./scripts/run_fast.sh`), but `./scripts/run.sh` is the recommended entry point.

## Build a DMG locally (from scratch)

1) Install dependencies (once):

```
brew install create-dmg cmake ninja boost eigen freeimage glog gflags suitesparse ceres-solver qt glew cgal libomp openimageio
```
If this is your first Xcode install, accept the license:

```
sudo xcodebuild -license accept
```

2) Build toolchain + app + DMG:

```
./scripts/release/build_dmg.sh --version 0.1.0
```

By default the app built into the DMG will be configured to read a manifest URL. If you want the DMG to point at a hosted toolchain, pass URLs explicitly:

```
./scripts/release/build_dmg.sh \
  --version 0.1.0 \
  --manifest-url "https://your-host/manifest.json" \
  --core-artifact-url "https://your-host/toolchain-macos-arm64-0.1.0-core.zip" \
  --models-artifact-url "https://your-host/toolchain-macos-arm64-0.1.0-models.zip"
```

The DMG will be created at `release/DMG/EasySplat-0.1.0.dmg`.
If `create-dmg` fails to unmount with a "Resource busy" error, re-run with (skips Finder layout):

```
EASYSPLAT_DMG_SKIP_JENKINS=1 ./scripts/release/build_dmg.sh --version 0.1.0
```
You can also increase retries or force sandbox-safe mode:

```
EASYSPLAT_DMG_HDIUTIL_RETRIES=40 EASYSPLAT_DMG_SANDBOX_SAFE=1 ./scripts/release/build_dmg.sh --version 0.1.0
```

If you want a locally-built DMG to use a local toolchain server (handy for testing), start a local server and pass localhost URLs that match `Toolchains/` layout:

```
./scripts/release/build_dmg.sh \
  --version 0.1.0 \
  --manifest-url "http://localhost:8000/manifest.json" \
  --core-artifact-url "http://localhost:8000/out/toolchain-macos-arm64-0.1.0-core.zip" \
  --models-artifact-url "http://localhost:8000/out/toolchain-macos-arm64-0.1.0-models.zip"
```

Then serve `Toolchains/`:

```
cd Toolchains
python3 -m http.server 8000
```

## Requirements (development)

- macOS 15+ on Apple Silicon
- Xcode 16+ (Swift 6). (Tests require a full Xcode install; Command Line Tools alone do not include XCTest.)
- Toolchain build dependencies:
  - `git`, `cmake`, `ninja`
  - COLMAP/GLOMAP deps (e.g. Eigen, Ceres, Boost, Glog, Gflags, OpenCV, SQLite3)
  - Rust toolchain (for Brush)
  - Network access for large downloads (VGGT model + Python wheels)
  - `create-dmg` (for DMG packaging)

## Release (GitHub Actions)

Release automation lives in `.github/workflows/` and `scripts/release/`.

At a high level:
- A toolchain release publishes a signed `manifest.json` plus the referenced toolchain artifacts.
- An app release embeds the manifest URL + public key into the app bundle and packages a DMG.

If you change toolchain artifact naming/layout (e.g. core/models split), update both the scripts and the workflows to match.

## Manual dev setup (optional)

1) Build the toolchain:

```
./scripts/toolchain/build_openssl.sh
./scripts/toolchain/build_colmap.sh
./scripts/toolchain/build_glomap.sh
./scripts/toolchain/build_brush.sh
./scripts/toolchain/build_vggt_mps.sh
./scripts/toolchain/package_toolchain.sh --version 0.1.0
```

2) Create a signed manifest:

```
swift run --package-path Tools/ManifestTool ManifestTool generate-keypair \
  --public-key-out Toolchains/public_key_ed25519.txt \
  --private-key-out Toolchains/private_key_ed25519.txt

swift run --package-path Tools/ManifestTool ManifestTool \
  --core-zip Toolchains/out/toolchain-macos-arm64-0.1.0-core.zip \
  --core-url http://localhost:8000/out/toolchain-macos-arm64-0.1.0-core.zip \
  --models-zip Toolchains/out/toolchain-macos-arm64-0.1.0-models.zip \
  --models-url http://localhost:8000/out/toolchain-macos-arm64-0.1.0-models.zip \
  --version 0.1.0 \
  --published-at 2026-01-27T00:00:00Z \
  --private-key "$(cat Toolchains/private_key_ed25519.txt)" \
  --manifest-out Toolchains/manifest.json
```

3) Serve the toolchain files locally:

```
cd Toolchains
python3 -m http.server 8000
```

4) Run the app:

```
EASYSPLAT_TOOLCHAIN_MANIFEST_URL=http://localhost:8000/manifest.json \
EASYSPLAT_TOOLCHAIN_PUBLIC_KEY_BASE64="$(cat Toolchains/public_key_ed25519.txt)" \
swift run EasySplatApp
```

Alternatively, open `Package.swift` in Xcode and run the `EasySplatApp` scheme.

## Tests

Run all tests:

```
./scripts/test.sh
```

Note: UI test target is a placeholder in SwiftPM (XCUITest requires an Xcode project).
Note: `./scripts/test.sh` requires a full Xcode install (Command Line Tools alone do not include XCTest).
