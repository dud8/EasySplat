# EasySplat maintainer guide

EasySplat is a macOS 15+ SwiftPM application for Apple Silicon. The app owns selection and presentation. `EasySplatCore` owns durable projects, tool installation, reconstruction, training, recovery, export, and diagnostics.

Start with `./scripts/run.sh`. Do not add another launcher.

## Product boundary

EasySplat `0.2.0` supports static-scene reconstruction from video, photo folders, and mixed input. It exports PLY and renders it with MetalSplatter. Only one reconstruction runs at a time.

It does not include cloud processing, telemetry, 4D reconstruction, meshes, measurements, a plugin system, generated sharing copy, or additional public export formats.

Implementation names belong in Technical Details and maintainer logs. The main UI speaks in four phases: Prepare, Reconstruct, Train, Finish.

## Source map

- `EasySplatApp/AppModel.swift` and focused extensions: app state, project selection, one-active-run policy, notes, export, share, recovery, and diagnostics.
- `EasySplatApp/UI/`: native split-view project workspace, new-project flow, processing state, result viewer, and inspector.
- `EasySplatCore/Project/`: strict metadata, safe project paths, artifact contracts, validation, and diagnostic scrubbing.
- `EasySplatCore/Pipeline/`: durable-stage orchestration, typed run policy, frame selection, geometry acceptance, training, and recovery.
- `EasySplatCore/SfM/`: DA3 runner, native COLMAP commands, scoring, real residual analysis, and model normalization.
- `EasySplatCore/Training/`: native msplat process contract and training artifacts.
- `EasySplatCore/Tools/`: signed manifests, capability selection, resumable downloads, safe extraction, receipts, rollback, and subprocesses.
- `Tools/Da3Sfm/`: local DA3 runner and canonical COLMAP-model export.
- `Tools/MsplatNative/`: pinned native C++/Metal trainer.
- `Tools/ManifestTool/`: manifest builder, critical-file hashing, Ed25519 signing, and release key utilities.
- `ThirdParty/MetalSplatter/`: native viewer dependency.
- `scripts/benchmark/`: corpus contracts, machine metadata, evidence validation, and release gates.
- `scripts/release/`: signed release packaging, notarization, provenance, and verification.

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
- benchmark run seed.

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

EasySplat reads only the project format written by the current build. The project library logs and skips older, newer, malformed, and unsafe bundles without changing or deleting them.

## Durable stages and recovery

The internal pipeline has finer stages than the UI. A checkpoint is useful only after its files and metadata are complete.

- Before training, Stop preserves the last durable geometry/import stage.
- Native training writes an atomic checkpoint generation with model arrays, optimizer moments, schedule, seed, trainer version, and geometry identity.
- Resume validates the checkpoint and dataset identity. If native msplat rejects it, EasySplat restarts training honestly.
- A replacement PLY is written to a temporary path, validated, then atomically promoted. A good previous output is never overwritten by an invalid replacement.

Do not call an intermediate file a checkpoint or snapshot unless its complete-state contract is validated.

## Geometry

The `0.2.0` route uses bounded COLMAP matching and camera reconstruction. A DA3 experiment remains behind the typed candidate override. Its resolved run plan selects Base for standard or performance memory tiers and Small for the constrained tier before any tool starts. Each run uses that one model for one coherent batch of at most 29 images at 336 px, followed by triangulation and bounded bundle adjustment. A memory failure ends that exact candidate; the runner neither substitutes models nor accepts a second inference window because independently inferred windows do not share a trustworthy coordinate frame.

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
- measured pair-graph topology and per-attempt matcher evidence, or an explicit `notEvaluated` state;
- raw canonical-orientation evidence and opening-view direction, with a `verified`, `axisAlignedSignUnverified`, or `unresolved` result.

`ColmapResidualAnalyzer` recomputes residuals from actual tracks. Placeholder or mapper-reported pseudo-residuals cannot pass. The pipeline requires at least 90% registration, median residual at most 1.5 px, and p90 at most 3 px before training. A learned candidate must also give at least 90% of selected views 20 or more verified track observations; one residual is not meaningful camera support.

The retained COLMAP runtime supplies feature extraction, FAISS and exact matching, `point_triangulator`, bounded `bundle_adjuster`, classic incremental `mapper`, conversion, and analysis. It is the correctness reference and recovery route, not a user option.

The release benchmark calls the 3,000-frame measurement the long-sequence route. It measures whichever route actually ships. EasySplat does not claim a separate streaming engine or package unless one clears the same license, memory, throughput, and quality gates.

### Research ledger · July 2026

Novelty is not a shipping criterion. Code, weights, training data, transitive licenses, Apple-Silicon behavior, memory, pose quality, and held-out rendering all have to clear the release gates.

