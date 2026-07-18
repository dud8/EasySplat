#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_DIR="$ROOT/Toolchains/build/da3_mps"
INSTALL_DIR="$BUILD_DIR/install/da3_mps"
PYTHON_DIR="$INSTALL_DIR/python"
MODELS_DIR="$INSTALL_DIR/models"
APP_DIR="$INSTALL_DIR/app"
BIN_DIR="$INSTALL_DIR/bin"
VENDOR_DIR="$INSTALL_DIR/vendor"
DA3_VENDOR="$VENDOR_DIR/depth-anything-3"
REQUIREMENTS_LOCK="$ROOT/Tools/Da3Sfm/requirements.txt"
DA3_RUNTIME_PATCH="$ROOT/Tools/Da3Sfm/patches/da3-api-lazy-export.patch"
DA3_RUNTIME_PATCH_SHA256="885ade24b466ab3dff04169ff47dd3813d64c40ffd0bdb7dd9b779de97a370eb"
DA3_PAYLOAD_VALIDATOR="$ROOT/scripts/toolchain/validate_da3_payload.py"
DA3_MODEL_LOCK="$ROOT/scripts/toolchain/da3-model-lock.json"
PIP_INSTALL_REPORT="$INSTALL_DIR/licenses/python-packages-install-report.json"
SUPPLEMENTAL_LICENSE_MANIFEST="$INSTALL_DIR/licenses/python-package-upstream-notices.json"
ANTLR_LICENSE_COMMIT="e4c1a74c66bd5290364ea2b36c97cd724b247357"
ANTLR_LICENSE_URL="https://raw.githubusercontent.com/antlr/antlr4/${ANTLR_LICENSE_COMMIT}/LICENSE.txt"
ANTLR_LICENSE_SHA256="b1b379fcaf3219593a4c433feb1b35c780bed23fafaae440b1ae2771a9521e3a"
ANTLR_LICENSE_CACHE="$BUILD_DIR/licenses/antlr4-python3-runtime-4.9.3-LICENSE.txt"

ALLOW_UNPINNED_DA3_SOURCE="${EASYSPLAT_ALLOW_UNPINNED_DA3_SOURCE:-0}"
if [ -n "${DA3_SOURCE:-}" ] && [ "$ALLOW_UNPINNED_DA3_SOURCE" != "1" ]; then
  echo "DA3_SOURCE requires EASYSPLAT_ALLOW_UNPINNED_DA3_SOURCE=1 and is forbidden in release builds." >&2
  exit 1
fi
for override in DA3_REPO DA3_REF DA3_BASE_REPO DA3_SMALL_REPO DA3_BASE_REVISION DA3_SMALL_REVISION; do
  if [ -n "${!override:-}" ]; then
    echo "$override is not configurable; update and review the pinned source in build_da3_mps.sh." >&2
    exit 1
  fi
done
DA3_SOURCE="${DA3_SOURCE:-$ROOT/ThirdParty/Depth-Anything-3}"
DA3_REPO="https://github.com/ByteDance-Seed/Depth-Anything-3.git"
DA3_REF="41736238f5bced4debf3f2a12375d2466874866d"
DA3_SOURCE_COMMIT=""
DA3_SOURCE_DESCRIPTOR=""
DA3_SOURCE_PROVENANCE=""
DA3_SOURCE_REPO_FOR_BUILD_INFO="$DA3_REPO"
DA3_SOURCE_REF_FOR_BUILD_INFO="$DA3_REF"

PYTHON_STANDALONE_TAG="20260127"
PYTHON_STANDALONE_VERSION="3.13.11"
PYTHON_STANDALONE_ASSET="cpython-${PYTHON_STANDALONE_VERSION}+${PYTHON_STANDALONE_TAG}-aarch64-apple-darwin-install_only_stripped.tar.gz"
PYTHON_STANDALONE_URL="https://github.com/indygreg/python-build-standalone/releases/download/${PYTHON_STANDALONE_TAG}/${PYTHON_STANDALONE_ASSET}"
PYTHON_STANDALONE_TARBALL="$BUILD_DIR/$PYTHON_STANDALONE_ASSET"
PYTHON_STANDALONE_SHA256="718a87bf84d81cb81355488ca37be1f66c2252304be2090721016948de96e7ca"
PYTHON_STANDALONE_FULL_ASSET="cpython-${PYTHON_STANDALONE_VERSION}+${PYTHON_STANDALONE_TAG}-aarch64-apple-darwin-pgo+lto-full.tar.zst"
PYTHON_STANDALONE_FULL_URL="https://github.com/indygreg/python-build-standalone/releases/download/${PYTHON_STANDALONE_TAG}/${PYTHON_STANDALONE_FULL_ASSET}"
PYTHON_STANDALONE_FULL_TARBALL="$BUILD_DIR/$PYTHON_STANDALONE_FULL_ASSET"
PYTHON_STANDALONE_FULL_SHA256="ff7e2bb25f1f29067a0663af42b32980b0da295b948238d5e3fc09d2b27228a6"

