#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$ROOT/Toolchains/build/brush"
SRC="$WORK/src"
INSTALL="$WORK/install"

mkdir -p "$WORK" "$INSTALL/bin"

BRUSH_REPO_URL="${BRUSH_REPO_URL:-https://github.com/ArthurBrussee/brush.git}"
# Pin to a known-good commit so toolchain builds are reproducible and don't break when upstream changes.
BRUSH_REF="${BRUSH_REF:-373d40aadc61313dd8c44ca14866bd86fc5fe8bb}"

if [ ! -d "$SRC/.git" ]; then
  git clone "$BRUSH_REPO_URL" "$SRC"
fi

pushd "$SRC" >/dev/null
git fetch origin "$BRUSH_REF" >/dev/null 2>&1 || true
git checkout "$BRUSH_REF" >/dev/null 2>&1 || {
  echo "Failed to checkout Brush ref '$BRUSH_REF'. Set BRUSH_REF to a valid commit/branch." >&2
  exit 1
}
cargo build --release
popd >/dev/null

cp "$SRC/target/release/brush" "$INSTALL/bin/brush"

echo "Brush installed to: $INSTALL"
