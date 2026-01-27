#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$ROOT/Toolchains/build/brush"
SRC="$WORK/src"
INSTALL="$WORK/install"

mkdir -p "$WORK" "$INSTALL/bin"

if [ ! -d "$SRC/.git" ]; then
  git clone --depth 1 https://github.com/ArthurBrussee/brush.git "$SRC"
fi

pushd "$SRC" >/dev/null
cargo build --release
popd >/dev/null

cp "$SRC/target/release/brush" "$INSTALL/bin/brush"

echo "Brush installed to: $INSTALL"
