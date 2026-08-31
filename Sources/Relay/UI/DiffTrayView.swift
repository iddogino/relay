import SwiftUI
import RelayCore

/// The right-hand changes tray: every changed file as a collapsible
/// section over the raw diff lines. v0 renders plain monospaced text with
/// added/removed tinting — no syntax highlighting yet.
///
/// Rendering is one flat lazy list of precomputed row blocks, with
/// consecutive same-kind lines merged into single multi-line Texts. Never
/// nest per-line views inside a lazy element: a large file would
/// materialize thousands of views at once and every collapse toggle would
/// re-lay them out (the v0 mistake — the sluggishness was CPU-side view
/// construction, not rendering).
struct DiffTrayView: View {
    @Bindable var model: AppModel

    @State private var rows: [DiffRenderRow] = []
    @State private var collapsedFiles: Set<String> = []

    private var visibleRows: [DiffRenderRow] {
        rows.filter { row in
            if case .fileHeader = row.kind { return true }
            return !collapsedFiles.contains(row.filePath)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .onChange(of: model.diff, initial: true) {
            rows = DiffRenderRow.build(from: model.diff)
            collapsedFiles = []
        }
    }

    // Metrics mirror TerminalHeaderBar (12pt text, 6pt vertical padding) so
    // the tray header lines up with the terminal header to its left.
    private var header: some View {
        HStack(spacing: 8) {
            Text("Changes")
                .font(.system(size: 12, weight: .semibold))
            if let diff = model.diff {
                Text(diff.baseRef.map { "\(diff.branch) vs \($0)" } ?? diff.branch)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if model.diffLoading {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Button {
                    model.refreshGitState()
                    Task { await model.loadDiff() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .help("Refresh diff")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    @ViewBuilder private var content: some View {
        if let error = model.diffError {
            ContentUnavailableView {
                Label("Couldn't Load Diff", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Retry") { Task { await model.loadDiff() } }
            }
        } else if let diff = model.diff {
            if diff.files.isEmpty {
                ContentUnavailableView(
                    "No Changes",
                    systemImage: "checkmark.circle",
                    description: Text(diff.baseRef.map { "This session matches \($0)." }
                        ?? "The working tree is clean.")
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(visibleRows) { row in
                            rowView(row)
                        }
                        if diff.truncated {
                            Label("Diff truncated — it exceeds the transfer cap.",
                                  systemImage: "scissors")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(12)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        } else if model.diffLoading {
            VStack {
                Spacer()
                ProgressView("Loading diff…")
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            ContentUnavailableView(
                "No Diff",
                systemImage: "doc.text.magnifyingglass",
                description: Text("This session isn't inside a git repository.")
            )
        }
    }

    @ViewBuilder
    private func rowView(_ row: DiffRenderRow) -> some View {
        switch row.kind {
        case .fileHeader(let info):
            FileHeaderRow(
                info: info,
                collapsed: collapsedFiles.contains(row.filePath)
            ) {
                if !collapsedFiles.insert(row.filePath).inserted {
                    collapsedFiles.remove(row.filePath)
                }
            }
        case .hunkHeader(let text):
            Text(text)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.25))
        case .lines(let kind, let text):
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(kind == .meta ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 1)
                .background(Self.blockBackground(kind))
                .textSelection(.enabled)
        case .binaryNote:
            Text("Binary file — no text diff.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
        }
    }

    private static func blockBackground(_ kind: DiffLine.Kind) -> Color {
        switch kind {
        case .addition: .green.opacity(0.13)
        case .deletion: .red.opacity(0.13)
        case .context, .meta: .clear
        }
    }
}

private struct FileHeaderRow: View {
    let info: DiffRenderRow.FileInfo
    let collapsed: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                VStack(alignment: .leading, spacing: 1) {
                    Text(info.path)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let oldPath = info.oldPath {
                        Text("renamed from \(oldPath)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 8)
                if info.isBinary {
                    Text("binary")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("+\(info.additions)")
                        .foregroundStyle(.green)
                    Text("−\(info.deletions)")
                        .foregroundStyle(.red)
                }
            }
            .font(.system(size: 11, design: .monospaced))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(.quaternary.opacity(0.5))
        .padding(.top, 6)
    }
}

/// One row of the flattened tray. Precomputed per diff so renders and
/// collapse toggles only filter an array.
struct DiffRenderRow: Identifiable {
    struct FileInfo {
        let path: String
        let oldPath: String?
        let additions: Int
        let deletions: Int
        let isBinary: Bool
    }

    enum Kind {
        case fileHeader(FileInfo)
        case hunkHeader(String)
        /// A run of consecutive same-kind lines merged into one text block,
        /// prefixes included.
        case lines(DiffLine.Kind, String)
        case binaryNote
    }

    let id: String
    let filePath: String
    let kind: Kind

    /// Blocks longer than this are split so a single lazy element can't
    /// grow monstrous.
    private static let maxBlockLines = 200

    static func build(from diff: SessionGitDiff?) -> [DiffRenderRow] {
        guard let diff else { return [] }
        var rows: [DiffRenderRow] = []
        for (fileIndex, file) in diff.files.enumerated() {
            let filePath = file.path
            rows.append(DiffRenderRow(
                id: "f\(fileIndex)",
                filePath: filePath,
                kind: .fileHeader(FileInfo(
                    path: file.path,
                    oldPath: file.oldPath,
                    additions: file.additions,
                    deletions: file.deletions,
                    isBinary: file.isBinary))))
            if file.isBinary {
                rows.append(DiffRenderRow(id: "f\(fileIndex)-bin", filePath: filePath, kind: .binaryNote))
                continue
            }
            for (hunkIndex, hunk) in file.hunks.enumerated() {
                rows.append(DiffRenderRow(
                    id: "f\(fileIndex)-h\(hunkIndex)",
                    filePath: filePath,
                    kind: .hunkHeader(hunk.header)))
                var block: [String] = []
                var blockKind: DiffLine.Kind?
                var blockIndex = 0
                func flush() {
                    guard let kind = blockKind, !block.isEmpty else { return }
                    rows.append(DiffRenderRow(
                        id: "f\(fileIndex)-h\(hunkIndex)-b\(blockIndex)",
                        filePath: filePath,
                        kind: .lines(kind, block.joined(separator: "\n"))))
                    blockIndex += 1
                    block = []
                    blockKind = nil
                }
                for line in hunk.lines {
                    if line.kind != blockKind || block.count >= maxBlockLines {
                        flush()
                        blockKind = line.kind
                    }
                    block.append(prefixed(line))
                }
                flush()
            }
        }
        return rows
    }

    private static func prefixed(_ line: DiffLine) -> String {
        switch line.kind {
        case .addition: "+" + line.text
        case .deletion: "-" + line.text
        case .context: " " + (line.text.isEmpty ? "" : line.text)
        case .meta: line.text
        }
    }
}
