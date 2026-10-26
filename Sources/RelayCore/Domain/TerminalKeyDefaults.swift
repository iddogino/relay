import Foundation

/// Keybinds Relay adds to the user's Ghostty configuration.
public enum TerminalKeyDefaults {
    /// Shift+Enter sends a line feed (Ctrl+J), the newline key in Claude
    /// Code, Codex and most line editors. Every Relay terminal runs in tmux,
    /// which hands programs a plain Enter for the encoded Shift+Enter unless
    /// they use a key protocol it speaks; a shell runs the line on Ctrl+J
    /// just as on Enter.
    public static let shiftEnterKeybind = #"keybind = shift+enter=text:\n"#

    /// The user's Ghostty config files, in the places Ghostty reads them on
    /// macOS (files they include with `config-file` aren't followed).
    public static func userConfigFiles(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                       environment: [String: String] = ProcessInfo.processInfo.environment) -> [URL] {
        let xdg = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".config")
        let support = home.appendingPathComponent("Library/Application Support/com.mitchellh.ghostty")
        return [xdg.appendingPathComponent("ghostty"), support].flatMap {
            [$0.appendingPathComponent("config"), $0.appendingPathComponent("config.ghostty")]
        }
    }

    /// Whether a Ghostty config binds Shift+Enter itself (any action,
    /// including `unbind`), in which case Relay leaves it alone.
    public static func bindsShiftEnter(_ config: String) -> Bool {
        config.split(whereSeparator: \.isNewline).contains { line in
            let compact = line.lowercased().filter { !$0.isWhitespace }
            guard compact.hasPrefix("keybind=") else { return false }
            let trigger = compact.dropFirst("keybind=".count).split(separator: "=", maxSplits: 1).first ?? ""
            // Prefixes (global:, all:, …) and sequences (a>b) aside, the
            // last key of the trigger is what's pressed.
            let key = trigger.split(separator: ":").last?.split(separator: ">").last ?? ""
            let parts = Set(key.split(separator: "+").map(String.init))
            return parts == ["shift", "enter"]
        }
    }
}
