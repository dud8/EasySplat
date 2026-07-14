// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EasySplat",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "EasySplatCore", targets: ["EasySplatCore"]),
        .executable(name: "EasySplatApp", targets: ["EasySplatApp"]),
        .executable(name: "EasySplatReleaseVerifier", targets: ["EasySplatReleaseVerifier"]),
        .executable(name: "EasySplatUIVerifier", targets: ["EasySplatUIVerifier"]),
        .executable(name: "EasySplatBenchmarkDriver", targets: ["EasySplatBenchmarkDriver"])
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
            exclude: ["AGENTS.md", "Resources/EasySplatAppIcon.icns"],
            resources: [
                .copy("Resources/project_home_url.txt"),
                .copy("Resources/public_key_ed25519.txt"),
                .copy("Resources/toolchain_manifest_url.txt")
            ]
        ),
        .executableTarget(
            name: "EasySplatReleaseVerifier",
            dependencies: ["EasySplatCore"],
            path: "Tools/ReleaseVerifier"
        ),
        .target(
            name: "EasySplatUIVerifierCore",
            dependencies: ["EasySplatCore"],
            path: "Tools/UIVerifier/Sources/UIVerifierCore"
        ),
        .executableTarget(
            name: "EasySplatUIVerifier",
            dependencies: ["EasySplatUIVerifierCore"],
            path: "Tools/UIVerifier/Sources/UIVerifier"
        ),
        .target(
            name: "EasySplatBenchmarkDriverCore",
            dependencies: [
                "EasySplatCore",
                .product(name: "MetalSplatter", package: "MetalSplatter")
            ],
            path: "Tools/BenchmarkDriver/Sources/BenchmarkDriverCore"
        ),
        .executableTarget(
            name: "EasySplatBenchmarkDriver",
            dependencies: ["EasySplatBenchmarkDriverCore"],
            path: "Tools/BenchmarkDriver/Sources/BenchmarkDriver"
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
            name: "EasySplatUIVerifierTests",
            dependencies: ["EasySplatUIVerifierCore"],
            path: "Tools/UIVerifier/Tests"
        ),
        .testTarget(
            name: "EasySplatBenchmarkDriverTests",
            dependencies: ["EasySplatBenchmarkDriverCore"],
            path: "Tools/BenchmarkDriver/Tests"
        )
    ]
)
