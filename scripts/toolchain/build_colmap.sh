#!/bin/bash
set -euo pipefail

SCRIPT_DIRECTORY="$(builtin cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")" && builtin pwd -P)"
IMPLEMENTATION="$SCRIPT_DIRECTORY/build_colmap_impl.sh"
BOOTSTRAP_CMAKE_BIN="$(builtin type -P cmake || true)"
BOOTSTRAP_GIT_BIN="$(builtin type -P git || true)"
BOOTSTRAP_NINJA_BIN="$(builtin type -P ninja || true)"
BOOTSTRAP_RG_BIN="$(builtin type -P rg || true)"

for tool in \
  "$BOOTSTRAP_CMAKE_BIN" \
  "$BOOTSTRAP_GIT_BIN" \
  "$BOOTSTRAP_NINJA_BIN" \
  "$BOOTSTRAP_RG_BIN"; do
  if [[ "$tool" != /* || ! -x "$tool" ]]; then
    builtin printf '%s\n' \
      "COLMAP build failed: cmake, git, ninja, and rg must resolve to external executables" >&2
    exit 1
  fi
done
if [[ ! -f "$IMPLEMENTATION" || -L "$IMPLEMENTATION" ]]; then
  builtin printf '%s\n' \
    "COLMAP build failed: hermetic implementation is missing" >&2
  exit 1
fi

builtin exec /usr/bin/env -i \
  EASYSPLAT_BOOTSTRAP_CMAKE="$BOOTSTRAP_CMAKE_BIN" \
  EASYSPLAT_BOOTSTRAP_GIT="$BOOTSTRAP_GIT_BIN" \
  EASYSPLAT_BOOTSTRAP_NINJA="$BOOTSTRAP_NINJA_BIN" \
  EASYSPLAT_BOOTSTRAP_RG="$BOOTSTRAP_RG_BIN" \
  PATH=/usr/bin:/bin:/usr/sbin:/sbin \
  /bin/bash --noprofile --norc "$IMPLEMENTATION" "$@"
