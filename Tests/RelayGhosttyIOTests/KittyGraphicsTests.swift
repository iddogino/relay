// macOS only: these run local programs and SSH servers.
#if os(macOS)
import AppKit
import Foundation
import GhosttyKit
import RelayTestSupport
import Testing
@testable import RelayGhosttyIO
@testable import RelaySSH

/// The kitty graphics protocol beyond showing one image: placements by id,
/// scaled to cells, offset within a cell, stacked by z-index, unicode
/// placeholders (how images survive tmux), every kind of delete (and the
/// uppercase ones that free the data), and re-transmitting an id. Step by
/// step on every path: after each step, what's drawn where is checked.
extension GhosttyIOSuites.TerminalProtocolTests {
    typealias RGB = (Int, Int, Int)
    static let red: RGB = (230, 30, 40)
    static let blue: RGB = (30, 60, 230)
    static let green: RGB = (30, 200, 60)
    static let yellow: RGB = (230, 220, 30)

    /// A pixel of a cell (column, row from 0; dx, dy pixels into it)
    /// that should, or should not, be `color`.
    struct Spot {
        let column: Int, row: Int, dx: Int, dy: Int
        let color: RGB
        let shown: Bool

        static func center(_ column: Int, _ row: Int, _ color: RGB, shown: Bool = true) -> Spot {
            Spot(column: column, row: row, dx: -1, dy: -1, color: color, shown: shown)
        }
    }

    struct Step {
        let what: String
        let bytes: String
        var spots: [Spot] = []
    }

    static func graphics(_ keys: String, _ payload: String = "") -> String { "\u{1B}_G\(keys);\(payload)\u{1B}\\" }
    static func image(_ color: RGB, _ width: Int = 16, _ height: Int = 16) -> String {
        String(format: "@IMG:%02x%02x%02x:%d:%d@", color.0, color.1, color.2, width, height)
    }
    static func at(_ row: Int, _ column: Int) -> String { "\u{1B}[\(row);\(column)H" }

    /// For tmux (allow-passthrough on, as Relay sets it): the sequence
    /// wrapped in its passthrough DCS, its escapes doubled.
    static func tmuxWrapped(_ sequence: String) -> String {
        "\u{1B}Ptmux;" + sequence.replacingOccurrences(of: "\u{1B}", with: "\u{1B}\u{1B}") + "\u{1B}\\"
    }

    /// Placeholder cells for image `id` (≤ 255, as a 256-color foreground):
    /// U+10EEEE, then diacritics for the row and column.
    static func placeholders(id: Int, row: Int, columns: Int) -> String {
        let diacritics: [UInt32] = [0x305, 0x30D, 0x30E, 0x310, 0x312, 0x33D, 0x33E, 0x33F]
        var text = "\u{1B}[38;5;\(id)m"
        for column in 0..<columns {
            text += "\u{10EEEE}" + String(UnicodeScalar(diacritics[row])!) + String(UnicodeScalar(diacritics[column])!)
        }
        return text + "\u{1B}[39m"
    }

    func matches(_ surface: TestSurface, _ spot: Spot) -> Bool {
        guard let cell = surface.cellSize else { return false }
        let x = spot.column * cell.width + (spot.dx < 0 ? cell.width / 2 : spot.dx)
        let y = spot.row * cell.height + (spot.dy < 0 ? cell.height / 2 : spot.dy)
        return isColor(surface.renderedPixel(x: x, y: y), spot.color.0, spot.color.1, spot.color.2) == spot.shown
    }

