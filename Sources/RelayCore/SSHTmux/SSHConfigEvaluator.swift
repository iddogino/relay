import Foundation

/// Evaluates an OpenSSH client config for one alias the way `ssh -G` does
/// — without running ssh, so it works in the App Sandbox and on iOS.
///
/// Covered (checked against `ssh -G` by differential tests):
/// - First obtained value wins; IdentityFile, CertificateFile and the
///   forwards accumulate (exact duplicates dropped).
/// - `Host` patterns (`*`, `?`, `!negation`; case-sensitive, against the
///   alias as typed) and `Match` with `all`, `host`, `originalhost`, `user`,
///   `localuser`, `tagged`, `canonical`, `final` and `!` negation — including
///   the second ("final") pass `Match final` triggers, in which `Host`
///   patterns match the resolved hostname.
/// - `Include` (globs, `~`, relative to `~/.ssh`, nested, inside blocks).
/// - ssh's line syntax: `Keyword=value`, quotes, backslash escapes,
///   comments, CRLF, case-insensitive keywords; ProxyCommand takes the raw
///   rest of the line.
/// - HostName `%h`/`%%` (then lowercased, as ssh does), User tokens and
///   `${VAR}`, ProxyJump/ProxyCommand precedence (whichever comes first,
///   `none` included), ForwardAgent, forwards normalized as `ssh -G` prints
///   them, Port service names, the default identity files.
///
/// Deliberately not supported: `Match exec` (would run a command — it
/// counts as not matching), `Match localnetwork`/`version`/`sessiontype`/
/// `command` (not matching), hostname canonicalization (needs DNS:
/// `CanonicalizeHostname` is ignored, so `Match canonical` matches only in
/// a final pass `Match final` asked for), `~user` paths, and ssh's
/// strictness: a line ssh would reject (unknown keyword, bad port, extra
/// arguments) is skipped here instead of failing the whole evaluation.
/// Keywords other than the modeled ones are kept raw, first value wins.
public enum SSHConfigEvaluator {
    /// Everything outside the config text, injected: the sandboxed app
    /// reads `~/.ssh` through a security-scoped bookmark, and `~` is the
    /// user's real home — not `NSHomeDirectory()`, the app's container.
    public struct Environment: Sendable {
        /// The real home directory (`~`, `%d`).
        public var home: String
        public var localUser: String
        public var uid: Int
        /// The full local hostname (`%l`; `%L` is its first label).
        public var localHostname: String
        /// A file's contents, or nil when it can't be read.
        public var readFile: @Sendable (String) -> String?
        /// The files an absolute pattern matches, sorted (what glob(3)
        /// returns): missing files match nothing.
        public var glob: @Sendable (String) -> [String]
        /// An environment variable, for `${VAR}`.
        public var variable: @Sendable (String) -> String?

        public init(
            home: String,
            localUser: String,
            uid: Int = Int(getuid()),
            localHostname: String = Environment.currentHostname(),
            readFile: @escaping @Sendable (String) -> String?,
            glob: @escaping @Sendable (String) -> [String],
            variable: @escaping @Sendable (String) -> String? = { ProcessInfo.processInfo.environment[$0] }
        ) {
            self.home = home
            self.localUser = localUser
            self.uid = uid
            self.localHostname = localHostname
            self.readFile = readFile
            self.glob = glob
            self.variable = variable
        }

        /// This Mac's files, with `~` the real home from the password
        /// database (right inside the sandbox too).
        public static func local() -> Environment {
            var home = NSHomeDirectory()
            var user = NSUserName()
            if let entry = getpwuid(getuid()) {
                home = String(cString: entry.pointee.pw_dir)
                user = String(cString: entry.pointee.pw_name)
            }
            return Environment(
                home: home,
                localUser: user,
                readFile: { try? String(contentsOfFile: $0, encoding: .utf8) },
                glob: systemGlob)
        }

        public static func currentHostname() -> String {
            var buffer = [CChar](repeating: 0, count: 256)
            guard gethostname(&buffer, buffer.count) == 0 else { return "localhost" }
            return String(cString: buffer)
        }