if [ "$(uname -m)" != "arm64" ]; then
  echo "da3_mps build must run on Apple Silicon (arm64). Refusing to build under Rosetta." >&2
  exit 1
fi

ensure_repo() {
  local repo="$1"
  local url="$2"
  local ref="$3"

  if ! is_git_checkout "$repo"; then
    git clone "$url" "$repo"
  fi
  pushd "$repo" >/dev/null
  require_clean_git_checkout "$repo"
  git fetch --tags origin "$ref"
  git checkout --detach "$ref"
  require_clean_git_checkout "$repo"
  local current_head
  local expected_head
  current_head="$(git rev-parse HEAD)"
  expected_head="$(git rev-parse "$ref^{commit}")"
  if [ "$current_head" != "$expected_head" ]; then
    echo "DA3 source checkout mismatch in $repo: expected $expected_head, got $current_head" >&2
    exit 1
  fi
  echo "DA3 source pinned at $current_head ($repo)"
  popd >/dev/null
}

is_git_checkout() {
  local repo="$1"
  git -C "$repo" rev-parse --git-dir >/dev/null 2>&1
}

require_clean_git_checkout() {
  local repo="$1"
  local status_output
  status_output="$(git -C "$repo" status --porcelain --untracked-files=all --ignored=matching --ignore-submodules=none)"
  if [ -n "$status_output" ]; then
    echo "DA3 source checkout is dirty at $repo. Refusing to package local edits or untracked files into the signed toolchain." >&2
    echo "$status_output" >&2
    exit 1
  fi
}

resolve_da3_source() {
  if is_git_checkout "$DA3_SOURCE"; then
    ensure_repo "$DA3_SOURCE" "$DA3_REPO" "$DA3_REF"
    DA3_SOURCE_COMMIT="$(git -C "$DA3_SOURCE" rev-parse HEAD)"
    DA3_SOURCE_DESCRIPTOR="git:${DA3_REPO}@${DA3_SOURCE_COMMIT}"
    DA3_SOURCE_PROVENANCE="pinned-git"
    return 0
  fi

  if [ -d "$DA3_SOURCE/src/depth_anything_3" ]; then
    if [ "$ALLOW_UNPINNED_DA3_SOURCE" != "1" ]; then
      echo "DA3 source at $DA3_SOURCE has no git metadata." >&2
      echo "Release/toolchain builds require pinned DA3 git provenance. Set EASYSPLAT_ALLOW_UNPINNED_DA3_SOURCE=1 only for local development snapshots." >&2
      exit 1
    fi
    DA3_SOURCE_COMMIT="unverified-local-snapshot"
    DA3_SOURCE_DESCRIPTOR="unverified-local-snapshot"
    DA3_SOURCE_PROVENANCE="unverified-local-snapshot"
    DA3_SOURCE_REPO_FOR_BUILD_INFO="unverified-local-snapshot"
    DA3_SOURCE_REF_FOR_BUILD_INFO="unverified-local-snapshot"
    echo "Using unpinned local DA3 source because EASYSPLAT_ALLOW_UNPINNED_DA3_SOURCE=1." >&2
    echo "Build info will record unverified-local-snapshot and will not include the local source path." >&2
    return 0
  fi

  DA3_SOURCE="$BUILD_DIR/depth-anything-3-upstream"
  ensure_repo "$DA3_SOURCE" "$DA3_REPO" "$DA3_REF"
  DA3_SOURCE_COMMIT="$(git -C "$DA3_SOURCE" rev-parse HEAD)"
  DA3_SOURCE_DESCRIPTOR="git:${DA3_REPO}@${DA3_SOURCE_COMMIT}"
  DA3_SOURCE_PROVENANCE="pinned-git"
}