    /// Runs `steps` on every path (each command line as `command` makes
    /// it), checking each step's spots once all paths show its marker.
    func runSteps(_ steps: [Step], command: ((String) -> String)? = nil,
                  cleanup: (Path) async -> Void = { _ in }) async throws -> [Path: Probe] {
        var probes: [Path: Probe] = [:]
        let arguments = ["steps"] + steps.map { Self.hex($0.bytes) }
        do {
            for path in Self.paths {
                if let command {
                    probes[path] = try Probe(path, [], command: command(Self.probeCommand(arguments)))
                } else {
                    probes[path] = try Probe(path, arguments)
                }
            }
            for (index, step) in steps.enumerated() {
                for (path, probe) in probes {
                    try await probe.waitFor("STEP \(index)", timeout: .seconds(45))
                    let surface = probe.surface
                    do {
                        try await GhosttyTestHost.shared.waitUntil("\(path): \(step.what)", timeout: .seconds(10)) {
                            step.spots.allSatisfy { matches(surface, $0) }
                        }
                    } catch {
                        let wrong = step.spots.filter { !matches(surface, $0) }
                        Issue.record("\(path), step \(index) (\(step.what)): wrong at \(wrong.map { "(\($0.column),\($0.row)) \($0.shown ? "should" : "shouldn't") be \($0.color)" })")
                    }
                }
                for probe in probes.values { probe.surface.typeKeys("n") }
            }
            for probe in probes.values { try await probe.waitFor("END", timeout: .seconds(30)) }
        } catch {
            for path in probes.keys { await cleanup(path) }
            try await closeAll(probes)
            throw error
        }
        for path in probes.keys { await cleanup(path) }
        return probes
    }

