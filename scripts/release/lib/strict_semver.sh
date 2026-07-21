#!/usr/bin/env bash

easysplat_is_strict_semver_without_build_metadata() {
  local value=${1-}
  local pattern='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-(0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)(\.(0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*))*)?$'
  [[ "$value" =~ $pattern ]]
}

easysplat_is_strict_semver_prerelease_without_build_metadata() {
  local value=${1-}
  easysplat_is_strict_semver_without_build_metadata "$value" \
    && [[ "$value" == *-* ]]
}

easysplat_is_strict_semver_stable() {
  local value=${1-}
  easysplat_is_strict_semver_without_build_metadata "$value" \
    && [[ "$value" != *-* ]]
}
