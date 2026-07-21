# EasySplatCore Sources (for agents)

Core library that orchestrates toolchain management and the end-to-end reconstruction pipeline.

## Key layout
- `Pipeline/`: pipeline stages, progress events, logging, and retry logic (`PipelineRunner`, `PipelineStage`, `PipelineEvent`).
- `Project/`: project metadata and file layout (`ProjectPaths`, `ProjectMetadataStore`).
- `SfM/`: DA3 learned initialization plus bounded COLMAP refinement and recovery.
- `Tools/`: toolchain manifest parsing, downloads, validation, and subprocess utilities (`ToolchainManager`, `SubprocessRunner`).
- `Video/`: frame extraction and selection heuristics.
- `Training/`: native msplat runner, dataset identity, and atomic checkpoint validation.
- `Viewer/`: export helpers for viewer outputs.

## Conventions
- Always use `ProjectPaths` and `ProjectMetadataStore` when reading or writing project state/layout.
- Run external binaries via `SubprocessRunner`; route stdout/stderr through `ToolLogWriter` and `TextTails`.
- Toolchain changes must stay compatible with `ToolchainManifest` and `ToolchainManager` validation rules.
- Keep pipeline stage transitions emitting `PipelineEvent` updates for UI progress tracking.
- Resume training only from a validated native checkpoint whose input and geometry identities match the current project.

## Tests
- Add or update tests in `EasySplatCore/Tests/EasySplatCoreTests/` when changing pipeline logic, toolchain validation, or path rules.
