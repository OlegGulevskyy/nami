// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Nami",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "NamiCore", targets: ["NamiCore"]),
        .library(name: "NamiStudio", targets: ["NamiStudio"]),
        .executable(name: "nami-bench", targets: ["NamiBench"]),
        .executable(name: "nami-lab", targets: ["NamiLab"]),
        .executable(name: "nami-snippets", targets: ["NamiSnippets"]),
        .executable(name: "nami-actions", targets: ["NamiActions"]),
        .executable(name: "Nami", targets: ["NamiApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle.git", exact: "2.10.0"),
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", exact: "1.1.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.4"),
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts.git", exact: "3.1.0"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "2.29.3"),
    ],
    targets: [
        .target(name: "NamiCore"),
        .target(name: "NamiAudio", dependencies: ["NamiCore"]),
        .target(name: "NamiStudio", dependencies: [
            "NamiCore", "NamiAudio", "NamiWhisperKit", "NamiMLXCleanup",
            .product(name: "Sparkle", package: "Sparkle"),
            .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
        ], resources: [.copy("Resources/Fonts"), .copy("Resources/nami-logo.svg"), .copy("Resources/Skills")]),
        .target(name: "NamiWhisperKit", dependencies: [
            "NamiCore", .product(name: "WhisperKit", package: "argmax-oss-swift"),
            .product(name: "FluidAudio", package: "FluidAudio"),
        ]),
        .target(name: "NamiMLXCleanup", dependencies: ["NamiCore",
            .product(name: "MLXLLM", package: "mlx-swift-lm"),
            .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
        ]),
        .executableTarget(name: "NamiBench", dependencies: ["NamiCore", "NamiAudio", "NamiWhisperKit"],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", "Resources/Info.plist"])]),
        .executableTarget(name: "NamiLab", dependencies: ["NamiStudio"]),
        // Depends only on NamiCore so it builds in seconds, without the speech and language models.
        .executableTarget(name: "NamiSnippets", dependencies: ["NamiCore"]),
        .executableTarget(name: "NamiActions", dependencies: ["NamiCore"]),
        .executableTarget(name: "NamiApp", dependencies: ["NamiStudio"]),
        .testTarget(name: "NamiCoreTests", dependencies: ["NamiCore", "NamiAudio"]),
        .testTarget(name: "NamiStudioTests", dependencies: ["NamiStudio"]),
        .testTarget(name: "NamiWhisperKitTests", dependencies: ["NamiWhisperKit", "NamiCore"]),
        .testTarget(name: "NamiMLXCleanupTests", dependencies: ["NamiMLXCleanup", "NamiCore"]),
    ]
)