        static func systemGlob(_ pattern: String) -> [String] {
            var result = glob_t()
            defer { globfree(&result) }
            guard Foundation.glob(pattern, 0, nil, &result) == 0 else { return [] }
            return (0..<Int(result.gl_matchc)).compactMap { result.gl_pathv[$0].map { String(cString: $0) } }
        }
    }

    /// The identity files `ssh -G` lists when none is configured.
    public static let defaultIdentityFiles = [
        "~/.ssh/id_rsa", "~/.ssh/id_ecdsa", "~/.ssh/id_ecdsa_sk", "~/.ssh/id_ed25519", "~/.ssh/id_ed25519_sk",
    ]

    /// The effective settings for `alias`, keyed by lowercased keyword as
    /// `ssh -G` prints them. Always has host, hostname, user, port,
    /// identityfile and forwardagent.
    public static func evaluate(alias: String, configPath: String, environment: Environment) -> [String: [String]] {
        var state = State(alias: alias, environment: environment)
        var evaluator = Pass(state: state, final: false, host: alias, configPath: configPath)
        evaluator.run()
        state = evaluator.state
        if state.wantsFinalPass {
            // ssh re-reads the config with the resolved hostname: `Host`
            // patterns now match it, `Match final`/`canonical` match, and
            // everything already set stays set.
            let resolved = state.resolvedHostname
            state.hostname = .resolved(resolved)
            var final = Pass(state: state, final: true, host: resolved, configPath: configPath)
            final.run()
            state = final.state
        }
        return state.output()
    }

    /// `evaluate` rendered as `ssh -G` output (`keyword value` lines), for
    /// code that parses that.
    public static func effectiveConfig(alias: String, configPath: String, environment: Environment) -> String {
        render(evaluate(alias: alias, configPath: configPath, environment: environment))
    }

    static let renderOrder = [
        "host", "user", "hostname", "port", "dynamicforward", "localforward", "remoteforward",
        "identityfile", "certificatefile", "forwardagent", "proxycommand", "proxyjump",
    ]

    public static func render(_ values: [String: [String]]) -> String {
        let rest = values.keys.filter { !renderOrder.contains($0) }.sorted()
        return (renderOrder + rest).flatMap { key in
            (values[key] ?? []).map { "\(key) \($0)" }
        }.joined(separator: "\n") + "\n"
    }

    // MARK: State

    enum Hostname {
        case unset
        /// As written: `%h` still to expand.
        case raw(String)
        /// Expanded and lowercased (the final pass).
        case resolved(String)
    }

    struct State {
        let alias: String
        let environment: Environment
        var hostname: Hostname = .unset
        var user: String?
        var port: Int?
        var identityFiles: [String] = []
        var certificateFiles: [String] = []
        /// As written (rest of the line): `none` is only the whole value.
        var proxyJump: String?
        var proxyCommand: String?

        var proxyJumpIsNone: Bool { proxyJump?.lowercased() == "none" }
        /// The jump host, as `ssh -G` prints it.
        var printedProxyJump: String? {
            guard let proxyJump, !proxyJumpIsNone else { return nil }
            return SSHConfigEvaluator.proxyJump(proxyJump)
        }
        /// Dynamic forwards live with the local ones, as in ssh (and
        /// duplicates are checked across both).
        var localForwards: [Forward] = []
        var remoteForwards: [Forward] = []
        var forwardAgent: String?
        var tag: String?
        var hostKeyAlias: String?
        var other: [String: [String]] = [:]
        var wantsFinalPass = false

        init(alias: String, environment: Environment) {
            self.alias = alias
            self.environment = environment
        }

        /// HostName with `%h` expanded (what `Match host` sees), not yet
        /// lowercased.
        var currentHostname: String {
            switch hostname {
            case .unset: return alias
            case .raw(let value): return SSHConfigEvaluator.expandHostname(value, alias: alias)
            case .resolved(let value): return value
            }
        }

        var resolvedHostname: String { currentHostname.lowercased() }

