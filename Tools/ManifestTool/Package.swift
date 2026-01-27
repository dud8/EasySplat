// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ManifestTool",
    platforms: [.macOS(.v14)],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "ManifestTool",
            dependencies: [],
            path: "Sources/ManifestTool"
        )
    ]
)
