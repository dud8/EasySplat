# EasySplat maintainer guide

EasySplat is a macOS 15+ SwiftPM application for Apple Silicon. The app owns selection and presentation. `EasySplatCore` owns durable projects, tool installation, reconstruction, training, recovery, export, and diagnostics.

Start with `./scripts/run.sh`. Do not add another launcher.

## Product boundary

The beta supports static-scene reconstruction from video, photo folders, and mixed input. It exports PLY and renders it with MetalSplatter.

`v0.2.0-beta.1` is an unsigned public beta, not a production release. Only one reconstruction runs at a time.

It does not include cloud processing, telemetry, 4D reconstruction, meshes, measurements, a plugin system, generated sharing copy, or additional public export formats.

Implementation names belong in Technical Details and maintainer logs. The main UI speaks in four phases: Prepare, Reconstruct, Train, Finish.

## Source map

- `EasySplatApp/AppModel.swift` and focused extensions: app state, project selection, one-active-run policy, notes, export, share, recovery, and diagnostics.
- `EasySplatApp/UI/`: native split-view project workspace, new-project flow, processing state, result viewer, and inspector.
- `EasySplatCore/Project/`: strict metadata, safe project paths, artifact contracts, validation, and diagnostic scrubbing.
- `EasySplatCore/Pipeline/`: durable-stage orchestration, typed run policy, frame selection, geometry acceptance, training, and recovery.
- `EasySplatCore/SfM/`: DA3 bridge, retained COLMAP commands, scoring, real residual analysis, and model normalization.
- `EasySplatCore/Training/`: native msplat process contract and training artifacts.
- `EasySplatCore/Tools/`: signed manifests, capability selection, resumable downloads, safe extraction, receipts, rollback, and subprocesses.
- `Tools/Da3Sfm/`: local DA3-to-COLMAP bridge.
- `Tools/MsplatNative/`: pinned native C++/Metal trainer.
- `Tools/ManifestTool/`: manifest builder, critical-file hashing, Ed25519 signing, and release key utilities.
- `ThirdParty/MetalSplatter/`: native viewer dependency.
- `scripts/benchmark/`: corpus contracts, machine metadata, evidence validation, and release gates.
- `scripts/release/`: unsigned-beta packaging and verification; production entry points fail closed.

Nested `AGENTS.md` files document local source and test conventions.

## Run policy

`RequestedRunOptions` is the user contract:

```swift
RequestedRunOptions {
    capturePath
    detailProfile
    cameraGrouping
    lensProjection
    inputOrdering
    resourcePolicy
    photoSelection
}
```

`RunPlanResolver` validates impossible combinations before tool installation or project creation, then produces a `ResolvedRunPlan` with:

- geometry route and fallback order;
- Base or Small model choice;
- memory tier and chunk size;
- keyframe and resolution budgets;
- camera grouping and lens model;
- pairing and overlap policy;
- bounded refinement iterations;
- native training and plateau budgets;
- required toolchain capabilities;
- deterministic benchmark seed.

Automatic capture remains neutral. Runtime decisions use requested options or the resolved plan.

Development overrides are intentionally limited to:

- `EASYSPLAT_LOCAL_TOOLCHAIN_ROOT`
- `EASYSPLAT_CANDIDATE_ROUTE`
- `EASYSPLAT_STOP_AFTER_STAGE`
- `EASYSPLAT_SKIP_TRAINING`
- `EASYSPLAT_BENCHMARK_SEED`

Tests inject policy directly. Do not restore backend, device, thread, raw-resolution, or solver environment knobs.

## Project lifecycle

A project is a `.easysplatproj` directory under `~/Documents/EasySplat Projects/`.

Stable artifacts:

```text
project.json
last_opened.json
Logs/pipeline.log
Logs/events.jsonl
SfM/colmap/sparse/0
SfM/geometry_manifest.json
Training/training_manifest.json
Output/splat.ply
```

`ProjectPaths` is the layout authority. Stored paths are relative to the project root and must pass the safe resolver before use. Never accept an absolute path, traversal, or escaping symlink from metadata.

The new-project order is deliberate:

1. validate the request;
2. resolve the run plan;
3. install required capabilities;
4. create the project directory;
5. atomically save metadata;
6. clear pending selection;
7. start the pipeline.

A setup failure therefore creates no failed project and keeps input available for Try Again.

`project.json` format v2 is the only supported project format. Other versions are rejected before a run changes the bundle.

## Durable stages and recovery

The internal pipeline has finer stages than the UI. A checkpoint is useful only after its files and metadata are complete.

- Before training, Stop preserves the last durable geometry/import stage.
- Native training writes an atomic checkpoint generation with model arrays, optimizer moments, schedule, seed, trainer version, and geometry identity.
- Resume validates the checkpoint and dataset identity. If native msplat rejects it, EasySplat restarts training honestly.
- A replacement PLY is written to a temporary path, validated, then atomically promoted. A good previous output is never overwritten by an invalid replacement.

Do not call an intermediate file a checkpoint or snapshot unless its complete-state contract is validated.

## Geometry

