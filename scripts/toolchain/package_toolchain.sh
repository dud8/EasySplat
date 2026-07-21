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
SEMVER_PATTERN='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?(\+[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$'
if [[ ! "$VERSION" =~ $SEMVER_PATTERN ]]; then
  echo "Toolchain version is not valid semantic versioning: $VERSION" >&2
  exit 1
fi

COLMAP_INSTALL="${COLMAP_INSTALL:-$ROOT/Toolchains/build/colmap/install}"
COLMAP_SUPPORT_INSTALL="${COLMAP_SUPPORT_INSTALL:-$ROOT/Toolchains/build/colmap-support/install}"
CERES_INSTALL="${CERES_INSTALL:-$ROOT/Toolchains/build/ceres/install}"
OPENIMAGEIO_INSTALL="${OPENIMAGEIO_INSTALL:-$ROOT/Toolchains/build/openimageio/install}"
MSPLAT_INSTALL="${MSPLAT_INSTALL:-$ROOT/Toolchains/build/msplat/install}"
DA3_MPS_INSTALL="${DA3_MPS_INSTALL:-$ROOT/Toolchains/build/da3_mps/install}"
MSPLAT_VALIDATOR="$ROOT/scripts/toolchain/validate_native_msplat.sh"
DA3_PAYLOAD_VALIDATOR="$ROOT/scripts/toolchain/validate_da3_payload.py"
SUPPLY_CHAIN_GENERATOR="$ROOT/scripts/toolchain/generate_supply_chain_manifest.py"
REPRODUCIBLE_ZIP="$ROOT/scripts/toolchain/create_reproducible_zip.py"

OUT="$ROOT/Toolchains/out"
BIN="$OUT/bin"
LIB="$OUT/lib"
LICENSES="$OUT/licenses"
PROVENANCE="$OUT/provenance"
SUPPLY_CHAIN="$OUT/supply-chain"
CORE_ZIP="$OUT/toolchain-macos-arm64-$VERSION-core.zip"
DA3_BASE_ZIP="$OUT/toolchain-geometry-da3-base-$VERSION.zip"
DA3_SMALL_ZIP="$OUT/toolchain-geometry-da3-small-$VERSION.zip"
MAX_RELEASE_ASSET_BYTES=2147483648
MAX_CORE_DOWNLOAD_BYTES=2500000000
MAX_FULL_DOWNLOAD_BYTES=6000000000

die() {
  echo "$*" >&2
  exit 1
}

require_committed_packaging_sources() {
  local status_output
  local -a source_pathspecs=(
    LICENSE
    Tools/Da3Sfm
    Tools/ManifestTool
    Tools/MsplatNative
    Tools/NativeColmap
    scripts/ci/generate_msplat_sparse_fixtures.py
    scripts/toolchain/atomic_swap_install.py
    scripts/toolchain/build_colmap_support.sh
    scripts/toolchain/build_colmap_support_impl.sh
    scripts/toolchain/colmap-support-lock.json
    scripts/toolchain/build_ceres.sh
    scripts/toolchain/build_ceres_impl.sh
    scripts/toolchain/ceres-lock.json
    scripts/toolchain/build_openimageio.sh
    scripts/toolchain/build_openimageio_impl.sh
    scripts/toolchain/openimageio-lock.json
    scripts/toolchain/build_colmap.sh
    scripts/toolchain/build_colmap_impl.sh
    scripts/toolchain/secure_colmap_build.py
    scripts/toolchain/patches/colmap-4.1.1-easysplat.patch
    scripts/toolchain/build_da3_mps.sh
    scripts/toolchain/da3-model-lock.json
    scripts/toolchain/build_msplat.sh
    scripts/toolchain/create_reproducible_zip.py
    scripts/toolchain/generate_supply_chain_manifest.py
    scripts/toolchain/package_toolchain.sh
    scripts/toolchain/safe_extract_source.py
    scripts/toolchain/tests
    scripts/toolchain/validate_da3_payload.py
    scripts/toolchain/validate_native_msplat.sh
  )
  status_output="$(
    git -C "$ROOT" status --porcelain --untracked-files=all -- \
      "${source_pathspecs[@]}"
  )"
  if [ -n "$status_output" ]; then
    echo "Toolchain source inputs must be committed before release packaging." >&2
    echo "$status_output" >&2
    exit 1
  fi
}