    static var placementSteps: [Step] {
        let (red, blue, green, yellow) = (Self.red, Self.blue, Self.green, Self.yellow)
        return [
            Step(what: "transmitting shows nothing",
                 bytes: graphics("a=t,f=32,s=16,v=16,i=1", image(red)) + graphics("a=t,f=32,s=16,v=16,i=2", image(blue))
                    + graphics("a=t,f=32,s=16,v=16,i=3", image(green)),
                 spots: [.center(2, 2, red, shown: false)]),
            Step(what: "a placement by id, the cursor after it",
                 bytes: at(3, 3) + graphics("a=p,i=1,p=7") + "\u{1B}[6n",
                 spots: [Spot(column: 2, row: 2, dx: 4, dy: 4, color: red, shown: true),
                         Spot(column: 3, row: 2, dx: 8, dy: 4, color: red, shown: false)]),
            Step(what: "scaled to 4×2 cells, the cursor left alone (C=1)",
                 bytes: at(3, 10) + graphics("a=p,i=1,p=8,c=4,r=2,C=1") + "\u{1B}[6n",
                 spots: [.center(9, 2, red), .center(12, 3, red), .center(13, 3, red, shown: false)]),
            Step(what: "placed relative to another placement (P, Q, H)",
                 bytes: graphics("a=p,i=1,p=40,P=1,Q=7,H=3,V=1,C=1"),
                 spots: [Spot(column: 5, row: 3, dx: 4, dy: 4, color: red, shown: true)]),
            Step(what: "offset within its cell (X, Y)",
                 bytes: at(6, 3) + graphics("a=p,i=1,p=11,X=8,Y=8,C=1"),
                 spots: [Spot(column: 2, row: 5, dx: 12, dy: 12, color: red, shown: true),
                         Spot(column: 2, row: 5, dx: 3, dy: 3, color: red, shown: false)]),
            Step(what: "a higher z-index on top",
                 bytes: at(3, 3) + graphics("a=p,i=2,p=20,z=1,C=1") + at(3, 20) + graphics("a=p,i=2,p=21,C=1"),
                 spots: [Spot(column: 2, row: 2, dx: 4, dy: 4, color: blue, shown: true),
                         Spot(column: 19, row: 2, dx: 4, dy: 4, color: blue, shown: true)]),
            Step(what: "re-placed below (same placement id, z=-1)",
                 bytes: at(3, 3) + graphics("a=p,i=2,p=20,z=-1,C=1"),
                 spots: [Spot(column: 2, row: 2, dx: 4, dy: 4, color: red, shown: true)]),
            Step(what: "unicode placeholders for a virtual placement",
                 bytes: graphics("a=p,U=1,i=3,p=30,c=2,r=1") + at(9, 1) + placeholders(id: 3, row: 0, columns: 2),
                 spots: [.center(0, 8, green), .center(1, 8, green), .center(2, 8, green, shown: false)]),
            Step(what: "delete by id (d=i)",
                 bytes: graphics("a=d,d=i,i=2"),
                 spots: [Spot(column: 19, row: 2, dx: 4, dy: 4, color: blue, shown: false),
                         Spot(column: 2, row: 2, dx: 4, dy: 4, color: red, shown: true)]),
            Step(what: "delete one placement by its id (d=i with p)",
                 bytes: graphics("a=d,d=i,i=1,p=8"),
                 spots: [.center(12, 3, red, shown: false), Spot(column: 2, row: 2, dx: 4, dy: 4, color: red, shown: true)]),
            Step(what: "delete at the cursor (d=c)",
                 bytes: at(3, 3) + graphics("a=d,d=c"),
                 spots: [Spot(column: 2, row: 2, dx: 4, dy: 4, color: red, shown: false),
                         Spot(column: 2, row: 5, dx: 12, dy: 12, color: red, shown: true)]),
            Step(what: "a placement to delete by its cell",
                 bytes: at(14, 10) + graphics("a=p,i=1,p=16,C=1"),
                 spots: [Spot(column: 9, row: 13, dx: 4, dy: 4, color: red, shown: true)]),
            Step(what: "delete what's at a cell (d=p, x, y)",
                 bytes: graphics("a=d,d=p,x=10,y=14"),
                 spots: [Spot(column: 9, row: 13, dx: 4, dy: 4, color: red, shown: false),
                         Spot(column: 2, row: 5, dx: 12, dy: 12, color: red, shown: true)]),
            Step(what: "a placement at z=5",
                 bytes: at(12, 3) + graphics("a=p,i=1,p=12,z=5,C=1"),
                 spots: [Spot(column: 2, row: 11, dx: 4, dy: 4, color: red, shown: true)]),
            Step(what: "delete by z-index (d=z)",
                 bytes: graphics("a=d,d=z,z=5"),
                 spots: [Spot(column: 2, row: 11, dx: 4, dy: 4, color: red, shown: false),
                         Spot(column: 2, row: 5, dx: 12, dy: 12, color: red, shown: true)]),
            Step(what: "delete every placement (d=a)",
                 bytes: graphics("a=d,d=a"),
                 spots: [Spot(column: 2, row: 5, dx: 12, dy: 12, color: red, shown: false)]),
            Step(what: "the data is kept: placed again",
                 bytes: at(12, 3) + graphics("a=p,i=1,p=13,C=1"),
                 spots: [Spot(column: 2, row: 11, dx: 4, dy: 4, color: red, shown: true)]),
            Step(what: "delete by id and free the data (d=I)",
                 bytes: graphics("a=d,d=I,i=1"),
                 spots: [Spot(column: 2, row: 11, dx: 4, dy: 4, color: red, shown: false)]),
            Step(what: "the freed image can't be placed",
                 bytes: at(12, 3) + graphics("a=p,i=1,p=14,C=1"),
                 spots: [Spot(column: 2, row: 11, dx: 4, dy: 4, color: red, shown: false)]),
            Step(what: "transmit and show",
                 bytes: at(15, 3) + graphics("a=T,f=32,s=16,v=16,i=5,C=1", image(yellow)),
                 spots: [Spot(column: 2, row: 14, dx: 4, dy: 4, color: yellow, shown: true)]),
            Step(what: "delete everything, freeing the data (d=A)",
                 bytes: graphics("a=d,d=A"),
                 spots: [Spot(column: 2, row: 14, dx: 4, dy: 4, color: yellow, shown: false)]),
            Step(what: "freed by d=A",
                 bytes: at(15, 3) + graphics("a=p,i=5,C=1"),
                 spots: [Spot(column: 2, row: 14, dx: 4, dy: 4, color: yellow, shown: false)]),
            Step(what: "an image shown",
                 bytes: at(18, 3) + graphics("a=T,f=32,s=16,v=16,i=6,C=1", image(red)),
                 spots: [Spot(column: 2, row: 17, dx: 4, dy: 4, color: red, shown: true)]),
            Step(what: "re-transmitted under the same id, then shown",
                 bytes: graphics("a=t,f=32,s=16,v=16,i=6", image(blue)) + at(18, 6) + graphics("a=p,i=6,C=1"),
                 spots: [Spot(column: 5, row: 17, dx: 4, dy: 4, color: blue, shown: true)]),
        ]
    }

