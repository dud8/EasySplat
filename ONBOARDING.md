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
