# EasySplat

EasySplat is a macOS‑only (Apple Silicon) desktop app that turns videos or image folders into Gaussian splats using COLMAP/GLOMAP + Brush, with a beginner‑friendly UI and progress tracking.

## Quick start (recommended)

1) Download the latest `EasySplat-<version>.dmg` from GitHub Releases.
2) Drag `EasySplat.app` into Applications.
3) First launch: right‑click → Open (unsigned app).
4) The app auto‑downloads the toolchain on first run.

## Developer one‑liner

This builds the local toolchain, serves it, and launches the app:

```
./scripts/dev_run.sh
```

Note: the learned matcher downloads several GB of model weights on first run.
Set `EASYSPLAT_LEARNED_RETRIEVAL=1` to also download retrieval weights and dependencies.

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

By default the manifest/artifact URLs are set to `http://localhost:8000/...`. If you want the DMG to point at a hosted toolchain instead, pass URLs explicitly:

```
./scripts/release/build_dmg.sh \
  --version 0.1.0 \
  --manifest-url "https://your-host/manifest.json" \
  --artifact-url "https://your-host/toolchain-macos-arm64-0.1.0.zip"
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
If you keep the default localhost URLs, start a local server before launching the app:

```
cd Toolchains
python3 -m http.server 8000
```

## Requirements (development)

- macOS 15+ on Apple Silicon
- Xcode 16+ (Swift 6) or the Xcode Command Line Tools
- Toolchain build dependencies:
  - `git`, `cmake`, `ninja`
  - COLMAP/GLOMAP deps (e.g. Eigen, Ceres, Boost, Glog, Gflags, OpenCV, SQLite3)
  - Rust toolchain (for Brush)
  - Python 3 + pip (for learned matching)
  - `create-dmg` (for DMG packaging)

## Release (GitHub Actions)

1) Build the toolchain (uploads `toolchain-macos-arm64-<version>.zip` + `manifest.json`):
   - Run the **Toolchain Build** workflow, or push tag `toolchain-v<version>`.
   - Requires repo secret `TOOLCHAIN_SIGNING_KEY_BASE64` (base64 private key).

2) Build the app + DMG (uploads `EasySplat-<version>.dmg`):
   - Run the **Release App** workflow, or push tag `v<version>`.
   - Requires repo secret `TOOLCHAIN_PUBLIC_KEY_BASE64` (base64 public key).
   - Expects the matching toolchain release tag `toolchain-v<version>`.

## Manual dev setup (optional)

1) Build the toolchain (COLMAP/GLOMAP/Brush/Learned matching):

```
./scripts/toolchain/build_colmap.sh
./scripts/toolchain/build_glomap.sh
./scripts/toolchain/build_brush.sh
./scripts/toolchain/build_learned_sfm.sh
./scripts/toolchain/package_toolchain.sh --version 0.1.0
```

2) Create a signed manifest:

```
swift run --package-path Tools/ManifestTool ManifestTool generate-keypair \
  --public-key-out Toolchains/public_key_ed25519.txt \
  --private-key-out Toolchains/private_key_ed25519.txt

swift run --package-path Tools/ManifestTool ManifestTool \
  --zip Toolchains/out/toolchain-macos-arm64-0.1.0.zip \
  --version 0.1.0 \
  --published-at 2026-01-27T00:00:00Z \
  --artifact-url http://localhost:8000/toolchain-macos-arm64-0.1.0.zip \
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

## Learned matching notes

EasySplat's learned matcher uses MASt3R (CC BY-NC-SA 4.0). The build script downloads several GB of model weights on first run.
