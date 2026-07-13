#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

VIDEO=""
OUT_DIR=""
FRAME_COUNT=30
PROFILE="single"
PROCESS_RES=504
MAX_POINTS=120000
SCALE_WIDTH=960
WINDOW_SIZE=6
WINDOW_OVERLAP=3
MEMORY_CEILING_BYTES="${EASYSPLAT_DA3_MEMORY_CEILING_BYTES:-15032385536}"
DA3_TOOL="${DA3_TOOL:-$ROOT/Toolchains/build/da3_mps/install/da3_mps/bin/easysplat_da3_sfm}"
DA3_MODELS_DIR="${DA3_MODELS_DIR:-$ROOT/Toolchains/build/da3_mps/install/da3_mps/models}"
COLMAP_BIN="${COLMAP_BIN:-$ROOT/Toolchains/out/bin/colmap}"

usage() {
  cat <<EOF
Usage: $(basename "$0") --video /absolute/path/to/input.mp4 [options]

Options:
  --out DIR                  Output directory. Defaults to a temp directory under $ROOT/tmp.
  --frame-count N            Uniformly sampled frame count (default: $FRAME_COUNT)
  --profile NAME             single or scaling-30-120-250 (default: $PROFILE)
  --process-res N            DA3 process resolution (default: $PROCESS_RES)
  --max-points N             Sparse point cap (default: $MAX_POINTS)
  --scale-width N            FFmpeg extraction width before inference (default: $SCALE_WIDTH)
  --window-size N            DA3 inference window size (default: $WINDOW_SIZE)
  --window-overlap N         DA3 inference window overlap (default: $WINDOW_OVERLAP)
  --memory-ceiling-bytes N   Fail if peak memory footprint exceeds N (default: $MEMORY_CEILING_BYTES)
  --da3-tool PATH            Override the packaged DA3 wrapper
  --da3-models-dir PATH      Override the packaged DA3 models directory
  --colmap-bin PATH          Override the COLMAP binary used for model_analyzer
  -h, --help                 Show this help
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
    --frame-count)
      FRAME_COUNT="$2"
      shift 2
      ;;
    --profile)
      PROFILE="$2"
      shift 2
      ;;
    --process-res)
      PROCESS_RES="$2"
      shift 2
      ;;
    --max-points)
      MAX_POINTS="$2"
      shift 2
      ;;
    --scale-width)
      SCALE_WIDTH="$2"
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
    --memory-ceiling-bytes)
      MEMORY_CEILING_BYTES="$2"
      shift 2
      ;;
    --da3-tool)
      DA3_TOOL="$2"
      shift 2
      ;;
    --da3-models-dir)
      DA3_MODELS_DIR="$2"
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

if [ "$PROFILE" != "single" ] && [ "$PROFILE" != "scaling-30-120-250" ]; then
  echo "--profile must be single or scaling-30-120-250" >&2
  exit 1
fi

if [ -z "$VIDEO" ]; then
  echo "--video is required" >&2
  usage >&2
  exit 1
fi

if [ ! -f "$VIDEO" ]; then
  echo "Video not found: $VIDEO" >&2
  exit 1
fi

if [ ! -x "$DA3_TOOL" ]; then
  echo "DA3 wrapper not found or not executable: $DA3_TOOL" >&2
  exit 1
fi

if [ ! -d "$DA3_MODELS_DIR" ]; then
  echo "DA3 models directory not found: $DA3_MODELS_DIR" >&2
  exit 1
fi

if [ ! -x "$COLMAP_BIN" ]; then
  echo "COLMAP binary not found or not executable: $COLMAP_BIN" >&2
  exit 1
fi

mkdir -p "$ROOT/tmp"
if [ -z "$OUT_DIR" ]; then
  OUT_DIR="$(mktemp -d "$ROOT/tmp/da3-bench.XXXXXX")"
else
  mkdir -p "$OUT_DIR"
fi