require_regular_file() {
  local path="$1"
  [ -f "$path" ] && [ ! -L "$path" ] && [ -s "$path" ] || \
    die "Required release input is missing, empty, or a symlink: $path"
}

assert_release_asset_size() {
  local archive="$1"
  local size
  size="$(stat -f '%z' "$archive")"
  (( size < MAX_RELEASE_ASSET_BYTES )) || \
    die "Release component must be smaller than 2 GiB: $archive ($size bytes)"
}

assert_download_closure_size() {
  local core_size total_size archive size
  core_size="$(stat -f '%z' "$CORE_ZIP")"
  (( core_size <= MAX_CORE_DOWNLOAD_BYTES )) || \
    die "Core-only toolchain download exceeds 2.5 GB: $core_size bytes"
  total_size=0
  for archive in "$@"; do
    size="$(stat -f '%z' "$archive")"
    total_size=$((total_size + size))
  done
  (( total_size <= MAX_FULL_DOWNLOAD_BYTES )) || \
    die "Full optional toolchain download exceeds 6 GB: $total_size bytes"
}

assert_exact_da3_model_payload() {
  local model_root="$1"
  local actual expected name
  expected="$(printf '%s\n' LICENSE config.json easysplat_model_info.json model.safetensors)"
  actual="$(find "$model_root" -mindepth 1 -maxdepth 1 -exec basename {} \; | LC_ALL=C sort)"
  [ "$actual" = "$expected" ] || {
    echo "DA3 model payload must contain exactly four release files: $model_root" >&2
    printf 'Found:\n%s\n' "$actual" >&2
    exit 1
  }
  for name in LICENSE config.json easysplat_model_info.json model.safetensors; do
    require_regular_file "$model_root/$name"
  done
}

require_arm64_only_macho() {
  local label="$1" binary="$2" desc architectures
  desc="$(/usr/bin/file -b "$binary")"
  [[ "$desc" == *Mach-O* ]] || die "$label is not a Mach-O binary (file reported: $desc)."
  architectures="$(/usr/bin/lipo -archs "$binary" 2>/dev/null)" || \
    die "$label architecture could not be inspected with lipo."
  [[ "$architectures" == "arm64" && "$desc" != *"universal binary"* ]] || \
    die "$label must be an arm64-only Mach-O binary (found: $architectures)."
}

require_macos_15_binary() {
  local label="$1" binary="$2"
  /usr/bin/vtool -show-build "$binary" 2>/dev/null | \
    awk '$1 == "minos" && $2 == "15.0" { found = 1 } END { exit found ? 0 : 1 }' || \
    die "$label must declare macOS 15.0 as its minimum deployment target."
}

require_adhoc_signature() {
  local label="$1" binary="$2" details
  /usr/bin/codesign --verify --strict "$binary" || die "$label has an invalid code signature."
  details="$(/usr/bin/codesign -dvv "$binary" 2>&1)"
  printf '%s\n' "$details" | grep -Fx 'Signature=adhoc' >/dev/null || \
    die "$label must carry an ad-hoc code signature."
}

