import CloudKit
import Foundation
import Observation
import os

/// Syncs the hosts and projects through the user's private iCloud
/// database: one record per item in Relay's own zone, its contents
/// end-to-end encrypted. CKSyncEngine schedules the work; `SyncState`
/// decides what to send and how to merge what comes back.
///
/// The owner (AppModel) records its items on every save
/// (`recordLocal`), applies what arrives (`onRemoteChanges`) and saves
/// `state` with its own state (`onStateChange`).
@MainActor
@Observable
public final class CloudSync {
    /// Whether this device can sync, as far as iCloud is concerned.
    public enum Availability: Equatable, Sendable {
        case checking
        case available
        /// This build isn't signed for iCloud.
        case notInThisBuild
        case noAccount
        case restricted
        case temporarilyUnavailable
        case unknown(String)
    }

    public private(set) var availability: Availability
    /// The engine is running (sync is on).
    public private(set) var isRunning = false
    public private(set) var isSyncing = false
    public private(set) var lastSyncedAt: Date?
    /// The last problem syncing, cleared by the next good sync.
    public private(set) var lastError: String?
    /// Versions not in iCloud yet.
    public private(set) var pendingCount = 0

    /// Saved by the owner, beside the items it describes.
    @ObservationIgnored public private(set) var state = SyncState()
    /// Applies changes from iCloud to the hosts and projects, then saves.
    @ObservationIgnored public var onRemoteChanges: ([SyncState.Change]) -> Void = { _ in }
    /// `state` changed on its own: save it.
    @ObservationIgnored public var onStateChange: () -> Void = {}
    /// iCloud's copy of Relay's data was deleted (in Settings ▸ Apple
    /// Account, or by an encryption reset). Sync has stopped; this
    /// device's copy stays, and is sent anew only when sync is turned on
    /// again.
    @ObservationIgnored public var onCloudDataDeleted: () -> Void = {}

    @ObservationIgnored private let containerIdentifier: String?
    @ObservationIgnored private var engine: CKSyncEngine?
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var operations = 0
    @ObservationIgnored private var lastFetch: Date?
    @ObservationIgnored private var catchingUp = false
    /// Counts starts-over (`resetServerState`): a catch-up begun before
    /// one has nothing more to apply.
    @ObservationIgnored private var resets = 0
    @ObservationIgnored private var sendTask: Task<Void, Never>?
    @ObservationIgnored private var accountObserver: NSObjectProtocol?

    /// Relay's zone in the private database: everything it syncs.
    public nonisolated static let zoneID = CKRecordZone.ID(zoneName: "Relay", ownerName: CKCurrentUserDefaultName)
    /// The one field of every record: the encrypted envelope.
    nonisolated static let payloadField = "payload"
    nonisolated static let logger = Logger(subsystem: "com.iddogino.Relay", category: "sync")

