import CloudKit
import Foundation
import Testing
@testable import RelayCore

@Suite("iCloud sync: payloads and merging")
struct SyncTests {
    static let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000.25)

    static func host(_ alias: String, hostname: String? = nil, keys: [String] = []) -> SyncedHost {
        SyncedHost(host: SSHHost(alias: alias, hostname: hostname ?? "\(alias).example.com", user: "me"), trustedHostKeys: keys)
    }

    static func project(_ name: String, on alias: String = "box", id: UUID = UUID()) -> Project {
        Project(
            id: ProjectID(uuid: id), name: name, workspace: WorkspaceRef(provider: .sshTmux, opaqueID: alias),
            pathInput: "~/\(name)", resolvedPath: "/home/me/\(name)", launchCommand: "claude")
    }

    static func json(_ data: Data?) -> [String: Any] {
        data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    }

    // MARK: Payloads

    @Test func hostsTravelFlatWithTheirTrustedKeys() throws {
        let synced = Self.host("box", keys: ["ssh-ed25519 AAAA"])
        let object = Self.json(try SyncPayload.canonical(.host(synced)))
        #expect(object["alias"] as? String == "box")
        #expect(object["hostname"] as? String == "box.example.com")
        #expect(object["trustedHostKeys"] as? [String] == ["ssh-ed25519 AAAA"])
        #expect(object["host"] == nil)
        let back = try SyncPayload.item(kind: .host, payload: try SyncPayload.canonical(.host(synced)))
        #expect(back == .host(synced))
    }

    @Test func envelopesKeepTheExactTimeAndContent() throws {
        let item = SyncItem.project(Self.project("api"))
        let payload = try SyncPayload.canonical(item)
        let envelope = SyncPayload.envelope(payload: payload, extra: nil, modifiedAt: Self.t0)
        let parsed = try SyncPayload.parse(envelope, kind: .project, recordName: item.recordName)
        #expect(parsed.payload == payload)
        #expect(parsed.modifiedAt == Self.t0)
        #expect(parsed.extra == nil)

        let tombstone = SyncPayload.envelope(payload: nil, extra: nil, modifiedAt: Self.t0)
        let deleted = try SyncPayload.parse(tombstone, kind: .project, recordName: item.recordName)
        #expect(deleted.payload == nil)
        #expect(deleted.modifiedAt == Self.t0)
    }

    @Test func fieldsFromNewerBuildsSurviveAnEdit() throws {
        let synced = Self.host("box")
        let name = SyncItem.host(synced).recordName
        // A newer build's version: a field this build doesn't know.
        var item = Self.json(try SyncPayload.canonical(.host(synced)))
        item["colorTag"] = "teal"
        let fromNewer = try JSONSerialization.data(withJSONObject: [
            "v": 2, "modifiedAt": Self.t0.timeIntervalSinceReferenceDate, "deleted": false, "item": item,
        ])
        let parsed = try SyncPayload.parse(fromNewer, kind: .host, recordName: name)
        #expect(Self.json(parsed.extra)["colorTag"] as? String == "teal")
        #expect(Self.json(parsed.payload)["colorTag"] == nil)

        // This build edits the host: the field goes back out with it.
        var edited = synced
        edited.host.hostname = "box.internal"
        let out = SyncPayload.envelope(payload: try SyncPayload.canonical(.host(edited)), extra: parsed.extra, modifiedAt: Self.t0)
        let sentItem = Self.json(out)["item"] as? [String: Any]
        #expect(sentItem?["colorTag"] as? String == "teal")
        #expect(sentItem?["hostname"] as? String == "box.internal")
    }

    @Test func recordsMustHoldWhatTheirNameSays() throws {
        let box = SyncItem.host(Self.host("box"))
        let envelope = SyncPayload.envelope(payload: try SyncPayload.canonical(box), extra: nil, modifiedAt: Self.t0)
        #expect(throws: SyncPayload.Failure.misnamed) {
            try SyncPayload.parse(envelope, kind: .host, recordName: SyncItem.recordName(hostAlias: "other"))
        }
        #expect(throws: SyncPayload.Failure.malformed) {
            try SyncPayload.parse(envelope, kind: .project, recordName: box.recordName)
        }
        #expect(throws: SyncPayload.Failure.malformed) {
            try SyncPayload.parse(Data("nope".utf8), kind: .host, recordName: box.recordName)
        }
    }

    @Test func hostsRelayCantUseAreRejected() throws {
        // A host that would put an option into the generated ssh config.
        var item = Self.json(try SyncPayload.canonical(.host(Self.host("box"))))
        item["hostname"] = "h\n  ProxyCommand evil"
        let envelope = try JSONSerialization.data(withJSONObject: [
            "v": 1, "modifiedAt": Self.t0.timeIntervalSinceReferenceDate, "deleted": false, "item": item,
        ])
        #expect(throws: SyncPayload.Failure.self) {
            try SyncPayload.parse(envelope, kind: .host, recordName: SyncItem.recordName(hostAlias: "box"))
        }
    }

    @Test func hostRecordNamesDontRevealAliases() {
        let name = SyncItem.recordName(hostAlias: "iddos-mac-mini")
        #expect(name.hasPrefix("host-"))
        #expect(!name.contains("mini"))
        #expect(name == SyncItem.recordName(hostAlias: "iddos-mac-mini"))
        #expect(name != SyncItem.recordName(hostAlias: "iddos-mac-mini2"))
        #expect(name.count <= 255 && name.allSatisfy(\.isASCII))
    }

    // MARK: The ledger

    @Test func anExistingInstallsItemsAreDatedOldest() {
        var state = SyncState()
        let items: [SyncItem] = [.host(Self.host("box")), .project(Self.project("api"))]
        let first = state.recordLocal(items, now: Self.t0)
        #expect(first.count == 2)
        #expect(state.entries.values.allSatisfy { $0.modifiedAt == .distantPast && $0.pending })
        #expect(state.recordLocal(items, now: Self.t0).isEmpty)

        var edited = Self.host("box")
        edited.host.port = 2222
        let later = Self.t0 + 10
        #expect(state.recordLocal([.host(edited), items[1]], now: later) == [SyncItem.host(edited).recordName])
        #expect(state.entries[SyncItem.host(edited).recordName]?.modifiedAt == later)
    }

    @Test func removalsBecomeTombstones() {
        var state = SyncState()
        let api = Self.project("api")
        _ = state.recordLocal([.project(api)], now: Self.t0)
        let changed = state.recordLocal([], now: Self.t0 + 5)
        #expect(changed == [SyncItem.project(api).recordName])
        let entry = state.entries[SyncItem.project(api).recordName]
        #expect(entry?.payload == nil)
        #expect(entry?.pending == true)
        #expect(entry?.modifiedAt == Self.t0 + 5)
        // Sent as a deletion.
        let out = state.outgoing(SyncItem.project(api).recordName)
        #expect(Self.json(out?.envelope)["deleted"] as? Bool == true)
    }

    @Test func newerUnsentLocalVersionsWinOlderOnesLose() throws {
        let api = Self.project("api")
        let name = SyncItem.project(api).recordName
        var state = SyncState()
        _ = state.recordLocal([.project(api)], now: Self.t0)
        var local = api
        local.launchCommand = "codex"
        _ = state.recordLocal([.project(local)], now: Self.t0 + 10)

        var remote = api
        remote.launchCommand = "zsh"
        let older = SyncPayload.envelope(payload: try SyncPayload.canonical(.project(remote)), extra: nil, modifiedAt: Self.t0 + 5)
        #expect(state.applyRemote(name: name, kind: .project, envelope: older, serverFields: Data([1])) == .keptLocal)
        #expect(state.entries[name]?.serverFields == Data([1]))
        #expect(state.outgoing(name) != nil)

        let newer = SyncPayload.envelope(payload: try SyncPayload.canonical(.project(remote)), extra: nil, modifiedAt: Self.t0 + 20)
        #expect(state.applyRemote(name: name, kind: .project, envelope: newer, serverFields: Data([2])) == .apply(.upsert(.project(remote))))
        #expect(state.entries[name]?.pending == false)
        #expect(state.outgoing(name) == nil)
        // The device applies it; recording that is not a change.
        #expect(state.recordLocal([.project(remote)], now: Self.t0 + 30).isEmpty)
    }

    @Test func tiesGoToICloud() throws {
        var state = SyncState()
        let api = Self.project("api")
        _ = state.recordLocal([.project(api)], now: Self.t0)
        var theirs = api
        theirs.name = "API"
        let envelope = SyncPayload.envelope(payload: try SyncPayload.canonical(.project(theirs)), extra: nil, modifiedAt: .distantPast)
        #expect(state.applyRemote(name: SyncItem.project(api).recordName, kind: .project, envelope: envelope, serverFields: Data())
                == .apply(.upsert(.project(theirs))))
    }

    @Test func remoteDeletionsRemoveWhatTheDeviceHas() {
        var state = SyncState()
        let api = Self.project("api")
        let name = SyncItem.project(api).recordName
        _ = state.recordLocal([.project(api)], now: Self.t0)
        _ = state.noteSaved(name, envelope: state.outgoing(name)!.envelope, serverFields: Data([1]))
        let tombstone = SyncPayload.envelope(payload: nil, extra: nil, modifiedAt: Self.t0 + 1)
        #expect(state.applyRemote(name: name, kind: .project, envelope: tombstone, serverFields: Data([2])) == .apply(.remove(.project(api))))
        // A tombstone for something never here is nothing to do.
        let unknown = SyncItem.recordName(project: ProjectID())
        #expect(state.applyRemote(name: unknown, kind: .project, envelope: tombstone, serverFields: Data()) == .unchanged)
        #expect(state.applyRemoteDeletion(name: "nothing") == .unchanged)
    }

    @Test func savesClearPendingOnlyForTheVersionSent() {
        var state = SyncState()
        let api = Self.project("api")
        let name = SyncItem.project(api).recordName
        _ = state.recordLocal([.project(api)], now: Self.t0)
        let sent = state.outgoing(name)!.envelope
        // Edited again while the save was in flight.
        var edited = api
        edited.name = "API"
        _ = state.recordLocal([.project(edited)], now: Self.t0 + 1)
        #expect(state.noteSaved(name, envelope: sent, serverFields: Data([1])) == true)
        #expect(state.entries[name]?.serverFields == Data([1]))
        let again = state.outgoing(name)!
        #expect(again.serverFields == Data([1]))
        #expect(state.noteSaved(name, envelope: again.envelope, serverFields: Data([2])) == false)
        #expect(state.pendingNames.isEmpty)
    }

    @Test func projectOrderIgnoresProjectsNotHere() throws {
        var state = SyncState()
        let a = Self.project("a"), b = Self.project("b"), c = Self.project("c")
        let orderName = SyncItem.projectOrderRecordName
        func items(_ projects: [Project]) -> [SyncItem] {
            projects.map(SyncItem.project) + [.projectOrder(SyncedProjectOrder(projects: projects.map(\.id)))]
        }
        _ = state.recordLocal(items([a, b]), now: Self.t0)
        // iCloud's order names c, which hasn't arrived yet.
        let remote = SyncedProjectOrder(projects: [c.id, b.id, a.id])
        let envelope = SyncPayload.envelope(payload: try SyncPayload.canonical(.projectOrder(remote)), extra: nil, modifiedAt: Self.t0 + 1)
        #expect(state.applyRemote(name: orderName, kind: .projectOrder, envelope: envelope, serverFields: Data()) == .apply(.upsert(.projectOrder(remote))))
        // The device shows b, a: the same order, minus c.
        #expect(!state.recordLocal(items([b, a]), now: Self.t0 + 2).contains(orderName))
        #expect(state.projectOrder == [c.id, b.id, a.id])
        // c arrives and takes its place: still not a reorder.
        #expect(!state.recordLocal(items([c, b, a]), now: Self.t0 + 3).contains(orderName))
        // A real reorder is.
        #expect(state.recordLocal(items([a, c, b]), now: Self.t0 + 4).contains(orderName))
        #expect(state.projectOrder == [a.id, c.id, b.id])
    }

    @Test func startingOverResendsEverythingButSentDeletions() {
        var state = SyncState()
        let a = Self.project("a"), b = Self.project("b")
        _ = state.recordLocal([.project(a), .project(b)], now: Self.t0)
        for name in state.pendingNames {
            state.noteSaved(name, envelope: state.outgoing(name)!.envelope, serverFields: Data([1]))
        }
        _ = state.recordLocal([.project(a)], now: Self.t0 + 1)
        let bName = SyncItem.project(b).recordName
        state.noteSaved(bName, envelope: state.outgoing(bName)!.envelope, serverFields: Data([2]))
        state.zoneSaved = true
        state.engineState = Data([9])

        state.resetServerState()
        #expect(state.pendingNames == [SyncItem.project(a).recordName])
        #expect(state.entries[bName] == nil)
        #expect(state.entries.values.allSatisfy { $0.serverFields == nil })
        #expect(!state.zoneSaved && state.engineState == nil)
    }

    @Test func stateSurvivesStateJSON() async throws {
        var state = SyncState()
        _ = state.recordLocal([.project(Self.project("a"))], now: Self.t0)
        _ = state.recordLocal([.project(Self.project("b"))], now: Self.t0 + 0.123)
        let saved = PersistedState(projects: [], hosts: [], sync: state)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("relay-sync-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ProjectStore(fileURL: url)
        try await store.save(saved)
        let loaded = try await store.load()
        #expect(loaded.sync == state)
        // Sub-second times survive (state.json's dates are whole seconds).
        #expect(loaded.sync?.entries.values.contains { $0.modifiedAt == Self.t0 + 0.123 } == true)
    }

    @Test func unreadableSyncStateDoesntCostTheProjects() throws {
        let json = #"{"projects": [], "hosts": [], "sync": {"entries": 5}}"#
        let state = try JSONDecoder().decode(PersistedState.self, from: Data(json.utf8))
        #expect(state.hosts == [])
        #expect(state.sync == nil)
    }

    // MARK: CloudKit records

    @Test func systemFieldsRoundTrip() throws {
        let id = CKRecord.ID(recordName: "project-x", zoneID: CloudSync.zoneID)
        let record = CKRecord(recordType: SyncKind.project.rawValue, recordID: id)
        record.encryptedValues[CloudSync.payloadField] = Data("{}".utf8)
        let fields = CloudSync.systemFields(of: record)
        let restored = try #require(CloudSync.record(systemFields: fields))
        #expect(restored.recordID == id)
        #expect(restored.recordType == "Project")
        // System fields only: the payload isn't in them.
        #expect(restored.encryptedValues[CloudSync.payloadField] == nil)
        #expect(record.encryptedValues[CloudSync.payloadField] as? Data == Data("{}".utf8))
    }
}
