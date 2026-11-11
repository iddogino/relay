// Debug builds only: none of this is compiled into a release.
#if DEBUG
#if os(macOS)
import AppKit
#endif
import CloudKit
import RelayCore
import RelaySSH
import SwiftUI

/// Dev builds only: drives and reads iCloud sync from
/// `<hook dir>/sync-request.json` on a distributed notification, writing
/// `sync-result.json`. The request is consumed, so several dev instances
/// (each with its own data folder, as two "devices") can share the
/// notification: only the one given a request answers.
@MainActor
enum SyncDevHook {
    static let notification = "com.iddogino.Relay.dev.sync"
    private static var installed = false

    static func installIfDevBuild(model: AppModel) {
        guard AppVariant.isDevBuild, !installed else { return }
        installed = true
        DevNotifications.observe(notification) { [weak model] in
            guard let model else { return }
            Task { await run(model) }
        }
    }

    private struct HookError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    private static func run(_ model: AppModel) async {
        let dir = AppVariant.devHookDirectory
        let requestURL = dir.appendingPathComponent("sync-request.json")
        guard let data = try? Data(contentsOf: requestURL) else { return }
        try? FileManager.default.removeItem(at: requestURL)
        let resultURL = dir.appendingPathComponent("sync-result.json")
        var result: [String: Any] = [:]
        defer {
            if let json = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
                try? json.write(to: resultURL)
            }
        }
        guard let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let op = request["op"] as? String else {
            result["error"] = "bad request"
            return
        }
        result["op"] = op
        do {
            switch op {
            case "status":
                break

            case "setEnabled":
                model.syncEnabled = request["enabled"] as? Bool ?? true

            case "syncNow":
                await model.cloudSync.syncNow()

            case "saveHost":
                var host = SSHHost(
                    alias: try string(request, "alias"), hostname: try string(request, "hostname"),
                    port: request["port"] as? Int, user: request["user"] as? String)
                if request["auth"] as? String == "password" { host.auth = .password }
                try host.validate()
                await model.saveHost(host, password: request["password"] as? String)

            case "removeHost":
                let alias = try string(request, "alias")
                guard let host = model.hosts.first(where: { $0.alias == alias }) else { throw HookError("no host \(alias)") }
                await model.removeHost(host)

            case "trustKey":
                let alias = try string(request, "alias")
                guard let host = model.hosts.first(where: { $0.alias == alias }) else { throw HookError("no host \(alias)") }
                try model.trustHostKey(try string(request, "key"), for: host)

            case "addProject":
                // Not validated on the host: test projects point nowhere.
                let path = try string(request, "path")
                model.addProject(Project(
                    name: try string(request, "name"),
                    workspace: WorkspaceRef(provider: .sshTmux, opaqueID: try string(request, "alias")),
                    pathInput: path, resolvedPath: path, launchCommand: request["launchCommand"] as? String))

            case "updateProject":
                var project = try projectNamed(model, try string(request, "name"))
                if let name = request["newName"] as? String { project.name = name }
                if let command = request["launchCommand"] as? String { project.launchCommand = command }
                model.updateProject(project)

            case "removeProject":
                model.removeProject(try projectNamed(model, try string(request, "name")))

            case "moveProject":
                let project = try projectNamed(model, try string(request, "name"))
                guard let from = model.projects.firstIndex(of: project), let to = request["to"] as? Int else {
                    throw HookError("no destination")
                }
                model.moveProjects(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)

            #if os(macOS)
            case "render":
                // Settings ▸ iCloud as drawn, for each named availability
                // ("current" leaves it as it is), into window-shots/.
                let shots = dir.appendingPathComponent("window-shots", isDirectory: true)
                try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
                var written: [String] = []
                for state in (request["states"] as? [String]) ?? ["current"] {
                    let name = "icloud-\(state).png"
                    // Once the pane has appeared (it checks the account then).
                    try await render(SyncSettingsView(model: model), to: shots.appendingPathComponent(name)) {
                        switch state {
                        case "noAccount": model.cloudSync.preview(.noAccount)
                        case "notInThisBuild": model.cloudSync.preview(.notInThisBuild)
                        case "restricted": model.cloudSync.preview(.restricted)
                        case "temporarilyUnavailable": model.cloudSync.preview(.temporarilyUnavailable)
                        case "unknown": model.cloudSync.preview(.unknown("The request timed out."))
                        default: break
                        }
                    }
                    written.append(name)
                }
                await model.cloudSync.refreshAvailability()
                result["shots"] = written
            #endif

            case "deleteCloudData":
                // Test cleanup: deletes Relay's zone (all synced records) in
                // this build's environment — Development, for dev builds.
                guard let container = AppVariant.cloudKitContainer else { throw HookError("no iCloud in this build") }
                try await CKContainer(identifier: container).privateCloudDatabase.deleteRecordZone(withID: CloudSync.zoneID)
                result["deleted"] = true

            case "forgetSecrets":
                // Test cleanup: these passwords, and this variant's GitHub
                // sign-in, gone from every keychain location.
                for alias in (request["aliases"] as? [String]) ?? [] {
                    SSHPasswordStore.secrets.deleteEverywhere(account: alias)
                }
                if request["github"] as? Bool == true {
                    GitHubTokenStore.secrets.deleteEverywhere(account: GitHubTokenStore.account)
                }
                result["left"] = ((request["aliases"] as? [String]) ?? []).reduce(into: [String: [String: String]]()) {
                    $0[$1] = SSHPasswordStore.secrets.locations(account: $1)
                }

            case "githubToken":
                if request["signOut"] as? Bool == true {
                    model.signOutGitHub()
                } else {
                    GitHubTokenStore.save(try string(request, "token"))
                }

            default:
                throw HookError("unknown op \(op)")
            }
        } catch {
            result["error"] = error.localizedDescription
        }
        describe(model, into: &result)
    }

    private static func describe(_ model: AppModel, into result: inout [String: Any]) {
        let sync = model.cloudSync
        result["syncEnabled"] = model.syncEnabled
        result["availability"] = "\(sync.availability)"
        result["running"] = sync.isRunning
        result["syncing"] = sync.isSyncing
        result["lastSyncedAt"] = sync.lastSyncedAt.map { ISO8601DateFormatter().string(from: $0) } ?? ""
        result["lastError"] = sync.lastError ?? ""
        result["pending"] = sync.state.pendingNames
        result["enginePending"] = sync.enginePendingCount ?? -1
        result["zoneSaved"] = sync.state.zoneSaved
        result["hasEngineState"] = sync.state.engineState != nil
        result["records"] = sync.state.entries.sorted { $0.key < $1.key }.map { name, entry -> [String: Any] in
            [
                "name": name, "kind": entry.kind.rawValue, "deleted": entry.payload == nil,
                "pending": entry.pending, "onServer": entry.serverFields != nil,
                "modifiedAt": entry.modifiedAt.timeIntervalSinceReferenceDate, "extra": entry.extra != nil,
            ]
        }
        result["hosts"] = model.hosts.map { host -> [String: Any] in
            [
                "alias": host.alias, "hostname": host.hostname, "port": host.port ?? 0, "user": host.user ?? "",
                "auth": "\(host.auth)", "problem": model.connectionProblem(host) ?? "",
                "passwordIn": SSHPasswordStore.secrets.locations(account: host.alias),
            ]
        }
        result["projects"] = model.projects.map { project -> [String: Any] in
            [
                "id": project.id.uuid.uuidString, "name": project.name, "alias": project.workspace.opaqueID,
                "path": project.resolvedPath, "launchCommand": project.launchCommand ?? "",
            ]
        }
        result["knownHosts"] = (try? String(contentsOf: AppVariant.knownHostsFile, encoding: .utf8)) ?? ""
        result["github"] = "\(model.gitHub)"
        result["githubTokenIn"] = GitHubTokenStore.secrets.locations(account: GitHubTokenStore.account)
        result["dataDirectory"] = AppVariant.dataDirectory.path
    }

    #if os(macOS)
    /// Draws `view` in an invisible window, as the Settings window would.
    private static func render(_ view: some View, to url: URL, onAppear: () -> Void = {}) async throws {
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 400), styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .windowBackgroundColor
        window.alphaValue = 0
        window.contentView = hosting
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(1200))
        onAppear()
        try await Task.sleep(for: .milliseconds(300))
        window.setContentSize(hosting.fittingSize)
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        let frame = window.contentView?.superview ?? hosting
        guard let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { throw HookError("no bitmap") }
        frame.cacheDisplay(in: frame.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])?.write(to: url)
    }
    #endif

    private static func string(_ request: [String: Any], _ key: String) throws -> String {
        guard let value = request[key] as? String, !value.isEmpty else { throw HookError("missing \(key)") }
        return value
    }

    private static func projectNamed(_ model: AppModel, _ name: String) throws -> Project {
        guard let project = model.projects.first(where: { $0.name == name }) else { throw HookError("no project \(name)") }
        return project
    }
}
#endif
