import SwiftUI
import AppKit
import RelayCore
import RelaySyntaxHighlighter

/// The right-hand changes tray: every changed file as a collapsible section.
/// Source lines render as per-hunk "slabs": one multi-line Text for the code
/// and a parallel fixed-width Text for the dual old/new gutter + change
/// marker, sharing font metrics so rows align. One Text per slab (not per
/// line) is what makes multi-line drag-selection work — and because the
/// gutter is a separate view, copied text is clean code with no line
/// numbers or +/− markers. Long lines scroll horizontally inside the slab
/// instead of wrapping (a wrapped line would break gutter alignment).
///
/// Highlighting is built once per diff, off the main thread (a capped-size
/// diff takes ~100ms/2k lines to tokenize); scrolling and collapse toggles
/// only filter prebuilt rows.
///
/// A file can switch to "full" mode — its entire working-tree content with
/// the diff overlaid — which fetches the file lazily from the session's repo.
struct DiffTrayView: View {
    @Bindable var model: AppModel

    @State private var blocks: [FileBlock] = []
    @State private var collapsedFiles: Set<String> = []
    @State private var fullFiles: Set<String> = []
    @State private var fullState: [String: FullFileState] = [:]
    /// Monotonic guard: a build or full-file fetch that finishes after the
    /// diff has changed again must not write stale rows back into state.
    @State private var generation = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .onChange(of: model.diff, initial: true) {
            rebuild()
        }
    }

    private func rebuild() {
        generation += 1
        let gen = generation
        let diff = model.diff
        // Highlight off the main thread; the previous rows stay up until the
        // new ones land, so a refresh never blanks or stalls the tray.
        Task {
            let built = await Self.buildBlocks(diff)
            apply(built, generation: gen)
        }
    }

    /// Runs on the concurrent executor (nonisolated async), keeping regex
    /// tokenization off the main thread.
    private nonisolated static func buildBlocks(_ diff: SessionGitDiff?) async -> [FileBlock] {
        FileBlock.build(from: diff)
    }

    private func apply(_ built: [FileBlock], generation gen: Int) {
        guard gen == generation else { return }
        blocks = built
        // Collapse and full-mode choices survive a refresh for files still
        // in the diff; full content is refetched (it may have changed).
        let paths = Set(built.map(\.info.path))
        collapsedFiles.formIntersection(paths)
        fullFiles.formIntersection(paths)
        fullState = [:]
        for block in built where fullFiles.contains(block.info.path) {
            fullState[block.info.path] = .loading
            Task { await loadFull(block, generation: gen) }
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
                ProgressView().controlSize(.mini)
            } else {
                Button {
                    model.refreshGitState()
                    Task { await model.loadDiff() }
                } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11))
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
                        ?? "The working tree is clean."))
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
            VStack { Spacer(); ProgressView("Loading diff…"); Spacer() }
                .frame(maxWidth: .infinity)
        } else {
            ContentUnavailableView(
                "No Diff",
                systemImage: "doc.text.magnifyingglass",
                description: Text("This session isn't inside a git repository."))
        }
    }

    /// Assembles the flat render list from the file blocks and per-file
    /// collapse / full-mode state.
    private var visibleRows: [DiffRow] {
        var rows: [DiffRow] = []
        for block in blocks {
            rows.append(DiffRow(id: "h:\(block.info.path)", kind: .fileHeader(block.info)))
            guard !collapsedFiles.contains(block.info.path) else { continue }
            if block.isBinary {
                rows.append(DiffRow(id: "bin:\(block.info.path)", kind: .status("Binary file — no text diff.")))
                continue
            }
            if fullFiles.contains(block.info.path) {
                switch fullState[block.info.path] {
                case .loaded(let fullRows): rows.append(contentsOf: fullRows)
                case .failed: rows.append(DiffRow(id: "full-x:\(block.info.path)", kind: .status("Full file unavailable — showing changes only.")))
                    rows.append(contentsOf: block.compactRows)
                case .loading, nil: rows.append(DiffRow(id: "full-l:\(block.info.path)", kind: .status("Loading full file…")))
                }
            } else {
                rows.append(contentsOf: block.compactRows)
            }
        }
        return rows
    }

    @ViewBuilder
    private func rowView(_ row: DiffRow) -> some View {
        switch row.kind {
        case .fileHeader(let info):
            FileHeaderRow(
                info: info,
                collapsed: collapsedFiles.contains(info.path),
                isFull: fullFiles.contains(info.path),
                // A deleted file has no working-tree content to fetch, so
                // full mode would only ever fail — don't offer it.
                canExpand: !info.isBinary && !info.isDeleted,
                toggleCollapse: { toggle(&collapsedFiles, info.path) },
                toggleFull: { toggleFull(info.path) })
        case .hunkGap(let text):
            Text(text.isEmpty ? "⋯" : text)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 3)
                .background(.quaternary.opacity(0.25))
        case .status(let text):
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
        case .slab(let slab):
            SlabView(slab: slab)
        }
    }

    private func toggle(_ set: inout Set<String>, _ value: String) {
        if !set.insert(value).inserted { set.remove(value) }
    }

    private func toggleFull(_ path: String) {
        if fullFiles.contains(path) {
            fullFiles.remove(path)
            return
        }
        fullFiles.insert(path)
        guard let block = blocks.first(where: { $0.info.path == path }) else { return }
        switch fullState[path] {
        case .loaded, .loading: return // cached, or a fetch is in flight
        case .failed, nil: break       // first load, or retry after a failure
        }
        fullState[path] = .loading
        Task { await loadFull(block, generation: generation) }
    }

    private func loadFull(_ block: FileBlock, generation gen: Int) async {
        let path = block.info.path
        guard let content = await model.fullFileContent(repoRelativePath: path),
              let file = model.diff?.files.first(where: { $0.path == path }) else {
            if gen == generation { fullState[path] = .failed }
            return
        }
        // Reconstruction + highlighting off the main thread: a 1MB file is
        // ~30k lines, seconds of tokenization.
        let rows = await Self.buildFullRows(
            file: file, content: content, path: path,
            language: block.language, baseDigits: block.digits)
        guard gen == generation else { return }
        guard let rows else {
            fullState[path] = .failed
            return
        }
        fullState[path] = .loaded(rows)
    }

    private nonisolated static func buildFullRows(
        file: DiffFile, content: String, path: String, language: String?, baseDigits: Int
    ) async -> [DiffRow]? {
        guard let lines = FullFileReconstructor.lines(file: file, newFileContent: content) else { return nil }
        // The full file may push line numbers past the compact gutter width.
        let maxLine = lines.compactMap { max($0.oldLineNumber ?? 0, $0.newLineNumber ?? 0) }.max() ?? 0
        let digits = max(baseDigits, String(maxLine).count)
        return FileBlock.rows(fromFull: lines, path: path, language: language, digits: digits)
    }

    enum FullFileState {
        case loading
        case loaded([DiffRow])
        case failed
    }
}

