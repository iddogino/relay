import AppKit
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
        let dir = AppVariant.dataDirectory
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
                    ["alias": host.alias, "auth": "\(host.auth)", "needsConnection": model.needsConnection(host)]
                }

            case "setup":
                guard let setup = model.relayKeySetup() else { throw HookError("no key setup") }
                var host = SSHHost(
                    alias: try string(request, "alias"), hostname: try string(request, "hostname"),
                    port: request["port"] as? Int, user: request["user"] as? String)
                switch request["bootstrap"] as? String {
                case "password": host.auth = .password
                case "keyFile": host.auth = .keyFile(path: try string(request, "keyFile"), certificatePath: nil)
                default: host.auth = .automatic
                }
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