uniform_select_expression() {
  local video_path="$1"
  local target_count="$2"
  python3 - "$video_path" "$target_count" <<'PY'
import json
import subprocess
import sys

video_path = sys.argv[1]
target_count = max(2, int(sys.argv[2]))

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
streams = (json.loads(probe.stdout or "{}").get("streams") or [])
if not streams:
    raise SystemExit("ffprobe did not return a video stream")

frame_count = int(streams[0].get("nb_read_packets") or 0)
if frame_count <= 1:
    raise SystemExit("ffprobe returned fewer than two frames")

target_count = min(target_count, frame_count)
if target_count == frame_count:
    indices = list(range(frame_count))
else:
    step = float(frame_count - 1) / float(target_count - 1)
    indices = []
    for index in range(target_count):
        candidate = max(0, min(frame_count - 1, int(round(index * step))))
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
  rm -rf "$out_dir"
  mkdir -p "$out_dir"
  local select_expr
  select_expr="$(uniform_select_expression "$video_path" "$target_count")"
  ffmpeg -y -i "$video_path" -vf "select='${select_expr}',scale=${SCALE_WIDTH}:-1" -vsync 0 "$out_dir/frame_%03d.png" >/dev/null 2>&1
}

summarize_case() {
  local case_dir="$1"
  local frame_count="$2"
  local refinement_seconds="$3"
  python3 - "$case_dir" "$VIDEO" "$MEMORY_CEILING_BYTES" "$frame_count" "$refinement_seconds" <<'PY'
import json
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
video_path = sys.argv[2]
memory_ceiling = int(sys.argv[3])
frame_count = int(sys.argv[4])
refinement_seconds = float(sys.argv[5])

def first_int(pattern: str, text: str):
    match = re.search(pattern, text, re.IGNORECASE | re.MULTILINE)
    return int(match.group(1)) if match else None

def first_float(pattern: str, text: str):
    match = re.search(pattern, text, re.IGNORECASE | re.MULTILINE)
    return float(match.group(1)) if match else None

log_text = (root / "da3.log").read_text(encoding="utf-8")
analyzer_text = (root / "model_analyzer.log").read_text(encoding="utf-8")
manifest = json.loads((root / "da3_coverage_manifest.json").read_text(encoding="utf-8"))
peak_memory = first_int(r"^\s*(\d+)\s+peak memory footprint", log_text)

summary = {
    "video": video_path,
    "frame_count": frame_count,
    "solve_mode": manifest.get("mode"),
    "input_ordering": manifest.get("input_ordering"),
    "log_path": str(root / "da3.log"),
    "manifest_path": str(root / "da3_coverage_manifest.json"),
    "model_analyzer_path": str(root / "model_analyzer.log"),
    "sparse_path": str(root / "refined"),
    "elapsed_seconds": first_float(r"^\s*([0-9]+(?:\.[0-9]+)?)\s+real", log_text),
    "refinement_seconds": refinement_seconds,
    "max_resident_set_size_bytes": first_int(r"^\s*(\d+)\s+maximum resident set size", log_text),
    "peak_memory_footprint_bytes": peak_memory,
    "memory_ceiling_bytes": memory_ceiling,
    "registered_images": first_int(r"registered images:\s*(\d+)", analyzer_text),
    "points": first_int(r"points:\s*(\d+)", analyzer_text),
    "observations": first_int(r"observations:\s*(\d+)", analyzer_text),
    "mean_track_length": first_float(r"mean track length:\s*([-+]?\d*\.?\d+)", analyzer_text),
    "mean_reprojection_error": first_float(r"mean reprojection error:\s*([-+]?\d*\.?\d+)", analyzer_text),
    "manifest_registered_images": manifest.get("registered_image_count"),
    "windows": len(manifest.get("windows") or []),
    "window_plan": [window.get("images") for window in manifest.get("windows") or []],
    "anchor_images": manifest.get("anchor_image_names") or [],
    "alignment_edges": manifest.get("alignment_edge_count"),
    "max_alignment_rmse": manifest.get("max_alignment_rmse"),
    "alignment_complete": manifest.get("alignment_complete"),
}

summary_path = root / "summary.json"
summary_path.write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
print(json.dumps(summary, indent=2))
print(f"\nSummary written to {summary_path}")

if peak_memory is not None and peak_memory > memory_ceiling:
    raise SystemExit(f"DA3 peak memory {peak_memory} exceeded ceiling {memory_ceiling}")
PY
}

