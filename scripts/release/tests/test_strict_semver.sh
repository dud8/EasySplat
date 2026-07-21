#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=../lib/strict_semver.sh
source "$ROOT/scripts/release/lib/strict_semver.sh"

valid_versions=(
  0.0.0
  1.2.3
  10.20.30
  0.2.0-beta.1
  1.0.0-0
  1.0.0-alpha
  1.0.0-alpha-1
  1.0.0-rc.1
)
invalid_versions=(
  ''
  v1.2.3
  1.2
  1.2.3.4
  01.2.3
  1.02.3
  1.2.03
  1.2.3-
  1.2.3-.
  1.2.3-..
  1.2.3-alpha..1
  1.2.3-01
  1.2.3+build.7
  1.2.3-alpha+build.7
  ' 1.2.3'
  '1.2.3 '
)

for version in "${valid_versions[@]}"; do
  if ! easysplat_is_strict_semver_without_build_metadata "$version"; then
    echo "Strict SemVer validator rejected a valid version: $version" >&2
    exit 1
  fi
done

for version in "${invalid_versions[@]}"; do
  if easysplat_is_strict_semver_without_build_metadata "$version"; then
    echo "Strict SemVer validator accepted an invalid version: $version" >&2
    exit 1
  fi
done

for version in 0.2.0-beta.1 1.0.0-0 1.0.0-rc.1; do
  if ! easysplat_is_strict_semver_prerelease_without_build_metadata "$version"; then
    echo "Prerelease validator rejected a valid prerelease: $version" >&2
    exit 1
  fi
done

for version in 0.2.0 1.0.0 1.0.0-01 1.0.0-.. 1.0.0+build.7; do
  if easysplat_is_strict_semver_prerelease_without_build_metadata "$version"; then
    echo "Prerelease validator accepted an invalid prerelease: $version" >&2
    exit 1
  fi
done

for version in 0.2.0 1.0.0 10.20.30; do
  if ! easysplat_is_strict_semver_stable "$version"; then
    echo "Stable SemVer validator rejected a valid stable version: $version" >&2
    exit 1
  fi
done

for version in 0.2.0-beta.1 1.0.0-rc.1 1.0.0+build.7 v1.0.0; do
  if easysplat_is_strict_semver_stable "$version"; then
    echo "Stable SemVer validator accepted a non-stable version: $version" >&2
    exit 1
  fi
done

echo "strict SemVer contracts passed"
