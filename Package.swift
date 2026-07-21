// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EasySplat",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "EasySplatCore", targets: ["EasySplatCore"]),
        .executable(name: "EasySplatApp", targets: ["EasySplatApp"]),
        .executable(name: "EasySplatReleaseVerifier", targets: ["EasySplatReleaseVerifier"]),
        .executable(name: "EasySplatBenchmarkDriver", targets: ["EasySplatBenchmarkDriver"]),
        .executable(name: "EasySplatMeasurementRunner", targets: ["EasySplatMeasurementRunner"])
    ],
    dependencies: [
        .package(path: "ThirdParty/MetalSplatter")
    ],
    targets: [
        .target(
            name: "EasySplatCore",
            dependencies: [
                .product(name: "SplatIO", package: "MetalSplatter")
            ],
            path: "EasySplatCore/Sources/EasySplatCore",
            exclude: ["AGENTS.md"]
        ),
        .target(
            name: "EasySplatReleaseVerifierCore",
            dependencies: ["EasySplatCore"],
            path: "Tools/ReleaseVerifierCore"
        ),
        .executableTarget(
            name: "EasySplatApp",
            dependencies: [
                "EasySplatCore",
                "EasySplatReleaseVerifierCore",
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
            dependencies: ["EasySplatCore", "EasySplatReleaseVerifierCore"],
            path: "Tools/ReleaseVerifier"
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
        .target(
            name: "EasySplatMeasurementRunnerCore",
            path: "Tools/MeasurementRunner/Sources/MeasurementRunnerCore"
        ),
        .target(
            name: "EasySplatMeasurementAdapterSupport",
            dependencies: ["EasySplatCore"],
            path: "Tools/MeasurementRunner/Sources/MeasurementAdapterSupport"
        ),
        .executableTarget(
            name: "EasySplatMeasurementRunner",
            dependencies: ["EasySplatCore", "EasySplatMeasurementRunnerCore"],
            path: "Tools/MeasurementRunner/Sources/MeasurementRunner"
        ),
        .testTarget(
            name: "EasySplatCoreTests",
            dependencies: ["EasySplatCore"],
            path: "EasySplatCore/Tests/EasySplatCoreTests",
            exclude: ["AGENTS.md"]
        ),
        .testTarget(
            name: "EasySplatReleaseVerifierTests",
            dependencies: ["EasySplatReleaseVerifierCore", "EasySplatCore"],
            path: "Tools/ReleaseVerifierTests"
        ),
        .testTarget(
            name: "EasySplatAppTests",
            dependencies: [
                "EasySplatApp",
                "EasySplatCore",
                "EasySplatReleaseVerifierCore",
            ],
            path: "EasySplatAppTests"
        ),
        .testTarget(
            name: "EasySplatBenchmarkDriverTests",
            dependencies: ["EasySplatBenchmarkDriverCore"],
            path: "Tools/BenchmarkDriver/Tests"
        ),
        .testTarget(
            name: "EasySplatMeasurementRunnerTests",
            dependencies: [
                "EasySplatCore",
                "EasySplatMeasurementRunnerCore",
                "EasySplatMeasurementAdapterSupport"
            ],
            path: "Tools/MeasurementRunner/Tests"
        )
    ]
)
