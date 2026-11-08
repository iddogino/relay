#if os(macOS)
import Foundation
import Testing
@testable import RelaySyntaxHighlighter

/// Where an app finds its grammars: in its resources, or nowhere — never
/// through SwiftPM's `Bundle.module`, which stops an app that doesn't have
/// them where it looks. The apps here are folders laid out the way
/// Xcode builds Relay.app.
struct ResourceBundleTests {
    static let bundleName = "RelaySyntaxHighlighter_RelaySyntaxHighlighter.bundle"

    /// A Fake.app with an Info.plist, and the grammars in Contents/Resources
    /// if `withGrammars`.
    func makeApp(withGrammars: Bool) throws -> URL {
        let app = FileManager.default.temporaryDirectory
            .appendingPathComponent("ResourceBundleTests-\(UUID().uuidString)")
            .appendingPathComponent("Fake.app")
        let resources = app.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": "dev.relay.fake", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        if withGrammars {
            // The build folder's copy, which is what `swift test` uses.
            let built = try #require(GrammarStore.resourceBundle())
            try FileManager.default.copyItem(at: built.bundleURL, to: resources.appendingPathComponent(Self.bundleName))
        }
        return app
    }

    @Test func anAppUsesTheGrammarsInItsResources() throws {
        let app = try makeApp(withGrammars: true)
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        let main = try #require(Bundle(url: app))

        let bundle = try #require(GrammarStore.resourceBundle(main: main))
        #expect(bundle.bundleURL.standardizedFileURL
            == app.appendingPathComponent("Contents/Resources/\(Self.bundleName)").standardizedFileURL)
        let store = GrammarStore(bundle: bundle)
        #expect(store.grammar(for: "swift") != nil)
        #expect(store.bundledLanguages().contains("typescript"))
    }

    @Test func anAppWithoutItsGrammarsHighlightsNothing() throws {
        let app = try makeApp(withGrammars: false)
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        let main = try #require(Bundle(url: app))

        #expect(GrammarStore.resourceBundle(main: main) == nil)
        let store = GrammarStore(bundle: nil)
        #expect(store.grammar(for: "swift") == nil)
        #expect(store.bundledLanguages().isEmpty)
    }

    @Test func outsideAnAppTheBuildFoldersGrammarsAreUsed() throws {
        let bundle = try #require(GrammarStore.resourceBundle())
        #expect(bundle.bundleURL.lastPathComponent == Self.bundleName)
        #expect(GrammarStore.shared.grammar(for: "swift") != nil)
    }
}
#endif
