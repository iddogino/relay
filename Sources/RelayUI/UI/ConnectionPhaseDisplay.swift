import SwiftUI

/// How a terminal's connection shows: the dot's color and, while it isn't
/// simply connected, a word for it — the same in the sidebar and over the
/// terminal.
extension TerminalAttachmentController.Phase {
    var statusColor: Color {
        switch self {
        case .attached: return .green
        case .connecting, .reconnecting: return .yellow
        case .ended, .failed: return .red
        case .idle: return .secondary
        }
    }

    /// The state in words, when it's worth saying (not connected or idle).
    var statusText: String? {
        switch self {
        case .connecting: return "Connecting\u{2026}"
        case .reconnecting: return "Reconnecting\u{2026}"
        case .ended: return "Ended"
        case .failed: return "Disconnected"
        case .attached, .idle: return nil
        }
    }

    /// The dot, in words (VoiceOver).
    var spokenDescription: String {
        switch self {
        case .attached: return "connected"
        case .connecting: return "connecting"
        case .reconnecting: return "reconnecting"
        case .ended: return "ended"
        case .failed: return "disconnected"
        case .idle: return "not connected"
        }
    }
}
