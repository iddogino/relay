import AppKit
import CryptoKit
import SwiftUI
import RelayCore
import RelaySSH

/// Dev builds only: runs the Relay-key flows the host editor runs — set up
/// a key, test, list and remove keys on a host — plus session creation,
/// upload and preview on a host, from `<data dir>/keys.json` on a
/// distributed notification, writing `keys-result.json`. Lets the whole
/// path (Keychain, Secure Enclave, built-in client) be checked live without
/// taking over the keyboard.
@MainActor
enum HostKeyDevHook {
    static let notification = Notification.Name("com.iddogino.Relay.dev.keys")
    private static var observer: NSObjectProtocol?

    static func installIfDevBuild(model: AppModel) {
        guard AppVariant.bundleIdentifier.hasSuffix(".dev"), observer == nil else { return }
        observer = DistributedNotificationCenter.default().addObserver(
            forName: notification, object: nil, queue: .main
        ) { [weak model] _ in
            MainActor.assumeIsolated {
                guard let model else { return }
                Task { await run(model) }
            }
        }
    }

    private static func run(_ model: AppModel) async {
        let dir = AppVariant.devHookDirectory
        let resultURL = dir.appendingPathComponent("keys-result.json")
        try? FileManager.default.removeItem(at: resultURL)
        var result: [String: Any] = [:]
        defer {
            if let json = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
                try? json.write(to: resultURL)
            }
        }
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("keys.json")),
              let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let op = request["op"] as? String else {
            result["error"] = "no keys.json"
            return
        }
        result["op"] = op
        do {
            switch op {
            case "status":
                let store = model.keyStore
                result["canSync"] = store?.canSync ?? false
                result["canUseSecureEnclave"] = store?.canUseSecureEnclave ?? false
                result["iCloudSignedIn"] = FileManager.default.ubiquityIdentityToken != nil
                result["keys"] = (store?.keys() ?? []).map(describe)
                result["hosts"] = model.hosts.map { host -> [String: Any] in
                    ["alias": host.alias, "auth": "\(host.auth)", "needsConnection": model.needsConnection(host),
                     "problem": model.connectionProblem(host) ?? "", "proxyJump": host.proxyJump ?? ""]
                }
                result["sandboxed"] = UserHome.isSandboxed
                result["home"] = UserHome.path
                result["sshFolder"] = FolderGrants.ssh.folder?.path ?? ""
                result["ghosttyFolder"] = FolderGrants.ghostty.folder?.path ?? ""
                result["ghosttyPickerStart"] = FolderGrants.ghostty.defaultFolder.path
                result["github"] = "\(model.gitHub)"

            case "setup":
                guard let setup = model.relayKeySetup() else { throw HookError("no key setup") }
                var host = SSHHost(
                    alias: try string(request, "alias"), hostname: try string(request, "hostname"),
                    port: request["port"] as? Int, user: request["user"] as? String)
                switch request["bootstrap"] as? String {
                case "password": host.auth = .password
                case "keyFile": host.auth = .keyFile(path: try string(request, "keyFile"), certificatePath: request["certificate"] as? String)
                default: host.auth = .automatic
                }
                host.proxyJump = request["proxyJump"] as? String
                let storage: SSHKeyInfo.Storage = request["storage"] as? String == "secureEnclave" ? .secureEnclave : .iCloudKeychain
                let setupRequest = RelayKeySetup.Request(
                    host: host, password: request["password"] as? String, storage: storage,
                    importKeyFile: request["importKeyFile"] as? String, passphrase: request["passphrase"] as? String)
                let outcome: RelayKeySetup.Outcome
                do {
                    outcome = try await setup.run(setupRequest)
                } catch RelayKeySetup.Failure.unknownHostKey(let presented) where request["trust"] as? Bool == true {
                    result["trusted"] = KnownHosts.fingerprint(ofPublicKey: presented)
                    try model.trustHostKey(presented, for: host)
                    outcome = try await setup.run(setupRequest)
                }
                await model.saveHost(outcome.host, password: nil)
                result["added"] = outcome.added
                result["key"] = describe(outcome.key)
                result["auth"] = "\(outcome.host.auth)"

            case "saveHost":
                // A host as the editor would save it (no key setup).
                var host = SSHHost(
                    alias: try string(request, "alias"), hostname: try string(request, "hostname"),
                    port: request["port"] as? Int, user: request["user"] as? String)
                switch request["auth"] as? String {
                case "password": host.auth = .password
                case "keyFile": host.auth = .keyFile(path: try string(request, "keyFile"), certificatePath: request["certificate"] as? String)
                default: host.auth = .automatic
                }
                host.proxyJump = request["proxyJump"] as? String
                try host.validate()
                await model.saveHost(host, password: request["password"] as? String)
                result["problem"] = model.connectionProblem(host) ?? ""

            case "removeHost":
                let host = try savedHost(model, request)
                await model.removeHost(host)
                result["removed"] = !model.hosts.contains { $0.alias == host.alias }

            case "removeHostAndProjects":
                // Test cleanup: forgets the host's projects (locally only).
                let host = try savedHost(model, request)
                for project in model.projects(on: host) { model.removeProject(project) }
                await model.removeHost(host)
                result["removed"] = !model.hosts.contains { $0.alias == host.alias }

            case "githubPR":
                // A PR's status with the saved sign-in, read back from the
                // keychain the way a launch does.
                await model.recheckGitHubAuth()
                result["github"] = "\(model.gitHub)"
                guard let token = GitHubTokenStore.load() else { throw HookError("not signed in") }
                let status = try await GitHubAPIClient(token: token).pullStatus(
                    owner: try string(request, "owner"), repo: try string(request, "repo"),
                    number: request["number"] as? Int ?? 1)
                result["pr"] = "\(status)"

            case "githubToken":
                // Stands in for finishing (or signing out of) the device
                // flow: saves the token where a login does, then rechecks.
                if request["signOut"] as? Bool == true {
                    model.signOutGitHub()
                } else {
                    GitHubTokenStore.save(try string(request, "token"))
                    await model.recheckGitHubAuth()
                }
                result["github"] = "\(model.gitHub)"

            case "grant":
                // Stands in for picking the folder in the open panel (the
                // path must be one this build's sandbox exempts).
                let grant = request["folder"] as? String == "ghostty" ? FolderGrants.ghostty : FolderGrants.ssh
                if request["revoke"] as? Bool == true {
                    grant.revoke()
                } else {
                    result["granted"] = grant.grant(URL(fileURLWithPath: try string(request, "path"), isDirectory: true))
                }
                model.builtInSSH?.hostsChanged()
                result["folder"] = grant.folder?.path ?? ""

            case "importable":
                let existing = Set(model.hosts.map(\.alias))
                result["canRead"] = !FolderGrants.ssh.needsGrant
                result["entries"] = SSHConfigDiscovery.discoverAliases()
                    .filter { !existing.contains($0) && SSHHost.isValidAlias($0) }
                    .map { alias in
                        SSHConfigImporter.importHosts(alias: alias, existing: existing, evaluate: SSHConfigImporter.effectiveConfig)
                            .map { ["alias": $0.alias, "hostname": $0.hostname, "user": $0.user ?? "", "port": $0.port ?? 22,
                                    "auth": "\($0.auth)", "proxyJump": $0.proxyJump ?? "",
                                    "inherited": $0.inheritedOptions] as [String: Any] }
                    }

            case "terminalConfig":
                if let use = request["useGhostty"] as? Bool { TerminalConfig.useGhosttyFiles = use }
                if let text = request["relayConfig"] as? String {
                    try FileManager.default.createDirectory(
                        at: TerminalConfig.relayConfigFile.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try text.write(to: TerminalConfig.relayConfigFile, atomically: true, encoding: .utf8)
                }
                GhosttyRuntime.shared.reloadConfig()
                result["useGhostty"] = TerminalConfig.useGhosttyFiles
                result["ghosttyFiles"] = TerminalConfig.ghosttyFiles.map(\.path)
                result["filesToLoad"] = TerminalConfig.filesToLoad.map(\.path)
                result["loadsGhosttyDefaults"] = TerminalConfig.loadsGhosttyDefaults
                result["diagnostics"] = GhosttyRuntime.lastDiagnostics
                result["overrides"] = (try? String(
                    contentsOf: AppVariant.dataDirectory.appendingPathComponent("ghostty-overrides.conf"), encoding: .utf8)) ?? ""

            case "trust":
                let host = try savedHost(model, request)
                try model.trustHostKey(try string(request, "presentedKey"), for: host)
                result["trusted"] = KnownHosts.fingerprint(ofPublicKey: try string(request, "presentedKey")) ?? ""

            case "test":
                let host = try savedHost(model, request)
                result["outcome"] = "\(await model.testConnection(host, password: request["password"] as? String))"

            case "authorized":
                let host = try savedHost(model, request)
                result["keys"] = try await model.authorizedKeys(on: host).map {
                    ["publicKey": $0.publicKey, "comment": $0.comment, "relay": $0.isRelayKey]
                }

            case "removeAuthorized":
                let host = try savedHost(model, request)
                let blob = try string(request, "blob")
                let keys = try await model.authorizedKeys(on: host)
                guard let key = keys.first(where: { $0.publicKeyBlob == blob }) else { throw HookError("no such key") }
                try await model.removeAuthorizedKey(key, from: host)
                result["removed"] = true

            case "deleteKey":
                try model.keyStore?.delete(id: try string(request, "id"))
                model.builtInSSH?.hostsChanged()
                result["deleted"] = true

            case "addProject":
                // Validated on the host, as the project editor does.
                let draft = Project(
                    name: try string(request, "project"),
                    workspace: WorkspaceRef(provider: .sshTmux, opaqueID: try string(request, "alias")),
                    pathInput: try string(request, "path"), resolvedPath: "")
                let validation = try await model.provider.validate(project: draft)
                var project = draft
                project.resolvedPath = validation.resolvedPath
                project.runtimeMetadata = validation.runtimeMetadata
                model.addProject(project)
                result["resolvedPath"] = validation.resolvedPath

            case "select":
                let id = try string(request, "session")
                guard let session = model.sessions.values.joined().first(where: { $0.id.uuid.uuidString == id }) else {
                    throw HookError("no session \(id)")
                }
                model.selectedSessionID = session.id
                result["selected"] = true

            case "sessions":
                let project = try projectNamed(model, request)
                result["sessions"] = try await model.provider.listSessions(for: project).map {
                    ["id": $0.id.uuid.uuidString, "name": $0.displayName, "backendID": $0.backendID]
                }

            case "newSession":
                let project = try projectNamed(model, request)
                let session = try await model.provider.createSession(
                    for: project, request: NewSessionRequest(displayName: try string(request, "name"), start: .shell))
                model.noteCreatedSession(session, project: project)
                result["session"] = ["id": session.id.uuid.uuidString, "backendID": session.backendID]

            case "upload":
                let project = try projectNamed(model, request)
                guard let session = model.selectedSession else { throw HookError("no selected session") }
                let paths = request["paths"] as? [String] ?? []
                result["remotePaths"] = try await model.provider.uploadFiles(
                    localPaths: paths, for: session, project: project, progress: nil)

            case "preview":
                let project = try projectNamed(model, request)
                guard let session = model.selectedSession else { throw HookError("no selected session") }
                let url = try await model.provider.fetchPreviewFile(
                    linkPath: try string(request, "path"), for: session, project: project)
                result["localPath"] = url.path
                if let data = try? Data(contentsOf: url) {
                    result["sha256"] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                    result["size"] = data.count
                }

            case "showSettings":
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                result["shown"] = true

            case "windowShots":
                // Each visible window (sheets included) as the app draws
                // it — no screen recording needed.
                let shots = dir.appendingPathComponent("window-shots", isDirectory: true)
                try? FileManager.default.removeItem(at: shots)
                try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
                var written: [String] = []
                for (index, window) in NSApp.windows.enumerated() where window.isVisible {
                    guard let view = window.contentView?.superview ?? window.contentView,
                          let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                    view.cacheDisplay(in: view.bounds, to: rep)
                    let name = "\(index)-\(window.title.isEmpty ? "untitled" : window.title).png"
                    try rep.representation(using: .png, properties: [:])?.write(to: shots.appendingPathComponent(name))
                    written.append(name)
                }
                result["shots"] = written

            case "renderSettings":
                // Settings panes (and Add Host) drawn in an invisible window.
                let shots = dir.appendingPathComponent("window-shots", isDirectory: true)
                try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
                let panes: [(String, AnyView)] = [
                    ("hosts", AnyView(HostsSettingsView(model: model))),
                    ("terminal", AnyView(TerminalSettingsView())),
                    ("terminal-ghostty", AnyView(TerminalSettingsView(selecting: TerminalConfig.ghosttyFiles.first))),
                    ("add-host", AnyView(HostEditorSheet(model: model, mode: .create))),
                ]
                var written: [String] = []
                for (name, view) in panes {
                    let hosting = NSHostingView(rootView: view)
                    let window = NSWindow(
                        contentRect: NSRect(x: 0, y: 0, width: 600, height: 560), styleMask: [.borderless],
                        backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.backgroundColor = .windowBackgroundColor
                    window.alphaValue = 0
                    window.contentView = hosting
                    window.orderFrontRegardless()
                    try await Task.sleep(for: .milliseconds(1200))
                    window.setContentSize(hosting.fittingSize)
                    hosting.layoutSubtreeIfNeeded()
                    try await Task.sleep(for: .milliseconds(300))
                    let frame = window.contentView?.superview ?? hosting
                    if let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) {
                        frame.cacheDisplay(in: frame.bounds, to: rep)
                        try rep.representation(using: .png, properties: [:])?.write(to: shots.appendingPathComponent("settings-\(name).png"))
                        written.append("settings-\(name).png")
                    }
                    window.orderOut(nil)
                }
                result["shots"] = written

            case "renderEditor":
                // The host editor for each given host, drawn in an
                // invisible window: `auth` is "storedKey:<id>",
                // "keyFile:<path>", "password" or "automatic".
                let shots = dir.appendingPathComponent("window-shots", isDirectory: true)
                try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
                var written: [String] = []
                for (index, spec) in (request["hosts"] as? [[String: Any]] ?? []).enumerated() {
                    var host = SSHHost(
                        alias: try string(spec, "alias"), hostname: try string(spec, "hostname"),
                        port: spec["port"] as? Int, user: spec["user"] as? String)
                    let auth = spec["auth"] as? String ?? "automatic"
                    if auth.hasPrefix("storedKey:") { host.auth = .storedKey(id: String(auth.dropFirst(10))) }
                    if auth.hasPrefix("keyFile:") { host.auth = .keyFile(path: String(auth.dropFirst(8)), certificatePath: nil) }
                    if auth == "password" { host.auth = .password }
                    let hosting = NSHostingView(rootView: HostEditorSheet(model: model, mode: .edit(host)))
                    let window = NSWindow(
                        contentRect: NSRect(x: 0, y: 0, width: 520, height: 700), styleMask: [.borderless],
                        backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.backgroundColor = .windowBackgroundColor
                    window.alphaValue = 0
                    window.contentView = hosting
                    window.orderFrontRegardless()
                    try await Task.sleep(for: .milliseconds(900))
                    let size = hosting.fittingSize
                    window.setContentSize(NSSize(width: 520, height: max(200, size.height)))
                    hosting.layoutSubtreeIfNeeded()
                    try await Task.sleep(for: .milliseconds(300))
                    let frame = window.contentView?.superview ?? hosting
                    if let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) {
                        frame.cacheDisplay(in: frame.bounds, to: rep)
                        let name = "editor-\(index)-\(host.alias).png"
                        try rep.representation(using: .png, properties: [:])?.write(to: shots.appendingPathComponent(name))
                        written.append(name)
                    }
                    window.orderOut(nil)
                }
                result["shots"] = written

            default:
                throw HookError("unknown op \(op)")
            }
            result["ok"] = true
        } catch {
            result["ok"] = false
            result["error"] = error.localizedDescription
            result["errorDetail"] = "\(error)"
        }
    }

    private struct HookError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    private static func string(_ request: [String: Any], _ key: String) throws -> String {
        guard let value = request[key] as? String else { throw HookError("missing \(key)") }
        return value
    }

    private static func savedHost(_ model: AppModel, _ request: [String: Any]) throws -> SSHHost {
        let alias = try string(request, "alias")
        guard let host = model.hosts.first(where: { $0.alias == alias }) else { throw HookError("no host \(alias)") }
        return host
    }

    private static func projectNamed(_ model: AppModel, _ request: [String: Any]) throws -> Project {
        let name = try string(request, "project")
        guard let project = model.projects.first(where: { $0.name == name }) else { throw HookError("no project \(name)") }
        return project
    }

    private static func describe(_ key: SSHKeyInfo) -> [String: Any] {
        ["id": key.id, "storage": key.storage.rawValue, "origin": key.origin.rawValue, "name": key.name,
         "publicKey": key.publicKey, "fingerprint": key.fingerprint, "device": key.deviceName]
    }
}
