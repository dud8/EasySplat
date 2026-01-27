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
        .package(url: "https://github.com/scier/MetalSplatter.git", from: "0.1.1"),
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.7.3"),
        .package(url: "https://github.com/swiftlang/swift-testing.git", exact: "6.0.2")
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
            dependencies: [
                "EasySplatCore",
                .product(name: "Testing", package: "swift-testing")
            ],
            path: "EasySplatCore/Tests/EasySplatCoreTests"
        ),
        .testTarget(
            name: "EasySplatAppTests",
            dependencies: [
                "EasySplatApp",
                "EasySplatCore",
                .product(name: "Testing", package: "swift-testing")
            ],
            path: "EasySplatAppTests"
        ),
        .testTarget(
            name: "EasySplatUITests",
            dependencies: ["EasySplatApp"],
            path: "EasySplatUITests"
        )
    ]
)
