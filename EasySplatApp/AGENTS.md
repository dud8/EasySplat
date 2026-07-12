# EasySplatApp (for agents)

SwiftUI front-end for EasySplat. `AppModel` is the single source of truth for UI state, pipeline progress, and toolchain installation status; views observe it.

## Key layout
- `AppModel.swift`: state for the project library and workspace, pipeline lifecycle, toolchain preparation, and project metadata.
- `EasySplatApp.swift`: app entry point and dependency wiring.
- `Model/`: lightweight UI models (for example `ProjectSummary`).
- `UI/`: SwiftUI screens and components (`Home`, `Project`, `Theme`, `Components`).
- `Viewer/`: MetalSplatter-based viewer wrappers.

## Conventions
- Keep heavy work in EasySplatCore; views should only coordinate UI and forward intents to `AppModel`.
- Update UI state on the main actor (`@MainActor` / `Task { @MainActor in ... }`).
- Use `AppConfig` for manifest/public key overrides; do not hardcode toolchain URLs elsewhere.
- Avoid shelling out or direct toolchain access here; use `ToolchainManager` and `PipelineRunner` from EasySplatCore.
- Use `UI/Theme/Theme.swift` tokens for colors, spacing, radii, and motion instead of hand-rolling local style constants.
- Custom controls should keep keyboard focus visible and respect `@Environment(\.accessibilityReduceMotion)`.
- Keep reusable component state local to the component when hover/focus state would otherwise cause parent view churn.

## Tests
- App-level tests live in `EasySplatAppTests/` at repo root.
- Packaged accessibility, keyboard, appearance, and viewport checks live in `Tools/UIVerifier/` and run through `scripts/release/verify_ui.sh`.
