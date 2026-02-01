# EasySplatCoreTests (for agents)

XCTest suite for core pipeline, toolchain, and utility logic.

## Key helpers
- `MockSubprocessRunner.swift`: stubs external process calls.
- `MockURLProtocol.swift`: intercepts network requests.
- `TestFileBuilder.swift`: temp directories and file fixtures.
- `ToolchainFixtureBuilder.swift` / `TestToolchains.swift`: build fake toolchains and manifests.
- `AsyncTestHelpers.swift`: async test utilities.

## Conventions
- Keep tests deterministic; avoid real network, disk-heavy toolchains, or external binaries.
- Use temporary directories from `TestFileBuilder` and clean up after.
- Favor small unit tests; keep integration tests scoped to synthetic fixtures.

## Running
- `./scripts/test.sh` from repo root (or `xcrun swift test`).
