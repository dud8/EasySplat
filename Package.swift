// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EasySplat",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "EasySplatCore", targets: ["EasySplatCore"]),
        .executable(name: "EasySplatApp", targets: ["EasySplatApp"])
    ],
    dependencies: [
        .package(path: "ThirdParty/MetalSplatter")
    ],
    targets: [
        .target(
            name: "EasySplatCore",
            dependencies: [],
            path: "EasySplatCore/Sources/EasySplatCore",
            exclude: ["AGENTS.md"]
        ),
        .executableTarget(
            name: "EasySplatApp",
            dependencies: [
                "EasySplatCore",
                .product(name: "MetalSplatter", package: "MetalSplatter"),
                .product(name: "SplatIO", package: "MetalSplatter")
            ],
            path: "EasySplatApp",
            exclude: ["AGENTS.md"],
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "EasySplatCoreTests",
            dependencies: ["EasySplatCore"],
            path: "EasySplatCore/Tests/EasySplatCoreTests",
            exclude: ["AGENTS.md"]
        ),
        .testTarget(
            name: "EasySplatAppTests",
            dependencies: ["EasySplatApp", "EasySplatCore"],
            path: "EasySplatAppTests"
        ),
        .testTarget(
            name: "EasySplatUITests",
            dependencies: ["EasySplatApp"],
            path: "EasySplatUITests"
        )
    ]
)