download_verified() {
  local url="$1"
  local dest="$2"
  local expected_sha256="$3"
  if [ -f "$dest" ] && [ "$(shasum -a 256 "$dest" | awk '{print $1}')" = "$expected_sha256" ]; then
    return
  fi
  mkdir -p "$(dirname "$dest")"
  local tmp="$dest.tmp.$$"
  rm -f "$dest" "$tmp"
  curl -fL --retry 3 --retry-delay 5 -o "$tmp" "$url"
  if [ "$(shasum -a 256 "$tmp" | awk '{print $1}')" != "$expected_sha256" ]; then
    rm -f "$tmp"
    echo "Checksum mismatch for $url" >&2
    exit 1
  fi
  mv "$tmp" "$dest"
}

install_supplemental_python_licenses() {
  local -a antlr_dist_info=(
    "$PYTHON_DIR"/lib/python*/site-packages/antlr4_python3_runtime-4.9.3.dist-info
  )
  if [ "${#antlr_dist_info[@]}" -ne 1 ] || [ ! -d "${antlr_dist_info[0]}" ]; then
    echo "Expected exactly one antlr4-python3-runtime 4.9.3 distribution." >&2
    exit 1
  fi
  download_verified \
    "$ANTLR_LICENSE_URL" \
    "$ANTLR_LICENSE_CACHE" \
    "$ANTLR_LICENSE_SHA256"

  local antlr_license="${antlr_dist_info[0]}/licenses/UPSTREAM_LICENSE.txt"
  mkdir -p "$(dirname "$antlr_license")"
  install -m 0644 "$ANTLR_LICENSE_CACHE" "$antlr_license"

  "$PYTHON_DIR/bin/python3" - \
    "$INSTALL_DIR" \
    "$SUPPLEMENTAL_LICENSE_MANIFEST" \
    "$antlr_license" <<PY
import json
import sys
from pathlib import Path

root = Path(sys.argv[1]).resolve()
manifest = Path(sys.argv[2])

def relative(path_text):
    path = Path(path_text).resolve(strict=True).relative_to(root).as_posix()
    return f"da3_mps/{path}"

payload = {
    "schemaVersion": 1,
    "notices": [
        {
            "package": "antlr4-python3-runtime",
            "version": "4.9.3",
            "license": "BSD-3-Clause",
            "source": "https://github.com/antlr/antlr4",
            "sourceCommit": "${ANTLR_LICENSE_COMMIT}",
            "artifact": "${ANTLR_LICENSE_URL}",
            "artifactSha256": "${ANTLR_LICENSE_SHA256}",
            "distInfo": "antlr4_python3_runtime-4.9.3.dist-info",
            "filename": "UPSTREAM_LICENSE.txt",
            "installedPath": relative(sys.argv[3]),
        },
    ],
}
manifest.parent.mkdir(parents=True, exist_ok=True)
manifest.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
}

ensure_python() {
  download_verified "$PYTHON_STANDALONE_URL" "$PYTHON_STANDALONE_TARBALL" "$PYTHON_STANDALONE_SHA256"
  mkdir -p "$INSTALL_DIR"
  /usr/bin/tar -xzf "$PYTHON_STANDALONE_TARBALL" -C "$INSTALL_DIR"

  echo "da3_mps python version: $("$PYTHON_DIR/bin/python3" -V 2>&1)"
}

reset_install_dir() {
  case "$INSTALL_DIR" in
    "$BUILD_DIR/install/da3_mps") ;;
    *)
      echo "Refusing to clean unsafe DA3 install directory: $INSTALL_DIR" >&2
      exit 1
      ;;
  esac
  rm -rf "$INSTALL_DIR"
  mkdir -p "$INSTALL_DIR" "$MODELS_DIR" "$BIN_DIR"
}

pip_install() {
  PYTHONNOUSERSITE=1 PIP_DISABLE_PIP_VERSION_CHECK=1 "$PYTHON_DIR/bin/python3" -m pip install --no-user "$@"
}

