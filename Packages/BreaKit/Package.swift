// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BreaKit",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "BreaCore", targets: ["BreaCore"]),
        .library(name: "BreaDSP", targets: ["BreaDSP"]),
        .library(name: "BreaAudioEngine", targets: ["BreaAudioEngine"]),
        .library(name: "BreaPresets", targets: ["BreaPresets"]),
        .library(name: "BreaUI", targets: ["BreaUI"]),
    ],
    targets: [
        .target(name: "BreaCore"),
        .target(name: "BreaDSP", dependencies: ["BreaCore"]),
        .target(name: "BreaAudioEngine", dependencies: ["BreaCore", "BreaDSP"]),
        .target(name: "BreaPresets", dependencies: ["BreaCore", "BreaDSP"]),
        .target(name: "BreaUI", dependencies: ["BreaCore", "BreaDSP", "BreaAudioEngine", "BreaPresets"],
                resources: [.process("Resources")]),
        .testTarget(name: "BreaDSPTests", dependencies: ["BreaDSP", "BreaCore"]),
        .testTarget(name: "BreaAudioEngineTests", dependencies: ["BreaAudioEngine"]),
        .testTarget(name: "BreaPresetsTests", dependencies: ["BreaPresets"]),
    ]
)
