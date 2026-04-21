// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ManifestTool",
    platforms: [.macOS(.v14)],
    dependencies: [],
    targets: [
        .target(
            name: "ManifestToolCore",
            dependencies: [],
            path: "Sources/ManifestToolCore"
        ),
        .executableTarget(
            name: "ManifestTool",
            dependencies: ["ManifestToolCore"],
            path: "Sources/ManifestTool"
        ),
        .testTarget(
            name: "ManifestToolCoreTests",
            dependencies: ["ManifestToolCore"],
            path: "Tests/ManifestToolCoreTests"
        )
    ]
)