    @Test func kittyPlacementsAndDeletesWorkAsLocally() async throws {
        let steps = Self.placementSteps
        let probes = try await runSteps(steps)
        let reply = { (path: Path, index: Int) in self.text(probes[path]!.bytes("R\(index)")) }
        for index in steps.indices {
            let reference = reply(.local, index)
            for path in Self.remotes {
                #expect(reply(path, index) == reference, "\(path), step \(index) (\(steps[index].what)): \(reply(path, index).debugDescription) — locally: \(reference.debugDescription)")
            }
        }
        // What the protocol says to reply.
        func at(_ what: String) -> String { reply(.local, steps.firstIndex { $0.what == what }!) }
        #expect(at("transmitting shows nothing") == "\u{1B}_Gi=1;OK\u{1B}\\\u{1B}_Gi=2;OK\u{1B}\\\u{1B}_Gi=3;OK\u{1B}\\")
        let placed = at("a placement by id, the cursor after it")
        #expect(placed.hasPrefix("\u{1B}_Gi=1,p=7;OK\u{1B}\\"), "\(placed.debugDescription)")
        #expect(placed.hasSuffix("\u{1B}[3;4R"), "the cursor moves past the image: \(placed.debugDescription)")
        let scaled = at("scaled to 4×2 cells, the cursor left alone (C=1)")
        #expect(scaled.hasSuffix("\u{1B}[3;10R"), "C=1 leaves the cursor: \(scaled.debugDescription)")
        #expect(at("the data is kept: placed again") == "\u{1B}_Gi=1,p=13;OK\u{1B}\\")
        #expect(at("the freed image can't be placed").contains("ENOENT"), "\(at("the freed image can't be placed").debugDescription)")
        #expect(at("freed by d=A").contains("ENOENT"), "\(at("freed by d=A").debugDescription)")
        try await closeAll(probes)
    }

    @Test func kittyGraphicsWrappedForRelaysTmux() async throws {
        // Inside tmux, the graphics commands go through its passthrough
        // and the placeholder cells are ordinary text tmux draws (and
        // redraws): how images work there. (A placement at the cursor
        // isn't reliable: passthrough lands wherever tmux's own cursor is
        // on the terminal, not the program's.)
        let green = Self.green
        let w = Self.tmuxWrapped
        let steps = [
            Step(what: "transmitted, a virtual placement and its placeholders",
                 bytes: w(Self.graphics("a=t,f=32,s=16,v=16,i=42,q=2", Self.image(green)))
                    + w(Self.graphics("a=p,U=1,i=42,c=3,r=1,q=2")) + Self.at(9, 1) + Self.placeholders(id: 42, row: 0, columns: 3),
                 spots: [.center(0, 8, green), .center(2, 8, green), .center(3, 8, green, shown: false)]),
            Step(what: "deleted, freeing the data",
                 bytes: w(Self.graphics("a=d,d=I,i=42,q=2")),
                 spots: [.center(0, 8, green, shown: false), .center(2, 8, green, shown: false)]),
        ]
        var sockets: [Path: String] = [:]
        for path in Self.paths { sockets[path] = "relay-e2e-\(UUID().uuidString.prefix(8))" }
        var index = Self.paths.makeIterator()
        let probes = try await runSteps(steps, command: { probe in
            let path = index.next()!
            return Self.inRelayTmux(probe, socket: sockets[path]!)
        }, cleanup: { path in await killTmux(sockets[path]!, on: path) })
        try await closeAll(probes)
    }
}

#endif