run_case() {
  local frame_count="$1"
  local case_dir="$OUT_DIR/${frame_count}-frames"
  local frames_dir="$case_dir/frames"
  local seed_dir="$case_dir/seed/0"
  local database_path="$case_dir/database.db"
  local triangulated_dir="$case_dir/triangulated"
  local refined_dir="$case_dir/refined"
  local manifest_path="$case_dir/da3_coverage_manifest.json"
  local log_path="$case_dir/da3.log"
  local analyzer_path="$case_dir/model_analyzer.log"

  rm -rf "$case_dir"
  mkdir -p "$case_dir"
  extract_frames "$VIDEO" "$frame_count" "$frames_dir"

  {
    /usr/bin/time -l "$DA3_TOOL" \
      --images "$frames_dir" \
      --out-sparse "$seed_dir" \
      --models-dir "$DA3_MODELS_DIR" \
      --manifest-out "$manifest_path" \
      --device mps \
      --input-ordering continuous \
      --model-subdir DA3-BASE \
      --fallback-model-subdir DA3-SMALL \
      --process-res "$PROCESS_RES" \
      --max-points "$MAX_POINTS" \
      --camera-type PINHOLE \
      --shared-camera \
      --window-size "$WINDOW_SIZE" \
      --window-overlap "$WINDOW_OVERLAP"
  } >"$log_path" 2>&1

  local refinement_start
  refinement_start="$(date +%s)"
  "$COLMAP_BIN" feature_extractor \
    --database_path "$database_path" \
    --image_path "$frames_dir" \
    --ImageReader.camera_model PINHOLE \
    --ImageReader.single_camera 1 >>"$log_path" 2>&1
  python3 - "$manifest_path" "$case_dir/match_pairs.txt" <<'PY'
import json
import sys
from pathlib import Path

manifest = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
pairs = set()
for window in manifest.get("windows") or []:
    names = window.get("images") or []
    for first_index in range(len(names) - 1):
        for second_index in range(first_index + 1, len(names)):
            first, second = sorted((names[first_index], names[second_index]))
            if first != second:
                pairs.add(f"{first} {second}")
if not pairs:
    raise SystemExit("DA3 manifest did not produce any bounded match pairs")
Path(sys.argv[2]).write_text("\n".join(sorted(pairs)) + "\n", encoding="utf-8")
PY
  "$COLMAP_BIN" matches_importer \
    --database_path "$database_path" \
    --match_list_path "$case_dir/match_pairs.txt" \
    --match_type pairs >>"$log_path" 2>&1
  mkdir -p "$triangulated_dir" "$refined_dir"
  "$COLMAP_BIN" point_triangulator \
    --database_path "$database_path" \
    --image_path "$frames_dir" \
    --input_path "$seed_dir" \
    --output_path "$triangulated_dir" >>"$log_path" 2>&1
  "$COLMAP_BIN" bundle_adjuster \
    --input_path "$triangulated_dir" \
    --output_path "$refined_dir" >>"$log_path" 2>&1
  local refinement_end
  refinement_end="$(date +%s)"

  "$COLMAP_BIN" model_analyzer --path "$refined_dir" >"$analyzer_path" 2>&1
  summarize_case "$case_dir" "$frame_count" "$((refinement_end - refinement_start))"
}

if [ "$PROFILE" = "scaling-30-120-250" ]; then
  frame_counts=(30 120 250)
else
  frame_counts=("$FRAME_COUNT")
fi

for count in "${frame_counts[@]}"; do
  run_case "$count"
done

python3 - "$OUT_DIR" "${frame_counts[@]}" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
counts = [int(value) for value in sys.argv[2:]]
cases = [json.loads((root / f"{count}-frames" / "summary.json").read_text(encoding="utf-8")) for count in counts]
(root / "summary.json").write_text(json.dumps({"cases": cases}, indent=2) + "\n", encoding="utf-8")
PY

echo "DA3 benchmark artifacts written to $OUT_DIR"