| Work | Current decision |
| --- | --- |
| Native COLMAP | The packaged Apple-Silicon runtime is a pinned, arm64-only COLMAP 4.1.1 source build with the exact nine-command surface EasySplat uses. It ships in the core component with its reviewed `libomp` runtime dependency; PyCOLMAP is not shipped. |
| COLMAP integrated `global_mapper` | Removed. The measured candidate was 2.45× slower in geometric mean and used more peak memory than the optimized incremental mapper. Its occasional coverage recovery did not meet the 30% speedup retention gate. |
| [FastMap](https://github.com/pals-ttic/fastmap) | Do not ship the PyTorch runtime or its internally inconsistent sparse-model export, which writes 3D tracks referencing image records with zero 2D observations. On the M4 Max, the pinned CPU implementation was 1.73× slower than the current mapper on the apartment walkthrough and 3.66× slower on the DJI orbit. A future unshipped Metal/Accelerate experiment is limited to its voting, accumulation, and fused-gradient kernels; it must also cap quadratic track completion and beat the full current mapper by at least 2× before product integration. |
| [XFeat](https://github.com/verlab/accelerated_features) | Highest-priority learned-feature challenger, not a default. A fixed-shape Core ML backbone ran in 3.53 ms and a 30-view apartment graph registered 30/30 where the same SIFT graph registered 15/30. The DJI subset also registered 30/30, but its p90 residual reached 2.86 px and SIFT retained more inliers. Redistribution remains blocked on explicit checkpoint and training-lineage clearance. LighterGlue was not benchmarked and receives no product slot unless XFeat first clears licensing and corpus gates. |
| SIFT + LightGlue | The tested route was rejected from the current queue. On 20 apartment pairs, eight workers took 29.79 seconds and about 15.14 GB versus 0.30 seconds and about 205 MB for FAISS, then recovered only one of twenty FAISS-failed cross-pairs. |
| [LocoTrack-S](https://github.com/KU-CVLAB/LocoTrack) | Rejected as an ordered-video track generator. The official small model ran on MPS without fallback, but 1,920 XFeat-seeded queries registered only 22/30 apartment cameras in 3.57 seconds; pairwise XFeat registered 30/30 and matched faster. A permissive visibility sweep reached 109/119 verified pairs without improving coverage, and the released inference path has quadratic temporal attention rather than a production streaming state. |
| [TAPNext++](https://github.com/google-deepmind/tapnet) | Next ordered-video track candidate, not a normal route. Its recurrent online design directly avoids LocoTrack-S's quadratic temporal path, and the official code and checkpoints are Apache-2.0. Convert the PyTorch checkpoint to a non-executable format, audit PointOdyssey and Kubric lineage, and run the same 30/120/3,000-frame MPS, memory, track-to-geometry, and wall-time gates. Retain only if it beats XFeat + FAISS end to end or uniquely rescues valid scenes. |
| [MapAnything](https://github.com/facebookresearch/map-anything) Apache model | Removed from the product. It may be retested only as a local-star rescue initializer after the optimized route rejects a scene; its multi-gigabyte model is not justified as the default. |
| [MoGe-2](https://github.com/microsoft/MoGe) | Depth/ray-prior candidate only after a residual-gated initializer boundary exists. It must reduce bundle-adjustment or training time, or uniquely rescue hard scenes; attractive depth images are not evidence. |
| [HorizonStream](https://github.com/3DAgentWorld/HorizonStream) | License-first watch. The public runtime is CUDA-oriented, the repository does not currently provide a usable license closure, and VGGT/DINOv2/Waymo lineage needs review before any Metal port. |
| [DGSfM](https://github.com/sithu31296/DGSfM) | Architecture input only. The official repository still says code is coming, so there is nothing reproducible to A/B test. |
| [Depth Anything 3](https://github.com/ByteDance-Seed/Depth-Anything-3) Base and Small | Keep as the only packaged learned geometry candidate. The official small checkpoints are Apache-2.0 and use safetensors. Multi-window stitching is disabled. |
| [LingBot-Map](https://arxiv.org/abs/2604.14141) | Do not port or redistribute yet. The official path is CUDA/FlashInfer, its checkpoints are executable `.pt` files, and the paper lists Waymo training data. [Waymo's terms](https://waymo.com/open/terms/) treat trained parameters as derivative IP restricted to non-commercial use. Written lineage clearance is required first. |
| [Anchor3R](https://arxiv.org/abs/2606.05035) | Best current long-sequence architecture to watch: transient anchors, loop reinsertion, and motion averaging. No auditable implementation or weights are available. |
| [GLUEMAP](https://github.com/colmap/gluemap) | Use the local-estimate/global-fusion design as a future reference, not as a current implementation or dependency. The reference stack combines several large or license-sensitive learned systems. |
| [LongStream](https://arxiv.org/abs/2602.13172) | Rejected for `0.2.0`. The public lineage is VGGT-derived, the available checkpoint is large and executable, and redistribution terms are not explicit. |
| [Glob3R](https://arxiv.org/abs/2607.09225) | Architecture reference only. Code is not public, its Pi3X weight lineage is non-commercial, and the reported 2.06 FPS is from an NVIDIA L20. |
| [InstantSfM](https://arxiv.org/abs/2510.13310) | Paper-only Metal sparse-solver experiment. The surviving implementation snapshot is non-commercial; Apache-2.0 [BAE](https://github.com/pypose/bae) is a numerical reference, not a portable runtime. |
| [Speed3R](https://github.com/Visual-AI/speed3r) | Reuse the sparse-attention principle only. Its Pi3-derived weights are non-commercial. |
| [Faster-GS](https://github.com/nerficg-project/faster-gaussian-splatting) | Clean-room candidate for measured raster, backward-pass, load-balancing, and buffer-reuse improvements in msplat. Do not import the CUDA stack. |
| [VkSplat](https://github.com/jaesung-cs/vksplat) | Do not replace native Metal. A realistic M4 Max fixture was only 2.7% faster in a comparison favorable to VkSplat, a sparse fixture was 13.7× slower, three backward paths exceed Apple's 32 KiB threadgroup-memory limit, and MoltenVK enlarges the runtime closure. Its dual-kernel and sort-key design remain useful references. |
| [3DGS²-TR](https://arxiv.org/abs/2602.00395v1) | Do not claim a faithful port. The paper has no source release, evaluates without densification, and does not fully specify the schedule and parameter mapping needed by EasySplat's densifying spherical-harmonic trainer. A separately derived trust clamp may be benchmarked under its own name; the complete optimizer is not currently in scope. |
| [SkipGS](https://github.com/ASU-ESIC-FAN-Lab/SkipGS) | Clean MIT-licensed candidate for a GPU-resident post-densification backward gate. Test it before speculative trust-region work. Do not port the upstream `loss.item()` synchronization; keep the loss history and decision on the GPU. Retain only if it improves end-to-end Apple-Silicon time at matched held-out quality. |
| [FastGS](https://github.com/fastgs/FastGS) | Benchmark the multi-view-consistency densification and pruning idea independently. Do not import the upstream CUDA implementation: its repository requires adherence to the licenses of 3DGS, Taming-3DGS, and Speedy-Splat. Retain a clean-room Metal experiment only if held-out quality improves at the same Apple-Silicon time and memory budget. |
| [SAD-GS](https://github.com/LinjieLyu/SADGS) | Instrument before implementing. The reported early anisotropic splits are promising, but the reference repository includes conflicting noncommercial lineage and its strongest result grows to roughly four million Gaussians. A clean-room Metal path must first prove stable proposals and bounded memory. |
| [ShorterSplatting](https://arxiv.org/abs/2603.09277) | Reject the non-commercial code and current reset idea. A clean-room 0.8 scale-reset diagnostic was 3.9% slower, raised peak resident memory from 3.43 GB to 6.16 GB, and increased exact raster fallbacks from 894 to 1,044. |
| [TurboGS](https://arxiv.org/abs/2606.15924) | Watchlist. No implementation was available to validate against Metal's tile-coherent renderer. |

The scale-reset result and the DA3 result below are untracked single-capture diagnostics, not release evidence. A 29-view Base run at 336 px spent 1.39 seconds in the model forward pass and 3.61 seconds in the full DA3 runner, followed by a separately timed 32-second refinement. The runner reported a 15.74 GB peak footprint. It registered every view with low aggregate residuals, but several cameras had weak track support. The 392 px variant contained a camera with only two observations and a 25× adjacent-position jump; a same-frame COLMAP comparison also showed a grossly different camera path. The fast result was not trustworthy.

The default route has a separate local end-to-end sanity result on an M4 Max with 48 GB. A 9.54-second 4K HEVC drone clip selected 30 frames at the persisted 3 FPS analysis rate, registered 30/30 views, produced 4,728 sparse points and 43,709 observations at 0.55 px mean reprojection error, then trained 247,750 Gaussians in 46.08 seconds. Input-to-validated-PLY time was 85.46 seconds with 2.61 GB maximum resident memory, down from 258.77 seconds for the earlier 1,600 px/55-frame plan. This proves the signed-cache COLMAP-to-Metal path on one real capture; it does not replace the release corpus or held-out rendering gates.

At `d41617e`, the private 250-view DJI regression completed in 194.01 seconds on the same M4 Max, down from the original 1,262-second app run. Frame extraction and selection took 15.04 seconds; SIFT took 20.08 seconds; FAISS matching took 12.51 seconds; mapping took 60.14 seconds; and native training took 83.21 seconds. It registered 250/250 views with 79,139 points and 965,890 observations at 0.371 px median and 1.279 px p90 residual. Geometry peaked at 2.21 GB and training at 3.39 GB. Training produced 696,290 Gaussians with zero dropped intersections, and canonical orientation resolved as verified with 0.469° median and 0.675° p90 right-axis residuals. This is a 6.50× same-capture speedup.

The run fetched a 9.33 MB native-core archive from an ephemerally signed loopback closure into a 35.6 MiB installed cache; neither DA3 nor Python was installed. With the server stopped, the same verified cache completed offline in 200.75 seconds, registered 250/250 views, and again reported zero dropped intersections. These are one-capture local install and offline-reuse checks, not public-release or corpus evidence.

A separate 4 minute 56 second 8K apartment walkthrough completed in 360.82 seconds. Sequential analysis and extraction took 144.32 seconds, SIFT took 17.69 seconds, three FAISS graph passes took 110.23 seconds, mapping took 26.65 seconds, and training took 60.55 seconds. The maximum FAISS graph contained a 239-view dominant component plus eleven weak views and met the 95% ordered-video floor, so exact matching was unnecessary. COLMAP registered 236/250 views with 33,034 points and 151,748 observations at 0.58 px median and 1.55 px p90 residual. Training published 515,481 Gaussians with zero dropped intersections and peaked at 2.82 GB resident memory. Orientation resolved as verified from all 236 cameras. This validates the bounded ordered-video recovery behavior on one difficult interior capture, not the complete release corpus.

Two native compressed-timeline preparation experiments were rejected and their code removed. Restricting analysis to codec sync frames cut preparation to 17.64 seconds but registered only 192/250 views. Sampling ordinary indexed timestamps took 91.10 seconds, yet the geometry-only run took 293.73 seconds and registered 229/250, seven fewer than the accepted result. Neither speed signal justified the coverage loss.

A bounded 4,096-intersection Metal tile replay remains untracked research. It reduced median trainer time from 94.39 to 67.85 seconds on an overflow-heavy fish-tank fixture and changed DJI median time by less than 1%, with zero dropped intersections. It was not promoted: the existing held-out fixture bound 1,600×899 cameras to 1,600×900 targets, and a diagnostic correction showed candidate median changes of −0.33 dB PSNR, −0.015 SSIM, and +0.003 LPIPS with material run-to-run variance. A speed signal without valid bound quality evidence is insufficient.

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

The run seed fixes COLMAP sampling, orientation bootstrap sampling, and trainer camera order. Relaxed FP32 Metal atomics can still change accumulation order, so matching seeds do not promise byte-identical checkpoints or PLY files.

## Toolchain trust

Manifest schema 2 has exactly three release components:

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

Every control needs a useful accessibility label and keyboard path. The input target must remain a real button with drop support. In the viewer, drag or the arrow keys orbit, Option-drag or Option-arrows pan, scroll, pinch, or `+`/`-` zoom, `F` fits, and `R` resets the opening view.

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

The full benchmark requires external media matching `scripts/benchmark/corpus.json`. Never fabricate evidence or mark an unavailable scene as passed. The Release App workflow runs the packaged verifier with the built app, DMG, signed component closure, generated fixture, and online/offline runners. Geometry conditioning is part of the production pipeline and is recomputed when a geometry artifact is loaded. The packaged fixture must reconstruct at least 11 of 12 views before native training. Release verification also checks the signed and notarized app, stapled DMG, Gatekeeper assessment, quarantined installation, SBOM, licenses, provenance, checksums, and cached offline reuse.

## Releases

Production packaging consumes an existing signed toolchain closure. Call `build_dmg.sh` with explicit HTTPS URLs for the manifest and every component, `--use-existing-toolchain`, and `--production`. It never builds a toolchain, creates a release key, or falls back to an unsigned artifact. Use `./scripts/run.sh` for local toolchain builds and development.

The app release workflow is manual and requires a stable version tag pointing at current protected `main`. Build, signing, notarization, and packaged verification run on isolated Apple Silicon release hosts. The workflow verifies hardened-runtime and nested-code signatures, notarization receipts, stapling, Gatekeeper assessment, and a quarantined clean installation before assembling the final release closure.

Publication is a separate human-approved step. The workflow refuses to overwrite an existing GitHub release and never creates or moves the version tag. Final artifacts must come from the merged tagged commit, not a feature-branch candidate.
