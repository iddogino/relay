import Foundation

/// Enumerates concrete host aliases from the user's OpenSSH configuration.
///
/// This parser exists ONLY to list aliases for the sidebar. It never resolves
/// connection parameters; actual connections always invoke `/usr/bin/ssh <alias>`
/// so the user's real OpenSSH behavior applies.
public enum SSHConfigDiscovery {
    public static let defaultConfigPath = NSString(string: "~/.ssh/config").expandingTildeInPath

    /// Discover concrete aliases starting from the given config file.
    /// Missing files yield an empty list; malformed lines are skipped.
    public static func discoverAliases(configPath: String = defaultConfigPath) -> [String] {
        var visited = Set<String>()
        var aliases: [String] = []
        var seen = Set<String>()
        parseFile(at: configPath, depth: 0, visited: &visited) { alias in
            if seen.insert(alias).inserted {
                aliases.append(alias)
            }
        }
        return aliases
    }

    private static let maxIncludeDepth = 16

    private static func parseFile(
        at path: String,
        depth: Int,
        visited: inout Set<String>,
        emit: (String) -> Void
    ) {
        guard depth < maxIncludeDepth else { return }
        let canonical = URL(fileURLWithPath: path).standardizedFileURL.path
        guard visited.insert(canonical).inserted else { return }
        guard let contents = try? String(contentsOfFile: canonical, encoding: .utf8) else { return }

        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            let tokens = tokenize(line)
            guard let keyword = tokens.first?.lowercased(), tokens.count >= 2 else { continue }
            let args = Array(tokens.dropFirst())

            switch keyword {
            case "host":
                for pattern in args where isConcreteAlias(pattern) {
                    emit(pattern)
                }
            case "include":
                for includePattern in args {
                    for file in resolveIncludes(pattern: includePattern, relativeTo: canonical) {
                        parseFile(at: file, depth: depth + 1, visited: &visited, emit: emit)
                    }
                }
            default:
                continue
            }
        }
    }

    /// A pattern is a concrete alias if it contains no wildcard characters
    /// and is not negated.
    static func isConcreteAlias(_ pattern: String) -> Bool {
        guard !pattern.isEmpty else { return false }
        if pattern.hasPrefix("!") { return false }
        if pattern.contains("*") || pattern.contains("?") { return false }
        return true
    }

    /// Tokenizes an ssh_config line: whitespace and `=` separate the keyword
    /// from arguments; double quotes group words containing spaces.
    static func tokenize(_ line: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false
        var sawKeywordSeparator = false

        func flush() {
            if !current.isEmpty {
                tokens.append(current)
                current = ""
            }
        }

        for char in line {
            if inQuotes {
                if char == "\"" { inQuotes = false } else { current.append(char) }
                continue
            }
            switch char {
            case "\"":
                inQuotes = true
            case " ", "\t":
                flush()
            case "=" where tokens.count <= 1 && !sawKeywordSeparator:
                // OpenSSH allows `Keyword=value`. Only the first `=` after the
                // keyword is a separator; later `=` are literal.
                sawKeywordSeparator = true
                flush()
            default:
                current.append(char)
            }
        }
        flush()
        return tokens
    }

    /// Expands an Include argument to matching files. Relative paths are
    /// relative to `~/.ssh`; `~` is expanded; globs are supported.
    static func resolveIncludes(pattern: String, relativeTo includingFile: String) -> [String] {
        var expanded = pattern
        if expanded.hasPrefix("~") {
            expanded = NSString(string: expanded).expandingTildeInPath
        }
        if !expanded.hasPrefix("/") {
            let sshDir = NSString(string: "~/.ssh").expandingTildeInPath
            expanded = sshDir + "/" + expanded
        }

        if expanded.contains("*") || expanded.contains("?") || expanded.contains("[") {
            return glob(expanded)
        }
        return [expanded]
    }

    private static func glob(_ pattern: String) -> [String] {
        var globResult = glob_t()
        defer { globfree(&globResult) }
        guard Foundation.glob(pattern, 0, nil, &globResult) == 0 else { return [] }
        var paths: [String] = []
        for i in 0..<Int(globResult.gl_matchc) {
            if let cString = globResult.gl_pathv[i] {
                paths.append(String(cString: cString))
            }
        }
        return paths
    }
}
