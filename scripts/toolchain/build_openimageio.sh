#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$ROOT/Toolchains/build/openimageio"
SRC="$WORK/src"
BUILD="$WORK/build"
INSTALL="$WORK/install"
DEPS="$WORK/deps"
FMT_SRC="$DEPS/fmt"
ROBINMAP_SRC="$DEPS/robin-map"
PUGIXML_SRC="$DEPS/pugixml"
RUNTIME_CLOSURE="$WORK/runtime-closure.txt"

OIIO_REPO="https://github.com/AcademySoftwareFoundation/OpenImageIO.git"
OIIO_COMMIT="f32bf6e6f8de38ab6d197a72fd72366b66fd30a3"
OIIO_VERSION="2.5.19.1"
FMT_REPO="https://github.com/fmtlib/fmt.git"
FMT_COMMIT="a0b8a92e3d1532361c2f7feb63babc5c18d00ef2"
FMT_VERSION="10.0.0"
ROBINMAP_REPO="https://github.com/Tessil/robin-map.git"
ROBINMAP_COMMIT="908ccf9f039a0e50813544c0444ca664ca292d7c"
ROBINMAP_VERSION="0.6.2"
PUGIXML_REPO="https://github.com/zeux/pugixml.git"
PUGIXML_COMMIT="314baf6605143f1e837209008f490e8559529e1c"
PUGIXML_VERSION="1.12"

die() {
  echo "OpenImageIO build failed: $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command is missing: $1"
}

cache_bool_is() {
  local name="$1"
  local expected="$2"
  grep -Eq "^${name}:BOOL=${expected}$" "$BUILD/CMakeCache.txt" || \
    die "CMake did not preserve boolean ${name}=${expected}"
}

cache_string_is() {
  local name="$1"
  local expected="$2"
  grep -Eq "^${name}:STRING=${expected}$" "$BUILD/CMakeCache.txt" || \
    die "CMake did not preserve string ${name}=${expected}"
}

prepare_git_source() {
  local source_url="$1"
  local source_commit="$2"
  local destination="$3"

  mkdir -p "$(dirname "$destination")"
  if [ ! -d "$destination/.git" ]; then
    rm -rf "$destination"
    git clone --filter=blob:none --no-checkout "$source_url" "$destination"
  fi
  [ "$(git -C "$destination" remote get-url origin)" = "$source_url" ] || \
    die "unexpected source origin in $destination"
  git -C "$destination" fetch --depth 1 --force origin "$source_commit"
  git -C "$destination" checkout --detach --force "$source_commit"
  git -C "$destination" clean -ffdqx
  [ "$(git -C "$destination" rev-parse HEAD)" = "$source_commit" ] || \
    die "source commit mismatch in $destination"
  [ -z "$(git -C "$destination" status --porcelain --untracked-files=all)" ] || \
    die "source checkout is dirty in $destination"
}

prepare_sources() {
  prepare_git_source "$OIIO_REPO" "$OIIO_COMMIT" "$SRC"
  prepare_git_source "$FMT_REPO" "$FMT_COMMIT" "$FMT_SRC"
  prepare_git_source "$ROBINMAP_REPO" "$ROBINMAP_COMMIT" "$ROBINMAP_SRC"
  prepare_git_source "$PUGIXML_REPO" "$PUGIXML_COMMIT" "$PUGIXML_SRC"

  rm -rf "$SRC/ext/fmt" "$SRC/ext/robin-map"
  mkdir -p "$SRC/ext"
  ln -s "$FMT_SRC" "$SRC/ext/fmt"
  ln -s "$ROBINMAP_SRC" "$SRC/ext/robin-map"

  grep -Eq '^#[[:space:]]*define[[:space:]]+PUGIXML_VERSION[[:space:]]+1120' \
    "$SRC/src/include/OpenImageIO/detail/pugixml/pugixml.hpp" || \
    die "OpenImageIO no longer vendors the reviewed PugiXML 1.12 source"
  [ -s "$PUGIXML_SRC/LICENSE.md" ] || die "PugiXML license could not be read"
}

