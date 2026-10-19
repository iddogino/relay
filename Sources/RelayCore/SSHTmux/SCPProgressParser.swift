import Foundation

/// A snapshot of an in-flight upload, as reported by `uploadFiles`.
public struct UploadProgress: Sendable, Equatable {
    /// Bytes sent so far across every file of the drop. Approximate while a
    /// multi-file drop is in flight (scp reports rounded sizes per file).
    public var bytesTransferred: Int64
    /// Exact completion of the file currently in flight, 0...1.
    public var currentFileFraction: Double
    /// How many files scp has started so far (1-based once any started).
    public var filesStarted: Int

    public init(bytesTransferred: Int64, currentFileFraction: Double, filesStarted: Int) {
        self.bytesTransferred = bytesTransferred
        self.currentFileFraction = currentFileFraction
        self.filesStarted = filesStarted
    }
}

/// Incrementally parses OpenSSH scp's progress meter (the tty-only output
/// suppressed by `-q`) into cumulative `UploadProgress`.
///
/// The meter redraws one line per file with carriage returns:
/// `name   45% 1234KB  12.3MB/s   00:10 ETA`. Sizes are rounded to at most
/// four or five significant digits (`format_size` in progressmeter.c), so
/// cross-file totals are approximate; the percentage is exact per file.
public struct SCPProgressParser: Sendable {
    private var pending = ""
    private var currentName: String?
    private var currentBytes: Int64 = 0
    private var currentPercent = 0
    private var completedBytes: Int64 = 0
    private var filesStarted = 0

    public init() {}

    /// Feeds raw terminal output; returns the latest progress if this chunk
    /// completed at least one meter line.
    public mutating func feed(_ data: Data) -> UploadProgress? {
        pending += String(decoding: data, as: UTF8.self)
        var latest: UploadProgress?
        // isNewline, not == "\r": a terminal's "\r\n" is one Character.
        while let sep = pending.firstIndex(where: \.isNewline) {
            let line = Self.visibleText(pending[..<sep])
            pending.removeSubrange(...sep)
            if let update = consume(line: line) { latest = update }
        }
        // A meter line that never terminates shouldn't grow without bound.
        if pending.count > 4096 { pending.removeAll() }
        return latest
    }

    private mutating func consume(line: String) -> UploadProgress? {
        guard let meter = Self.parse(line: line) else { return nil }
        // A new file starts when the name changes, or when the same name
        // restarts from a lower percentage (two same-named files in a tree).
        if meter.name != currentName || meter.percent < currentPercent {
            if currentName != nil { completedBytes += currentBytes }
            currentName = meter.name
            filesStarted += 1
        }
        currentBytes = meter.bytes
        currentPercent = meter.percent
        return UploadProgress(
            bytesTransferred: completedBytes + currentBytes,
            currentFileFraction: Double(min(meter.percent, 100)) / 100,
            filesStarted: filesStarted
        )
    }

    /// Drops what a terminal would have erased: anything before the last
    /// backspace (script(1) echoes the stdin EOF as "^D\u{8}\u{8}" ahead
    /// of the first meter line) and other control characters.
    static func visibleText(_ raw: Substring) -> String {
        let afterErase = raw.lastIndex(of: "\u{8}").map { raw[raw.index(after: $0)...] } ?? raw
        return String(afterErase.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }.map(Character.init))
    }

    /// Terminal output with every progress-meter redraw removed — what's
    /// left is scp's diagnostics (its stderr shares the terminal).
    public static func nonMeterText(_ output: String) -> String {
        output.split(whereSeparator: \.isNewline)
            .map { visibleText($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "^D" && parse(line: $0) == nil }
            .joined(separator: "\n")
    }

    struct MeterLine: Equatable {
        var name: String
        var percent: Int
        var bytes: Int64
    }

    /// Parses one redrawn meter line, or nil for anything else (banners,
    /// blank redraws). Anchored on the first ` NN% ` token followed by a
    /// size, so file names containing `%` or digits don't confuse it.
    static func parse(line: String) -> MeterLine? {
        let tokens = line.split(separator: " ", omittingEmptySubsequences: true)
        guard tokens.count >= 3 else { return nil }
        for i in 1..<(tokens.count - 1) {
            let pctToken = tokens[i]
            guard pctToken.hasSuffix("%"),
                  let percent = Int(pctToken.dropLast()), (0...100).contains(percent),
                  let bytes = parseSize(tokens[i + 1], next: i + 2 < tokens.count ? tokens[i + 2] : nil)
            else { continue }
            // The name is everything before the percentage, trimmed. Using
            // the original line keeps internal runs of spaces intact.
            guard let range = line.range(of: " \(pctToken) ") ?? line.range(of: " \(pctToken)") else { continue }
            let name = line[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            return MeterLine(name: name, percent: percent, bytes: bytes)
        }
        return nil
    }

    /// `format_size` output: a bare byte count (unit column blank, so the
    /// next token is the rate) or a count with KB/MB/GB/TB.
    private static func parseSize(_ token: Substring, next: Substring?) -> Int64? {
        let units: [Character: Int64] = ["K": 1 << 10, "M": 1 << 20, "G": 1 << 30, "T": 1 << 40]
        if let plain = Int64(token) {
            // A bare number must be followed by the rate column (".../s").
            guard next?.hasSuffix("/s") == true else { return nil }
            return plain
        }
        guard token.hasSuffix("B"), token.count >= 3 else { return nil }
        let unit = token[token.index(token.endIndex, offsetBy: -2)]
        guard let multiplier = units[unit],
              let value = Int64(token.dropLast(2))
        else { return nil }
        return value * multiplier
    }
}
