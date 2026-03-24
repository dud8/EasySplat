#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

VIDEO=""
OUT_DIR=""
DIRECT_COUNT=6
SEED_COUNT=24
RESOLUTION=518
SCALE_WIDTH=960
ANCHOR_MAX_VIEWS=24
WINDOW_SIZE=6
WINDOW_OVERLAP=2
MAPANYTHING_TOOL="${MAPANYTHING_TOOL:-$ROOT/Toolchains/build/mapanything_mps/install/mapanything_mps/bin/easysplat_mapanything_sfm}"
COLMAP_BIN="${COLMAP_BIN:-$ROOT/Toolchains/out/bin/colmap}"

usage() {
  cat <<EOF
Usage: $(basename "$0") --video /absolute/path/to/input.mp4 [options]

Options:
  --out DIR                 Output directory. Defaults to a temp directory under $ROOT/tmp.
  --direct-count N         Number of uniformly sampled frames for direct mode (default: $DIRECT_COUNT)
  --seed-count N           Number of uniformly sampled frames for seed_refine mode (default: $SEED_COUNT)
  --resolution N           MapAnything resolution set (default: $RESOLUTION)
  --scale-width N          FFmpeg extraction width before inference (default: $SCALE_WIDTH)
  --anchor-max-views N     Seed/refine anchor budget (default: $ANCHOR_MAX_VIEWS)
  --window-size N          Seed/refine window size (default: $WINDOW_SIZE)
  --window-overlap N       Seed/refine window overlap (default: $WINDOW_OVERLAP)
  --mapanything-tool PATH  Override the packaged MapAnything wrapper
  --colmap-bin PATH        Override the COLMAP binary used for model_analyzer
  -h, --help               Show this help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --video)
      VIDEO="$2"
      shift 2
      ;;
    --out)
      OUT_DIR="$2"
      shift 2
      ;;
    --direct-count)
      DIRECT_COUNT="$2"
      shift 2
      ;;
    --seed-count)
      SEED_COUNT="$2"
      shift 2
      ;;
    --resolution)
      RESOLUTION="$2"
      shift 2
      ;;
    --scale-width)
      SCALE_WIDTH="$2"
      shift 2
      ;;
    --anchor-max-views)
      ANCHOR_MAX_VIEWS="$2"
      shift 2
      ;;
    --window-size)
      WINDOW_SIZE="$2"
      shift 2
      ;;
    --window-overlap)
      WINDOW_OVERLAP="$2"
      shift 2
      ;;
    --mapanything-tool)
      MAPANYTHING_TOOL="$2"
      shift 2
      ;;
    --colmap-bin)
      COLMAP_BIN="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [ -z "$VIDEO" ]; then
  echo "--video is required" >&2
  usage >&2
  exit 1
fi

if [ ! -f "$VIDEO" ]; then
  echo "Video not found: $VIDEO" >&2
  exit 1
fi

if [ ! -x "$MAPANYTHING_TOOL" ]; then
  echo "MapAnything wrapper not found or not executable: $MAPANYTHING_TOOL" >&2
  exit 1
fi

if [ ! -x "$COLMAP_BIN" ]; then
  echo "COLMAP binary not found or not executable: $COLMAP_BIN" >&2
  exit 1
fi

mkdir -p "$ROOT/tmp"
if [ -z "$OUT_DIR" ]; then
  OUT_DIR="$(mktemp -d "$ROOT/tmp/mapanything-bench.XXXXXX")"
else
  mkdir -p "$OUT_DIR"
fi

direct_frames="$OUT_DIR/direct_frames"
seed_frames="$OUT_DIR/seed_frames"