join_by_semicolon() {
  local IFS=';'
  echo "$*"
}

configure() {
  local boost_prefix jpeg_prefix png_prefix tiff_prefix openexr_prefix imath_prefix
  local forbidden_prefix
  local -a prefix_paths=()
  local -a ignore_paths=()

  boost_prefix="$(brew --prefix boost 2>/dev/null || true)"
  jpeg_prefix="$(brew --prefix jpeg-turbo 2>/dev/null || true)"
  png_prefix="$(brew --prefix libpng 2>/dev/null || true)"
  tiff_prefix="$(brew --prefix libtiff 2>/dev/null || true)"
  openexr_prefix="$(brew --prefix openexr 2>/dev/null || true)"
  imath_prefix="$(brew --prefix imath 2>/dev/null || true)"

  for required in \
    "$boost_prefix" \
    "$jpeg_prefix" \
    "$png_prefix" \
    "$tiff_prefix" \
    "$openexr_prefix" \
    "$imath_prefix"; do
    [ -d "$required" ] || die "required Homebrew image dependency is missing"
    prefix_paths+=("$required")
  done

  for forbidden in \
    openimageio \
    opencolorio \
    opencv \
    tbb \
    dcmtk \
    ffmpeg \
    giflib \
    libheif \
    libraw \
    openjpeg \
    openvdb \
    ptex \
    webp \
    freetype \
    qt; do
    forbidden_prefix="$(brew --prefix "$forbidden" 2>/dev/null || true)"
    if [ -n "$forbidden_prefix" ] && [ -d "$forbidden_prefix" ]; then
      ignore_paths+=("$forbidden_prefix")
    fi
  done

  rm -rf "$BUILD" "$INSTALL"
  env GIT_ALLOW_PROTOCOL=file cmake -S "$SRC" -B "$BUILD" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$INSTALL" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 \
    -DCMAKE_CXX_STANDARD:STRING=17 \
    -DCMAKE_CXX_STANDARD_REQUIRED:BOOL=ON \
    -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
    -DCMAKE_FIND_USE_PACKAGE_REGISTRY=OFF \
    -DCMAKE_FIND_USE_SYSTEM_PACKAGE_REGISTRY=OFF \
    -DCMAKE_PREFIX_PATH="$(join_by_semicolon "${prefix_paths[@]}")" \
    -DCMAKE_IGNORE_PREFIX_PATH="$(join_by_semicolon "${ignore_paths[@]}")" \
    -DCMAKE_DISABLE_FIND_PACKAGE_Git:BOOL=TRUE \
    -DBUILD_SHARED_LIBS:BOOL=ON \
    -DLINKSTATIC:BOOL=OFF \
    -DEMBEDPLUGINS:BOOL=ON \
    -DOIIO_BUILD_TOOLS:BOOL=OFF \
    -DOIIO_BUILD_TESTS:BOOL=OFF \
    -DBUILD_TESTING:BOOL=OFF \
    -DBUILD_DOCS:BOOL=OFF \
    -DINSTALL_DOCS:BOOL=OFF \
    -DINSTALL_FONTS:BOOL=OFF \
    -DUSE_PYTHON:BOOL=OFF \
    -DBUILD_MISSING_DEPS:BOOL=OFF \
    -DBUILD_MISSING_FMT:BOOL=OFF \
    -DBUILD_FMT_FORCE:BOOL=ON \
    -DBUILD_MISSING_ROBINMAP:BOOL=OFF \
    -DBUILD_ROBINMAP_FORCE:BOOL=ON \
    -DBUILD_FMT_VERSION="$FMT_VERSION" \
    -DBUILD_ROBINMAP_VERSION="$ROBINMAP_VERSION" \
    -DINTERNALIZE_FMT:BOOL=ON \
    -DUSE_EXTERNAL_PUGIXML:BOOL=OFF \
    -DUSE_STD_FILESYSTEM:BOOL=ON \
    -DUSE_CCACHE:BOOL=OFF \
    -DUSE_LIBJPEG-TURBO:BOOL=ON \
    -DUSE_JPEG:BOOL=ON \
    -DUSE_PNG:BOOL=ON \
    -DUSE_TIFF:BOOL=ON \
    -DUSE_OPENEXR:BOOL=ON \
    -DUSE_FREETYPE:BOOL=OFF \
    -DUSE_OPENCOLORIO:BOOL=OFF \
    -DUSE_OPENCV:BOOL=OFF \
    -DUSE_TBB:BOOL=OFF \
    -DUSE_DCMTK:BOOL=OFF \
    -DUSE_FFMPEG:BOOL=OFF \
    -DUSE_GIF:BOOL=OFF \
    -DUSE_LIBHEIF:BOOL=OFF \
    -DUSE_LIBRAW:BOOL=OFF \
    -DUSE_OPENJPEG:BOOL=OFF \
    -DUSE_OPENVDB:BOOL=OFF \
    -DUSE_PTEX:BOOL=OFF \
    -DUSE_WEBP:BOOL=OFF \
    -DUSE_JXL:BOOL=OFF \
    -DUSE_R3DSDK:BOOL=OFF \
    -DUSE_NUKE:BOOL=OFF \
    -DUSE_QT:BOOL=OFF \
    -DENABLE_BMP:BOOL=OFF \
    -DENABLE_CINEON:BOOL=OFF \
    -DENABLE_DDS:BOOL=OFF \
    -DENABLE_DICOM:BOOL=OFF \
    -DENABLE_DPX:BOOL=OFF \
    -DENABLE_FFMPEG:BOOL=OFF \
    -DENABLE_FITS:BOOL=OFF \
    -DENABLE_GIF:BOOL=OFF \
    -DENABLE_HDR:BOOL=OFF \
    -DENABLE_HEIF:BOOL=OFF \
    -DENABLE_ICO:BOOL=OFF \
    -DENABLE_IFF:BOOL=OFF \
    -DENABLE_JPEG2000:BOOL=OFF \
    -DENABLE_JPEGXL:BOOL=OFF \
    -DENABLE_NULL:BOOL=OFF \
    -DENABLE_OPENVDB:BOOL=OFF \
    -DENABLE_PNM:BOOL=OFF \
    -DENABLE_PSD:BOOL=OFF \
    -DENABLE_PTEX:BOOL=OFF \
    -DENABLE_R3D:BOOL=OFF \
    -DENABLE_RAW:BOOL=OFF \
    -DENABLE_RLA:BOOL=OFF \
    -DENABLE_SGI:BOOL=OFF \
    -DENABLE_SOFTIMAGE:BOOL=OFF \
    -DENABLE_TARGA:BOOL=OFF \
    -DENABLE_TERM:BOOL=OFF \
    -DENABLE_WEBP:BOOL=OFF \
    -DENABLE_ZFILE:BOOL=OFF

  for option in \
    BUILD_SHARED_LIBS \
    EMBEDPLUGINS \
    INTERNALIZE_FMT \
    BUILD_FMT_FORCE \
    BUILD_ROBINMAP_FORCE \
    USE_STD_FILESYSTEM \
    USE_LIBJPEG-TURBO \
    USE_JPEG \
    USE_PNG \
    USE_TIFF \
    USE_OPENEXR; do
    cache_bool_is "$option" ON
  done
  cache_string_is CMAKE_CXX_STANDARD 17
  cache_bool_is CMAKE_CXX_STANDARD_REQUIRED ON
  for option in \
    LINKSTATIC \
    OIIO_BUILD_TOOLS \
    OIIO_BUILD_TESTS \
    BUILD_TESTING \
    BUILD_DOCS \
    INSTALL_DOCS \
    INSTALL_FONTS \
    USE_PYTHON \
    BUILD_MISSING_DEPS \
    BUILD_MISSING_FMT \
    BUILD_MISSING_ROBINMAP \
    USE_EXTERNAL_PUGIXML \
    USE_CCACHE \
    USE_FREETYPE \
    USE_OPENCOLORIO \
    USE_OPENCV \
    USE_TBB \
    USE_DCMTK \
    USE_FFMPEG \
    USE_GIF \
    USE_LIBHEIF \
    USE_LIBRAW \
    USE_OPENJPEG \
    USE_OPENVDB \
    USE_PTEX \
    USE_WEBP \
    USE_JXL \
    USE_R3DSDK \
    USE_NUKE \
    USE_QT \
    ENABLE_BMP \
    ENABLE_CINEON \
    ENABLE_DDS \
    ENABLE_DICOM \
    ENABLE_DPX \
    ENABLE_FFMPEG \
    ENABLE_FITS \
    ENABLE_GIF \
    ENABLE_HDR \
    ENABLE_HEIF \
    ENABLE_ICO \
    ENABLE_IFF \
    ENABLE_JPEG2000 \
    ENABLE_JPEGXL \
    ENABLE_NULL \
    ENABLE_OPENVDB \
    ENABLE_PNM \
    ENABLE_PSD \
    ENABLE_PTEX \
    ENABLE_R3D \
    ENABLE_RAW \
    ENABLE_RLA \
    ENABLE_SGI \
    ENABLE_SOFTIMAGE \
    ENABLE_TARGA \
    ENABLE_TERM \
    ENABLE_WEBP \
    ENABLE_ZFILE; do
    cache_bool_is "$option" OFF
  done

  rg -F "$SRC/ext/fmt/include" "$BUILD/build.ninja" >/dev/null || \
    die "pinned fmt headers are absent from the configured build"
  rg -F "$SRC/ext/robin-map/include" "$BUILD/build.ninja" >/dev/null || \
    die "pinned robin-map headers are absent from the configured build"
  if rg -n '/opt/homebrew/(opt|Cellar)/(openimageio|opencolorio|opencv|tbb|dcmtk|ffmpeg|giflib|libheif|libraw|openjpeg|openvdb|ptex|webp|freetype|qt)/' \
    "$BUILD/build.ninja" "$BUILD/compile_commands.json" >/dev/null; then
    die "a disabled image dependency leaked into the configured build"
  fi
  python3 - "$BUILD/compile_commands.json" <<'PY'
import json
import re
import sys
from pathlib import Path

allowed = {"jpeg", "openexr", "png", "tiff"}
found = set()
for entry in json.loads(Path(sys.argv[1]).read_text(encoding="utf-8")):
    match = re.search(r"/([^/]+)\.imageio/", entry.get("file", "").replace("\\", "/"))
    if match:
        found.add(match.group(1).lower())
unexpected = found - allowed
if unexpected:
    raise SystemExit(f"disabled format plugins entered the build: {sorted(unexpected)}")
missing = allowed - found
if missing:
    raise SystemExit(f"required format plugins are absent from the build: {sorted(missing)}")
PY
}