The public-beta route uses bounded COLMAP matching and camera reconstruction. A DA3 Base experiment remains behind the typed candidate override, with DA3 Small as its memory-failure retry: one coherent batch of at most 29 images at 336 px, followed by triangulation and bounded bundle adjustment. The bridge rejects a second inference window because independently inferred windows do not share a trustworthy coordinate frame.

Video extraction is dual-purpose: low-resolution analysis chooses useful timestamps, and only selected timestamps are extracted at training resolution. Selected-frame names and manifests preserve exact video timestamps.

Photo and mixed input use plan-specific grouping and ordering. `Use all valid photos` remains bounded by the resolved keyframe budget and still rejects unreadable files and exact duplicates.

Accepted geometry must provide:

- ordered frame names and timestamps;
- explicit pose convention, quaternion order, handedness, and scale type;
- camera model and intrinsics grouping;
- input, selected-frame, and model hashes;
- the project-relative path, exact hash, and point count for any learned initializer;
- registered and total views;
- track and point counts;
- real pixel residual provenance;
- median and p90 pixel residuals;
- timings and measured peak memory;
- fallback reason when applicable.

`ColmapResidualAnalyzer` recomputes residuals from actual tracks. Placeholder or mapper-reported pseudo-residuals cannot pass. The pipeline requires at least 90% registration, median residual at most 1.5 px, and p90 at most 3 px before training. A learned candidate must also give at least 90% of selected views 20 or more verified track observations; one residual is not meaningful camera support.

The retained COLMAP binary supplies feature extraction, matching, `point_triangulator`, bounded `bundle_adjuster`, `global_mapper`, classic `mapper`, conversion, and analysis. It is the correctness reference and recovery route, not a user option.

The release benchmark calls the 3,000-frame measurement the long-sequence route. It measures whichever route actually ships. The beta does not claim a separate streaming engine or package unless one later clears the same license, memory, throughput, and quality gates.

### Research ledger · July 2026

Novelty is not a shipping criterion. Code, weights, training data, transitive licenses, Apple-Silicon behavior, memory, pose quality, and held-out rendering all have to clear the release gates.

