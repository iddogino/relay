import AppKit
import CoreImage
import GhosttyKit
import IOSurface

/// Dev builds only: on a distributed notification, every live terminal
/// writes what it shows — the frame libghostty's renderer presented, and
/// the visible text — to `<data dir>/snapshots/`. Lets a terminal be
/// checked live (e.g. by test tooling) without screen capture, which a
/// locked or sleeping display rules out.
@MainActor
enum TerminalSnapshots {
    static let notification = Notification.Name("com.iddogino.Relay.dev.snapshot")
    private static var views: [ObjectIdentifier: WeakView] = [:]
    private static var observer: NSObjectProtocol?

    private struct WeakView { weak var view: TerminalSurfaceView? }

    static var isAvailable: Bool { AppVariant.bundleIdentifier.hasSuffix(".dev") }

    static func installIfDevBuild() {
        guard isAvailable, observer == nil else { return }
        observer = DistributedNotificationCenter.default().addObserver(
            forName: notification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { writeAll() }
        }
    }

    static func register(_ view: TerminalSurfaceView) {
        guard isAvailable else { return }
        views[ObjectIdentifier(view)] = WeakView(view: view)
    }

    static func unregister(_ view: TerminalSurfaceView) {
        views[ObjectIdentifier(view)] = nil
    }

    private static func writeAll() {
        let dir = AppVariant.dataDirectory.appendingPathComponent("snapshots", isDirectory: true)
        // Start clean, so nothing from an earlier snapshot is mistaken for
        // this one.
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        views = views.filter { $0.value.view != nil }
        let live = views.values.compactMap(\.view)
        for view in live { view.drawNow() }
        // Give the renderer a moment to present the frame just requested.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            MainActor.assumeIsolated {
                for (index, view) in live.enumerated() {
                    view.writeSnapshot(to: dir, name: "terminal-\(index)")
                }
                try? "\(live.count)\n".write(to: dir.appendingPathComponent("done"), atomically: true, encoding: .utf8)
            }
        }
    }
}

extension TerminalSurfaceView {
    func drawNow() {
        guard let surface else { return }
        ghostty_surface_draw(surface)
    }

    /// The presented frame as `<name>.png`, the visible text as `<name>.txt`.
    func writeSnapshot(to dir: URL, name: String) {
        guard let surface else { return }
        if let contents = layer?.contents,
           CFGetTypeID(contents as CFTypeRef) == IOSurfaceGetTypeID() {
            let ioSurface = unsafeBitCast(contents as AnyObject, to: IOSurfaceRef.self)
            // Locked while copied, so a frame being drawn can't tear it.
            IOSurfaceLock(ioSurface, .readOnly, nil)
            let image = CIImage(ioSurface: ioSurface)
            let context = CIContext()
            let png = context.pngRepresentation(of: image, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            IOSurfaceUnlock(ioSurface, .readOnly, nil)
            if let png { try? png.write(to: dir.appendingPathComponent("\(name).png")) }
        }
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
            rectangle: false)
        var text = ghostty_text_s()
        if ghostty_surface_read_text(surface, selection, &text) {
            defer { ghostty_surface_free_text(surface, &text) }
            if let pointer = text.text {
                let data = Data(bytes: pointer, count: Int(text.text_len))
                try? data.write(to: dir.appendingPathComponent("\(name).txt"))
            }
        }
    }
}
