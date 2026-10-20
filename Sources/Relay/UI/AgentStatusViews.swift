import SwiftUI
import RelayCore

/// The trailing glyph on a session row for its agent's reported state:
/// a turning ring while working, an orange target when it needs the user,
/// a check when done (filled until looked at), red when the turn failed.
struct AgentStatusGlyph: View {
    let activity: AgentActivity
    let unseen: Bool

    var body: some View {
        glyph
            .frame(width: 14, height: 14)
            .help(helpText)
            .accessibilityLabel(helpText)
    }

    @ViewBuilder private var glyph: some View {
        switch activity.state {
        case .working:
            WorkingRing()
        case .blocked:
            ZStack {
                Circle().strokeBorder(Color.orange, lineWidth: 1.5)
                Circle().fill(Color.orange).padding(3.5)
            }
            .frame(width: 13, height: 13)
        case .done:
            if unseen {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
            } else {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        case .failed:
            Image(systemName: unseen ? "exclamationmark.circle.fill" : "exclamationmark.circle")
                .font(.system(size: 13))
                .foregroundStyle(unseen ? AnyShapeStyle(.red) : AnyShapeStyle(.tertiary))
        case .idle:
            EmptyView()
        }
    }

    private var helpText: String {
        let agent = activity.agent.displayName
        switch activity.state {
        case .working: return "\(agent) is working"
        case .blocked: return "\(agent) needs your input"
        case .done: return "\(agent) finished its turn"
        case .failed: return "\(agent)'s turn failed"
        case .idle: return "\(agent) is idle"
        }
    }
}

/// An open ring turning at a calm pace. Time-driven rather than an
/// implicit repeatForever animation, which List row reuse tends to drop or
/// restart.
private struct WorkingRing: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.2) / 1.2
            Circle()
                .trim(from: 0, to: 0.72)
                .stroke(.secondary, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                .rotationEffect(.degrees(turn * 360))
                .frame(width: 11, height: 11)
        }
    }
}
