// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "EasySplat",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "EasySplatCore", targets: ["EasySplatCore"]),
        .executable(name: "EasySplatApp", targets: ["EasySplatApp"])
    ],
    dependencies: [
        .package(url: "https://github.com/scier/MetalSplatter.git", revision: "0c286e79b3ad5c5b95e4aeea7a3d7653613fe0e0"),
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.7.3")
    ],
    targets: [
        .target(
            name: "EasySplatCore",
            dependencies: [],
            path: "EasySplatCore/Sources/EasySplatCore"
        ),
        .executableTarget(
            name: "EasySplatApp",
            dependencies: [
                "EasySplatCore",
                .product(name: "MetalSplatter", package: "MetalSplatter"),
                .product(name: "SplatIO", package: "MetalSplatter"),
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "EasySplatApp",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "EasySplatCoreTests",
            dependencies: ["EasySplatCore"],
            path: "EasySplatCore/Tests/EasySplatCoreTests"
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
