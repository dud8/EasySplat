# EasySplatApp repository map

`EasySplatApp` is the macOS 15+ SwiftUI executable target. It presents the
capture-to-splat workflow, project library, processing status, result viewer,
export/share surfaces, and release-verification UI path. Pipeline execution,
project-bundle persistence, toolchains, and artifact validation live in
`EasySplatCore`.

## Target and runtime entry points

- `Package.swift` declares `EasySplatApp` as an executable target depending on
  `EasySplatCore`, `EasySplatReleaseVerifierCore`, and the local MetalSplatter
  package. Its bundled resources are the project-home URL, toolchain manifest
  URL, and Ed25519 public key; `AGENTS.md` and the app icon are excluded from
  SwiftPM source compilation.
- `EasySplatApp.swift` is the `@main` entry point. It resolves the guarded
  release-verification startup mode, configures the AppKit activation policy,
  instantiates `AppDelegate`, and starts `NSApplication`.
- `AppDelegate.swift` owns the AppKit shell: the main window, menu hierarchy,
  menu validation, app/file-open events, standalone PLY windows, window title
  updates, and quit/close coordination. Normal startup shows the SwiftUI
  workspace; the authorized verification path runs the bundled pipeline and
  exits without presenting the ordinary application window.
- `AppRootView` injects one shared `AppModel` into `RootView` as an environment
  object. The app model is `@MainActor`, so published UI state has main-actor
  ownership.

## Configuration and bundled authority

`AppConfig.swift` is the app-facing configuration boundary.

- The project home, signed toolchain manifest, and Ed25519 public key resolve
  from development overrides only in DEBUG builds, then from the corresponding
  bundled text resource, then from compiled defaults.
- `bundledToolchainBootstrap` recognizes paired bundled authority resources.
  `currentDevelopmentOverrides` produces the typed pipeline development
  settings consumed by the core pipeline configuration.
- The configuration file also validates the isolated,
  `--easysplat-release-verify-bundled-pipeline` startup contract. It rejects
  release-verification attempts that lack the expected token, arguments,
  isolated home, or poisoned development environment.
- `Resources/` contains the three authority values copied into the app bundle;
  `EasySplatAppIcon.icns` is the application icon.

## State ownership and application flow

`AppModel.swift` defines the shared observable state and dependency seams.
It owns the current view state (`home`, `opening`, `processing`, or `viewer`),
pipeline progress and logs, active project/output metadata, selected inputs and
run options, project-library summaries, notes, disk-space snapshot, viewer
preferences, training-preview state, subject-isolation state, sharing state,
and recoverable error presentation.

The model is split by responsibility rather than by screen:

- `AppModel+InputSelection.swift` accepts videos, images, folders, ZIPs, and
  datasets; detects structured datasets; deduplicates selections; produces the
  core `InputSpec`; and derives a project title.
- `AppModel+PipelineLifecycle.swift` creates/resumes/retrains projects,
  prepares toolchains, constructs `PipelineRunner` configurations, receives
  batched pipeline events, coordinates stop/quit/close behavior, and persists
  failures or checkpoints through core project APIs.
- `AppModel+Logging.swift` translates `PipelineEvent` and toolchain progress
  into visible phase/progress state and bounded log tails.
- `AppModel+ProjectManagement.swift` manages the project library, opening
  finished output, recovery choices, notes, rename, trash, duration timing,
  and free-space refreshes.
- `AppModel+Export.swift` validates the selected finished output and performs
  cancellation-aware publication to an export destination.
- `AppModel+Sharing.swift` prepares a validated snapshot, presents AppKit’s
  sharing picker, tracks its session callbacks, and reclaims stale snapshots.
- `AppModel+SubjectIsolation.swift` coordinates optional subject extraction,
  choice/retry/cancellation, variant selection, and removal of the derived
  artifact without replacing the canonical output.
- `AppModel+Diagnostics.swift` copies sanitized technical details and writes
  diagnostic bundles. `AppModel+ReleaseVerification.swift` provides the
  app-side bundled-pipeline verification run. `AppModel+Testing.swift` exposes
  narrowly scoped seams used by the app test target.

`AppModel` receives injectable collaborators for the toolchain manager,
hardware profile, pipeline runner, power assertion, output validation, input
preflight, project publication, isolation coordinator, and filesystem actions.
Those seams make app behavior testable without running the full toolchain.

## SwiftUI workspace