// MARK: - File header

private struct FileHeaderRow: View {
    let info: FileBlock.FileInfo
    let collapsed: Bool
    let isFull: Bool
    let canExpand: Bool
    let toggleCollapse: () -> Void
    let toggleFull: () -> Void

    @State private var copied = false

    var body: some View {
        HStack(spacing: 6) {
            Button(action: toggleCollapse) {
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
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 8)

            Button(action: copyPath) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 10))
                    .foregroundStyle(copied ? Color.green : Color.secondary)
            }
            .buttonStyle(.borderless)
            .help("Copy file path")

            if canExpand {
                Button(action: toggleFull) {
                    Image(systemName: isFull ? "rectangle.compress.vertical" : "rectangle.expand.vertical")
                        .font(.system(size: 10))
                        .foregroundStyle(isFull ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.borderless)
                .help(isFull ? "Show changes only" : "Show the whole file")
            }

            if info.isDeleted {
                Image(systemName: "minus.square")
                    .font(.system(size: 10))
                    .foregroundStyle(.red.opacity(0.8))
                    .help("File deleted")
            }
            if info.isBinary {
                Text("binary").font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("+\(info.additions)").foregroundStyle(.green)
                Text("−\(info.deletions)").foregroundStyle(.red)
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(.quaternary.opacity(0.5))
        .padding(.top, 6)
    }

    private func copyPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(info.path, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
    }
}

// MARK: - One slab of source lines

/// A pinned gutter Text beside a horizontally scrolling, selectable code
/// Text. Both are built from the same lines with the same font, so their
/// rows align; the gutter never scrolls or gets copied.
private struct SlabView: View {
    let slab: SlabRow

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text(slab.gutter)
            ScrollView(.horizontal) {
                Text(slab.code)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.trailing, 12)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        }
        .font(.system(size: 11, design: .monospaced))
    }
}

// MARK: - Render model

/// A flattened render row. Precomputed per diff so scrolling and collapse
/// toggles only filter arrays and never re-highlight.
struct DiffRow: Identifiable {
    enum Kind {
        case fileHeader(FileBlock.FileInfo)
        case hunkGap(String)
        case slab(SlabRow)
        case status(String)
    }
    let id: String
    let kind: Kind
}

/// A contiguous run of source lines merged into one multi-line code Text
/// (so drag-selection spans lines) plus its parallel gutter Text.
struct SlabRow: Identifiable {
    let id: String
    let gutter: AttributedString
    let code: AttributedString
}

/// All rows for one changed file, pre-highlighted at diff-load.
struct FileBlock {
    struct FileInfo {
        let path: String
        let oldPath: String?
        let additions: Int
        let deletions: Int
        let isBinary: Bool
        let isDeleted: Bool
    }

