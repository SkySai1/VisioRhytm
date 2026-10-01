// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VisioRhytm",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "VisioRhytmCore", targets: ["VisioRhytmCore"]),
        .library(name: "VisioRhytmAudio", targets: ["VisioRhytmAudio"]),
        .executable(name: "VisioRhytm", targets: ["VisioRhytm"])
    ],
    targets: [
        .target(name: "VisioRhytmCore"),
        .target(name: "VisioRhytmAudio", dependencies: ["VisioRhytmCore"]),
        .executableTarget(name: "VisioRhytm", dependencies: ["VisioRhytmCore", "VisioRhytmAudio"]),
        .testTarget(name: "VisioRhytmCoreTests", dependencies: ["VisioRhytmCore"]),
        .testTarget(name: "VisioRhytmAudioTests", dependencies: ["VisioRhytmCore", "VisioRhytmAudio"])
    ]
)
