import Foundation
import Testing
@testable import RelayCore

/// Devices syncing through a stand-in for CloudKit: records with change
/// tags, where a save from a device that hasn't seen the latest tag fails
/// with the server's copy (serverRecordChanged), as CloudKit does. Each
/// device applies changes the way AppModel does.
@Suite("iCloud sync: devices converge")
struct SyncConvergenceTests {
    final class Server {
        struct Record {
            var kind: SyncKind
            var envelope: Data
            var tag: Int
        }
        var records: [String: Record] = [:]
        var nextTag = 1
    }

    struct Device {
        var hosts: [SyncedHost] = []
        var projects: [Project] = []
        var state = SyncState()
        /// The tag of each record this device has fetched (its change token).
        var seen: [String: Int] = [:]

        var items: [SyncItem] {
            hosts.map(SyncItem.host) + projects.map(SyncItem.project)
                + [.projectOrder(SyncedProjectOrder(projects: projects.map(\.id)))]
        }

        mutating func save(_ now: Date) {
            _ = state.recordLocal(items, now: now)
        }

        /// What AppModel does with changes from iCloud: a host still used
        /// by a project here stays (and is sent back by the save after).
        mutating func apply(_ changes: [SyncState.Change], now: Date) {
            for change in SyncState.Change.inApplyOrder(changes) {
                switch change {
                case .upsert(.host(let host)):
                    if let index = hosts.firstIndex(where: { $0.host.alias == host.host.alias }) {
                        hosts[index] = host
                    } else {
                        hosts.append(host)
                    }
                case .remove(.host(let host)):
                    if !projects.contains(where: { $0.workspace.opaqueID == host.host.alias }) {
                        hosts.removeAll { $0.host.alias == host.host.alias }
                    }
                case .upsert(.project(let project)):
                    if let index = projects.firstIndex(where: { $0.id == project.id }) {
                        projects[index] = project
                    } else {
                        projects.append(project)
                    }
                case .remove(.project(let project)):
                    projects.removeAll { $0.id == project.id }
                case .upsert(.projectOrder), .remove(.projectOrder):
                    break
                }
            }
            if let order = state.projectOrder {
                projects = SyncedProjectOrder(projects: order).arrange(projects)
            }
            save(now)
        }

        mutating func fetch(from server: Server, now: Date) {
            var changes: [SyncState.Change] = []
            for (name, record) in server.records.sorted(by: { $0.key < $1.key }) where (seen[name] ?? 0) < record.tag {
                seen[name] = record.tag
                if case .apply(let change) = state.applyRemote(
                    name: name, kind: record.kind, envelope: record.envelope, serverFields: tagData(record.tag)) {
                    changes.append(change)
                }
            }
            if !changes.isEmpty { apply(changes, now: now) }
        }

        mutating func send(to server: Server, now: Date) {
            for _ in 0..<5 where !state.pendingNames.isEmpty {
                var changes: [SyncState.Change] = []
                for name in state.pendingNames {
                    guard let out = state.outgoing(name) else { continue }
                    let clientTag = out.serverFields.flatMap(tag(from:))
                    if let existing = server.records[name], clientTag != existing.tag {
                        // serverRecordChanged: merge with the server's copy.
                        seen[name] = existing.tag
                        if case .apply(let change) = state.applyRemote(
                            name: name, kind: existing.kind, envelope: existing.envelope, serverFields: tagData(existing.tag)) {
                            changes.append(change)
                        }
                    } else if server.records[name] == nil, clientTag != nil {
                        // unknownItem
                        state.forgetServerRecord(name)
                    } else {
                        let tag = server.nextTag
                        server.nextTag += 1
                        server.records[name] = Server.Record(kind: out.kind, envelope: out.envelope, tag: tag)
                        seen[name] = tag
                        state.noteSaved(name, envelope: out.envelope, serverFields: tagData(tag))
                    }
                }
                if !changes.isEmpty { apply(changes, now: now) }
            }
        }
    }

    static func tagData(_ tag: Int) -> Data { Data("\(tag)".utf8) }
    static func tag(from data: Data) -> Int? { Int(String(decoding: data, as: UTF8.self)) }

    /// Each device fetches then sends, in turn, until nothing changes.
    static func syncAll(_ devices: inout [Device], _ server: Server, now: Date) {
        for _ in 0..<10 {
            let before = server.nextTag
            for index in devices.indices {
                devices[index].fetch(from: server, now: now)
                devices[index].send(to: server, now: now)
            }
            if server.nextTag == before, devices.allSatisfy({ $0.state.pendingNames.isEmpty }) { break }
        }
        for index in devices.indices { devices[index].fetch(from: server, now: now) }
    }