remove_build_only_python_tools() {
  local site_packages="$PYTHON_DIR/lib/python3.13/site-packages"
  rm -f "$PYTHON_DIR/bin/pip" "$PYTHON_DIR/bin/pip3" "$PYTHON_DIR/bin/pip3.13"
  rm -rf \
    "$PYTHON_DIR/lib/python3.13/ensurepip" \
    "$site_packages/pip" \
    "$site_packages"/pip-*.dist-info

  if [ -e "$PYTHON_DIR/bin/pip" ] \
    || [ -e "$PYTHON_DIR/bin/pip3" ] \
    || [ -e "$PYTHON_DIR/bin/pip3.13" ] \
    || [ -e "$PYTHON_DIR/lib/python3.13/ensurepip" ] \
    || [ -e "$site_packages/pip" ] \
    || find "$site_packages" -maxdepth 1 -type d -name 'pip-*.dist-info' -print -quit | grep -F . >/dev/null; then
    echo "Build-only pip files survived runtime pruning." >&2
    exit 1
  fi
}

materialize_runtime_symlinks() {
  python3 - "$INSTALL_DIR" <<'PY'
import os
import shutil
import sys
from pathlib import Path

root = Path(sys.argv[1]).resolve(strict=True)
links = []
for path in sorted(root.rglob("*")):
    if not path.is_symlink():
        continue
    try:
        target = path.resolve(strict=True)
        target.relative_to(root)
    except (OSError, ValueError) as exc:
        raise SystemExit(f"DA3 runtime has an unsafe symlink: {path}: {exc}") from exc
    if not target.is_file():
        raise SystemExit(
            f"DA3 runtime symlink does not resolve to an internal regular file: {path}"
        )
    links.append((path, target))

for index, (path, target) in enumerate(links):
    temporary = path.with_name(f".{path.name}.materialize-{os.getpid()}-{index}")
    try:
        shutil.copy2(target, temporary, follow_symlinks=True)
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)

remaining = [path for path in root.rglob("*") if path.is_symlink()]
if remaining:
    raise SystemExit(f"DA3 runtime still contains symlinks: {remaining}")
PY
}

require_arm64_python() {
  local arch
  arch="$("$PYTHON_DIR/bin/python3" - <<'PY'
import platform
print(platform.machine())
PY
)"
  if [ "$arch" != "arm64" ]; then
    echo "da3_mps python is not arm64 (got: $arch). Rebuild toolchain on Apple Silicon without Rosetta." >&2
    exit 1
  fi
}

verify_runtime_patch() {
  if [ ! -f "$DA3_RUNTIME_PATCH" ] || [ -L "$DA3_RUNTIME_PATCH" ]; then
    echo "DA3 runtime patch is missing or is not a regular file: $DA3_RUNTIME_PATCH" >&2
    exit 1
  fi
  local actual_sha256
  actual_sha256="$(shasum -a 256 "$DA3_RUNTIME_PATCH" | awk '{print $1}')"
  if [ "$actual_sha256" != "$DA3_RUNTIME_PATCH_SHA256" ]; then
    echo "DA3 runtime patch checksum mismatch: expected $DA3_RUNTIME_PATCH_SHA256, got $actual_sha256" >&2
    exit 1
  fi
}

verify_torch_mps() {
  PYTHONNOUSERSITE=1 "$PYTHON_DIR/bin/python3" - <<'PY'
import sys
try:
    import torch
except Exception as exc:
    sys.stderr.write(f"da3_mps: failed to import torch: {exc}\n")
    raise SystemExit(1)
print(f"torch={torch.__version__}")
print(f"mps.is_built={torch.backends.mps.is_built()}")
print(f"mps.is_available={torch.backends.mps.is_available()}")
if not torch.backends.mps.is_built():
    sys.stderr.write("da3_mps: torch was built without MPS support.\n")
    raise SystemExit(1)
PY
}

