// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Lumos",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "LumosSpikeCore", targets: ["LumosSpikeCore"]),
        .executable(name: "lumos-spike", targets: ["LumosSpike"]),
    ],
    targets: [
        .target(
            name: "LumosSpikeCore",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("IOKit"),
                .linkedFramework("Network"),
            ]
        ),
        .executableTarget(
            name: "LumosSpike",
            dependencies: ["LumosSpikeCore"]
        ),
        .testTarget(
            name: "LumosSpikeCoreTests",
            dependencies: ["LumosSpikeCore"]
        ),
    ]
)

