import AppKit
import CoreImage
import GhosttyKit
import IOSurface

/// Dev builds only: on a distributed notification, every live terminal
/// writes what it shows — the frame libghostty's renderer presented, and
/// the visible text — to `<data dir>/snapshots/`. Lets a terminal be
/// checked live (e.g. by test tooling) without screen capture, which a
/// locked or sleeping display rules out.
///
/// A second notification drives the shown terminal: the steps in
/// `<data dir>/drive.json` (keys, text, mouse, wheel, focus, binding
/// actions) go to its surface the way the view forwards real events, and
/// the result goes to `drive-result.json` — so input paths can be checked
/// live without taking over the machine's keyboard and mouse.
@MainActor
enum TerminalSnapshots {
    static let notification = Notification.Name("com.iddogino.Relay.dev.snapshot")
    static let driveNotification = Notification.Name("com.iddogino.Relay.dev.drive")
    private static var views: [ObjectIdentifier: WeakView] = [:]
    private static var observer: NSObjectProtocol?
    private static var driveObserver: NSObjectProtocol?

    private struct WeakView { weak var view: TerminalSurfaceView? }

    static var isAvailable: Bool { AppVariant.bundleIdentifier.hasSuffix(".dev") }

    static func installIfDevBuild() {
        guard isAvailable, observer == nil else { return }
        observer = DistributedNotificationCenter.default().addObserver(
            forName: notification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { writeAll() }
        }
        driveObserver = DistributedNotificationCenter.default().addObserver(
            forName: driveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { drive() }
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
        let dir = AppVariant.devHookDirectory.appendingPathComponent("snapshots", isDirectory: true)
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
                    let info: [String: Any] = [
                        "manualIO": view.isManualIO, "presented": view.isPresented,
                        "inWindow": view.window != nil, "title": view.terminalTitle,
                    ]
                    if let json = try? JSONSerialization.data(withJSONObject: info) {
                        try? json.write(to: dir.appendingPathComponent("terminal-\(index).json"))
                    }
                }
                try? "\(live.count)\n".write(to: dir.appendingPathComponent("done"), atomically: true, encoding: .utf8)
            }
        }
    }
}

// MARK: - Driving

extension TerminalSnapshots {
    private static func drive() {
        let dir = AppVariant.devHookDirectory
        let resultURL = dir.appendingPathComponent("drive-result.json")
        try? FileManager.default.removeItem(at: resultURL)
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("drive.json")),
              let script = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let steps = script["steps"] as? [[String: Any]] else { return }
        // The terminal on screen; with `manualIO`, only one in that mode.
        let wantsManual = script["manualIO"] as? Bool
        let view = views.values.compactMap(\.view).first {
            $0.window != nil && $0.isPresented && (wantsManual == nil || $0.isManualIO == wantsManual)
        }
        var results: [String: Any] = ["found": view != nil, "manualIO": view?.isManualIO ?? false]
        var recorded: [String] = []
        func finish() {
            results["recorded"] = recorded
            if let json = try? JSONSerialization.data(withJSONObject: results) { try? json.write(to: resultURL) }
        }
        guard let view else { return finish() }
        func run(_ index: Int) {
            guard index < steps.count else { return finish() }
            // Read each step: the terminal may have closed during a wait.
            guard let surface = view.surface else {
                results["closed"] = true
                return finish()
            }
            let step = steps[index]
            var delay = 0.05
            switch step["op"] as? String {
            case "key":
                let mods = ghostty_input_mods_e(rawValue: UInt32(step["mods"] as? Int ?? 0))
                for action in [GHOSTTY_ACTION_PRESS, GHOSTTY_ACTION_RELEASE] {
                    var event = ghostty_input_key_s()
                    event.action = action
                    event.mods = mods
                    event.consumed_mods = GHOSTTY_MODS_NONE
                    event.keycode = UInt32(step["keycode"] as? Int ?? 0)
                    event.composing = false
                    event.unshifted_codepoint = (step["unshifted"] as? String)?.unicodeScalars.first?.value ?? 0
                    if action == GHOSTTY_ACTION_PRESS, let text = step["text"] as? String {
                        text.withCString { event.text = $0; _ = ghostty_surface_key(surface, event) }
                    } else {
                        event.text = nil
                        _ = ghostty_surface_key(surface, event)
                    }
                }
            case "text":
                let text = step["text"] as? String ?? ""
                text.withCString { ghostty_surface_text(surface, $0, UInt(text.utf8.count)) }
            case "mousepos":
                ghostty_surface_mouse_pos(surface, step["x"] as? Double ?? 0, step["y"] as? Double ?? 0, GHOSTTY_MODS_NONE)
            case "button":
                let button: ghostty_input_mouse_button_e = switch step["button"] as? String {
                case "right": GHOSTTY_MOUSE_RIGHT
                case "middle": GHOSTTY_MOUSE_MIDDLE
                default: GHOSTTY_MOUSE_LEFT
                }
                let state = step["state"] as? String == "release" ? GHOSTTY_MOUSE_RELEASE : GHOSTTY_MOUSE_PRESS
                _ = ghostty_surface_mouse_button(surface, state, button, GHOSTTY_MODS_NONE)
            case "scroll":
                ghostty_surface_mouse_scroll(surface, step["dx"] as? Double ?? 0, step["dy"] as? Double ?? 0,
                                             step["precise"] as? Bool == true ? 1 : 0)
            case "focus":
                ghostty_surface_set_focus(surface, step["value"] as? Bool ?? true)
            case "action":
                let name = step["name"] as? String ?? ""
                recorded.append("\(name): \(ghostty_surface_binding_action(surface, name, UInt(name.utf8.count)))")
            case "selection":
                var text = ghostty_text_s()
                if ghostty_surface_read_selection(surface, &text) {
                    recorded.append(text.text.map { String(decoding: UnsafeRawBufferPointer(start: $0, count: Int(text.text_len)), as: UTF8.self) } ?? "")
                    ghostty_surface_free_text(surface, &text)
                } else {
                    recorded.append("<no selection>")
                }
            case "wait":
                delay = (step["ms"] as? Double ?? 100) / 1000
            default:
                break
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                MainActor.assumeIsolated { run(index + 1) }
            }
        }
        run(0)
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
