import Foundation
import RelaySSH
import RelayTestSupport
import Testing
@testable import RelayCore

/// Regressions found in the pre-release review: scripts that must read the
/// same in every login shell, the authorized_keys rewrite, and what sync
/// does with hosts it can't read or wouldn't accept.
@Suite("Hardening")
struct HardeningTests {
    static func run(_ executable: String, _ arguments: [String], stdin: Data = Data(), environment: [String: String]? = nil) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        input.fileHandleForWriting.write(stdin)
        try input.fileHandleForWriting.close()
        let out = output.fileHandleForReading.readDataToEndOfFile()
        let err = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: out, as: UTF8.self), String(decoding: err, as: UTF8.self))
    }

    // MARK: Scripts through any login shell

    /// sshd hands the command line to the user's login shell: a
    /// multi-line script (quotes, a here-document, non-ASCII) must arrive
    /// at /bin/sh whole from each of them. csh and tcsh refused the
    /// quoted form outright ("Unmatched '").
    @Test(arguments: ["/bin/sh", "/bin/bash", "/bin/zsh", "/bin/dash", "/bin/ksh", "/bin/csh", "/bin/tcsh"])
    func scriptsSurviveEveryLoginShell(shell: String) throws {
        let script = """
        set -eu
        say() { printf '%s|' "$1"; }
        say 'single'"'"'quote'
        say "dollar $0 and $1"
        say 'bang! star* hash# tilde~ é 日本'
        cat <<'RELAY_EOF'
        here $HOME `not run`
        RELAY_EOF
        cat
        exit 7
        """
        let line = RemoteShCommand.line(script, arguments: ["zero", "one"])
        // Only what every shell passes through untouched.
        #expect(!line.contains("\n"))
        let result = try Self.run(shell, ["-c", line], stdin: Data("from stdin".utf8))
        #expect(result.status == 7, "\(result.stderr)")
        #expect(result.stdout == "single'quote|dollar zero and one|bang! star* hash# tilde~ é 日本|here $HOME `not run`\nfrom stdin")
    }

    @Test(arguments: ["plain", "sp ace/'q'/\"d\"/$(x)/`y`/#z", "trailing newline\n", "é 日本語 🙂", "-n", "%s %d \\n \\101"])
    func assignmentsCarryAnyValue(value: String) throws {
        let script = RemoteShCommand.assignment("p", value: value) + #"; printf '%s' "$p""#
        for shell in ["/bin/sh", "/bin/tcsh"] {
            let result = try Self.run(shell, ["-c", RemoteShCommand.line(script)])
            #expect(result.status == 0)
            #expect(result.stdout == value)
        }
    }

    // MARK: authorized_keys

    static let keyA = "AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
    static let keyB = "AAAAC3NzaC1lZDI1NTE5AAAAIBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"

    func removeKey(_ blob: String, home: URL) throws -> (status: Int32, stdout: String, stderr: String) {
        try Self.run("/bin/sh", ["-s"], stdin: Data(SSHKeyInstaller.removeScript(publicKeyBlob: blob).utf8),
                     environment: ["HOME": home.path, "PATH": "/usr/bin:/bin"])
    }

    func home(authorizedKeys: String?) throws -> (home: URL, file: URL) {
        let home = try makeScratchDirectory("authkeys")
        let ssh = home.appendingPathComponent(".ssh", isDirectory: true)
        try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true)
        let file = ssh.appendingPathComponent("authorized_keys")
        if let authorizedKeys {
            try authorizedKeys.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: file.path)
        }
        return (home, file)
    }

    @Test func removingAKeyKeepsEveryOtherLine() throws {
        let original = "# mine\nssh-ed25519 \(Self.keyB) other\n\nrestrict ssh-ed25519 \(Self.keyA) Relay\nssh-ed25519 \(Self.keyA) again"
        let (home, file) = try home(authorizedKeys: original)
        let result = try removeKey(Self.keyA, home: home)
        #expect(result.status == 0 && result.stdout.contains("RTERM_STATUS=ok"), "\(result.stderr)")
        #expect(try String(contentsOf: file, encoding: .utf8) == "# mine\nssh-ed25519 \(Self.keyB) other\n\n")
        // The same file, as it was: not replaced by one with other permissions.
        #expect((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int) == 0o640)
        #expect(try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path) == ["authorized_keys"])
    }

    @Test func removingTheOnlyKeyLeavesAnEmptyFile() throws {
        let (home, file) = try home(authorizedKeys: "ssh-ed25519 \(Self.keyA) Relay\n")
        let result = try removeKey(Self.keyA, home: home)
        #expect(result.status == 0 && result.stdout.contains("RTERM_STATUS=ok"))
        #expect(try String(contentsOf: file, encoding: .utf8) == "")
    }

    @Test func removingAKeyThatIsntThereChangesNothing() throws {
        let original = "ssh-ed25519 \(Self.keyB) other"
        let (home, file) = try home(authorizedKeys: original)
        #expect(try removeKey(Self.keyA, home: home).stdout.contains("RTERM_STATUS=ok"))
        #expect(try String(contentsOf: file, encoding: .utf8) == original)
        let (bare, _) = try self.home(authorizedKeys: nil)
        #expect(try removeKey(Self.keyA, home: bare).stdout.contains("RTERM_STATUS=ok"))
    }

    /// The rewrite goes through a file beside authorized_keys. When that
    /// can't be written (a full disk, a quota), the keys must stay exactly
    /// as they were: the script used to carry on and empty the file,
    /// locking a key-only user out.
    @Test func aFailedRewriteLeavesTheKeysAlone() throws {
        let original = "ssh-ed25519 \(Self.keyB) other\nssh-ed25519 \(Self.keyA) Relay\n"
        let (home, file) = try home(authorizedKeys: original)
        let ssh = file.deletingLastPathComponent().path
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: ssh)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: ssh) }
        let result = try removeKey(Self.keyA, home: home)
        #expect(result.status == 26)
        #expect(result.stdout.contains("RTERM_STATUS=failed"))
        #expect(try String(contentsOf: file, encoding: .utf8) == original)
    }

    // MARK: Hosts sync can't read, or wouldn't accept

    static func synced(_ alias: String, hostname: String = "box.example.com") -> SyncItem {
        .host(SyncedHost(host: SSHHost(alias: alias, hostname: hostname, user: "me")))
    }

    /// A host record a newer build wrote (an auth this build doesn't
    /// know): kept in the file as it is, and never mistaken for a host
    /// the user removed — which sync would delete on every device.
    @Test func anUnreadableHostIsKeptAndNeverSyncedAsDeleted() throws {
        let json = #"""
        {"projects": [], "hosts": [
          {"alias": "known", "hostname": "known.example.com"},
          {"alias": "future", "hostname": "future.example.com", "auth": {"passkey": {"id": 7, "ratio": 1.5, "on": true, "tags": ["a", null]}}}
        ]}
        """#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var state = try decoder.decode(PersistedState.self, from: Data(json.utf8))
        #expect(state.hosts?.map(\.alias) == ["known"])
        #expect(state.unreadableHostAliases == ["future"])

        // Saved and loaded again, the record is still there, whole.
        state.hosts?.append(SSHHost(alias: "added", hostname: "added.example.com"))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let saved = try encoder.encode(state)
        let reloaded = try decoder.decode(PersistedState.self, from: saved)
        #expect(reloaded.hosts?.map(\.alias) == ["known", "added"])
        #expect(reloaded.unreadableHosts == state.unreadableHosts)
        let original = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let written = try #require(try JSONSerialization.jsonObject(with: saved) as? [String: Any])
        let future = { (object: [String: Any]) in
            (object["hosts"] as? [[String: Any]])?.first { $0["alias"] as? String == "future" } as NSDictionary?
        }
        #expect(future(written) != nil && future(written) == future(original))

        // Sync had it recorded; this build's items don't include it.
        var sync = SyncState()
        _ = sync.recordLocal([Self.synced("known"), Self.synced("future")], now: SyncTests.t0)
        let futureName = SyncItem.recordName(hostAlias: "future")
        sync.entries[futureName]?.pending = false
        let payload = sync.entries[futureName]?.payload
        let keeping = Set(state.unreadableHostAliases.map(SyncItem.recordName(hostAlias:)))
        let changed = sync.recordLocal([Self.synced("known")], keeping: keeping, now: SyncTests.t0 + 60)
        #expect(changed.isEmpty)
        #expect(sync.entries[futureName]?.payload == payload)
        #expect(sync.entries[futureName]?.pending == false)
        // Without that, it's a deletion — the bug.
        #expect(sync.recordLocal([Self.synced("known")], now: SyncTests.t0 + 120) == [futureName])
    }

    /// A host no device would accept isn't sent, and isn't a deletion of
    /// whatever iCloud has under its name.
    @Test func anInvalidHostIsNeitherSentNorDeleted() {
        var sync = SyncState()
        _ = sync.recordLocal([Self.synced("mac")], now: SyncTests.t0)
        let name = SyncItem.recordName(hostAlias: "mac")
        sync.entries[name]?.pending = false
        let changed = sync.recordLocal([Self.synced("mac", hostname: "my mac.local")], now: SyncTests.t0 + 60)
        #expect(changed.isEmpty)
        #expect(sync.entries[name]?.payload != nil && sync.entries[name]?.pending == false)
        let both = [Self.synced("mac", hostname: "my mac.local"), Self.synced("new", hostname: "user@host")]
        #expect(sync.recordLocal(both, now: SyncTests.t0 + 120) == [])
        #expect(sync.entries[SyncItem.recordName(hostAlias: "new")] == nil)
    }

    /// What iCloud saved is compared as it was sent. Reading it back
    /// (which validates) left a record this build wouldn't accept pending
    /// for good: sent, saved, and sent again, without end.
    @Test func aSavedRecordIsSettledEvenIfItWouldntParse() throws {
        var sync = SyncState()
        let name = SyncItem.recordName(hostAlias: "mac")
        let payload = try SyncPayload.canonical(Self.synced("mac", hostname: "my mac.local"))
        sync.entries[name] = SyncState.Entry(
            kind: .host, payload: payload, modifiedAt: SyncTests.t0, pending: true, serverFields: nil, extra: nil)
        let outgoing = try #require(sync.outgoing(name))
        #expect(throws: (any Error).self) { try SyncPayload.parse(outgoing.envelope, kind: .host, recordName: name) }
        #expect(sync.noteSaved(name, envelope: outgoing.envelope, serverFields: Data([1])) == false)
        #expect(sync.pendingNames.isEmpty)
    }

    // MARK: tmux without a UTF-8 locale

    static let tmuxPath: String? = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    /// A host that takes no LANG from the client (sshd's AcceptEnv) runs
    /// Relay's scripts in the C locale, where tmux prints every tab and
    /// non-ASCII character as `_`: the session list (tab-separated) came
    /// back unreadable, so sessions that existed weren't shown. And tmux
    /// expands formats in a start directory: a folder named `c#Sharp`
    /// started its sessions somewhere else. Real tmux, private socket.
    @Test(.enabled(if: tmuxPath != nil, "needs tmux"))
    func sessionsAreListedWithoutALocaleAndStartWhereAsked() throws {
        let tmux = try #require(Self.tmuxPath)
        // Short: the tmux socket path has a 104-byte limit.
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("relay-ht-\(UUID().uuidString.prefix(6))", isDirectory: true)
        let folder = root.appendingPathComponent("c#Sharp #{pane_pid} é", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let sockets = root.appendingPathComponent("s", isDirectory: true)
        try FileManager.default.createDirectory(at: sockets, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // No LANG, no LC_*: the C locale.
        let environment = ["HOME": root.path, "PATH": "/usr/bin:/bin", "TMUX_TMPDIR": sockets.path, "SHELL": "/bin/sh"]
        defer {
            _ = try? Self.run(tmux, ["kill-server"], environment: environment)
            try? FileManager.default.removeItem(at: root)
        }
        let projectID = UUID(), sessionID = UUID()
        let name = "rterm-0123456789abcdef"
        let create = SSHTmuxScripts.createSession(.init(
            tmuxName: name, windowName: "w", pathInput: folder.path, knownTmuxPath: tmux, launchCommand: nil,
            environment: [("RTERM_SESSION_NAME", "é")],
            metadata: [
                ("@rterm_schema", TmuxSessionCodec.schemaVersion),
                ("@rterm_project_id", projectID.uuidString),
                ("@rterm_session_id", sessionID.uuidString),
                ("@rterm_session_name_b64", TmuxSessionCodec.encodeDisplayName("naïve ✳")),
                ("@rterm_created_at", "1700000000"),
            ]))
        let created = try Self.run("/bin/sh", ["-s"], stdin: Data(create.utf8), environment: environment)
        #expect(created.stdout.contains("RTERM_STATUS=ok"), "\(created.stdout) \(created.stderr)")

        let list = SSHTmuxScripts.listSessions(knownTmuxPath: tmux)
        let listed = try Self.run("/bin/sh", ["-s"], stdin: Data(list.utf8), environment: environment)
        let sessions = listed.stdout.split(separator: "\n").compactMap { TmuxSessionCodec.parse(line: String($0)) }
        #expect(sessions.map(\.tmuxName) == [name], "\(listed.stdout)")
        #expect(sessions.first?.displayName == "naïve ✳")
        #expect(sessions.first?.sessionID.uuid == sessionID)

        let cwd = try Self.run(tmux, ["-u", "display-message", "-p", "-t", name, "-F", "#{pane_current_path}"], environment: environment)
        let real = try #require(realpath(folder.path, nil))
        defer { free(real) }
        #expect(cwd.stdout.trimmingCharacters(in: .newlines) == String(cString: real))
    }
}