    static func expectSame(_ devices: [Device], sourceLocation: SourceLocation = #_sourceLocation) {
        for device in devices.dropFirst() {
            #expect(device.hosts.sorted { $0.host.alias < $1.host.alias } == devices[0].hosts.sorted { $0.host.alias < $1.host.alias },
                    sourceLocation: sourceLocation)
            #expect(device.projects == devices[0].projects, sourceLocation: sourceLocation)
            #expect(device.state.pendingNames.isEmpty, sourceLocation: sourceLocation)
        }
    }

    static let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
    static let box = SyncTests.host("box"), gpu = SyncTests.host("gpu", keys: ["ssh-ed25519 AAAAC3Nz"])

    /// A Mac with hosts and projects (an existing install) and a new one.
    static func existingAndNew() -> (Server, [Device], [Project]) {
        let server = Server()
        let projects = [SyncTests.project("api", on: "box"), SyncTests.project("train", on: "gpu"), SyncTests.project("web", on: "box")]
        var mac = Device(hosts: [box, gpu], projects: projects)
        mac.save(t0)
        var fresh = Device()
        fresh.save(t0)
        var devices = [mac, fresh]
        syncAll(&devices, server, now: t0)
        return (server, devices, projects)
    }

    @Test func aNewDeviceGetsEverything() {
        let (server, devices, projects) = Self.existingAndNew()
        Self.expectSame(devices)
        #expect(devices[1].projects == projects)
        #expect(devices[1].hosts.count == 2)
        #expect(devices[1].hosts.first { $0.host.alias == "gpu" }?.trustedHostKeys == ["ssh-ed25519 AAAAC3Nz"])
        // One record per host and project, plus the order.
        #expect(server.records.count == 6)
    }

    @Test func aNewDeviceWithItsOwnHostsMergesThem() {
        let server = Server()
        var mac = Device(hosts: [Self.box], projects: [SyncTests.project("api", on: "box")])
        mac.save(Self.t0)
        // The other Mac imported the same host (same alias) with an older
        // setup, plus one of its own.
        var stale = Self.box
        stale.host.port = 2200
        var other = Device(hosts: [stale, SyncTests.host("nas")])
        other.save(Self.t0)
        var devices = [mac, other]
        Self.syncAll(&devices, server, now: Self.t0)
        Self.expectSame(devices)
        #expect(devices[0].hosts.count == 2)
        // Both setups were dated "before sync": the first one in iCloud stays.
        #expect(devices[1].hosts.first { $0.host.alias == "box" }?.host.port == nil)
    }

    @Test func theLaterEditWins() {
        let (server, initial, _) = Self.existingAndNew()
        var devices = initial
        var early = devices[0].projects[0]
        early.name = "API (renamed early)"
        devices[0].projects[0] = early
        devices[0].save(Self.t0 + 10)
        var late = devices[1].projects[0]
        late.launchCommand = "codex"
        devices[1].projects[0] = late
        devices[1].save(Self.t0 + 20)
        Self.syncAll(&devices, server, now: Self.t0 + 30)
        Self.expectSame(devices)
        // Whole items, not fields: the later version, as it was made.
        #expect(devices[0].projects[0] == late)
    }

    @Test func anEditAfterADeletionBringsTheProjectBack() {
        let (server, initial, projects) = Self.existingAndNew()
        var devices = initial
        devices[0].projects.removeAll { $0.id == projects[1].id }
        devices[0].save(Self.t0 + 10)
        devices[1].projects[1].name = "train v2"
        devices[1].save(Self.t0 + 20)
        Self.syncAll(&devices, server, now: Self.t0 + 30)
        Self.expectSame(devices)
        #expect(devices[0].projects.contains { $0.name == "train v2" })
    }

    @Test func aDeletionAfterAnEditWins() {
        let (server, initial, projects) = Self.existingAndNew()
        var devices = initial
        devices[1].projects[1].name = "train v2"
        devices[1].save(Self.t0 + 10)
        devices[0].projects.removeAll { $0.id == projects[1].id }
        devices[0].save(Self.t0 + 20)
        Self.syncAll(&devices, server, now: Self.t0 + 30)
        Self.expectSame(devices)
        #expect(!devices[1].projects.contains { $0.id == projects[1].id })
    }

    @Test func aHostStillInUseSomewhereComesBack() {
        let (server, initial, projects) = Self.existingAndNew()
        var devices = initial
        // One Mac drops the gpu host and its project…
        devices[0].projects.removeAll { $0.id == projects[1].id }
        devices[0].hosts.removeAll { $0.host.alias == "gpu" }
        devices[0].save(Self.t0 + 10)
        // …while the other, offline, starts a new project there.
        devices[1].projects.append(SyncTests.project("eval", on: "gpu"))
        devices[1].save(Self.t0 + 20)
        Self.syncAll(&devices, server, now: Self.t0 + 30)
        Self.expectSame(devices)
        #expect(devices[0].hosts.contains { $0.host.alias == "gpu" })
        #expect(devices[0].projects.contains { $0.name == "eval" })
        #expect(!devices[0].projects.contains { $0.id == projects[1].id })
    }

    @Test func removingEverythingRemovesItEverywhere() {
        let (server, initial, _) = Self.existingAndNew()
        var devices = initial
        devices[1].projects = []
        devices[1].hosts = []
        devices[1].save(Self.t0 + 10)
        Self.syncAll(&devices, server, now: Self.t0 + 20)
        Self.expectSame(devices)
        #expect(devices[0].projects.isEmpty && devices[0].hosts.isEmpty)
    }

    @Test func copiesOfTheSameStateMergeTheirEdits() {
        // The user copied state.json to a second Mac before sync existed,
        // and each changed a different project since.
        let server = Server()
        let projects = [SyncTests.project("api"), SyncTests.project("web")]
        var a = Device(hosts: [Self.box], projects: projects)
        var b = Device(hosts: [Self.box], projects: projects)
        a.save(Self.t0)
        b.save(Self.t0)
        a.projects[0].launchCommand = "codex"
        a.save(Self.t0 + 10)
        b.projects[1].launchCommand = "zsh"
        b.save(Self.t0 + 20)
        var devices = [a, b]
        Self.syncAll(&devices, server, now: Self.t0 + 30)
        Self.expectSame(devices)
        #expect(devices[0].projects.map(\.launchCommand) == ["codex", "zsh"])
    }

    @Test func reordersAndAdditionsConverge() {
        let (server, initial, projects) = Self.existingAndNew()
        var devices = initial
        devices[0].projects = [projects[2], projects[0], projects[1]]
        devices[0].save(Self.t0 + 10)
        Self.syncAll(&devices, server, now: Self.t0 + 15)
        #expect(devices[1].projects.map(\.id) == [projects[2].id, projects[0].id, projects[1].id])
        devices[1].projects.append(SyncTests.project("docs"))
        devices[1].save(Self.t0 + 20)
        devices[0].projects.removeAll { $0.id == projects[0].id }
        devices[0].save(Self.t0 + 25)
        Self.syncAll(&devices, server, now: Self.t0 + 30)
        Self.expectSame(devices)
        #expect(devices[0].projects.map(\.name) == ["web", "train", "docs"])
    }

    @Test func fieldsFromANewerBuildSurviveOlderDevices() throws {
        let (server, initial, _) = Self.existingAndNew()
        var devices = initial
        // A newer build adds a field to the box host.
        let name = SyncItem.recordName(hostAlias: "box")
        let record = try #require(server.records[name])
        var envelope = try #require(try JSONSerialization.jsonObject(with: record.envelope) as? [String: Any])
        var item = try #require(envelope["item"] as? [String: Any])
        item["colorTag"] = "teal"
        envelope["item"] = item
        envelope["modifiedAt"] = (Self.t0 + 5).timeIntervalSinceReferenceDate
        server.records[name] = .init(kind: .host, envelope: try JSONSerialization.data(withJSONObject: envelope), tag: server.nextTag)
        server.nextTag += 1

        // This build fetches it, then edits the host.
        Self.syncAll(&devices, server, now: Self.t0 + 6)
        let index = try #require(devices[0].hosts.firstIndex { $0.host.alias == "box" })
        devices[0].hosts[index].host.user = "root"
        devices[0].save(Self.t0 + 10)
        Self.syncAll(&devices, server, now: Self.t0 + 20)
        Self.expectSame(devices)

        let saved = try #require(server.records[name])
        let sent = try #require(try JSONSerialization.jsonObject(with: saved.envelope) as? [String: Any])
        let sentItem = try #require(sent["item"] as? [String: Any])
        #expect(sentItem["colorTag"] as? String == "teal")
        #expect(sentItem["user"] as? String == "root")
    }

    @Test func anotherAccountGetsThisDevicesCopy() {
        let (_, initial, projects) = Self.existingAndNew()
        var devices = initial
        // Signed in to a different iCloud account: an empty database.
        let other = Server()
        devices[0].state.resetServerState()
        devices[0].seen = [:]
        var just = [devices[0]]
        Self.syncAll(&just, other, now: Self.t0 + 10)
        #expect(other.records.count == 6)
        var fresh = Device()
        fresh.save(Self.t0 + 10)
        var both = [just[0], fresh]
        Self.syncAll(&both, other, now: Self.t0 + 20)
        Self.expectSame(both)
        #expect(both[1].projects == projects)
    }
}
