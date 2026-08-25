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
        .executable(name: "lumos-app", targets: ["LumosApp"]),
        .executable(name: "lumos-privileged-helper", targets: ["LumosPrivilegedHelper"]),
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
        .executableTarget(
            name: "LumosApp",
            dependencies: ["LumosSpikeCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
            ]
        ),
        .executableTarget(
            name: "LumosPrivilegedHelper",
            dependencies: ["LumosSpikeCore"],
            linkerSettings: [
                .linkedFramework("Security"),
            ]
        ),
        .testTarget(
            name: "LumosSpikeCoreTests",
            dependencies: ["LumosSpikeCore"]
        ),
    ]
)