| Work | Current decision |
| --- | --- |
| [Depth Anything 3](https://github.com/ByteDance-Seed/Depth-Anything-3) Base and Small | Keep as the only learned candidate. The official small checkpoints are Apache-2.0 and use safetensors. Multi-window stitching is disabled. |
| [LingBot-Map](https://arxiv.org/abs/2604.14141) | Do not port or redistribute yet. The official path is CUDA/FlashInfer, its checkpoints are executable `.pt` files, and the paper lists Waymo training data. [Waymo's terms](https://waymo.com/open/terms/) treat trained parameters as derivative IP restricted to non-commercial use. Written lineage clearance is required first. |
| [Anchor3R](https://arxiv.org/abs/2606.05035) | Best current long-sequence architecture to watch: transient anchors, loop reinsertion, and motion averaging. No auditable implementation or weights are available. |
| [GLUEMAP](https://github.com/colmap/gluemap) | Use the local-estimate/global-fusion design as a future reference, not as a current implementation or dependency. The reference stack combines several large or license-sensitive learned systems. |
| [LongStream](https://arxiv.org/abs/2602.13172) | Reject for this beta. The public lineage is VGGT-derived, the available checkpoint is large and executable, and redistribution terms are not explicit. |
| [InstantSfM](https://arxiv.org/abs/2510.13310) | Paper-only Metal sparse-solver experiment. No stable official implementation was available to audit. |
| [Speed3R](https://github.com/Visual-AI/speed3r) | Reuse the sparse-attention principle only. Its Pi3-derived weights are non-commercial. |
| [Faster-GS](https://github.com/nerficg-project/faster-gaussian-splatting) | Clean-room candidate for measured raster, backward-pass, load-balancing, and buffer-reuse improvements in msplat. Do not import the CUDA stack. |
| [FastGS](https://github.com/fastgs/FastGS) and [SAD-GS](https://arxiv.org/abs/2604.28016) | Benchmark their multi-view splitting and early anisotropic densification ideas independently. Retain only Pareto improvements with a clean license closure. |
| [TurboGS](https://arxiv.org/abs/2606.15924) | Watchlist. No implementation was available to validate against Metal's tile-coherent renderer. |

An untracked local single-capture diagnostic explains why DA3 is not the default, but is not release evidence. A 29-view Base run at 336 px spent 1.39 seconds in the model forward pass and 3.61 seconds in the full DA3 bridge, followed by a separately timed 32-second refinement. The bridge reported a 15.74 GB peak footprint. It registered every view with low aggregate residuals, but several cameras had weak track support. The 392 px variant contained a camera with only two observations and a 25× adjacent-position jump; a same-frame COLMAP comparison also showed a grossly different camera path. The fast result was not trustworthy.

The default route has a separate local end-to-end sanity result on an M4 Max with 48 GB. A 9.54-second 4K HEVC drone clip selected 30 frames at the persisted 3 FPS analysis rate, registered 30/30 views, produced 4,728 sparse points and 43,709 observations at 0.55 px mean reprojection error, then trained 247,750 Gaussians in 46.08 seconds. Input-to-validated-PLY time was 85.46 seconds with 2.61 GB maximum resident memory, down from 258.77 seconds for the earlier 1,600 px/55-frame plan. This proves the signed-cache COLMAP-to-Metal path on one real capture; it does not replace the release corpus or held-out rendering gates.

The next learned route must use a bounded initializer subset, register the remaining selected views into one canonical model, reject weak per-view topology, and pass true held-out PSNR, SSIM, and LPIPS comparisons. Until then, direct COLMAP is the honest default.

## Native training

`easysplat-train` is the only trainer. It communicates with `MsplatRunner` using JSONL events and writes atomic checkpoint generations.

Resolved maximum iterations and plateau windows are:

| Detail | Iterations | Plateau window |
| --- | ---: | ---: |
| Fast | 3,000 | 400 |
| Balanced | 7,000 | 800 |
| High Detail | 15,000 | 1,500 |

The process contract binds the checkpoint and final artifact to the geometry digest, input identity, profile, budget, seed, and trainer version. Exit zero without a validated completion event and PLY is failure.

## Toolchain trust

Manifest schema 2 has exactly three beta components:

- `macos-arm64-core`
- `geometry-da3-base`
- `geometry-da3-small`

The signed manifest binds API version, key ID, app-version range, component capabilities, dependencies, exact byte size, SHA-256, archive contents, and critical-file hashes. ManifestTool derives extensionless executables from ZIP permissions and hashes the complete signed executable superset. Every release asset must be smaller than 2 GiB.

Installation enforces HTTPS except explicit loopback development, redirect policy, free-space preflight, expected size, full archive hash, traversal and symlink rejection, atomic promotion, rollback, signed receipts, and critical-file revalidation. Interrupted component downloads retain only partial data bound to the same URL, expected size, and SHA-256.

Private signing keys may come from a protected file or environment source accepted by ManifestTool. Never place a private key in command arguments, logs, Git, or a PR artifact.

## UI rules

Use native SwiftUI/AppKit behavior first:

- `NavigationSplitView`, source-list rows, toolbars, menus, `LabeledContent`, dividers, system controls and materials;
- spacing tokens 8, 12, 20, and 32;
- one 12-point radius for the input target and canvas;
- accent blue only for selection, active progress, and the primary action;
- a single 0.16-second workspace crossfade disabled by Reduce Motion.

Do not reintroduce dashboards, generic cards, quality badges, hover lift, shimmer, ornamental shadows, custom button styles, generated captions, or metadata-chip piles.

Every control needs a useful accessibility label and keyboard path. The input target must remain a real button with drop support. Viewer keys are arrows to orbit, Option-arrows to pan, `+`/`-` to zoom, `F` to fit, and `R` to reset.

## Diagnostics and privacy

There is no telemetry or crash SDK. Diagnostics exclude media and notes by default, remove title and UUID, scrub home/removable-volume paths and URL credentials, and show the payload before copy or save.

Keep diagnostic facts measured and useful. Do not revive service history, usage counters, fleet comparisons, qualitative ratings, or app event logs.

## Tests

Run the narrow suite while iterating, then the full relevant gates before committing:

```bash
./scripts/test.sh
swift test --package-path Tools/ManifestTool
./scripts/test_python_tools.sh
./scripts/ci/check_repo_health.sh
./scripts/ci/check_workflows.sh
./scripts/ci/test_release_scripts.sh
find scripts -type f -name '*.sh' -print0 | xargs -0 -n1 bash -n
```

Release verification adds:

```bash
./scripts/benchmark/run_suite.sh --profile release
./scripts/ci/test_msplat_native_build.sh
shellcheck $(git ls-files 'scripts/*.sh' 'scripts/**/*.sh')
actionlint
gitleaks git --redact
```

The full benchmark requires external media matching `scripts/benchmark/corpus.json`. Never fabricate evidence or mark an unavailable scene as passed. The Release App workflow invokes `verify_beta.sh` with the built app, DMG, signed component closure, real fixture, and online/offline runners, then invokes `verify_ui.sh` on its isolated interactive runner. `--help` output is not verification.

## Releases

Unsigned beta packaging consumes an existing signed toolchain closure. Call `build_dmg.sh` with explicit HTTPS URLs for the manifest and every component plus `--use-existing-toolchain`; it never builds a toolchain or creates a release key locally. Use `./scripts/run.sh` for local toolchain builds and development.

Unsigned beta artifacts say so in the filename, plist, release notes, provenance, and verification output. `--production` fails closed in both app and DMG builders.

The app release workflow is manual, runs only from current protected `main` on the isolated self-hosted Apple Silicon runner, requires the release environment, and publishes to an existing reviewed prerelease tag. It does not create or move tags.

Production packaging is intentionally disabled until Developer ID signing, hardened runtime, notarization, stapling, strict nested-code verification, Gatekeeper assessment, and a quarantined clean-Mac install all pass. It must never fall back to an unsigned artifact.
