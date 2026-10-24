// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Relay",
    platforms: [
        .macOS(.v15)
    ],
    dependencies: [
        // Auto-updates. The framework is embedded into the bundle (and its
        // nested executables signed) by Scripts/build-app.sh.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6"),
        // Diff-viewer syntax highlighting. Standalone by design (own
        // manifest, Linux-testable) so it can be swapped out — see
        // RelaySyntaxHighlighter/PORTING.md.
        .package(path: "RelaySyntaxHighlighter"),
        // Built-in SSH client (RelaySSH). The maintainer's (Joannis
        // Orlandos, of Citadel) fork of apple/swift-nio-ssh: it adds custom
        // private keys, which signing through ssh-agent needs. Pinned
        // exactly — this is the crypto/transport layer.
        .package(url: "https://github.com/Joannis/swift-nio-ssh.git", exact: "0.3.5"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.12.3"),
    ],
    targets: [
        // Pinned libghostty build. See docs/GHOSTTY_PIN.md and Scripts/build-libghostty.sh.
        .binaryTarget(
            name: "GhosttyKit",
            path: "Vendor/ghostty/macos/GhosttyKit.xcframework"
        ),

        // Built-in SSH client: connections, exec channels, ssh-agent and
        // key-file auth, known_hosts. No Relay types; portable to iOS.
        .target(
            name: "RelaySSH",
            dependencies: [
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            path: "Sources/RelaySSH",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),

        // Connects a libghostty surface in manual I/O mode (the Relay patch,
        // see patches/ghostty) to a program it doesn't run itself: output
        // in, keystrokes and size changes out, over RelaySSH.
        .target(
            name: "RelayGhosttyIO",
            dependencies: ["GhosttyKit", "RelaySSH"],
            path: "Sources/RelayGhosttyIO",
            linkerSettings: ghosttyLinkerSettings
        ),

        // Domain, runtime providers, and persistence. No AppKit, no libghostty.
        .target(
            name: "RelayCore",
            dependencies: ["RelaySSH"],
            path: "Sources/RelayCore"
        ),

        // The macOS app.
        .executableTarget(
            name: "Relay",
            dependencies: [
                "RelayCore",
                "GhosttyKit",
                "RelayGhosttyIO",
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "RelaySyntaxHighlighter", package: "RelaySyntaxHighlighter"),
            ],
            path: "Sources/Relay",
            linkerSettings: [
                // Sparkle.framework is embedded at Contents/Frameworks.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ] + ghosttyLinkerSettings
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

        .testTarget(
            name: "RelaySSHTests",
            dependencies: ["RelaySSH", "RelayTestSupport"],
            path: "Tests/RelaySSHTests"
        ),

        // Libghostty manual I/O, from the C API up to full terminals over SSH.
        .testTarget(
            name: "RelayGhosttyIOTests",
            dependencies: ["RelayGhosttyIO", "GhosttyKit", "RelaySSH", "RelayTestSupport"],
            path: "Tests/RelayGhosttyIOTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),

        // Test-only SSH servers: an in-process fake that runs real
        // processes on real ptys (with fault injection), and a throwaway
        // instance of the system's OpenSSH sshd.
        .target(
            name: "RelayTestSupport",
            dependencies: [
                "RelaySSH",
                "RelayPTYSpawn",
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            path: "Tests/Support/RelayTestSupport",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "RelayPTYSpawn",
            path: "Tests/Support/RelayPTYSpawn"
        ),
    ]
)

/// What linking libghostty needs on macOS.
var ghosttyLinkerSettings: [LinkerSetting] {
    [
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
}