download_model() {
  local local_name="$1"
  local target="$MODELS_DIR/$local_name"
  rm -rf "$target"
  mkdir -p "$target"
  HF_HUB_DISABLE_TELEMETRY=1 DO_NOT_TRACK=1 PYTHONNOUSERSITE=1 \
    "$PYTHON_DIR/bin/python3" - "$DA3_MODEL_LOCK" "$local_name" "$target" <<'PY'
import hashlib
import json
import sys
from pathlib import Path

from huggingface_hub import model_info, snapshot_download

lock_path = Path(sys.argv[1])
local_name = sys.argv[2]
target = Path(sys.argv[3])
lock = json.loads(lock_path.read_text(encoding="utf-8"))
try:
    expected = lock["models"][local_name]
    repo_id = expected["repo_id"]
    revision = expected["requested_revision"]
except (KeyError, TypeError) as exc:
    raise SystemExit(f"invalid DA3 model lock for {local_name}: {exc}") from exc

def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()

print(f"Downloading {repo_id}@{revision} into {target}")
info = model_info(repo_id=repo_id, revision=revision)
license_value = ""
card_data = getattr(info, "cardData", None)
if isinstance(card_data, dict):
    license_value = str(card_data.get("license") or "").lower()
elif card_data is not None and getattr(card_data, "license", None):
    license_value = str(card_data.license).lower()
tags = {str(tag).lower() for tag in (getattr(info, "tags", None) or [])}
if license_value != "apache-2.0" and "license:apache-2.0" not in tags:
    raise SystemExit(
        f"{repo_id}@{revision} is not Apache-2.0 "
        f"(license={license_value!r}, tags={sorted(tags)!r})"
    )
if info.sha != expected["resolved_sha"]:
    raise SystemExit(
        f"{repo_id}@{revision} resolved to {info.sha}, expected "
        f"{expected['resolved_sha']}"
    )
if expected["license"] != "apache-2.0":
    raise SystemExit(f"{repo_id}@{revision} has an unreviewed locked license")

snapshot_download(
    repo_id=repo_id,
    revision=revision,
    local_dir=target,
    allow_patterns=["config.json", "model.safetensors"],
)
for filename in ("config.json", "model.safetensors"):
    path = target / filename
    artifact = expected["artifacts"][filename]
    if not path.is_file() or path.is_symlink():
        raise SystemExit(f"missing regular DA3 model artifact: {path}")
    if path.stat().st_size != artifact["size_bytes"]:
        raise SystemExit(f"DA3 model artifact byte size mismatch: {path}")
    if sha256(path) != artifact["sha256"]:
        raise SystemExit(f"DA3 model artifact SHA-256 mismatch: {path}")

(target / "easysplat_model_info.json").write_text(
    json.dumps(expected, indent=2, sort_keys=True)
    + "\n",
    encoding="utf-8",
)
PY
  install -m 0644 "$DA3_SOURCE/LICENSE" "$target/LICENSE"
  rm -rf "$target/.cache"
  PYTHONNOUSERSITE=1 "$PYTHON_DIR/bin/python3" - "$target" <<'PY'
import sys
from pathlib import Path

root = Path(sys.argv[1])
expected = {"LICENSE", "config.json", "easysplat_model_info.json", "model.safetensors"}
actual = {entry.name for entry in root.iterdir()}
if actual != expected:
    raise SystemExit(
        f"DA3 model payload must contain exactly {sorted(expected)}; got {sorted(actual)}"
    )
for name in expected:
    path = root / name
    if not path.is_file() or path.is_symlink() or path.stat().st_size <= 0:
        raise SystemExit(f"DA3 model payload entry must be a nonempty regular file: {path}")
PY
}

stage_da3_app() {
  local source_root="$ROOT/Tools/Da3Sfm/easysplat_da3_sfm"
  if [ ! -d "$source_root" ]; then
    echo "DA3 app source missing at $source_root" >&2
    exit 1
  fi
  rm -rf "$APP_DIR"
  mkdir -p "$APP_DIR"
  cp -R "$source_root" "$APP_DIR/"
  find "$APP_DIR" -type d -name "__pycache__" -prune -exec rm -rf {} +
  find "$APP_DIR" -type f -name "*.pyc" -delete
}

mkdir -p "$BUILD_DIR"

resolve_da3_source
verify_runtime_patch
reset_install_dir
ensure_python
require_arm64_python

# OmegaConf 2.3.0 requires antlr4-python3-runtime 4.9.x, which has no wheel.
# Every artifact is hash-locked; all other packages must come from wheels.
mkdir -p "$(dirname "$PIP_INSTALL_REPORT")"
install -m 0644 "$REQUIREMENTS_LOCK" "$INSTALL_DIR/licenses/python-packages-requirements.txt"
pip_install \
  --require-hashes \
  --only-binary=:all: \
  --no-binary=antlr4-python3-runtime \
  --force-reinstall \
  --no-cache-dir \
  --report "$PIP_INSTALL_REPORT" \
  -r "$REQUIREMENTS_LOCK"
