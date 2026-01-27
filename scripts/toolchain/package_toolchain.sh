#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VERSION=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      VERSION="$2"
      shift 2
      ;;
    *)
      echo "Unknown arg: $1" >&2
      exit 1
      ;;
  esac
done

if [ -z "$VERSION" ]; then
  echo "Usage: package_toolchain.sh --version <semver>" >&2
  exit 1
fi

COLMAP_INSTALL="${COLMAP_INSTALL:-$ROOT/Toolchains/build/colmap/install}"
GLOMAP_INSTALL="${GLOMAP_INSTALL:-$ROOT/Toolchains/build/glomap/install}"
BRUSH_INSTALL="${BRUSH_INSTALL:-$ROOT/Toolchains/build/brush/install}"

OUT="$ROOT/Toolchains/out"
BIN="$OUT/bin"
ZIP="$OUT/toolchain-macos-arm64-$VERSION.zip"

rm -rf "$OUT"
mkdir -p "$BIN"

cp "$COLMAP_INSTALL/bin/colmap" "$BIN/colmap"
cp "$GLOMAP_INSTALL/bin/glomap" "$BIN/glomap"
cp "$BRUSH_INSTALL/bin/brush" "$BIN/brush"

chmod +x "$BIN/colmap" "$BIN/glomap" "$BIN/brush"

pushd "$OUT" >/dev/null
zip -r "$ZIP" bin
popd >/dev/null

echo "Packaged toolchain: $ZIP"
