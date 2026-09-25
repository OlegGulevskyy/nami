// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Nami",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "NamiCore", targets: ["NamiCore"]),
        .executable(name: "nami-bench", targets: ["NamiBench"]),
        .executable(name: "Nami", targets: ["NamiApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", exact: "1.1.0"),
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts.git", exact: "3.1.0"),
    ],
    targets: [
        .target(name: "NamiCore"),
        .target(name: "NamiAudio", dependencies: ["NamiCore"]),
        .target(name: "NamiStudio", dependencies: [
            "NamiCore", "NamiAudio", "NamiWhisperKit",
            .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
        ]),
        .target(name: "NamiWhisperKit", dependencies: [
            "NamiCore", .product(name: "WhisperKit", package: "argmax-oss-swift"),
        ]),
        .executableTarget(name: "NamiBench", dependencies: ["NamiCore", "NamiAudio", "NamiWhisperKit"],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", "Resources/Info.plist"])]),
        .executableTarget(name: "NamiApp", dependencies: ["NamiStudio"]),
        .testTarget(name: "NamiCoreTests", dependencies: ["NamiCore", "NamiAudio"]),
        .testTarget(name: "NamiStudioTests", dependencies: ["NamiStudio"]),
    ]
)
