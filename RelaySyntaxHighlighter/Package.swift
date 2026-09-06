// swift-tools-version: 6.0
import PackageDescription

// Standalone on purpose: the highlighter is an experiment in vendoring
// Prism's grammar data behind a hand-rolled Swift engine. Keeping it a
// self-contained package (own manifest, no dependency on the app or
// RelayCore) means it can be tested on Linux in isolation — and replaced
// wholesale if the approach doesn't pan out.
let package = Package(
    name: "RelaySyntaxHighlighter",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "RelaySyntaxHighlighter", targets: ["RelaySyntaxHighlighter"])
    ],
    targets: [
        .target(
            name: "RelaySyntaxHighlighter",
            resources: [.copy("Grammars")]
        ),
        .testTarget(
            name: "RelaySyntaxHighlighterTests",
            dependencies: ["RelaySyntaxHighlighter"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
