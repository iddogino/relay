import Foundation

/// What the device knows about each synced record: the item as it has it,
/// when that version was made, whether it still has to be sent, and the
/// server's bookkeeping for it. Pure state — `CloudSync` moves it to and
/// from iCloud, `AppModel` keeps it beside the hosts and projects in
/// state.json, so the two are always saved together.
///
/// Conflicts resolve per item, last writer wins: each version carries the
/// time it was made, and a device keeps its own version only while it's
/// unsent and newer. Deletions are versions too (tombstones), so a
/// deletion and an edit made apart resolve the same way.
public struct SyncState: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        public var kind: SyncKind
        /// The item's canonical JSON as this device has it; nil once deleted.
        public var payload: Data?
        /// When this version was made — on this device or the one it came from.
        public var modifiedAt: Date
        /// This version hasn't reached iCloud yet.
        public var pending: Bool
        /// The server record's system fields (opaque; `CloudSync` reads them).
        public var serverFields: Data?
        /// Item keys from iCloud this build doesn't decode, sent back with
        /// its edits (see SyncPayload).
        public var extra: Data?

        private enum CodingKeys: String, CodingKey {
            case kind, payload, modifiedAt, pending, serverFields, extra
        }

        init(kind: SyncKind, payload: Data?, modifiedAt: Date, pending: Bool, serverFields: Data?, extra: Data?) {
            self.kind = kind
            self.payload = payload
            self.modifiedAt = modifiedAt
            self.pending = pending
            self.serverFields = serverFields
            self.extra = extra
        }

        // `modifiedAt` as seconds, whatever the encoder does with dates
        // (state.json's whole-second ISO 8601 would lose the order of
        // edits made within a second).
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            kind = try container.decode(SyncKind.self, forKey: .kind)
            payload = try container.decodeIfPresent(Data.self, forKey: .payload)
            modifiedAt = Date(timeIntervalSinceReferenceDate: try container.decode(Double.self, forKey: .modifiedAt))
            pending = try container.decode(Bool.self, forKey: .pending)
            serverFields = try container.decodeIfPresent(Data.self, forKey: .serverFields)
            extra = try container.decodeIfPresent(Data.self, forKey: .extra)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(kind, forKey: .kind)
            try container.encodeIfPresent(payload, forKey: .payload)
            try container.encode(modifiedAt.timeIntervalSinceReferenceDate, forKey: .modifiedAt)
            try container.encode(pending, forKey: .pending)
            try container.encodeIfPresent(serverFields, forKey: .serverFields)
            try container.encodeIfPresent(extra, forKey: .extra)
        }
    }

    /// By record name.
    public var entries: [String: Entry] = [:]
    /// Whether this device's items have been recorded before. The first
    /// recording (an existing install's hosts and projects) is dated as
    /// old as can be, so wherever iCloud already has the same item, its
    /// copy wins.
    public var seeded = false
    /// Whether Relay's record zone is known to exist in iCloud.
    public var zoneSaved = false
    /// CKSyncEngine's own state (opaque).
    public var engineState: Data?
    /// Where the last catch-up fetch got to in the zone (an archived
    /// CKServerChangeToken; see CloudSync).
    public var catchUpToken: Data?

    public init() {}

    public var pendingNames: [String] {
        entries.filter(\.value.pending).map(\.key).sorted()
    }

    /// The project order from iCloud or this device, whichever is latest
    /// (may name projects not here yet).
    public var projectOrder: [ProjectID]? {
        guard let payload = entries[SyncItem.projectOrderRecordName]?.payload,
              case .projectOrder(let order)? = try? SyncPayload.item(kind: .projectOrder, payload: payload) else { return nil }
        return order.projects
    }

    // MARK: Local changes

    /// Records the device's items as they are now: anything new or
    /// different is a new version made `now`, anything gone is deleted
    /// `now`. Returns the records that now have to be sent.
    ///
    /// `keeping` names records that are here though not among `items`
    /// (hosts this build can't read): they're left as recorded, never
    /// taken for deleted. So is a host that isn't valid: other devices
    /// would refuse it, so it's neither sent nor a deletion of what
    /// iCloud has under its name.
    public mutating func recordLocal(_ items: [SyncItem], keeping: Set<String> = [], now: Date = Date()) -> [String] {
        let madeAt = seeded ? now : .distantPast
        seeded = true
        var kept = keeping
        var current: [String: (kind: SyncKind, payload: Data)] = [:]
        for item in items {
            if case .host(let synced) = item, (try? synced.host.validate()) == nil {
                kept.insert(item.recordName)
                continue
            }
            guard let payload = try? SyncPayload.canonical(item) else {
                kept.insert(item.recordName)
                continue
            }
            current[item.recordName] = (item.kind, payload)
        }
        let liveProjects = Set(items.compactMap { item -> ProjectID? in
            if case .project(let project) = item { return project.id }
            return nil
        })
        var changed: [String] = []
        for (name, item) in current {
            if let entry = entries[name] {
                guard entry.payload != item.payload else { continue }
                if item.kind == .projectOrder,
                   Self.sameOrder(entry.payload, item.payload, among: liveProjects) { continue }
                entries[name]?.payload = item.payload
                entries[name]?.modifiedAt = madeAt
                entries[name]?.pending = true
            } else {
                entries[name] = Entry(
                    kind: item.kind, payload: item.payload, modifiedAt: madeAt,
                    pending: true, serverFields: nil, extra: nil)
            }
            changed.append(name)
        }
        for (name, entry) in entries where entry.payload != nil && current[name] == nil && !kept.contains(name) {
            entries[name]?.payload = nil
            entries[name]?.extra = nil
            entries[name]?.modifiedAt = madeAt
            entries[name]?.pending = true
            changed.append(name)
        }
        return changed.sorted()
    }

    /// The order this device shows is the recorded one when it differs
    /// only in projects that aren't here (deleted, or not arrived yet):
    /// those aren't a reorder.
    private static func sameOrder(_ recorded: Data?, _ local: Data, among live: Set<ProjectID>) -> Bool {
        guard let recorded,
              case .projectOrder(let old)? = try? SyncPayload.item(kind: .projectOrder, payload: recorded),
              case .projectOrder(let new)? = try? SyncPayload.item(kind: .projectOrder, payload: local) else { return false }
        return old.projects.filter(live.contains) == new.projects
    }

    // MARK: Sending

    public struct Outgoing: Sendable, Equatable {
        public var kind: SyncKind
        public var envelope: Data
        public var serverFields: Data?
    }

    /// What to send for a record, or nil when it has nothing to send.
    public func outgoing(_ name: String) -> Outgoing? {
        guard let entry = entries[name], entry.pending else { return nil }
        return Outgoing(
            kind: entry.kind,
            envelope: SyncPayload.envelope(payload: entry.payload, extra: entry.extra, modifiedAt: entry.modifiedAt),
            serverFields: entry.serverFields)
    }

    /// iCloud saved `envelope` for the record. Returns whether the record
    /// still has to be sent (it changed again since).
    @discardableResult
    public mutating func noteSaved(_ name: String, envelope: Data, serverFields: Data) -> Bool {
        guard var entry = entries[name] else { return false }
        entry.serverFields = serverFields
        // Compared as sent, not by reading it back: a record this build
        // sent but wouldn't accept (parse validates) must still count as
        // saved, or it would be sent again forever.
        let current = SyncPayload.envelope(payload: entry.payload, extra: entry.extra, modifiedAt: entry.modifiedAt)
        if envelope == current {
            entry.pending = false
        } else if let sent = try? SyncPayload.parse(envelope, kind: entry.kind, recordName: name),
                  sent.payload == entry.payload, sent.modifiedAt == entry.modifiedAt {
            entry.pending = false
        }
        entries[name] = entry
        return entry.pending
    }

    /// The server no longer has the record (or its zone): the next send
    /// makes it anew.
    public mutating func forgetServerRecord(_ name: String) {
        guard entries[name] != nil else { return }
        entries[name]?.serverFields = nil
        entries[name]?.pending = true
    }

    // MARK: Changes from iCloud

    public enum Change: Sendable, Equatable {
        /// Add the item, or replace this device's copy.
        case upsert(SyncItem)
        /// Delete this device's copy (the item as this device had it).
        case remove(SyncItem)

        /// The order to apply a batch in: hosts arrive before the projects
        /// on them, and leave after — a device keeps a host its projects
        /// still use, which must be judged once the batch's project
        /// removals are in.
        public static func inApplyOrder(_ changes: [Change]) -> [Change] {
            func rank(_ change: Change) -> Int {
                switch change {
                case .upsert(.host): return 0
                case .upsert(.project), .remove(.project): return 1
                case .upsert(.projectOrder), .remove(.projectOrder): return 2
                case .remove(.host): return 3
                }
            }
            return changes.enumerated()
                .sorted { a, b in
                    rank(a.element) != rank(b.element) ? rank(a.element) < rank(b.element) : a.offset < b.offset
                }
                .map(\.element)
        }
    }

    public enum Outcome: Sendable, Equatable {
        /// The device must apply this.
        case apply(Change)
        /// Nothing to do: the device already has this version's content.
        case unchanged
        /// The device's own unsent version is newer: it must be sent.
        case keptLocal
        /// The record can't be used (malformed, or not something Relay
        /// can connect with); the device's copy stands.
        case ignored(SyncPayload.Failure)
    }

    /// A version of a record from iCloud: fetched, or the server's copy
    /// when a save conflicted.
    public mutating func applyRemote(name: String, kind: SyncKind, envelope: Data, serverFields: Data) -> Outcome {
        let parsed: SyncPayload.Parsed
        do {
            parsed = try SyncPayload.parse(envelope, kind: kind, recordName: name)
        } catch let failure as SyncPayload.Failure {
            entries[name]?.serverFields = serverFields
            return .ignored(failure)
        } catch {
            return .ignored(.malformed)
        }
        let previous = entries[name]
        if let previous, previous.pending, previous.modifiedAt > parsed.modifiedAt {
            entries[name]?.serverFields = serverFields
            return .keptLocal
        }
        entries[name] = Entry(
            kind: kind, payload: parsed.payload, modifiedAt: parsed.modifiedAt,
            pending: false, serverFields: serverFields, extra: parsed.extra)
        return Self.change(from: previous?.payload, to: parsed.payload, kind: kind)
    }

    /// A record deleted outright in iCloud (Relay itself sends deletions
    /// as tombstones; this is the server's own housekeeping).
    public mutating func applyRemoteDeletion(name: String) -> Outcome {
        guard let previous = entries[name] else { return .unchanged }
        entries[name] = Entry(
            kind: previous.kind, payload: nil, modifiedAt: previous.modifiedAt,
            pending: false, serverFields: nil, extra: nil)
        return Self.change(from: previous.payload, to: nil, kind: previous.kind)
    }

    private static func change(from old: Data?, to new: Data?, kind: SyncKind) -> Outcome {
        if old == new { return .unchanged }
        if let new, let item = try? SyncPayload.item(kind: kind, payload: new) {
            return .apply(.upsert(item))
        }
        if let old, let item = try? SyncPayload.item(kind: kind, payload: old) {
            return .apply(.remove(item))
        }
        return .unchanged
    }

    // MARK: Starting over

    /// The server's copies are gone or belong to someone else (another
    /// iCloud account, a reset zone): every item this device has is sent
    /// anew, keeping when each version was made. Deletions already sent
    /// are dropped — there's nothing left for them to delete.
    public mutating func resetServerState() {
        for (name, entry) in entries {
            if entry.payload == nil && !entry.pending {
                entries[name] = nil
            } else {
                entries[name]?.serverFields = nil
                entries[name]?.pending = true
            }
        }
        zoneSaved = false
        engineState = nil
        catchUpToken = nil
    }
}