- `UI/Project/RootView.swift` is the navigation shell. It combines the
  project sidebar with the workspace, synchronizes sidebar selection to the
  active project, drains standalone-splat open requests, and presents
  app-level action failures.
- `UI/Project/WorkspaceView.swift` switches the detail area among `HomeView`,
  `OpeningSplatView`, `ProcessingView`, and `ViewerView`. It reports settled
  workspace width to the model and suppresses the workspace transition when
  Reduce Motion is enabled.
- `UI/Home/HomeView.swift` is the new-splat form: importer/drop input,
  capture and run settings, input warnings, duration prediction, and launch.
  `ProjectSidebar.swift` renders and filters/sorts the persisted project
  library, exposes resume/retry actions, and owns selection identity.
- `UI/Project/ProcessingView.swift` presents grouped pipeline phases,
  progress, logs, timing, training preview availability, recovery actions, and
  the stop workflow.
- `UI/Project/ViewerView.swift` is the result workspace. It coordinates the
  viewer load lifecycle, inspector, run facts and notes, export, sharing,
  original/subject variant selection, optional subject-isolation sheet, and
  result toolbar controls.
- `UI/Project/ViewerArtifactLoader.swift` is the asynchronous, request-token
  loader that suppresses stale validation results. `ShareToolbarButton.swift`
  bridges the share affordance to AppKit; `SubjectChoiceSheet.swift` renders
  selectable Vision-label masks and resolves a chosen subject anchor.
- `UI/Components/` supplies the file drop zone, disclosure section, and
  AppKit-backed sidebar search field. `UI/Theme/Theme.swift` centralizes color,
  spacing, radii, and motion tokens; `PageScroll.swift` applies the shared
  scroll edge effect. `WindowAccessor.swift` passes the hosting `NSWindow`
  into view-level coordination.

## Presentation models and helpers

- `Model/DatasetSniffer.swift` recognizes supported COLMAP, Nerfstudio, and
  Polycam folder/ZIP layouts. `PendingDataset.swift` carries a selected dataset
  before run creation.
- `Model/ProjectSummary.swift` defines library rows plus filter, sort, and
  status types. `RunDurationPredictor.swift` estimates a fresh run from
  comparable completed projects.
- `Model/InputSpec+Display.swift`, `StageTimings+Display.swift`, and
  `OutputPlyInfo.swift` provide user-facing presentation data. `SplatFileType`
  classifies splat files accepted by the app and standalone viewer.
- `RunStatusPresenter.swift` turns completed/failed pipeline outcomes into
  notifications when the main window is not attended.

## Viewer subsystem

`Viewer/` combines SwiftUI/AppKit input with MetalSplatter rendering.

- `SplatViewerView.swift` is the SwiftUI-facing viewer surface and load-state
  presentation. `StandaloneSplatViewer.swift` opens PLY files outside a
  project in their own AppKit windows.
- `ViewerCameraState.swift`, `ViewerKeyboardCommand.swift`, and
  `ViewerPointerCommand.swift` contain deterministic camera, keyboard, and
  pointer interaction logic. `RobustSplatBounds.swift` derives resilient scene
  bounds from splat data.
- `Viewer/MetalSplatterSample/` contains the MetalKit bridge and renderer:
  `MetalKitSceneView` manages representable/coordinator loading and
  accessibility state; `MetalKitSceneRenderer` serializes model loading,
  applies memory admission, commits complete scene configurations, and renders
  interactions; the remaining files provide camera math and MetalSplatter
  adapter types.

The app viewer consumes rendering primitives from `ThirdParty/MetalSplatter`.
Core artifact metadata and validation come from `EasySplatCore`; the app layer
does not define a second project or toolchain format.

## Tests and local validation

`EasySplatAppTests/` is the SwiftPM `EasySplatAppTests` target. It covers the
app model and lifecycle, input/dataset handling, project-library behavior,
output and publication safety, subject isolation, sharing, processing text and
timing, workspace presentation, standalone splats, viewer artifact loading,
camera/renderer behavior, color and preview layout contracts, and notification
behavior. `ArtifactFixtureSupport.swift` contains shared test fixtures.

The repository’s app/core test entry point is:

```bash
./scripts/test.sh
```

For focused app-target work, SwiftPM can select the same target directly:

```bash
swift test --filter EasySplatAppTests
```

`./scripts/run.sh` is the repository development launcher; it supplies the
local toolchain configuration consumed by `AppConfig` and `EasySplatCore`.
