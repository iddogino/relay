import Foundation
import RelayCore
import RelaySSH

/// Which configuration Relay's terminals load, in order: the user's Ghostty
/// config files (when they opt in — and, in the App Sandbox, granted the
/// folder), then Relay's own terminal config, then Relay's required
/// overrides (`GhosttyRuntime`).
@MainActor
enum TerminalConfig {
    static let useGhosttyFilesKey = "useGhosttyConfigFiles"

    /// Whether terminals use the user's Ghostty config. On by default
    /// outside the sandbox (as Relay always did); in it, from when the user
    /// turns it on and grants the folder.
    static var useGhosttyFiles: Bool {
        get {
            UserDefaults.standard.object(forKey: useGhosttyFilesKey) as? Bool ?? !UserHome.isSandboxed
        }
        set {
            UserDefaults.standard.set(newValue, forKey: useGhosttyFilesKey)
        }
    }

    /// Relay's own terminal config: Ghostty syntax, editable in Settings ▸
    /// Terminal, kept with Relay's data (so it works without any grant).
    static var relayConfigFile: URL {
        AppVariant.dataDirectory.appendingPathComponent("terminal.conf")
    }

    /// The Ghostty config files Relay can read now (existing ones only).
    static var ghosttyFiles: [URL] {
        guard let folder = FolderGrants.ghostty.folder else { return [] }
        if UserHome.isSandboxed {
            // The folder itself, or Ghostty's folder inside it (when the
            // user picked `~/.config` or Application Support).
            let folders = [folder, folder.appendingPathComponent("ghostty"),
                           folder.appendingPathComponent("com.mitchellh.ghostty")]
            return folders.flatMap { dir in ["config", "config.ghostty"].map { dir.appendingPathComponent($0) } }
                .filter { FileManager.default.isReadableFile(atPath: $0.path) }
        }
        // Outside the sandbox, every place Ghostty itself reads.
        return TerminalKeyDefaults.userConfigFiles(home: URL(fileURLWithPath: UserHome.path))
            .filter { FileManager.default.isReadableFile(atPath: $0.path) }
    }

    /// The files the terminal loads before Relay's overrides, in order.
    /// Outside the sandbox Ghostty's own files are loaded by libghostty's
    /// default lookup (`loadsGhosttyDefaults`), so they aren't listed.
    static var filesToLoad: [URL] {
        var files: [URL] = []
        if useGhosttyFiles, UserHome.isSandboxed { files += ghosttyFiles }
        if FileManager.default.fileExists(atPath: relayConfigFile.path) { files.append(relayConfigFile) }
        return files
    }

    /// Whether libghostty should load its default config files itself.
    static var loadsGhosttyDefaults: Bool {
        useGhosttyFiles && !UserHome.isSandboxed
    }

    /// Every user-written config in effect (for checks like Shift+Enter).
    static var userConfigInEffect: [URL] {
        var files: [URL] = []
        if useGhosttyFiles { files += ghosttyFiles }
        if FileManager.default.fileExists(atPath: relayConfigFile.path) { files.append(relayConfigFile) }
        return files
    }
}