uniform_select_expression() {
  local video_path="$1"
  local target_count="$2"
  python3 - "$video_path" "$target_count" <<'PY'
import json
import math
import subprocess
import sys

video_path = sys.argv[1]
target_count = max(1, int(sys.argv[2]))

probe = subprocess.run(
    [
        "ffprobe",
        "-v",
        "error",
        "-select_streams",
        "v:0",
        "-count_packets",
        "-show_entries",
        "stream=nb_read_packets",
        "-of",
        "json",
        video_path,
    ],
    check=True,
    capture_output=True,
    text=True,
)
payload = json.loads(probe.stdout or "{}")
streams = payload.get("streams") or []
if not streams:
    raise SystemExit("ffprobe did not return a video stream")

frame_count = int(streams[0].get("nb_read_packets") or 0)
if frame_count <= 0:
    raise SystemExit("ffprobe returned a non-positive frame count")

if target_count >= frame_count:
    indices = list(range(frame_count))
elif target_count == 1:
    indices = [frame_count // 2]
else:
    step = float(frame_count - 1) / float(target_count - 1)
    indices = []
    for index in range(target_count):
        candidate = int(round(index * step))
        candidate = max(0, min(candidate, frame_count - 1))
        if not indices or indices[-1] != candidate:
            indices.append(candidate)
    if indices[-1] != frame_count - 1:
        indices[-1] = frame_count - 1

print("+".join(f"eq(n,{index})" for index in indices))
PY
}

extract_frames() {
  local video_path="$1"
  local target_count="$2"
  local out_dir="$3"
  mkdir -p "$out_dir"
  local select_expr
  select_expr="$(uniform_select_expression "$video_path" "$target_count")"
  ffmpeg -y -i "$video_path" -vf "select='${select_expr}',scale=${SCALE_WIDTH}:-1" -vsync 0 "$out_dir/frame_%03d.png" >/dev/null 2>&1
}

run_case() {
  local name="$1"
  local mode="$2"
  local frames_dir="$3"
  local sparse_dir="$4"
  local manifest_path="$5"
  local log_path="$6"
  local analyzer_path="$7"
  shift 7

  {
    /usr/bin/time -l "$MAPANYTHING_TOOL" \
      --images "$frames_dir" \
      --out-sparse "$sparse_dir" \
      --coverage-manifest "$manifest_path" \
      --mode "$mode" \
      --device mps \
      --resolution "$RESOLUTION" \
      --memory-efficient-inference \
      --shared-camera \
      "$@"
  } >"$log_path" 2>&1

  "$COLMAP_BIN" model_analyzer --path "$sparse_dir" >"$analyzer_path" 2>&1
  echo "Completed $name benchmark"
}

extract_frames "$VIDEO" "$DIRECT_COUNT" "$direct_frames"
extract_frames "$VIDEO" "$SEED_COUNT" "$seed_frames"

run_case \
  "direct" \
  "direct" \
  "$direct_frames" \
  "$OUT_DIR/direct_sparse" \
  "$OUT_DIR/direct_manifest.json" \
  "$OUT_DIR/direct.log" \
  "$OUT_DIR/direct_model_analyzer.log"

run_case \
  "seed_refine" \
  "seed_refine" \
  "$seed_frames" \
  "$OUT_DIR/seed_sparse" \
  "$OUT_DIR/seed_manifest.json" \
  "$OUT_DIR/seed.log" \
  "$OUT_DIR/seed_model_analyzer.log" \
  --anchor-max-views "$ANCHOR_MAX_VIEWS" \
  --window-size "$WINDOW_SIZE" \
  --window-overlap "$WINDOW_OVERLAP"

python3 - "$OUT_DIR" "$VIDEO" <<'PY'
import json
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
video_path = sys.argv[2]

def first_int(pattern: str, text: str):
    match = re.search(pattern, text, re.IGNORECASE | re.MULTILINE)
    return int(match.group(1)) if match else None

def first_float(pattern: str, text: str):
    match = re.search(pattern, text, re.IGNORECASE | re.MULTILINE)
    return float(match.group(1)) if match else None

def read_case(prefix: str):
    log_text = (root / f"{prefix}.log").read_text(encoding="utf-8")
    analyzer_text = (root / f"{prefix}_model_analyzer.log").read_text(encoding="utf-8")
    manifest = json.loads((root / f"{prefix}_manifest.json").read_text(encoding="utf-8"))
    return {
        "log_path": str(root / f"{prefix}.log"),
        "manifest_path": str(root / f"{prefix}_manifest.json"),
        "model_analyzer_path": str(root / f"{prefix}_model_analyzer.log"),
        "sparse_path": str(root / f"{prefix}_sparse"),
        "elapsed_seconds": first_float(r"^\s*([0-9]+(?:\.[0-9]+)?)\s+real", log_text),
        "max_resident_set_size_bytes": first_int(r"^\s*(\d+)\s+maximum resident set size", log_text),
        "peak_memory_footprint_bytes": first_int(r"^\s*(\d+)\s+peak memory footprint", log_text),
        "registered_images": first_int(r"registered images:\s*(\d+)", analyzer_text),
        "points": first_int(r"points:\s*(\d+)", analyzer_text),
        "observations": first_int(r"observations:\s*(\d+)", analyzer_text),
        "mean_track_length": first_float(r"mean track length:\s*([-+]?\d*\.?\d+)", analyzer_text),
        "mean_reprojection_error": first_float(r"mean reprojection error:\s*([-+]?\d*\.?\d+)", analyzer_text),
        "anchors": manifest.get("anchor_image_count"),
        "windows": len(manifest.get("windows") or []),
        "window_reduction_count": manifest.get("window_reduction_count"),
        "manifest_registered_images": manifest.get("registered_image_count"),
        "raw_point_sample_count": manifest.get("raw_point_sample_count"),
        "fused_sparse_point_count": manifest.get("fused_sparse_point_count"),
        "manifest_observation_count": manifest.get("final_observation_count"),
        "manifest_mean_track_length": manifest.get("mean_track_length"),
    }

summary = {
    "video": video_path,
    "direct": read_case("direct"),
    "seed_refine": read_case("seed"),
}

summary_path = root / "summary.json"
summary_path.write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
print(json.dumps(summary, indent=2))
print(f"\nSummary written to {summary_path}")
PY

echo "Benchmark artifacts written to $OUT_DIR"