        func output() -> [String: [String]] {
            var values = other
            let hostname = resolvedHostname
            let port = self.port ?? 22
            values["host"] = [alias]
            values["hostname"] = [hostname]
            values["port"] = [String(port)]
            values["user"] = [user.map { expandUser($0, hostname: hostname, port: port) } ?? environment.localUser]
            values["identityfile"] = identityFiles.isEmpty ? SSHConfigEvaluator.defaultIdentityFiles : identityFiles
            if !certificateFiles.isEmpty { values["certificatefile"] = certificateFiles }
            if let printedProxyJump { values["proxyjump"] = [printedProxyJump] }
            if let proxyCommand, proxyCommand.lowercased() != "none" { values["proxycommand"] = [proxyCommand] }
            let dynamic = localForwards.filter { $0.connect == .socks }
            let local = localForwards.filter { $0.connect != .socks }
            if !dynamic.isEmpty { values["dynamicforward"] = dynamic.map { $0.listen.rendered } }
            if !local.isEmpty { values["localforward"] = local.map(\.rendered) }
            if !remoteForwards.isEmpty { values["remoteforward"] = remoteForwards.map(\.rendered) }
            values["forwardagent"] = [forwardAgent ?? "no"]
            return values
        }

        /// User's tokens, expanded once the config is fully read (so `%h`
        /// and `%p` are the final hostname and port).
        func expandUser(_ value: String, hostname: String, port: Int) -> String {
            let localHost = environment.localHostname
            let tokens: [Character: String] = [
                "%": "%", "d": environment.home, "h": hostname, "i": String(environment.uid),
                "j": printedProxyJump ?? "",
                "k": hostKeyAlias ?? alias, "L": String(localHost.prefix { $0 != "." }), "l": localHost,
                "n": alias, "p": String(port), "u": environment.localUser,
            ]
            return SSHConfigEvaluator.expand(value, tokens: tokens, variable: environment.variable) ?? value
        }
    }

    // MARK: Passes

    struct Pass {
        var state: State
        let final: Bool
        /// What `Host` patterns match: the alias as typed, or (final pass)
        /// the resolved hostname.
        let host: String
        let configPath: String

        static let maxDepth = 16

        mutating func run() {
            read(path: configPath, depth: 0, active: true, neverMatch: false)
        }

        mutating func read(path: String, depth: Int, active inherited: Bool, neverMatch: Bool) {
            guard depth <= Self.maxDepth, let text = state.environment.readFile(path) else { return }
            var active = inherited
            // "\r\n" is a single Character in Swift: split on both.
            for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" }) {
                guard let line = SSHConfigEvaluator.parseLine(String(rawLine)) else { continue }
                switch line.keyword {
                case "host":
                    active = !neverMatch && hostMatches(line.arguments)
                case "match":
                    active = matches(line.arguments) && !neverMatch
                case "include":
                    for pattern in line.arguments {
                        for file in includedFiles(pattern) {
                            read(path: file, depth: depth + 1, active: active, neverMatch: neverMatch || !active)
                        }
                    }
                default:
                    if active { apply(line) }
                }
            }
        }

        func hostMatches(_ patterns: [String]) -> Bool {
            var matched = false
            for pattern in patterns {
                if pattern.hasPrefix("!") {
                    if SSHConfigEvaluator.wildcardMatch(host, String(pattern.dropFirst())) { return false }
                } else if SSHConfigEvaluator.wildcardMatch(host, pattern) {
                    matched = true
                }
            }
            return matched
        }

        mutating func matches(_ arguments: [String]) -> Bool {
            guard !arguments.isEmpty else { return false }
            var result = true
            var index = 0
            while index < arguments.count {
                var criterion = arguments[index].lowercased()
                index += 1
                let negated = criterion.hasPrefix("!")
                if negated { criterion.removeFirst() }
                var value: Bool
                switch criterion {
                case "all":
                    value = true
                case "canonical", "final":
                    // Only a plain `final` asks for the final pass (`!final` doesn't).
                    if criterion == "final" && !negated { state.wantsFinalPass = true }
                    value = final
                default:
                    guard index < arguments.count else { return false }
                    let argument = arguments[index]
                    index += 1
                    switch criterion {
                    case "host":
                        value = SSHConfigEvaluator.patternListMatch(state.currentHostname, argument, ignoringCase: true)
                    case "originalhost":
                        value = SSHConfigEvaluator.patternListMatch(state.alias, argument, ignoringCase: true)
                    case "user":
                        value = SSHConfigEvaluator.patternListMatch(state.user ?? state.environment.localUser, argument, ignoringCase: false)
                    case "localuser":
                        value = SSHConfigEvaluator.patternListMatch(state.environment.localUser, argument, ignoringCase: false)
                    case "tagged":
                        value = SSHConfigEvaluator.patternListMatch(state.tag ?? "", argument, ignoringCase: false)
                    default:
                        // exec, localnetwork, version, sessiontype, command
                        // and anything unknown: can't (or won't) evaluate.
                        value = false
                    }
                }
                if negated { value.toggle() }
                if !value { result = false }
            }
            return result
        }