    let info: FileInfo
    let language: String?
    /// Gutter digit width for this file's line numbers.
    let digits: Int
    let compactRows: [DiffRow]
    var isBinary: Bool { info.isBinary }

    /// One line's worth of slab input (compact and full modes both feed
    /// through this).
    struct SlabLine {
        let kind: DiffLine.Kind
        let old: Int?
        let new: Int?
        let text: String
    }

    /// Longest run merged into a single Text: bounds one slab's layout cost.
    /// Selection can't cross a chunk boundary — in compact mode chunks are
    /// whole hunks so it never comes up; in full mode it's every 300 lines.
    private static let maxSlabLines = 300

    static func build(from diff: SessionGitDiff?) -> [FileBlock] {
        guard let diff else { return [] }
        return diff.files.enumerated().map { fileIndex, file in
            let language = SyntaxHighlighter.language(forPath: file.path)
            let info = FileInfo(
                path: file.path, oldPath: file.oldPath,
                additions: file.additions, deletions: file.deletions,
                isBinary: file.isBinary, isDeleted: file.isDeleted)
            let maxLine = file.hunks.flatMap(\.lines)
                .map { max($0.oldLineNumber ?? 0, $0.newLineNumber ?? 0) }.max() ?? 0
            let digits = max(2, String(maxLine).count)
            var rows: [DiffRow] = []
            for (hunkIndex, hunk) in file.hunks.enumerated() {
                rows.append(DiffRow(
                    id: "f\(fileIndex)h\(hunkIndex)gap",
                    kind: .hunkGap(UnifiedDiffParser.hunkContext(hunk.header))))
                let slabLines = hunk.lines.compactMap { line -> SlabLine? in
                    line.kind == .meta ? nil : SlabLine(
                        kind: line.kind, old: line.oldLineNumber,
                        new: line.newLineNumber, text: line.text)
                }
                rows += slabRows(
                    slabLines, idPrefix: "f\(fileIndex)h\(hunkIndex)",
                    language: language, digits: digits)
            }
            return FileBlock(info: info, language: language, digits: digits, compactRows: rows)
        }
    }

    static func rows(fromFull lines: [FullFileLine], path: String, language: String?, digits: Int) -> [DiffRow] {
        let slabLines = lines.compactMap { line -> SlabLine? in
            line.kind == .meta ? nil : SlabLine(
                kind: line.kind, old: line.oldLineNumber,
                new: line.newLineNumber, text: line.text)
        }
        return slabRows(slabLines, idPrefix: "full:\(path)", language: language, digits: digits)
    }

    private static func slabRows(
        _ lines: [SlabLine], idPrefix: String, language: String?, digits: Int
    ) -> [DiffRow] {
        stride(from: 0, to: lines.count, by: maxSlabLines).map { start in
            let chunk = lines[start..<min(start + maxSlabLines, lines.count)]
            let slab = buildSlab(chunk, id: "\(idPrefix)s\(start)", language: language, digits: digits)
            return DiffRow(id: slab.id, kind: .slab(slab))
        }
    }

    private static func buildSlab(
        _ lines: ArraySlice<SlabLine>, id: String, language: String?, digits: Int
    ) -> SlabRow {
        var gutter = AttributedString()
        var code = AttributedString()
        var first = true
        for line in lines {
            if !first {
                gutter += AttributedString("\n")
                code += AttributedString("\n")
            }
            first = false

            // "  <old> <new> <marker> " — two leading spaces stand in for the
            // row's leading padding so the tint reaches the left edge.
            var g = AttributedString("  \(pad(line.old, digits)) \(pad(line.new, digits)) ")
            g.foregroundColor = Color(nsColor: .tertiaryLabelColor)
            var mark = AttributedString("\(markerGlyph(line.kind)) ")
            mark.foregroundColor = .secondary
            g += mark

            var c = SyntaxTheme.highlight(line.text, language: language)
            if let tint = tint(line.kind) {
                // Attribute-based tint covers the glyph extent, so the
                // highlight ends where the line's text ends (delta-style),
                // not at the tray edge.
                g.backgroundColor = tint
                c.backgroundColor = tint
            }
            gutter += g
            code += c
        }
        return SlabRow(id: id, gutter: gutter, code: code)
    }

    private static func pad(_ number: Int?, _ digits: Int) -> String {
        let s = number.map(String.init) ?? ""
        return String(repeating: " ", count: max(0, digits - s.count)) + s
    }

    private static func markerGlyph(_ kind: DiffLine.Kind) -> String {
        switch kind {
        case .addition: "+"
        case .deletion: "−"
        case .context, .meta: " "
        }
    }

    private static func tint(_ kind: DiffLine.Kind) -> Color? {
        switch kind {
        case .addition: .green.opacity(0.13)
        case .deletion: .red.opacity(0.13)
        case .context, .meta: nil
        }
    }
}