if find "$PYTHON_DIR" -iname '*opencv*' -print -quit | grep -F . >/dev/null; then
  echo "opencv-python-headless survived the clean install; refusing the release runtime." >&2
  exit 1
fi
install_supplemental_python_licenses
remove_build_only_python_tools
verify_torch_mps

rm -rf "$DA3_VENDOR"
mkdir -p "$DA3_VENDOR/src/depth_anything_3"
if command -v rsync >/dev/null 2>&1; then
  rsync -a --delete \
    --exclude "__pycache__" \
    --exclude "*.pyc" \
    "$DA3_SOURCE/src/depth_anything_3/" "$DA3_VENDOR/src/depth_anything_3/"
else
  cp -R "$DA3_SOURCE/src/depth_anything_3/." "$DA3_VENDOR/src/depth_anything_3/"
fi
install -m 0644 "$DA3_SOURCE/LICENSE" "$DA3_VENDOR/LICENSE"
test ! -e "$DA3_VENDOR/da3_streaming"
/usr/bin/patch --dry-run -s -p1 -d "$DA3_VENDOR" < "$DA3_RUNTIME_PATCH"
/usr/bin/patch -s -p1 -d "$DA3_VENDOR" < "$DA3_RUNTIME_PATCH"

if ! command -v unzstd >/dev/null 2>&1; then
  echo "unzstd is required to extract python-build-standalone license metadata." >&2
  exit 1
fi
download_verified \
  "$PYTHON_STANDALONE_FULL_URL" \
  "$PYTHON_STANDALONE_FULL_TARBALL" \
  "$PYTHON_STANDALONE_FULL_SHA256"
rm -rf "$INSTALL_DIR/licenses/python-build-standalone"
mkdir -p "$INSTALL_DIR/licenses/python-build-standalone"
/usr/bin/tar --use-compress-program=unzstd \
  -xf "$PYTHON_STANDALONE_FULL_TARBALL" \
  -C "$INSTALL_DIR/licenses/python-build-standalone" \
  --strip-components=1 \
  python/PYTHON.json python/licenses
test -s "$INSTALL_DIR/licenses/python-build-standalone/PYTHON.json"
test -d "$INSTALL_DIR/licenses/python-build-standalone/licenses"

if [ ! -f "$DA3_VENDOR/src/depth_anything_3/api.py" ]; then
  echo "DA3 vendor tree missing expected module: src/depth_anything_3/api.py" >&2
  exit 1
fi

stage_da3_app
download_model "DA3-BASE"
download_model "DA3-SMALL"

PYTHONNOUSERSITE=1 "$PYTHON_DIR/bin/python3" - <<PY
import hashlib
import json
import platform
from pathlib import Path
import torch
import torchvision
import huggingface_hub

def packaged_model_info(name):
    path = Path("${MODELS_DIR}") / name / "easysplat_model_info.json"
    return json.loads(path.read_text(encoding="utf-8"))

base_info = packaged_model_info("DA3-BASE")
small_info = packaged_model_info("DA3-SMALL")
requirements_lock = Path("${REQUIREMENTS_LOCK}")
requirements_lock_sha256 = hashlib.sha256(requirements_lock.read_bytes()).hexdigest()
runtime_patch = Path("${DA3_RUNTIME_PATCH}")
runtime_patch_sha256 = hashlib.sha256(runtime_patch.read_bytes()).hexdigest()
supplemental_license_manifest = Path("${SUPPLEMENTAL_LICENSE_MANIFEST}")
supplemental_license_manifest_sha256 = hashlib.sha256(
    supplemental_license_manifest.read_bytes()
).hexdigest()
model_lock = Path("${DA3_MODEL_LOCK}")
model_lock_sha256 = hashlib.sha256(model_lock.read_bytes()).hexdigest()