        func includedFiles(_ pattern: String) -> [String] {
            var path = SSHConfigEvaluator.expandTilde(pattern, home: state.environment.home)
            if !path.hasPrefix("/") {
                path = state.environment.home + "/.ssh/" + path
            }
            return state.environment.glob(path)
        }

        mutating func apply(_ line: Line) {
            let arguments = line.arguments
            guard let first = arguments.first else { return }
            switch line.keyword {
            case "hostname":
                guard arguments.count == 1, case .unset = state.hostname else { return }
                state.hostname = .raw(first)
            case "user":
                guard arguments.count == 1, state.user == nil else { return }
                state.user = first
            case "port":
                guard arguments.count == 1, state.port == nil, let port = SSHConfigEvaluator.port(first) else { return }
                state.port = port
            case "identityfile":
                guard arguments.count == 1, !state.identityFiles.contains(first) else { return }
                state.identityFiles.append(first)
            case "certificatefile":
                guard arguments.count == 1, !state.certificateFiles.contains(first) else { return }
                state.certificateFiles.append(first)
            case "proxyjump":
                guard state.proxyJump == nil, state.proxyCommand == nil else { return }
                state.proxyJump = line.rawArgument
            case "proxycommand":
                guard state.proxyCommand == nil, state.proxyJump == nil || state.proxyJumpIsNone else { return }
                state.proxyCommand = line.rawArgument
            case "localforward", "remoteforward", "dynamicforward":
                let remote = line.keyword == "remoteforward"
                let forward: Forward?
                if line.keyword == "dynamicforward" {
                    forward = arguments.count == 1 ? Forward.parse(listen: first, connect: nil) : nil
                } else if arguments.count == 2 {
                    forward = Forward.parse(listen: first, connect: arguments[1])
                } else if arguments.count == 1 && remote {
                    forward = Forward.parse(listen: first, connect: nil)
                } else {
                    forward = nil
                }
                guard let forward else { return }
                if remote {
                    if !state.remoteForwards.contains(forward) { state.remoteForwards.append(forward) }
                } else if !state.localForwards.contains(forward) {
                    state.localForwards.append(forward)
                }
            case "forwardagent":
                guard arguments.count == 1, state.forwardAgent == nil else { return }
                switch first.lowercased() {
                case "yes", "true": state.forwardAgent = "yes"
                case "no", "false": state.forwardAgent = "no"
                default:
                    let path = SSHConfigEvaluator.expandTilde(first, home: state.environment.home)
                    state.forwardAgent = SSHConfigEvaluator.expand(path, tokens: [:], variable: state.environment.variable) ?? path
                }
            case "tag":
                guard arguments.count == 1, state.tag == nil else { return }
                state.tag = first
            case "hostkeyalias":
                guard arguments.count == 1, state.hostKeyAlias == nil else { return }
                state.hostKeyAlias = first
            default:
                guard state.other[line.keyword] == nil else { return }
                state.other[line.keyword] = [arguments.joined(separator: " ")]
            }
        }
    }

    // MARK: Lines

    struct Line {
        /// Lowercased.
        let keyword: String
        let arguments: [String]
        /// Everything after the keyword, as written (ProxyCommand).
        let rawArgument: String
    }

    static let whitespace: Set<Character> = [" ", "\t", "\r", "\n", "\u{0C}"]

    /// One config line, split the way ssh's readconf does; nil for blank
    /// lines, comments and lines ssh would reject.
    static func parseLine(_ text: String) -> Line? {
        var line = Substring(text)
        while let last = line.last, whitespace.contains(last) { line.removeLast() }
        while let first = line.first, whitespace.contains(first) { line.removeFirst() }
        guard let first = line.first, first != "#" else { return nil }
        guard let end = line.firstIndex(where: { whitespace.contains($0) || $0 == "=" || $0 == "\"" }) else {
            return nil  // a keyword with no argument
        }
        let keyword = line[..<end].lowercased()
        var rest = line[end...]
        // One `=` may separate the keyword, with whitespace either side.
        while let c = rest.first, whitespace.contains(c) { rest.removeFirst() }
        if rest.first == "=" { rest.removeFirst() }
        while let c = rest.first, whitespace.contains(c) { rest.removeFirst() }
        // Command values (ProxyCommand) skip any further `=` too.
        var raw = rest
        while let c = raw.first, whitespace.contains(c) || c == "=" { raw.removeFirst() }
        guard !keyword.isEmpty, !rest.isEmpty, let arguments = splitArguments(String(rest)) else { return nil }
        return Line(keyword: keyword, arguments: arguments, rawArgument: String(raw))
    }

    /// ssh's argv_split: whitespace-separated, single or double quotes,
    /// backslash escapes for quotes, backslash and (unquoted) space; an
    /// unquoted `#` starting a word ends the line. nil on an unclosed quote.
    static func splitArguments(_ text: String) -> [String]? {
        let chars = Array(text)
        var arguments: [String] = []
        var i = 0
        while i < chars.count {
            if chars[i] == " " || chars[i] == "\t" { i += 1; continue }
            if chars[i] == "#" { break }
            var quote: Character?
            var word = ""
            while i < chars.count {
                let c = chars[i]
                if c == "\\", i + 1 < chars.count,
                   chars[i + 1] == "'" || chars[i + 1] == "\"" || chars[i + 1] == "\\" || (quote == nil && chars[i + 1] == " ") {
                    word.append(chars[i + 1])
                    i += 2
                    continue
                }
                if quote == nil && (c == " " || c == "\t") { break }
                if quote == nil && (c == "\"" || c == "'") {
                    quote = c
                } else if let open = quote, c == open {
                    quote = nil
                } else {
                    word.append(c)
                }
                i += 1
            }
            if quote != nil { return nil }
            arguments.append(word)
        }
        return arguments
    }

    // MARK: Matching

    /// ssh's match_pattern: `*` and `?` only.
    static func wildcardMatch(_ string: String, _ pattern: String) -> Bool {
        let s = Array(string.unicodeScalars), p = Array(pattern.unicodeScalars)
        var si = 0, pi = 0
        var starP = -1, starS = 0
        while si < s.count {
            if pi < p.count && (p[pi] == "?" || p[pi] == s[si]) {
                si += 1; pi += 1
            } else if pi < p.count && p[pi] == "*" {
                starP = pi; starS = si; pi += 1
            } else if starP >= 0 {
                pi = starP + 1; starS += 1; si = starS
            } else {
                return false
            }
        }
        while pi < p.count && p[pi] == "*" { pi += 1 }
        return pi == p.count
    }

    /// ssh's match_pattern_list: comma-separated patterns; any negated
    /// match fails the list, otherwise one positive match is needed.
    static func patternListMatch(_ string: String, _ list: String, ignoringCase: Bool) -> Bool {
        let subject = ignoringCase ? string.lowercased() : string
        var matched = false
        for entry in list.split(separator: ",", omittingEmptySubsequences: false) {
            var pattern = ignoringCase ? entry.lowercased() : String(entry)
            let negated = pattern.hasPrefix("!")
            if negated { pattern.removeFirst() }
            if wildcardMatch(subject, pattern) {
                if negated { return false }
                matched = true
            }
        }
        return matched
    }

    // MARK: Values

    /// ProxyJump as `ssh -G` prints it: the line as written up to any
    /// `#` (quotes kept), its last hop's `ssh://` dropped.
    static func proxyJump(_ raw: String) -> String {
        var value = Substring(raw.prefix { $0 != "#" })
        while let last = value.last, whitespace.contains(last) { value.removeLast() }
        let lastHopStart = value.lastIndex(of: ",").map { value.index(after: $0) } ?? value.startIndex
        if value[lastHopStart...].hasPrefix("ssh://") {
            var hop = value[lastHopStart...].dropFirst("ssh://".count)
            if hop.hasSuffix("/") { hop.removeLast() }
            value = value[..<lastHopStart] + hop
        }
        return String(value)
    }

    static func expandHostname(_ value: String, alias: String) -> String {
        expand(value, tokens: ["%": "%", "h": alias], variable: nil) ?? value
    }

    /// `%x` tokens and (when `variable` is given) `${VAR}`. nil for an
    /// unknown token or variable, as ssh fails on those.
    static func expand(_ value: String, tokens: [Character: String], variable: (@Sendable (String) -> String?)?) -> String? {
        var out = ""
        var chars = Substring(value)
        while let c = chars.first {
            chars.removeFirst()
            if c == "%" {
                guard let key = chars.first, let replacement = tokens[key] else { return nil }
                chars.removeFirst()
                out += replacement
            } else if c == "$", let variable, chars.first == "{" {
                guard let close = chars.firstIndex(of: "}") else { return nil }
                let name = String(chars[chars.index(after: chars.startIndex)..<close])
                guard let replacement = variable(name) else { return nil }
                out += replacement
                chars = chars[chars.index(after: close)...]
            } else {
                out.append(c)
            }
        }
        return out
    }

    static func expandTilde(_ path: String, home: String) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + path.dropFirst() }
        return path
    }

    private static let servicesLock = NSLock()

    /// A port number or a service name (ssh's a2port), 1–65535.
    static func port(_ text: String) -> Int? {
        if let number = Int(text) { return (1...65535).contains(number) ? number : nil }
        return serviceNamePort(text)
    }

    static func serviceNamePort(_ name: String) -> Int? {
        guard !name.isEmpty, name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { return nil }
        return servicesLock.withLock {
            guard let entry = getservbyname(name, "tcp") else { return nil }
            return Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: entry.pointee.s_port)))
        }
    }

    // MARK: Forwards

    enum Endpoint: Hashable {
        case port(host: String?, port: Int)
        case path(String)
        /// A dynamic (SOCKS) forward's "connect" side.
        case socks

        var rendered: String {
            switch self {
            case .port(nil, let port): return String(port)
            case .port(let host?, let port): return "[\(host)]:\(port)"
            case .path(let path): return path
            case .socks: return "[socks]:0"
            }
        }
    }

    struct Forward: Hashable {
        let listen: Endpoint
        let connect: Endpoint

        var rendered: String { "\(listen.rendered) \(connect.rendered)" }

        static func parse(listen: String, connect: String?) -> Forward? {
            guard let listenEnd = endpoint(listen, requireHost: false) else { return nil }
            guard let connect else { return Forward(listen: listenEnd, connect: .socks) }
            guard let connectEnd = endpoint(connect, requireHost: true) else { return nil }
            return Forward(listen: listenEnd, connect: connectEnd)
        }

        /// `[host:]port` (host may be `[bracketed]`) or a socket path.
        static func endpoint(_ text: String, requireHost: Bool) -> Endpoint? {
            if text.contains("/") && !text.hasPrefix("[") && !text.contains(":") { return .path(text) }
            var fields: [String] = []
            var current = ""
            var bracket = false
            for c in text {
                if c == "[" && current.isEmpty && !bracket { bracket = true; continue }
                if c == "]" && bracket { bracket = false; continue }
                if c == ":" && !bracket { fields.append(current); current = ""; continue }
                current.append(c)
            }
            if bracket { return nil }
            fields.append(current)
            switch fields.count {
            case 1 where !requireHost:
                guard let port = portOrZero(fields[0]) else { return nil }
                return .port(host: nil, port: port)
            case 2:
                guard !fields[0].isEmpty || !requireHost, let port = portOrZero(fields[1]) else { return nil }
                return .port(host: fields[0].isEmpty ? nil : fields[0], port: port)
            default:
                return nil
            }
        }

        static func portOrZero(_ text: String) -> Int? {
            if text == "0" { return 0 }
            return SSHConfigEvaluator.port(text)
        }
    }
}
