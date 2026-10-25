// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MiningKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "MiningCore", targets: ["MiningCore"]),
        .library(name: "MiningSpeech", targets: ["MiningSpeech"]),
        .executable(name: "speech-probe", targets: ["SpeechProbe"]),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git",
                 revision: "1b0ed50d686873128a4129b3510ce3914c849bab", traits: ["Diarizer"]),
    ],
    targets: [
        .target(name: "MiningCore"),
        .target(name: "MiningSpeech", dependencies: ["MiningCore", .product(name: "FluidAudio", package: "FluidAudio")]),
        .executableTarget(name: "SpeechProbe", dependencies: ["MiningSpeech", "MiningCore", .product(name: "FluidAudio", package: "FluidAudio")]),
        .testTarget(name: "MiningCoreTests", dependencies: ["MiningCore"]),
    ]
)
