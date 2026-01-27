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

## Requirements (development)

- macOS 15+ on Apple Silicon
- Xcode 16+ (Swift 5.9) or the Xcode Command Line Tools
- Toolchain build dependencies:
  - `git`, `cmake`, `ninja`
  - COLMAP/GLOMAP deps (e.g. Eigen, Ceres, Boost, Glog, Gflags, OpenCV, SQLite3)
  - Rust toolchain (for Brush)

## Manual dev setup (optional)

1) Build the toolchain (COLMAP/GLOMAP/Brush):

```
./scripts/toolchain/build_colmap.sh
./scripts/toolchain/build_glomap.sh
./scripts/toolchain/build_brush.sh
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
swift test
```

Note: UI test target is a placeholder in SwiftPM (XCUITest requires an Xcode project).