strip_install() {
  [ -d "$INSTALL/include/OpenImageIO" ] || die "installed OpenImageIO headers are missing"
  [ -s "$INSTALL/lib/cmake/OpenImageIO/OpenImageIOConfig.cmake" ] || \
    die "installed OpenImageIO CMake package is missing"
  find "$INSTALL/lib" -maxdepth 1 -type f -name 'libOpenImageIO*.dylib' -print | \
    grep -q . || die "installed OpenImageIO dylibs are missing"

  rm -rf "${INSTALL:?}/bin" "${INSTALL:?}/share" "${INSTALL:?}/lib/pkgconfig"
  find "$INSTALL" -type d -empty -delete
}

resolve_dependency() {
  local owner="$1"
  local dependency="$2"
  local candidate
  local prefix

  case "$dependency" in
    /*)
      [ -e "$dependency" ] || return 1
      realpath "$dependency"
      ;;
    @loader_path/*)
      candidate="$(dirname "$owner")/${dependency#@loader_path/}"
      [ -e "$candidate" ] || return 1
      realpath "$candidate"
      ;;
    @rpath/*)
      candidate="$(dirname "$owner")/${dependency#@rpath/}"
      if [ -e "$candidate" ]; then
        realpath "$candidate"
        return
      fi
      for prefix in \
        "$INSTALL/lib" \
        "$(brew --prefix openexr 2>/dev/null || true)/lib" \
        "$(brew --prefix imath 2>/dev/null || true)/lib" \
        "$(brew --prefix boost 2>/dev/null || true)/lib"; do
        candidate="$prefix/${dependency#@rpath/}"
        if [ -e "$candidate" ]; then
          realpath "$candidate"
          return
        fi
      done
      return 1
      ;;
    *) return 1 ;;
  esac
}

is_system_dependency() {
  case "$1" in
    /System/Library/*|/usr/lib/*) return 0 ;;
    *) return 1 ;;
  esac
}

validate_macos_version() {
  local file="$1"
  local require_exact="$2"
  local minos
  minos="$(xcrun vtool -show-build "$file" 2>/dev/null | awk '
    $1 == "minos" { print $2; exit }
    $1 == "cmd" && $2 == "LC_VERSION_MIN_MACOSX" { legacy = 1; next }
    legacy && $1 == "version" { print $2; exit }
  ')"
  [ -n "$minos" ] || die "could not read the macOS deployment target from $file"
  python3 - "$file" "$minos" "$require_exact" <<'PY'
import sys

path, raw_version, exact = sys.argv[1:]
version = tuple(int(part) for part in raw_version.split("."))
target = (15, 0)
if exact == "yes" and version != target:
    raise SystemExit(f"OpenImageIO deployment target is {raw_version}, expected 15.0: {path}")
if version > target:
    raise SystemExit(f"dependency requires macOS {raw_version}, newer than macOS 15.0: {path}")
PY
}

validate_binary_closure() {
  local current dependency resolved basename basename_lower
  local -a queue=()
  local index=0
  local seen='|'
  local permitted='^(libOpenImageIO(_Util)?|libboost_(atomic|chrono|container|date_time|thread)|lib(OpenEXR(Core)?|Iex|IlmThread|Imath)|lib(tiff|jpeg|png|zstd|lzma|deflate|openjph))[.0-9_A-Za-z-]*\.dylib$'
  local forbidden='(gpl|avcodec|avformat|avutil|swscale|ffmpeg|heif|de265|x264|x265|aom|dav1d|vpx|svtav1|theora|vorbis|opencolorio|ocio|tbb|freetype|webp|raw|dcmtk|gif)'

  while IFS= read -r current; do
    queue+=("$(realpath "$current")")
  done < <(find "$INSTALL/lib" -maxdepth 1 -type f -name 'libOpenImageIO*.dylib' -print | sort)
  [ "${#queue[@]}" -gt 0 ] || die "OpenImageIO runtime closure is empty"
  : > "$RUNTIME_CLOSURE"

  while [ "$index" -lt "${#queue[@]}" ]; do
    current="${queue[$index]}"
    index=$((index + 1))
    if [[ "$seen" == *"|$current|"* ]]; then
      continue
    fi
    seen="${seen}${current}|"
    basename="$(basename "$current")"
    [[ "$basename" =~ $permitted ]] || die "unexpected dylib in OpenImageIO closure: $current"
    basename_lower="$(printf '%s' "$basename" | tr '[:upper:]' '[:lower:]')"
    if [[ "$basename_lower" =~ $forbidden ]]; then
      die "forbidden dependency in OpenImageIO closure: $current"
    fi
    /usr/bin/file -b "$current" | grep -q 'Mach-O 64-bit dynamically linked shared library arm64' || \
      die "closure contains a non-arm64 dylib: $current"
    if [[ "$current" == "$INSTALL/lib/"* ]]; then
      validate_macos_version "$current" yes
    else
      validate_macos_version "$current" no
    fi
    printf '%s\n' "$basename" >> "$RUNTIME_CLOSURE"

    while IFS= read -r dependency; do
      [ -n "$dependency" ] || continue
      if is_system_dependency "$dependency"; then
        continue
      fi
      resolved="$(resolve_dependency "$current" "$dependency")" || \
        die "could not resolve $dependency referenced by $current"
      queue+=("$resolved")
    done < <(/usr/bin/otool -L "$current" | awk 'NR > 1 {print $1}')
  done

  LC_ALL=C sort -u -o "$RUNTIME_CLOSURE" "$RUNTIME_CLOSURE"
}

stage_metadata() {
  local licenses="$INSTALL/licenses/OpenImageIO"
  local source_tree_sha256 fmt_tree_sha256 robinmap_tree_sha256
  local pugixml_tree_sha256 pugixml_vendored_sha256
  local library_hashes runtime_dependencies

  mkdir -p "$licenses"
  install -m 0644 "$SRC/LICENSE.md" "$licenses/OpenImageIO-LICENSE.md"
  install -m 0644 "$SRC/THIRD-PARTY.md" "$licenses/OpenImageIO-THIRD-PARTY.md"
  install -m 0644 "$SRC/RELICENSING.md" "$licenses/OpenImageIO-RELICENSING.md"
  install -m 0644 "$FMT_SRC/LICENSE.rst" "$licenses/fmt-LICENSE.rst"
  install -m 0644 "$ROBINMAP_SRC/LICENSE" "$licenses/robin-map-LICENSE"
  install -m 0644 "$PUGIXML_SRC/LICENSE.md" "$licenses/pugixml-LICENSE.md"

  source_tree_sha256="$(git -C "$SRC" ls-tree -r --full-tree "$OIIO_COMMIT" | shasum -a 256 | awk '{print $1}')"
  fmt_tree_sha256="$(git -C "$FMT_SRC" ls-tree -r --full-tree "$FMT_COMMIT" | shasum -a 256 | awk '{print $1}')"
  robinmap_tree_sha256="$(git -C "$ROBINMAP_SRC" ls-tree -r --full-tree "$ROBINMAP_COMMIT" | shasum -a 256 | awk '{print $1}')"
  pugixml_tree_sha256="$(git -C "$PUGIXML_SRC" ls-tree -r --full-tree "$PUGIXML_COMMIT" | shasum -a 256 | awk '{print $1}')"
  pugixml_vendored_sha256="$(
    cd "$SRC/src/include/OpenImageIO/detail/pugixml"
    find . -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256
  )"
  pugixml_vendored_sha256="$(printf '%s\n' "$pugixml_vendored_sha256" | shasum -a 256 | awk '{print $1}')"
  library_hashes="$(find "$INSTALL/lib" -maxdepth 1 -type f -name 'libOpenImageIO*.dylib' -print0 | \
    LC_ALL=C sort -z | xargs -0 shasum -a 256)"
  runtime_dependencies="$(tr '\n' ',' < "$RUNTIME_CLOSURE" | sed 's/,$//')"

  python3 - \
    "$INSTALL/build_info.json" \
    "$OIIO_REPO" \
    "$OIIO_COMMIT" \
    "$OIIO_VERSION" \
    "$source_tree_sha256" \
    "$FMT_REPO" \
    "$FMT_COMMIT" \
    "$FMT_VERSION" \
    "$fmt_tree_sha256" \
    "$ROBINMAP_REPO" \
    "$ROBINMAP_COMMIT" \
    "$ROBINMAP_VERSION" \
    "$robinmap_tree_sha256" \
    "$PUGIXML_REPO" \
    "$PUGIXML_COMMIT" \
    "$PUGIXML_VERSION" \
    "$pugixml_tree_sha256" \
    "$pugixml_vendored_sha256" \
    "$library_hashes" \
    "$runtime_dependencies" <<'PY'
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

(
    destination,
    source_url,
    source_commit,
    source_version,
    source_tree_sha256,
    fmt_url,
    fmt_commit,
    fmt_version,
    fmt_tree_sha256,
    robin_url,
    robin_commit,
    robin_version,
    robin_tree_sha256,
    pugi_url,
    pugi_commit,
    pugi_version,
    pugi_tree_sha256,
    pugi_vendored_sha256,
    raw_library_hashes,
    raw_runtime_dependencies,
) = sys.argv[1:]

library_hashes = {}
for row in raw_library_hashes.splitlines():
    digest, path = row.split(maxsplit=1)
    library_hashes[Path(path).name] = digest

payload = {
    "toolchain_name": "openimageio",
    "source_url": source_url,
    "source_commit": source_commit,
    "source_version": source_version,
    "source_tree_sha256": source_tree_sha256,
    "license": "Apache-2.0 AND BSD-3-Clause AND BSD-2-Clause AND MIT",
    "license_files": [
        "licenses/OpenImageIO/OpenImageIO-LICENSE.md",
        "licenses/OpenImageIO/OpenImageIO-THIRD-PARTY.md",
        "licenses/OpenImageIO/OpenImageIO-RELICENSING.md",
    ],
    "dependencies": {
        "fmt": {
            "source_url": fmt_url,
            "source_commit": fmt_commit,
            "source_version": fmt_version,
            "source_tree_sha256": fmt_tree_sha256,
            "license": "MIT",
            "license_files": ["licenses/OpenImageIO/fmt-LICENSE.rst"],
            "linkage": "header-only",
        },
        "pugixml": {
            "source_url": f"{source_url.removesuffix('.git')}/tree/{source_commit}/src/include/OpenImageIO/detail/pugixml",
            "source_commit": source_commit,
            "source_version": pugi_version,
            "source_tree_sha256": pugi_vendored_sha256,
            "upstream_source_url": pugi_url,
            "upstream_source_commit": pugi_commit,
            "upstream_source_tree_sha256": pugi_tree_sha256,
            "license": "MIT",
            "license_files": ["licenses/OpenImageIO/pugixml-LICENSE.md"],
            "linkage": "compiled-in",
        },
        "robin-map": {
            "source_url": robin_url,
            "source_commit": robin_commit,
            "source_version": robin_version,
            "source_tree_sha256": robin_tree_sha256,
            "license": "MIT",
            "license_files": ["licenses/OpenImageIO/robin-map-LICENSE"],
            "linkage": "header-only",
        },
    },
    "enabled_formats": ["JPEG", "OpenEXR", "PNG", "TIFF"],
    "disabled_dependencies": [
        "DCMTK",
        "FFmpeg",
        "Freetype",
        "GIF",
        "JPEG XL",
        "LibRaw",
        "Libheif",
        "Nuke",
        "OpenColorIO",
        "OpenCV",
        "OpenJPEG",
        "OpenVDB",
        "PTex",
        "Qt",
        "R3DSDK",
        "TBB",
        "WebP",
    ],
    "deployment_target": "macOS 15.0",
    "embedded_plugins": True,
    "library_sha256": dict(sorted(library_hashes.items())),
    "runtime_dependencies": sorted(filter(None, raw_runtime_dependencies.split(","))),
    "build_timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
}
Path(destination).write_text(
    json.dumps(payload, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
PY
}

validate_install() {
  [ -s "$INSTALL/build_info.json" ] || die "provenance is missing"
  python3 -m json.tool "$INSTALL/build_info.json" >/dev/null || die "provenance is invalid JSON"
  if find "$INSTALL" -mindepth 1 \( -type f -o -type l \) -print | \
    grep -Ei '/(bin|plugins|python|fonts|doc|man)/' >/dev/null; then
    die "non-runtime OpenImageIO content survived installation pruning"
  fi
  if rg -n '/opt/homebrew/(opt|Cellar)/openimageio/' "$INSTALL" >/dev/null; then
    die "Homebrew OpenImageIO leaked into the source-built installation"
  fi
}

[ "$(uname -m)" = "arm64" ] || die "must run natively on Apple Silicon arm64"
[ "$(sysctl -in sysctl.proc_translated 2>/dev/null || true)" != "1" ] || die "Rosetta is unsupported"
for command in brew cmake ninja git python3 rg realpath xcrun; do
  require_command "$command"
done

prepare_sources
configure
cmake --build "$BUILD" --target install --parallel "$(sysctl -n hw.ncpu)"
strip_install
validate_binary_closure
stage_metadata
validate_install

echo "OpenImageIO installed to: $INSTALL"