    /// `containerIdentifier` is nil in builds without iCloud.
    public init(containerIdentifier: String?) {
        self.containerIdentifier = containerIdentifier
        availability = containerIdentifier == nil ? .notInThisBuild : .checking
        guard containerIdentifier != nil else { return }
        accountObserver = NotificationCenter.default.addObserver(
            forName: .CKAccountChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.refreshAvailability() }
            }
        }
    }

    /// Installs the saved state. Nothing is recorded, sent or applied
    /// before this (the owner's items aren't loaded yet).
    public func restore(_ saved: SyncState?) {
        state = saved ?? SyncState()
        loaded = true
        pendingCount = state.pendingNames.count
    }

    /// Records the owner's items as they are now (see
    /// `SyncState.recordLocal`); changes go out with the next sync. The
    /// owner saves `state` right after.
    public func recordLocal(_ items: [SyncItem]) {
        guard loaded else { return }
        let changed = state.recordLocal(items)
        enqueue(changed)
        pendingCount = state.pendingNames.count
        if !changed.isEmpty { sendSoon() }
    }

    /// Changes the engine is holding to send (for the dev hooks).
    public var enginePendingCount: Int? {
        engine?.state.pendingRecordZoneChanges.count
    }

    /// Sends shortly after the last of a burst of changes. The engine
    /// would send them anyway, but when the system next lets it — which
    /// can be minutes — and the user's other devices should update now.
    ///
    /// Detached: a change can come from inside one of the engine's
    /// callbacks (one applied from iCloud, saved, makes the project order
    /// change), and a task started there would carry the callback along.
    /// CloudKit stops the app when that task sends.
    private func sendSoon() {
        guard let engine else { return }
        sendTask?.cancel()
        sendTask = Task.detached {
            try? await Task.sleep(for: .seconds(1.5))
            await self.send(through: engine)
        }
    }

    private func send(through engine: CKSyncEngine) async {
        guard !Task.isCancelled, engine === self.engine else { return }
        do {
            try await engine.sendChanges()
        } catch is CancellationError {
            // Stopped.
        } catch {
            Self.logger.error("send failed: \(error, privacy: .public)")
        }
    }

    // MARK: Running

    /// Starts syncing (a no-op without iCloud in this build). Safe at any
    /// time: without an account the engine waits for one.
    public func start() {
        guard loaded, engine == nil, let containerIdentifier else { return }
        let container = CKContainer(identifier: containerIdentifier)
        let saved = state.engineState.flatMap {
            try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0)
        }
        var configuration = CKSyncEngine.Configuration(
            database: container.privateCloudDatabase, stateSerialization: saved, delegate: self)
        configuration.automaticallySync = true
        let engine = CKSyncEngine(configuration)
        self.engine = engine
        isRunning = true
        if !state.zoneSaved {
            engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
        }
        enqueue(state.pendingNames)
        if !state.pendingNames.isEmpty { sendSoon() }
        Task {
            await refreshAvailability()
            await catchUp()
        }
        Self.logger.info("sync started (\(self.state.entries.count, privacy: .public) records, \(self.pendingCount, privacy: .public) pending)")
    }

    /// Stops syncing. What's recorded meanwhile goes out once it starts
    /// again.
    public func stop() {
        guard let engine else { return }
        self.engine = nil
        sendTask?.cancel()
        isRunning = false
        operations = 0
        isSyncing = false
        // Detached, as in sendSoon: this can run inside a callback
        // (iCloud's copy found deleted).
        Task.detached { await engine.cancelOperations() }
        Self.logger.info("sync stopped")
    }

    /// Fetches and sends now, rather than when the engine gets to it.
    public func syncNow() async {
        guard let engine else { return }
        do {
            lastFetch = Date()
            await catchUp()
            // Stopped meanwhile (iCloud's copy was found deleted).
            guard engine === self.engine else { return }
            try await engine.fetchChanges()
            try await engine.sendChanges()
            lastError = nil
        } catch {
            lastError = Self.describe(error)
        }
    }

    /// Catches up when the app comes forward. At most once a minute.
    public func fetchIfStale() {
        guard engine != nil, Date().timeIntervalSince(lastFetch ?? .distantPast) > 60 else { return }
        lastFetch = Date()
        Task { await catchUp() }
    }

    /// Fetches the zone's changes since the last catch-up, past the
    /// engine: it fetches only when a push tells it to, so a change it
    /// wasn't told about — made while this device was off or Relay quit,
    /// or by another copy of Relay on this device (CloudKit doesn't push to
    /// the device a change came from) — would otherwise wait for the next
    /// push. What the engine fetches again later merges as unchanged.
    private func catchUp() async {
        guard engine != nil, let containerIdentifier, state.zoneSaved, !catchingUp else { return }
        catchingUp = true
        defer { catchingUp = false }
        let database = CKContainer(identifier: containerIdentifier).privateCloudDatabase
        var token = state.catchUpToken.flatMap {
            try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: $0)
        }
        let resetsBefore = resets
        var moreComing = true
        while moreComing {
            let changes: (
                modificationResultsByID: [CKRecord.ID: Result<CKDatabase.RecordZoneChange.Modification, Error>],
                deletions: [CKDatabase.RecordZoneChange.Deletion], changeToken: CKServerChangeToken, moreComing: Bool)
            do {
                changes = try await database.recordZoneChanges(inZoneWith: Self.zoneID, since: token)
            } catch let error as CKError where error.code == .changeTokenExpired && token != nil {
                token = nil
                continue
            } catch let error as CKError where error.code == .zoneNotFound {
                // Gone since it was made: deleted (with the user's other
                // iCloud data for Relay, or by an encryption reset), as the
                // engine hears only by push. Not made yet: nothing to do.
                if state.zoneSaved { cloudDataDeleted(.deleted) }
                return
            } catch {
                Self.logger.error("catch-up failed: \(error, privacy: .public)")
                return
            }
            // Stopped or started over meanwhile: nothing more to apply.
            guard engine != nil, resets == resetsBefore else { return }
            let records = changes.modificationResultsByID.values.compactMap { try? $0.get().record }
            applyFetched(records: records, deletions: changes.deletions.map(\.recordID), via: "catch-up")
            token = changes.changeToken
            state.catchUpToken = try? NSKeyedArchiver.archivedData(
                withRootObject: changes.changeToken, requiringSecureCoding: true)
            moreComing = changes.moreComing
        }
        onStateChange()
    }

    /// Shows `availability` until the next refresh (dev hooks: drawing
    /// states that can't be produced on demand, like no iCloud account).
    public func preview(_ availability: Availability) {
        self.availability = availability
    }

    public func refreshAvailability() async {
        guard let containerIdentifier else {
            availability = .notInThisBuild
            return
        }
        do {
            switch try await CKContainer(identifier: containerIdentifier).accountStatus() {
            case .available: availability = .available
            case .noAccount: availability = .noAccount
            case .restricted: availability = .restricted
            case .temporarilyUnavailable: availability = .temporarilyUnavailable
            case .couldNotDetermine: availability = .unknown("iCloud didn\u{2019}t say whether you\u{2019}re signed in.")
            @unknown default: availability = .unknown("iCloud reported an unknown account status.")
            }
        } catch {
            availability = .unknown(Self.describe(error))
        }
    }

    private func resetServerState() {
        state.resetServerState()
        resets += 1
    }

    private func enqueue(_ names: [String]) {
        guard let engine, !names.isEmpty else { return }
        engine.state.add(pendingRecordZoneChanges: names.map {
            .saveRecord(CKRecord.ID(recordName: $0, zoneID: Self.zoneID))
        })
    }

    /// Takes records iCloud's version settled (nothing of this device's
    /// left to send) off the engine's list.
    private func dropSettled(_ names: [String]) {
        guard let engine else { return }
        let settled = names.filter { state.entries[$0]?.pending != true }
        guard !settled.isEmpty else { return }
        engine.state.remove(pendingRecordZoneChanges: settled.map {
            .saveRecord(CKRecord.ID(recordName: $0, zoneID: Self.zoneID))
        })
    }

    // MARK: Engine events

    private func handle(_ event: CKSyncEngine.Event, from syncEngine: CKSyncEngine) {
        guard syncEngine === engine else { return }
        switch event {
        case .stateUpdate(let update):
            state.engineState = try? JSONEncoder().encode(update.stateSerialization)
            onStateChange()

        case .accountChange(let change):
            switch change.changeType {
            case .signIn, .switchAccounts:
                // A fresh start in this account: everything here goes up,
                // merging with whatever the account already has.
                resetServerState()
                syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
                enqueue(state.pendingNames)
            case .signOut:
                resetServerState()
            @unknown default:
                break
            }
            pendingCount = state.pendingNames.count
            onStateChange()
            Task { await refreshAvailability() }

        case .fetchedDatabaseChanges(let changes):
            // Only a zone this device knows to exist: a first fetch (a new
            // device, or sync turned back on) also reports deletions from
            // before, which the zone it's about to make replaces.
            if state.zoneSaved, let deletion = changes.deletions.first(where: { $0.zoneID == Self.zoneID }) {
                cloudDataDeleted(deletion.reason)
            }

        case .fetchedRecordZoneChanges(let changes):
            applyFetched(
                records: changes.modifications.map(\.record), deletions: changes.deletions.map(\.recordID),
                via: "engine")

        case .sentDatabaseChanges(let sent):
            if sent.savedZones.contains(where: { $0.zoneID == Self.zoneID }) {
                state.zoneSaved = true
            }
            for failure in sent.failedZoneSaves where failure.zone.zoneID == Self.zoneID {
                lastError = Self.describe(failure.error)
            }
            onStateChange()

        case .sentRecordZoneChanges(let sent):
            applySent(sent, engine: syncEngine)

        case .willFetchChanges, .willSendChanges:
            operations += 1
            isSyncing = true

        case .didFetchChanges, .didSendChanges:
            operations = max(0, operations - 1)
            isSyncing = operations > 0
            if !isSyncing {
                lastSyncedAt = Date()
            }

        default:
            break
        }
    }

    private func applyFetched(records: [CKRecord], deletions: [CKRecord.ID], via source: String) {
        var applied: [SyncState.Change] = []
        var resend: [String] = []
        for record in records {
            guard record.recordID.zoneID == Self.zoneID, let kind = SyncKind(rawValue: record.recordType),
                  let envelope = record.encryptedValues[Self.payloadField] as? Data else { continue }
            let name = record.recordID.recordName
            switch state.applyRemote(name: name, kind: kind, envelope: envelope, serverFields: Self.systemFields(of: record)) {
            case .apply(let change): applied.append(change)
            case .keptLocal: resend.append(name)
            case .unchanged: break
            case .ignored(let failure):
                Self.logger.error("ignored record \(name, privacy: .public): \(String(describing: failure), privacy: .public)")
            }
        }
        for id in deletions where id.zoneID == Self.zoneID {
            if case .apply(let change) = state.applyRemoteDeletion(name: id.recordName) {
                applied.append(change)
            }
        }
        dropSettled(records.map(\.recordID.recordName))
        enqueue(resend)
        pendingCount = state.pendingNames.count
        lastError = nil
        Self.logger.info("fetched (\(source, privacy: .public)) \(records.count, privacy: .public) changed, \(deletions.count, privacy: .public) deleted: \(applied.count, privacy: .public) applied, \(resend.count, privacy: .public) kept")
        if applied.isEmpty {
            onStateChange()
        } else {
            onRemoteChanges(applied)
        }
    }

    private func applySent(_ sent: CKSyncEngine.Event.SentRecordZoneChanges, engine syncEngine: CKSyncEngine) {
        var applied: [SyncState.Change] = []
        var resend: [String] = []
        for record in sent.savedRecords where record.recordID.zoneID == Self.zoneID {
            guard let envelope = record.encryptedValues[Self.payloadField] as? Data else { continue }
            let name = record.recordID.recordName
            if state.noteSaved(name, envelope: envelope, serverFields: Self.systemFields(of: record)) {
                resend.append(name)
            }
        }
        for failure in sent.failedRecordSaves where failure.record.recordID.zoneID == Self.zoneID {
            let name = failure.record.recordID.recordName
            switch failure.error.code {
            case .serverRecordChanged:
                // Someone else's version landed first: merge with it.
                guard let server = failure.error.serverRecord, let kind = SyncKind(rawValue: server.recordType),
                      let envelope = server.encryptedValues[Self.payloadField] as? Data else {
                    state.forgetServerRecord(name)
                    resend.append(name)
                    continue
                }
                switch state.applyRemote(name: name, kind: kind, envelope: envelope, serverFields: Self.systemFields(of: server)) {
                case .apply(let change):
                    applied.append(change)
                    dropSettled([name])
                case .keptLocal: resend.append(name)
                case .unchanged: dropSettled([name])
                case .ignored:
                    // The server's copy is unusable: replace it.
                    if state.entries[name]?.pending == true { resend.append(name) }
                }
            case .zoneNotFound:
                state.zoneSaved = false
                syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
                state.forgetServerRecord(name)
                resend.append(name)
            case .unknownItem:
                state.forgetServerRecord(name)
                resend.append(name)
            case .networkFailure, .networkUnavailable, .zoneBusy, .serviceUnavailable, .requestRateLimited,
                 .notAuthenticated, .accountTemporarilyUnavailable, .operationCancelled:
                resend.append(name)
            case .quotaExceeded:
                // Stays pending; tried again on the next change or launch.
                lastError = "Your iCloud storage is full, so Relay can\u{2019}t sync."
            default:
                lastError = Self.describe(failure.error)
                Self.logger.error("couldn't save \(name, privacy: .public): \(failure.error, privacy: .public)")
            }
        }
        enqueue(resend)
        pendingCount = state.pendingNames.count
        if sent.failedRecordSaves.isEmpty, !sent.savedRecords.isEmpty {
            lastError = nil
        }
        if applied.isEmpty {
            onStateChange()
        } else {
            onRemoteChanges(applied)
        }
    }

    private func cloudDataDeleted(_ reason: CKDatabase.DatabaseChange.Deletion.Reason) {
        // CloudKit asks that deleted data not be sent back on its own.
        // This device's copy is the user's own setup, so it stays; sync
        // stops until the user turns it on again.
        resetServerState()
        pendingCount = state.pendingNames.count
        switch reason {
        case .encryptedDataReset:
            lastError = "Your iCloud encrypted data was reset, which removed Relay\u{2019}s synced data. Turn sync on to upload this Mac\u{2019}s hosts and projects again."
        default:
            lastError = "Relay\u{2019}s data was deleted from iCloud. Turn sync on to upload this Mac\u{2019}s hosts and projects again."
        }
        Self.logger.info("zone deleted: \(String(describing: reason), privacy: .public)")
        stop()
        onStateChange()
        onCloudDataDeleted()
    }

    // MARK: Records

    private func record(for id: CKRecord.ID) -> CKRecord? {
        guard id.zoneID == Self.zoneID, let outgoing = state.outgoing(id.recordName) else { return nil }
        let known = outgoing.serverFields.flatMap(Self.record(systemFields:)).flatMap { $0.recordID == id ? $0 : nil }
        let record = known ?? CKRecord(recordType: outgoing.kind.rawValue, recordID: id)
        record.encryptedValues[Self.payloadField] = outgoing.envelope
        return record
    }

    private func nextBatch(_ context: CKSyncEngine.SendChangesContext, from syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        guard syncEngine === engine else { return nil }
        let scope = context.options.scope
        let changes = syncEngine.state.pendingRecordZoneChanges.filter { scope.contains($0) }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: changes) { id in
            await self.record(for: id)
        }
    }

    nonisolated static func systemFields(of record: CKRecord) -> Data {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archiver)
        archiver.finishEncoding()
        return archiver.encodedData
    }

    nonisolated static func record(systemFields: Data) -> CKRecord? {
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: systemFields) else { return nil }
        unarchiver.requiresSecureCoding = true
        defer { unarchiver.finishDecoding() }
        return CKRecord(coder: unarchiver)
    }

    nonisolated static func describe(_ error: Error) -> String {
        if let error = error as? CKError {
            switch error.code {
            case .notAuthenticated: return "You\u{2019}re not signed in to iCloud."
            case .networkUnavailable, .networkFailure: return "iCloud can\u{2019}t be reached right now."
            case .quotaExceeded: return "Your iCloud storage is full, so Relay can\u{2019}t sync."
            default: break
            }
        }
        return error.localizedDescription
    }
}

extension CloudSync: CKSyncEngineDelegate {
    public nonisolated func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        await handle(event, from: syncEngine)
    }

    public nonisolated func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        await nextBatch(context, from: syncEngine)
    }
}
