import Foundation

extension SSHConfigImporter {
    /// `alias`'s effective settings from the user's `~/.ssh/config`, in
    /// `ssh -G`'s format (evaluated in-app), or nil when the config can't
    /// be read — missing, or, in the App Sandbox, not granted yet.
    public static func effectiveConfig(alias: String) -> String? {
        let path = SSHConfigDiscovery.defaultConfigPath
        guard FileManager.default.isReadableFile(atPath: path) else { return nil }
        return SSHConfigEvaluator.effectiveConfig(alias: alias, configPath: path, environment: .local())
    }
}
