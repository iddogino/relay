// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Relay",
    platforms: [
        .macOS(.v15)
    ],
    targets: [
        // Pinned libghostty build. See docs/GHOSTTY_PIN.md and Scripts/build-libghostty.sh.
        .binaryTarget(
            name: "GhosttyKit",
            path: "Vendor/ghostty/macos/GhosttyKit.xcframework"
        ),

        // Domain, runtime providers, and persistence. No AppKit, no libghostty.
        .target(
            name: "RelayCore",
            path: "Sources/RelayCore"
        ),

        // The macOS app.
        .executableTarget(
            name: "Relay",
            dependencies: ["RelayCore", "GhosttyKit"],
            path: "Sources/Relay",
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("CoreText"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("IOSurface"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("UniformTypeIdentifiers"),
            ]
        ),

        // Live end-to-end harness driving the real provider against real remotes.
        .executableTarget(
            name: "relay-e2e",
            dependencies: ["RelayCore"],
            path: "Sources/RelayE2E"
        ),

        .testTarget(
            name: "RelayCoreTests",
            dependencies: ["RelayCore"],
            path: "Tests/RelayCoreTests"
        ),
    ]
)
