import SwiftUI
import RelayCore

/// The toolbar PR pill: opens the PR on click; when the GitHub API is
/// connected it grows a status indicator (spinner / green / red / orange
/// dot) and a hover popover listing mergeability + individual checks.
struct PRBadge: View {
    @Bindable var model: AppModel
    let sessionID: SessionID
    let pr: PullRequestRef

    @State private var pillHovered = false
    @State private var popoverHovered = false
    @State private var popoverShown = false

    private var status: PullRequestStatus? { model.prStatus(for: sessionID) }

    var body: some View {
        Button {
            NSWorkspace.shared.open(pr.url)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.pull")
                Text("#\(pr.number)")
                    .font(.system(size: 11, design: .monospaced))
                indicator
            }
        }
        .help("Open pull request #\(pr.number) on GitHub")
        .onHover { hovering in
            pillHovered = hovering
            syncPopover()
        }
        .popover(isPresented: $popoverShown, arrowEdge: .bottom) {
            if let status {
                PRChecksPopover(model: model, status: status, prURL: pr.url)
                    .onHover { hovering in
                        popoverHovered = hovering
                        syncPopover()
                    }
            }
        }
    }

    @ViewBuilder
    private var indicator: some View {
        switch status?.indicator {
        case nil:
            EmptyView()
        case .inProgress:
            ProgressView()
                .controlSize(.mini)
                .scaleEffect(0.75)
                .frame(width: 10, height: 10)
        case .good:
            dot(.green)
        case .ciFailed:
            dot(.red)
        case .notMergeable:
            dot(.orange)
        case .merged:
            dot(.purple)
        case .closed:
            dot(Color(nsColor: .tertiaryLabelColor))
        }
    }

    private func dot(_ color: Color) -> some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
    }

    /// Hover in shows immediately; hover out closes after a grace period so
    /// the pointer can travel from the pill into the popover.
    private func syncPopover() {
        if pillHovered || popoverHovered {
            if status != nil { popoverShown = true }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) {
                if !pillHovered && !popoverHovered { popoverShown = false }
            }
        }
    }
}

/// GitHub-checks dropdown, macOS-flavored: the popover's own translucent
/// material, small type, plain rows.
struct PRChecksPopover: View {
    @Bindable var model: AppModel
    let status: PullRequestStatus
    let prURL: URL

    private let maxRows = 30

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(status.headline)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(headlineColor)
                    if let summary = status.checkSummary {
                        Text(summary)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    if let note = status.mergeabilityNote {
                        Text(note)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                if model.prStatusRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 16, height: 16)
                } else {
                    Button {
                        model.refreshPRStatusNow()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .medium))
                            .frame(width: 16, height: 16)
                    }
                    .buttonStyle(.borderless)
                    .help("Refresh status now")
                }
            }

            if !status.checks.isEmpty {
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(status.checks.prefix(maxRows)) { check in
                            CheckRow(check: check)
                        }
                        if status.totalCheckCount > min(status.checks.count, maxRows) {
                            Text("…and \(status.totalCheckCount - min(status.checks.count, maxRows)) more on GitHub")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 6)
                        }
                    }
                }
                .frame(maxHeight: 300)
            }

            Divider()
            Button {
                NSWorkspace.shared.open(prURL)
            } label: {
                Label("Open in GitHub", systemImage: "arrow.up.forward.square")
                    .font(.system(size: 11))
            }
            .buttonStyle(.link)
        }
        .padding(14)
        .frame(width: 380)
        // Expanding the details always fetches a fresh view; the button's
        // spinner reflects ANY in-flight fetch (prStatusRefreshing is
        // global), including one this open didn't launch.
        .onAppear { model.refreshPRStatusNow() }
    }

    private var headlineColor: Color {
        switch status.indicator {
        case .ciFailed: return .red
        case .good: return status.checks.isEmpty ? .primary : .green
        case .notMergeable: return .orange
        case .inProgress: return .primary
        case .merged: return .purple
        case .closed: return .secondary
        }
    }
}

private struct CheckRow: View {
    let check: PRCheck

    var body: some View {
        HStack(spacing: 8) {
            icon
                .frame(width: 14, height: 14)
            Text(check.name)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 12)
            detailText
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let url = check.detailsURL {
                Button("Details") {
                    NSWorkspace.shared.open(url)
                }
                .buttonStyle(.link)
                .font(.system(size: 11))
            }
        }
        .padding(.vertical, 5)
    }

    /// Running checks get a live elapsed counter ("In progress · 4:12");
    /// `.timer` ticks by itself, no timer of ours.
    private var detailText: Text {
        if check.outcome == .inProgress, let startedAt = check.startedAt {
            return Text(check.detail)
                + Text(" · ")
                + Text(startedAt, style: .timer)
                    .font(.system(size: 11, design: .monospaced))
        }
        return Text(check.detail)
    }

    @ViewBuilder
    private var icon: some View {
        switch check.outcome {
        case .success:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failure:
            Image(systemName: "x.circle.fill").foregroundStyle(.red)
        case .cancelled:
            Image(systemName: "slash.circle.fill").foregroundStyle(.secondary)
        case .skipped, .neutral:
            Image(systemName: "minus.circle").foregroundStyle(.secondary)
        case .queued:
            Image(systemName: "clock").foregroundStyle(.secondary)
        case .inProgress:
            ProgressView()
                .controlSize(.mini)
                .scaleEffect(0.75)
        }
    }
}
