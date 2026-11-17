// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "VoiceCloneProbe",
    platforms: [.macOS("15.0"), .iOS("18.0")],
    products: [
        .library(name: "VoiceCloneCore", targets: ["VoiceCloneCore"]),
        .library(name: "VoiceCloneInfrastructure", targets: ["VoiceCloneInfrastructure"])
    ],
    dependencies: [
        .package(url: "https://github.com/soniqo/speech-swift.git", exact: "0.0.29"),
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.31.6")
    ],
    targets: [
        .target(name: "VoiceCloneCore"),
        .target(
            name: "VoiceCloneInfrastructure",
            dependencies: [
                "VoiceCloneCore",
                .product(name: "OmniVoiceTTS", package: "speech-swift"),
                .product(name: "AudioCommon", package: "speech-swift"),
                .product(name: "MLX", package: "mlx-swift", condition: .when(platforms: [.iOS]))
            ]
        ),
        .executableTarget(
            name: "VoiceCloneProbe",
            dependencies: ["VoiceCloneCore", "VoiceCloneInfrastructure"]
        )
    ]
)