Path("${INSTALL_DIR}").mkdir(parents=True, exist_ok=True)
Path("${INSTALL_DIR}/build_info.json").write_text(
    json.dumps(
        {
            "toolchain_name": "da3_mps",
            "source_repo": "${DA3_SOURCE_REPO_FOR_BUILD_INFO}",
            "source_ref": "${DA3_SOURCE_REF_FOR_BUILD_INFO}",
            "source_commit": "${DA3_SOURCE_COMMIT}",
            "source_path": "${DA3_SOURCE_DESCRIPTOR}",
            "source_provenance": "${DA3_SOURCE_PROVENANCE}",
            "expected_upstream_repo": "${DA3_REPO}",
            "expected_upstream_ref": "${DA3_REF}",
            "base_checkpoint_repo": base_info["repo_id"],
            "base_checkpoint_revision": base_info["requested_revision"],
            "base_checkpoint_commit": base_info["resolved_sha"],
            "small_checkpoint_repo": small_info["repo_id"],
            "small_checkpoint_revision": small_info["requested_revision"],
            "small_checkpoint_commit": small_info["resolved_sha"],
            "model_lock": "scripts/toolchain/da3-model-lock.json",
            "model_lock_sha256": model_lock_sha256,
            "python_version": platform.python_version(),
            "python_standalone_url": "${PYTHON_STANDALONE_URL}",
            "python_standalone_sha256": "${PYTHON_STANDALONE_SHA256}",
            "python_standalone_license_archive_url": "${PYTHON_STANDALONE_FULL_URL}",
            "python_standalone_license_archive_sha256": "${PYTHON_STANDALONE_FULL_SHA256}",
            "requirements_lock": "Tools/Da3Sfm/requirements.txt",
            "requirements_lock_sha256": requirements_lock_sha256,
            "runtime_patch": "Tools/Da3Sfm/patches/da3-api-lazy-export.patch",
            "runtime_patch_sha256": runtime_patch_sha256,
            "supplemental_license_manifest": "licenses/python-package-upstream-notices.json",
            "supplemental_license_manifest_sha256": supplemental_license_manifest_sha256,
            "pip_install_report": "licenses/python-packages-install-report.json",
            "torch_version": torch.__version__,
            "torchvision_version": torchvision.__version__,
            "huggingface_hub_version": huggingface_hub.__version__,
        },
        indent=2,
    )
    + "\n",
    encoding="utf-8",
)
PY

cat >"$BIN_DIR/easysplat_da3_sfm" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PY="$ROOT/python/bin/python3"
APP="$ROOT/app"
VENDOR_DA3="$ROOT/vendor/depth-anything-3"
unset PYTHONHOME PYTHONUSERBASE PYTHONSTARTUP PYTHONINSPECT
export PYTHONNOUSERSITE=1
export PYTHONSAFEPATH=1
export PYTHONDONTWRITEBYTECODE=1
export PYTHONPATH="$APP:$VENDOR_DA3/src"
export EASYSPLAT_DA3_MODELS_DIR="$ROOT/models"
CACHE_ROOT="${EASYSPLAT_DA3_CACHE_DIR:-${TMPDIR:-/tmp}/EasySplat/DA3Cache}"
export TORCH_HOME="$CACHE_ROOT/torch"
export HF_HOME="$CACHE_ROOT/huggingface"
export HF_HUB_OFFLINE=1
export TRANSFORMERS_OFFLINE=1
export HF_HUB_DISABLE_TELEMETRY=1
export DO_NOT_TRACK=1
export KMP_DUPLICATE_LIB_OK=TRUE
export TOKENIZERS_PARALLELISM=false
export PYTORCH_ENABLE_MPS_FALLBACK=1
exec "$PY" -m easysplat_da3_sfm.run "$@"
SCRIPT
chmod +x "$BIN_DIR/easysplat_da3_sfm"

materialize_runtime_symlinks

KMP_DUPLICATE_LIB_OK=TRUE PYTHONDONTWRITEBYTECODE=1 PYTHONNOUSERSITE=1 \
  PYTHONPATH="$APP_DIR:$DA3_VENDOR/src" "$PYTHON_DIR/bin/python3" - <<'PY'
import sys
try:
    import depth_anything_3.api  # noqa: F401
    import easysplat_da3_sfm  # noqa: F401
except Exception as exc:  # noqa: BLE001
    sys.stderr.write(f"da3_mps import sanity check failed: {exc}\n")
    raise SystemExit(1)
PY

"$BIN_DIR/easysplat_da3_sfm" --help >/dev/null
python3 "$DA3_PAYLOAD_VALIDATOR" --root "$INSTALL_DIR"

echo "da3_mps ready at $INSTALL_DIR"
