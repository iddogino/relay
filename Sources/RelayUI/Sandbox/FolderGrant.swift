import AppKit
import Observation
import RelaySSH

/// Access to a folder outside the app's container — `~/.ssh`, the Ghostty
/// config folder. Outside the App Sandbox Relay reads them directly; in
/// it, only once the user picks the folder in an open panel, after which a
/// security-scoped bookmark keeps the access across launches.
@MainActor
@Observable
final class FolderGrant {
    /// The folder Relay expects (a different one can be picked).
    let defaultFolder: URL
    private let defaultsKey: String
    private let panelMessage: String
    /// The granted folder, being accessed (sandbox only).
    private(set) var grantedFolder: URL?

    init(defaultFolder: URL, defaultsKey: String, panelMessage: String) {
        self.defaultFolder = defaultFolder
        self.defaultsKey = defaultsKey
        self.panelMessage = panelMessage
        restore()
    }

    /// The folder Relay reads, if it can: the default one outside the
    /// sandbox, the granted one in it.
    var folder: URL? {
        UserHome.isSandboxed ? grantedFolder : defaultFolder
    }

    /// Whether Relay needs the user to grant access before it can read.
    var needsGrant: Bool {
        UserHome.isSandboxed && grantedFolder == nil
    }

    /// Resolves the saved bookmark (at launch) and starts accessing it.
    private func restore() {
        guard UserHome.isSandboxed, let data = UserDefaults.standard.data(forKey: defaultsKey) else { return }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale),
              url.startAccessingSecurityScopedResource() else {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
            return
        }
        grantedFolder = url
        if stale, let fresh = try? url.bookmarkData(options: [.withSecurityScope]) {
            UserDefaults.standard.set(fresh, forKey: defaultsKey)
        }
    }

    /// Asks the user to pick the folder (starting at the default one).
    /// Returns whether Relay can now read it.
    @discardableResult
    func requestAccess() async -> Bool {
        guard UserHome.isSandboxed else { return true }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = defaultFolder
        panel.message = panelMessage
        panel.prompt = "Allow Access"
        guard await panel.begin() == .OK, let url = panel.url else { return false }
        return grant(url)
    }

    /// Records access to `url` — a folder the user just picked (or, in dev
    /// automation, one the build's sandbox exempts).
    @discardableResult
    func grant(_ url: URL) -> Bool {
        guard UserHome.isSandboxed else { return true }
        guard let data = try? url.bookmarkData(options: [.withSecurityScope]) else { return false }
        revoke()
        UserDefaults.standard.set(data, forKey: defaultsKey)
        guard url.startAccessingSecurityScopedResource() || FileManager.default.isReadableFile(atPath: url.path) else {
            return false
        }
        grantedFolder = url
        return true
    }

    func revoke() {
        grantedFolder?.stopAccessingSecurityScopedResource()
        grantedFolder = nil
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }
}

/// The folders Relay reads outside its own data.
@MainActor
enum FolderGrants {
    /// `~/.ssh`: config (to import hosts), keys, known_hosts.
    static let ssh = FolderGrant(
        defaultFolder: URL(fileURLWithPath: UserHome.path).appendingPathComponent(".ssh", isDirectory: true),
        defaultsKey: "sshFolderBookmark",
        panelMessage: "Relay reads your SSH config, keys and known hosts from this folder. It never changes them.")

    /// Ghostty's config folder: `~/.config/ghostty`, or Ghostty's folder in
    /// Application Support (where Ghostty on macOS creates it). The picker
    /// starts at whichever exists — a folder that doesn't would open the
    /// panel at its parent.
    static let ghostty: FolderGrant = {
        let home = URL(fileURLWithPath: UserHome.path)
        let xdg = home.appendingPathComponent(".config/ghostty", isDirectory: true)
        let support = home.appendingPathComponent("Library/Application Support/com.mitchellh.ghostty", isDirectory: true)
        let folder = [xdg, support].first { FileManager.default.fileExists(atPath: $0.path) } ?? support
        return FolderGrant(
            defaultFolder: folder,
            defaultsKey: "ghosttyFolderBookmark",
            panelMessage: "Choose the folder with your Ghostty config. Relay's terminals will use it, and you can edit it in Relay.")
    }()
}
