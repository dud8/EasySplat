#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$ROOT/Toolchains/build/openssl"
SRC="$WORK/src"
INSTALL="$WORK/install"

OPENSSL_VERSION="${OPENSSL_VERSION:-3.0.13}"
TARBALL="openssl-$OPENSSL_VERSION.tar.gz"
URL="https://www.openssl.org/source/$TARBALL"

mkdir -p "$WORK"

if [ -f "$INSTALL/lib/libcrypto.3.dylib" ] && [ -f "$INSTALL/lib/libssl.3.dylib" ]; then
  echo "OpenSSL already installed to: $INSTALL"
  exit 0
fi

ARCH="$(uname -m)"
if [ "$ARCH" != "arm64" ]; then
  echo "Expected Apple Silicon (arm64), got: $ARCH" >&2
  exit 1
fi

TAR_PATH="$WORK/$TARBALL"
if [ ! -f "$TAR_PATH" ]; then
  curl -L --fail "$URL" -o "$TAR_PATH"
fi

rm -rf "$SRC"
mkdir -p "$SRC"
tar -xzf "$TAR_PATH" -C "$SRC" --strip-components=1

pushd "$SRC" >/dev/null
./Configure darwin64-arm64-cc shared no-tests --prefix="$INSTALL"
make -j"$(sysctl -n hw.ncpu)"
make install_sw
popd >/dev/null

echo "OpenSSL installed to: $INSTALL"