is_system_dependency() {
  case "$1" in
    /usr/lib/*|/System/Library/*) return 0 ;;
    *) return 1 ;;
  esac
}

otool_dependency_names() {
  otool -L "$1" | awk 'NR > 1 { print $1 }'
}

validate_native_colmap_linkage() {
  local binary="$1" dependency install_id found_openmp=0
  install_id="$(otool -D "$binary" 2>/dev/null | awk 'NR == 2 { print; exit }' || true)"
  while IFS= read -r dependency; do
    [ -n "$dependency" ] || continue
    [ "$dependency" = "$install_id" ] && continue
    if is_system_dependency "$dependency"; then
      continue
    fi
    if [ "$dependency" = '@rpath/libomp.dylib' ]; then
      found_openmp=1
      continue
    fi
    die "Native COLMAP has an unapproved runtime dependency: $dependency"
  done < <(otool_dependency_names "$binary")
  (( found_openmp == 1 )) || die "Native COLMAP does not link @rpath/libomp.dylib."
  otool -l "$binary" | \
    awk '$1 == "cmd" && $2 == "LC_RPATH" { in_rpath = 1; next }
         in_rpath && $1 == "path" && $2 == "@executable_path/../lib" { found = 1 }
         in_rpath && $1 == "path" { in_rpath = 0 }
         END { exit found ? 0 : 1 }' || \
    die "Native COLMAP is missing the @executable_path/../lib rpath."
}

validate_libomp_linkage() {
  local binary="$1" dependency install_id
  install_id="$(otool -D "$binary" 2>/dev/null | awk 'NR == 2 { print; exit }' || true)"
  [ "$install_id" = '@rpath/libomp.dylib' ] || \
    die "Packaged libomp has an unexpected install name: $install_id"
  while IFS= read -r dependency; do
    [ -n "$dependency" ] || continue
    [ "$dependency" = "$install_id" ] && continue
    is_system_dependency "$dependency" || \
      die "Packaged libomp has an unapproved runtime dependency: $dependency"
  done < <(otool_dependency_names "$binary")
}

validate_native_receipts() {
  python3 - \
    "$COLMAP_INSTALL" \
    "$COLMAP_SUPPORT_INSTALL" \
    "$CERES_INSTALL" \
    "$OPENIMAGEIO_INSTALL" <<'PY'
import hashlib
import json
import os
import stat
import sys
from pathlib import Path

colmap, support, ceres, openimageio = map(Path, sys.argv[1:])


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def load_receipt(root: Path, name: str) -> dict:
    path = root / "build_info.json"
    if path.is_symlink() or not path.is_file():
        raise SystemExit(f"{name} receipt is missing or unsafe: {path}")
    payload = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict) or payload.get("toolchain_name") != name:
        raise SystemExit(f"unexpected toolchain_name in {path}")
    return payload


def library_hashes(root: Path, receipt: dict) -> dict[str, str]:
    declared: dict[str, str] = {}
    for entry in receipt.get("libraries", []):
        declared[f"lib/{entry['file']}"] = entry["sha256"]
    for raw_path, digest in receipt.get("library_sha256", {}).items():
        relative = raw_path if "/" in raw_path else f"lib/{raw_path}"
        declared[relative] = digest
    if not declared:
        raise SystemExit(f"dependency receipt has no library hashes: {root}")
    for relative, expected in declared.items():
        if relative.startswith("/") or ".." in Path(relative).parts:
            raise SystemExit(f"unsafe library path in receipt: {relative}")
        path = root / relative
        if path.is_symlink() or not path.is_file() or sha256(path) != expected:
            raise SystemExit(f"dependency library hash mismatch: {path}")
    return dict(sorted(declared.items()))


def prefix_tree_sha256(root: Path) -> str:
    if root.is_symlink() or not root.is_dir():
        raise SystemExit(f"dependency prefix is missing or unsafe: {root}")
    digest = hashlib.sha256()
    paths = [root, *sorted(
        root.rglob("*"), key=lambda path: path.relative_to(root).as_posix()
    )]
    for path in paths:
        relative = "." if path == root else path.relative_to(root).as_posix()
        metadata = path.lstat()
        if (metadata.st_uid, metadata.st_gid) != (os.getuid(), os.getgid()):
            raise SystemExit(f"dependency has noncanonical ownership: {relative}")
        if relative == "build_info.json":
            continue
        if stat.S_ISDIR(metadata.st_mode):
            kind, content = "directory", ""
        elif stat.S_ISREG(metadata.st_mode):
            kind, content = "file", sha256(path)
        else:
            raise SystemExit(f"dependency has an unsupported entry: {relative}")
        for value in (
            relative,
            kind,
            f"{stat.S_IMODE(metadata.st_mode):o}",
            str(metadata.st_mtime_ns),
            content,
        ):
            digest.update(value.encode())
            digest.update(b"\0")
    return digest.hexdigest()


colmap_receipt = load_receipt(colmap, "colmap")
dependency_roots = {
    "colmap-support": support,
    "ceres": ceres,
    "openimageio": openimageio,
}
dependency_receipts = {
    name: load_receipt(root, expected)
    for name, root, expected in (
        ("colmap-support", support, "colmap-support"),
        ("ceres", ceres, "ceres-static"),
        ("openimageio", openimageio, "openimageio-static"),
    )
}
for name, receipt in dependency_receipts.items():
    if receipt.get("architecture") != "arm64" or receipt.get("deployment_target") != "macOS 15.0":
        raise SystemExit(f"{name} receipt does not describe the arm64 macOS 15 build")
    if receipt.get("ownership_policy") != "invoking-build-user-and-primary-group":
        raise SystemExit(f"{name} receipt has an unsupported ownership policy")
    if "normalized_owner_uid" in receipt or "normalized_owner_gid" in receipt:
        raise SystemExit(f"{name} receipt contains host-specific numeric ownership")

binary = colmap / "bin/colmap"
if binary.is_symlink() or not binary.is_file():
    raise SystemExit("native COLMAP executable is missing or unsafe")
if colmap_receipt.get("schema_version") != 2:
    raise SystemExit("native COLMAP receipt schema is not 2")
if colmap_receipt.get("executable_sha256") != sha256(binary):
    raise SystemExit("native COLMAP executable does not match its receipt")
expected_commands = [
    "feature_extractor", "matches_importer", "local_vocab_retriever", "mapper",
    "point_triangulator", "bundle_adjuster", "model_analyzer",
    "image_undistorter", "model_converter",
]
if colmap_receipt.get("enabled_capabilities") != expected_commands:
    raise SystemExit("native COLMAP receipt does not declare the exact nine-command surface")
options = colmap_receipt.get("build_options", {})
if options.get("architecture") != "arm64" or options.get("deployment_target") != "15.0":
    raise SystemExit("native COLMAP receipt has the wrong architecture or deployment target")
if options.get("gpu") is not False or options.get("mvs") is not False:
    raise SystemExit("native COLMAP receipt enables an unapproved GPU or MVS surface")

inputs = colmap_receipt.get("build_inputs", {})
expected_receipt_hashes = {
    name: sha256(root / "build_info.json")
    for name, root in dependency_roots.items()
}
if inputs.get("dependency_receipt_sha256") != expected_receipt_hashes:
    raise SystemExit("native COLMAP dependency receipt hashes do not match the installed receipts")
expected_library_hashes = {
    name: library_hashes(dependency_roots[name], dependency_receipts[name])
    for name in sorted(dependency_roots)
}
if inputs.get("dependency_library_sha256") != expected_library_hashes:
    raise SystemExit("native COLMAP dependency library hashes do not match the installed libraries")
expected_tree_hashes = {
    "ceres": prefix_tree_sha256(ceres),
    "colmap-support": prefix_tree_sha256(support),
    "openimageio": prefix_tree_sha256(openimageio),
}
if inputs.get("dependency_tree_sha256") != expected_tree_hashes:
    raise SystemExit("native COLMAP dependency trees do not match the reviewed receipt")

for root, receipt in ((support, dependency_receipts["colmap-support"]),
                      (ceres, dependency_receipts["ceres"]),
                      (openimageio, dependency_receipts["openimageio"])):
    for dependency in receipt.get("dependencies", {}).values():
        for relative in dependency.get("license_files", []):
            path = root / relative
            if path.is_symlink() or not path.is_file() or path.stat().st_size == 0:
                raise SystemExit(f"dependency license is missing or unsafe: {path}")
PY
}

validate_da3_receipt() {
  python3 - "$DA3_MPS_INSTALL/da3_mps" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
receipt_path = root / "build_info.json"
if receipt_path.is_symlink() or not receipt_path.is_file():
    raise SystemExit("DA3 build_info.json is missing or unsafe")
payload = json.loads(receipt_path.read_text(encoding="utf-8"))
required = {
    "toolchain_name", "source_path", "python_version", "torch_version",
    "torchvision_version",
}
if payload.get("toolchain_name") != "da3_mps":
    raise SystemExit("DA3 build_info.json has the wrong toolchain_name")
missing = sorted(key for key in required if not payload.get(key))
if missing:
    raise SystemExit(f"DA3 build_info.json is missing required keys: {', '.join(missing)}")
if payload.get("source_provenance") != "pinned-git":
    raise SystemExit("DA3 build_info.json must record pinned-git source provenance")
PY
}

require_colmap_options() {
  local command="$1"
  shift
  local help_output option
  help_output="$("$BIN/colmap" "$command" -h 2>&1)" || \
    die "Native COLMAP command failed to launch: $command"
  for option in "$@"; do
    printf '%s\n' "$help_output" | \
      awk -v required="--$option" '$1 == required { found = 1 } END { exit found ? 0 : 1 }' || \
      die "Native COLMAP $command is missing required option --$option"
  done
}

validate_native_colmap_cli() {
  local command actual expected
  expected="$(printf '%s\n' \
    help version \
    feature_extractor matches_importer local_vocab_retriever mapper \
    point_triangulator bundle_adjuster model_analyzer image_undistorter model_converter | \
    LC_ALL=C sort)"
  actual="$("$BIN/colmap" help 2>&1 | awk '
    $0 == "Available commands:" { in_commands = 1; next }
    in_commands && NF == 1 { print $1 }
  ' | LC_ALL=C sort)"
  [ "$actual" = "$expected" ] || {
    echo "Native COLMAP does not expose the exact reviewed command surface." >&2
    printf 'Expected:\n%s\nActual:\n%s\n' "$expected" "$actual" >&2
    exit 1
  }
  for command in \
    feature_extractor matches_importer local_vocab_retriever mapper \
    point_triangulator bundle_adjuster model_analyzer image_undistorter model_converter; do
    "$BIN/colmap" "$command" -h >/dev/null 2>&1 || \
      die "Native COLMAP command failed to launch: $command"
  done
  require_colmap_options feature_extractor \
    database_path image_path ImageReader.single_camera ImageReader.camera_model \
    FeatureExtraction.max_image_size FeatureExtraction.use_gpu \
    FeatureExtraction.num_threads SiftExtraction.max_num_features
  require_colmap_options matches_importer \
    database_path match_list_path match_type FeatureMatching.use_gpu \
    FeatureMatching.num_threads FeatureMatching.max_num_matches \
    SiftMatching.cpu_brute_force_matcher \
    EasySplat.require_empty_matching_results TwoViewGeometry.random_seed
  require_colmap_options local_vocab_retriever \
    database_path output_pair_list_path request_digest query_stride \
    query_image_list_path excluded_pair_list_path \
    image_group_list_path image_group_list_digest \
    num_images returned_neighbor_count minimum_frame_separation num_visual_words \
    max_features_per_image max_training_descriptors num_iterations num_rounds \
    num_checks num_threads
  require_colmap_options mapper \
    database_path image_path output_path Mapper.ba_global_frames_ratio \
    Mapper.ba_global_points_ratio Mapper.ba_local_max_refinements \
    Mapper.ba_global_max_refinements Mapper.ba_global_max_num_iterations \
    Mapper.ba_local_max_num_iterations Mapper.ba_local_function_tolerance \
    Mapper.ba_global_function_tolerance Mapper.ba_local_num_images Mapper.random_seed \
    Mapper.min_num_matches Mapper.ba_refine_focal_length
  require_colmap_options point_triangulator database_path image_path input_path output_path
  require_colmap_options bundle_adjuster \
    input_path output_path BundleAdjustment.refine_focal_length \
    BundleAdjustment.refine_principal_point BundleAdjustment.refine_extra_params \
    BundleAdjustmentCeres.max_num_iterations
  require_colmap_options model_analyzer path
  require_colmap_options image_undistorter \
    image_path input_path output_path output_type copy_policy max_image_size
  require_colmap_options model_converter input_path output_path output_type
}

validate_native_colmap_semantics() {
  EASYSPLAT_NATIVE_COLMAP_BIN="$BIN/colmap" \
  EASYSPLAT_NATIVE_COLMAP_DYLD_LIBRARY_PATH="$LIB" \
    python3 "$ROOT/scripts/toolchain/tests/test_native_colmap_retriever.py" \
      NativeRetrieverTests NativeMatchesImporterTests
}

find_macho_files() {
  python3 - "$OUT" <<'PY'
import os
import sys
from pathlib import Path

root = Path(sys.argv[1])
magics = {
    b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca", b"\xca\xfe\xba\xbf",
    b"\xbf\xba\xfe\xca", b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf",
    b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xce",
}
for path in root.rglob("*"):
    if path.is_symlink() or not path.is_file():
        continue
    with path.open("rb") as stream:
        if stream.read(4) in magics:
            sys.stdout.buffer.write(os.fsencode(path) + b"\0")
PY
}

validate_packaged_native_files() {
  local file relative dependency install_id
  while IFS= read -r -d '' file; do
    relative="${file#"$OUT"/}"
    require_arm64_only_macho "Packaged native file $relative" "$file"
    /usr/bin/codesign --verify --strict "$file" || \
      die "Packaged Mach-O has no valid embedded signature: $relative"
    install_id="$(otool -D "$file" 2>/dev/null | awk 'NR == 2 { print; exit }' || true)"
    while IFS= read -r dependency; do
      [ -n "$dependency" ] || continue
      [ "$dependency" = "$install_id" ] && continue
      if is_system_dependency "$dependency"; then
        continue
      fi
      case "$dependency" in
        @loader_path/*|@executable_path/*|@rpath/*) ;;
        *) die "Unportable dependency in $relative: $dependency" ;;
      esac
    done < <(otool_dependency_names "$file")
  done < <(find_macho_files)
}

require_committed_packaging_sources
for path in \
  "$COLMAP_INSTALL/bin/colmap" \
  "$COLMAP_INSTALL/build_info.json" \
  "$COLMAP_SUPPORT_INSTALL/lib/libomp.dylib" \
  "$COLMAP_SUPPORT_INSTALL/build_info.json" \
  "$CERES_INSTALL/build_info.json" \
  "$OPENIMAGEIO_INSTALL/build_info.json"; do
  require_regular_file "$path"
done
validate_native_receipts

rm -rf "$OUT"
mkdir -p "$BIN" "$LIB" "$LICENSES" "$PROVENANCE" "$SUPPLY_CHAIN"

install -m 0755 "$COLMAP_INSTALL/bin/colmap" "$BIN/colmap"
install -m 0755 "$COLMAP_SUPPORT_INSTALL/lib/libomp.dylib" "$LIB/libomp.dylib"
install -m 0644 "$COLMAP_INSTALL/build_info.json" "$PROVENANCE/colmap.json"
install -m 0644 "$COLMAP_SUPPORT_INSTALL/build_info.json" "$PROVENANCE/colmap-support.json"
install -m 0644 "$CERES_INSTALL/build_info.json" "$PROVENANCE/ceres.json"
install -m 0644 "$OPENIMAGEIO_INSTALL/build_info.json" "$PROVENANCE/openimageio.json"

cp -R "$COLMAP_INSTALL/licenses/COLMAP" "$LICENSES/COLMAP"
cp -R "$COLMAP_SUPPORT_INSTALL/licenses/COLMAPSupport" "$LICENSES/COLMAPSupport"
cp -R "$CERES_INSTALL/licenses/Ceres" "$LICENSES/Ceres"
cp -R "$CERES_INSTALL/licenses/Eigen" "$LICENSES/Eigen"
cp -R "$OPENIMAGEIO_INSTALL/licenses/OpenImageIO" "$LICENSES/OpenImageIO"
mkdir -p "$LICENSES/EasySplat"
install -m 0644 "$ROOT/LICENSE" "$LICENSES/EasySplat/LICENSE"

require_arm64_only_macho "Native COLMAP" "$BIN/colmap"
require_macos_15_binary "Native COLMAP" "$BIN/colmap"
require_adhoc_signature "Native COLMAP" "$BIN/colmap"
validate_native_colmap_linkage "$BIN/colmap"
require_arm64_only_macho "Packaged libomp" "$LIB/libomp.dylib"
require_macos_15_binary "Packaged libomp" "$LIB/libomp.dylib"
require_adhoc_signature "Packaged libomp" "$LIB/libomp.dylib"
validate_libomp_linkage "$LIB/libomp.dylib"

python3 - "$PROVENANCE/colmap.json" "$BIN/colmap" "$PROVENANCE/colmap-support.json" "$LIB/libomp.dylib" <<'PY'
import hashlib
import json
import sys
from pathlib import Path

colmap_receipt, colmap_binary, support_receipt, libomp = map(Path, sys.argv[1:])
sha = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
if json.loads(colmap_receipt.read_text())["executable_sha256"] != sha(colmap_binary):
    raise SystemExit("packaged native COLMAP hash differs from its receipt")
support = json.loads(support_receipt.read_text())
if support["library_sha256"].get("lib/libomp.dylib") != sha(libomp):
    raise SystemExit("packaged libomp hash differs from its receipt")
PY

validate_native_colmap_cli
validate_native_colmap_semantics

"$MSPLAT_VALIDATOR" --source "$MSPLAT_INSTALL/msplat"
mkdir -p "$OUT/msplat"
install -m 0755 "$MSPLAT_INSTALL/msplat/bin/easysplat-train" "$BIN/easysplat-train"
install -m 0644 "$MSPLAT_INSTALL/msplat/bin/default.metallib" "$BIN/default.metallib"
install -m 0644 "$MSPLAT_INSTALL/msplat/build_info.json" "$OUT/msplat/build_info.json"
install -m 0644 "$MSPLAT_INSTALL/msplat/LICENSE" "$OUT/msplat/LICENSE"
MSPLAT_DEPS="$ROOT/Toolchains/build/msplat/dependencies"
mkdir -p "$LICENSES/msplat/CLI11" "$LICENSES/msplat/nanoflann" "$LICENSES/msplat/nlohmann-json"
install -m 0644 "$MSPLAT_DEPS/CLI11-2.4.2/LICENSE" "$LICENSES/msplat/CLI11/LICENSE"
install -m 0644 "$MSPLAT_DEPS/nanoflann-1.5.5/COPYING" "$LICENSES/msplat/nanoflann/COPYING"
install -m 0644 "$MSPLAT_DEPS/nlohmann-json-3.11.3/LICENSE.MIT" "$LICENSES/msplat/nlohmann-json/LICENSE.MIT"

DA3_ROOT="$DA3_MPS_INSTALL/da3_mps"
python3 "$DA3_PAYLOAD_VALIDATOR" --root "$DA3_ROOT"
for path in \
  "$DA3_ROOT/bin/easysplat_da3_sfm" \
  "$DA3_ROOT/python/bin/python3" \
  "$DA3_ROOT/build_info.json" \
  "$DA3_ROOT/app/easysplat_da3_sfm/run.py" \
  "$DA3_ROOT/vendor/depth-anything-3/src/depth_anything_3/api.py"; do
  require_regular_file "$path"
done
[ -d "$DA3_ROOT/licenses" ] || die "DA3 bundle is missing its license closure."
validate_da3_receipt
for model in DA3-BASE DA3-SMALL; do
  assert_exact_da3_model_payload "$DA3_ROOT/models/$model"
done
mkdir -p "$OUT/da3_mps/models"
cp -R "$DA3_ROOT/bin" "$OUT/da3_mps/bin"
cp -R "$DA3_ROOT/python" "$OUT/da3_mps/python"
cp -R "$DA3_ROOT/app" "$OUT/da3_mps/app"
cp -R "$DA3_ROOT/vendor" "$OUT/da3_mps/vendor"
cp -R "$DA3_ROOT/licenses" "$OUT/da3_mps/licenses"
cp -R "$DA3_ROOT/models/DA3-BASE" "$OUT/da3_mps/models/DA3-BASE"
cp -R "$DA3_ROOT/models/DA3-SMALL" "$OUT/da3_mps/models/DA3-SMALL"
install -m 0644 "$DA3_ROOT/build_info.json" "$OUT/da3_mps/build_info.json"
find "$OUT/da3_mps/python" -type f -name '*.pyc' -delete
find "$OUT/da3_mps/python" -type d -name '__pycache__' -empty -delete
python3 "$DA3_PAYLOAD_VALIDATOR" --root "$OUT/da3_mps"

validate_packaged_native_files
"$MSPLAT_VALIDATOR" --packaged "$OUT"

[ -x "$SUPPLY_CHAIN_GENERATOR" ] || \
  die "Supply-chain manifest generator is missing or not executable: $SUPPLY_CHAIN_GENERATOR"
"$SUPPLY_CHAIN_GENERATOR" --toolchain-root "$OUT" --version "$VERSION"

for forbidden in AGPL CGAL LSD SPQR SiftGPU da3_streaming salad; do
  if find "$OUT" -mindepth 1 -print | \
    grep -Ei "(^|/)${forbidden}([^/]*)(/|$)" >/dev/null; then
    die "Forbidden release payload entry matched ${forbidden}."
  fi
done

python3 "$REPRODUCIBLE_ZIP" \
  --root "$OUT" \
  --output "$CORE_ZIP" \
  --path "bin" \
  --path "lib" \
  --path "licenses" \
  --path "provenance" \
  --path "supply-chain/components.json" \
  --path "msplat/build_info.json" \
  --path "msplat/LICENSE"
python3 "$REPRODUCIBLE_ZIP" \
  --root "$OUT" \
  --output "$DA3_BASE_ZIP" \
  --path "da3_mps/bin" \
  --path "da3_mps/python" \
  --path "da3_mps/app" \
  --path "da3_mps/vendor" \
  --path "da3_mps/licenses" \
  --path "da3_mps/build_info.json" \
  --path "da3_mps/models/DA3-BASE"
python3 "$REPRODUCIBLE_ZIP" \
  --root "$OUT" \
  --output "$DA3_SMALL_ZIP" \
  --path "da3_mps/models/DA3-SMALL"

assert_release_asset_size "$CORE_ZIP"
assert_release_asset_size "$DA3_BASE_ZIP"
assert_release_asset_size "$DA3_SMALL_ZIP"
assert_download_closure_size "$CORE_ZIP" "$DA3_BASE_ZIP" "$DA3_SMALL_ZIP"

echo "Packaged toolchain (core): $CORE_ZIP"
echo "Packaged optional component (DA3 runtime + BASE): $DA3_BASE_ZIP"
echo "Packaged optional component (DA3-SMALL): $DA3_SMALL_ZIP"
