// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MixBar",
    platforms: [.macOS("14.2")],
    products: [
        .executable(name: "MixBar", targets: ["MixBar"])
    ],
    targets: [
        .executableTarget(
            name: "MixBar",
            path: "Sources/MixBar",
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("ServiceManagement"),
            ]
        )
    ]
)
