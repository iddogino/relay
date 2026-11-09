import Foundation
import RelaySSH

/// The tmux builds Relay carries (`Scripts/build-tmux.sh`): static Linux
/// binaries and a universal macOS one, gzip'd, plus a few terminfo entries
/// — so a host without tmux can get one with no sudo and no package
/// manager.
public struct TmuxBundle: Sendable {
    public let directory: URL
    public let version: String
    let files: [String: Manifest.File]

    struct Manifest: Decodable {
        struct File: Decodable {
            /// For the tmux binaries: of the unpacked binary (checked on
            /// the host). For the terminfo tarball: of the tarball.
            var uncompressedSha256: String?
            var sha256: String?
            var size: Int?
        }
        var version: String
        var files: [String: File]
    }

    /// The bundle in `directory` (its `manifest.json`), or nil when there's
    /// none (a build made without `build-tmux.sh`).
    public init?(directory: URL) {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("manifest.json")),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else { return nil }
        self.directory = directory
        self.version = manifest.version
        self.files = manifest.files
    }

    func binary(for platform: HostPlatform) -> (url: URL, sha256: String)? {
        guard let name = platform.bundledAssetName, let file = files[name],
              let sum = file.uncompressedSha256 else { return nil }
        let url = directory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return (url, sum)
    }

    var terminfo: (url: URL, sha256: String?)? {
        let url = directory.appendingPathComponent("terminfo.tar.gz")
        return FileManager.default.fileExists(atPath: url.path) ? (url, files["terminfo.tar.gz"]?.sha256) : nil
    }

    public func supports(_ platform: HostPlatform) -> Bool {
        binary(for: platform) != nil
    }
}

/// What a host is and what it has, for installing tmux on it.
public struct HostPlatform: Sendable, Equatable {
    public enum Sudo: String, Sendable, Equatable {
        case root, passwordless, needsPassword, unavailable
    }

    /// `uname -s`, e.g. "Linux", "Darwin".
    public var os: String
    /// `uname -m`, e.g. "x86_64", "aarch64", "arm64".
    public var arch: String
    /// The tmux Relay would use there, if any.
    public var tmuxPath: String?
    public var tmuxVersion: String?
    /// The package manager's command (e.g. "apt-get", "/opt/homebrew/bin/brew").
    public var packageManager: String?
    public var sudo: Sudo
    /// gzip and tar, which the bundled install unpacks with.
    public var canUnpack: Bool

    /// Which of the bundled binaries runs there. Pure; unit-tested.
    public var bundledAssetName: String? {
        guard canUnpack else { return nil }
        switch (os, arch) {
        case ("Darwin", _): return "tmux-darwin-universal.gz"
        case ("Linux", "x86_64"), ("Linux", "amd64"): return "tmux-linux-x86_64.gz"
        case ("Linux", "aarch64"), ("Linux", "arm64"): return "tmux-linux-aarch64.gz"
        default: return nil
        }
    }

    /// The package manager command that installs tmux system-wide, or nil
    /// when there's no package manager this can use. Pure; unit-tested.
    public var packageInstallCommand: String? {
        guard let manager = packageManager else { return nil }
        let name = (manager as NSString).lastPathComponent
        if name == "brew" { return "\(POSIXShellQuote.quote(manager)) install tmux" }
        let sudo: String
        switch self.sudo {
        case .root: sudo = ""
        case .passwordless, .needsPassword: sudo = "sudo "
        case .unavailable: return nil
        }
        switch name {
        case "apt-get": return "\(sudo)apt-get update && \(sudo)apt-get install -y tmux"
        case "dnf", "yum": return "\(sudo)\(name) install -y tmux"
        case "apk": return "\(sudo)apk add tmux"
        case "pacman": return "\(sudo)pacman -S --noconfirm tmux"
        case "zypper": return "\(sudo)zypper install -y tmux"
        default: return nil
        }
    }

    /// Whether `packageInstallCommand` can run unattended (no password
    /// prompt) — otherwise the user runs it themselves.
    public var packageInstallIsUnattended: Bool {
        guard packageInstallCommand != nil else { return false }
        if let manager = packageManager, (manager as NSString).lastPathComponent == "brew" { return true }
        return sudo == .root || sudo == .passwordless
    }
}

/// Installs tmux on a host for Relay: the bundled build into
/// `~/.relay/tmux/<version>/`, behind a `~/.relay/bin/tmux` wrapper that
/// points it at Relay's terminfo entries — linked into `~/.local/bin` when
/// nothing's there, so plain `ssh host; tmux attach` finds it too. Never
/// replaces a tmux the host already has.
public enum TmuxInstaller {
    public enum Failure: Error, LocalizedError, Equatable {
        case alreadyInstalled(String)
        case unsupported(String)
        case checksumMismatch
        case wontRun(String)
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .alreadyInstalled(let path): return "tmux is already installed there (\(path))."
            case .unsupported(let what): return "Relay doesn\u{2019}t carry a tmux for \(what)."
            case .checksumMismatch: return "The uploaded tmux didn\u{2019}t arrive intact. Try again."
            case .wontRun(let detail): return "tmux was installed but won\u{2019}t run there. \(detail)"
            case .failed(let detail): return "Couldn\u{2019}t install tmux. \(detail)"
            }
        }
    }

    public static let installRoot = "$HOME/.relay"
    public static let wrapperPath = "$HOME/.relay/bin/tmux"

    // MARK: Probe

    static let probeScript = """
        os=$(uname -s 2>/dev/null || printf unknown)
        arch=$(uname -m 2>/dev/null || printf unknown)
        printf 'RTERM_OS=%s\\nRTERM_ARCH=%s\\n' "$os" "$arch"
        \(SSHTmuxScripts.findTmuxFunction)
        if tmux_path=$(find_tmux); then
          printf 'RTERM_TMUX=%s\\n' "$tmux_path"
          printf 'RTERM_TMUX_VERSION=%s\\n' "$("$tmux_path" -V 2>/dev/null || printf unknown)"
        fi
        pm=
        for m in brew /opt/homebrew/bin/brew /usr/local/bin/brew apt-get dnf yum apk pacman zypper; do
          if command -v "$m" >/dev/null 2>&1; then pm=$(command -v "$m"); break; fi
        done
        printf 'RTERM_PM=%s\\n' "$pm"
        if [ "$(id -u)" = 0 ]; then s=root
        elif command -v sudo >/dev/null 2>&1; then
          if sudo -n true >/dev/null 2>&1; then s=passwordless; else s=needsPassword; fi
        else s=unavailable; fi
        printf 'RTERM_SUDO=%s\\n' "$s"
        if command -v gzip >/dev/null 2>&1 && command -v tar >/dev/null 2>&1; then u=yes; else u=no; fi
        printf 'RTERM_UNPACK=%s\\n' "$u"
        """

    /// Pure; unit-tested.
    static func parseProbe(_ stdout: String) -> HostPlatform {
        let markers = SSHCommandRunner.CommandResult(exitCode: 0, stdout: stdout, stderr: "").markers()
        func value(_ key: String) -> String? {
            guard let v = markers[key], !v.isEmpty else { return nil }
            return v
        }
        return HostPlatform(
            os: value("RTERM_OS") ?? "unknown",
            arch: value("RTERM_ARCH") ?? "unknown",
            tmuxPath: value("RTERM_TMUX"),
            tmuxVersion: value("RTERM_TMUX_VERSION"),
            packageManager: value("RTERM_PM"),
            sudo: value("RTERM_SUDO").flatMap(HostPlatform.Sudo.init(rawValue:)) ?? .unavailable,
            canUnpack: value("RTERM_UNPACK") == "yes")
    }

    public static func probe(target: SSHTarget, pool: SSHConnectionPool) async throws -> HostPlatform {
        let result = try await pool.exec(
            target: target, command: "/bin/sh -s", stdin: Data(probeScript.utf8), timeout: .seconds(20))
        guard result.exitCode == 0 else {
            throw Failure.failed(SSHTmuxRuntimeProvider.sanitizedStderr(String(decoding: result.stderr, as: UTF8.self)))
        }
        return parseProbe(String(decoding: result.stdout, as: UTF8.self))
    }

    // MARK: Bundled install

    /// Unpacks the gzip'd binary arriving on stdin, checks it, and moves it
    /// into place.
    /// `sha256 FILE` prints the file's SHA-256, or nothing on a host with
    /// no tool for it. The files are gzip'd, and gzip checks its own CRC as
    /// it unpacks (failing the script under `set -e`), so a truncated or
    /// corrupted upload is caught either way.
    static let sha256Function = """
        sha256() {
          if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
          elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1
          elif command -v openssl >/dev/null 2>&1; then openssl dgst -sha256 -r "$1" | cut -d' ' -f1
          fi
        }
        """

    static func binaryScript(version: String, sha256: String) -> String {
        """
        set -eu
        \(sha256Function)
        dir="$HOME/.relay/tmux/\(version)"
        mkdir -p "$dir"
        tmp="$dir/tmux.part.$$"
        trap 'rm -f "$tmp"' EXIT
        gzip -dc > "$tmp"
        sum=$(sha256 "$tmp")
        if [ -n "$sum" ] && [ "$sum" != \(POSIXShellQuote.quote(sha256)) ]; then printf 'RTERM_STATUS=bad_checksum\\n'; exit 31; fi
        chmod 755 "$tmp"
        mv -f "$tmp" "$dir/tmux"
        printf 'RTERM_STATUS=ok\\n'
        """
    }

    /// Checks and unpacks the terminfo tarball arriving on stdin. Saved
    /// first, so a failed gzip isn't hidden by the pipe into tar.
    static func terminfoScript(sha256: String?) -> String {
        """
        set -eu
        \(sha256Function)
        mkdir -p "$HOME/.relay/terminfo"
        tmp="$HOME/.relay/terminfo.part.$$"
        trap 'rm -f "$tmp" "$tmp.tar"' EXIT
        cat > "$tmp"
        sum=$(sha256 "$tmp")
        expected=\(POSIXShellQuote.quote(sha256 ?? ""))
        if [ -n "$expected" ] && [ -n "$sum" ] && [ "$sum" != "$expected" ]; then printf 'RTERM_STATUS=bad_checksum\\n'; exit 31; fi
        gzip -dc "$tmp" > "$tmp.tar"
        tar -xf "$tmp.tar" -C "$HOME/.relay/terminfo"
        printf 'RTERM_STATUS=ok\\n'
        """
    }

    /// Writes the wrapper, links it into ~/.local/bin when that's free,
    /// and runs it.
    static func wrapperScript(version: String) -> String {
        """
        set -eu
        mkdir -p "$HOME/.relay/bin"
        w="$HOME/.relay/bin/tmux"
        cat > "$w.part" <<'RELAY_EOF'
        #!/bin/sh
        # Installed by Relay: its own tmux build, with the terminfo entries it
        # needs. Remove ~/.relay to uninstall.
        TERMINFO_DIRS="$HOME/.relay/terminfo${TERMINFO_DIRS:+:$TERMINFO_DIRS}:/etc/terminfo:/lib/terminfo:/usr/share/terminfo"
        export TERMINFO_DIRS
        exec "$HOME/.relay/tmux/\(version)/tmux" "$@"
        RELAY_EOF
        chmod 755 "$w.part"
        mv -f "$w.part" "$w"
        linked=no
        if [ ! -e "$HOME/.local/bin/tmux" ] && [ ! -L "$HOME/.local/bin/tmux" ]; then
          mkdir -p "$HOME/.local/bin" && ln -s "$w" "$HOME/.local/bin/tmux" && linked=yes
        fi
        if ! v=$("$w" -V 2>&1); then printf 'RTERM_STATUS=wont_run\\n'; printf '%s\\n' "$v" >&2; exit 32; fi
        printf 'RTERM_STATUS=ok\\nRTERM_TMUX=%s\\nRTERM_TMUX_VERSION=%s\\nRTERM_LINKED=%s\\n' "$w" "$v" "$linked"
        """
    }

    public struct Installed: Sendable, Equatable {
        /// Where it is on the host (the wrapper).
        public let path: String
        /// Its `-V` line.
        public let version: String
        /// Whether it was linked into ~/.local/bin.
        public let linked: Bool
    }

    /// Installs the bundled tmux on `target`, whose platform `probe`
    /// reported.
    public static func installBundled(
        target: SSHTarget, pool: SSHConnectionPool, bundle: TmuxBundle, platform: HostPlatform,
        replacingExisting: Bool = false
    ) async throws -> Installed {
        if let existing = platform.tmuxPath, !replacingExisting { throw Failure.alreadyInstalled(existing) }
        guard let binary = bundle.binary(for: platform) else {
            throw Failure.unsupported(platform.canUnpack ? "\(platform.os) on \(platform.arch)" : "a host without gzip and tar")
        }
        func run(_ script: String, input: SSHExecInput) async throws -> [String: String] {
            let result = try await pool.exec(
                target: target, command: "/bin/sh -c \(POSIXShellQuote.quote(script))", input: input,
                timeout: .seconds(120))
            let stdout = String(decoding: result.stdout, as: UTF8.self)
            let markers = SSHCommandRunner.CommandResult(exitCode: result.exitCode, stdout: stdout, stderr: "").markers()
            let stderr = SSHTmuxRuntimeProvider.sanitizedStderr(String(decoding: result.stderr, as: UTF8.self))
            switch (result.exitCode, markers["RTERM_STATUS"]) {
            case (0, "ok"): return markers
            case (31, _): throw Failure.checksumMismatch
            case (32, _): throw Failure.wontRun(stderr)
            default: throw Failure.failed(stderr.isEmpty ? "It exited with status \(result.exitCode)." : stderr)
            }
        }
        _ = try await run(binaryScript(version: bundle.version, sha256: binary.sha256), input: .file(binary.url, onProgress: nil))
        if let terminfo = bundle.terminfo {
            _ = try await run(terminfoScript(sha256: terminfo.sha256), input: .file(terminfo.url, onProgress: nil))
        }
        let markers = try await run(wrapperScript(version: bundle.version), input: .data(Data()))
        return Installed(
            path: markers["RTERM_TMUX"] ?? wrapperPath,
            version: markers["RTERM_TMUX_VERSION"] ?? "tmux \(bundle.version)",
            linked: markers["RTERM_LINKED"] == "yes")
    }

    /// Runs the package manager's install where it needs no password.
    public static func installWithPackageManager(
        target: SSHTarget, pool: SSHConnectionPool, platform: HostPlatform
    ) async throws -> String {
        guard platform.packageInstallIsUnattended, let command = platform.packageInstallCommand else {
            throw Failure.failed("Installing with the package manager needs a password there.")
        }
        // A login shell, so Homebrew's PATH applies.
        let script = "export HOMEBREW_NO_AUTO_UPDATE=1; \(command)"
        let result = try await pool.exec(
            target: target, command: "/bin/sh -lc \(POSIXShellQuote.quote(script))", stdin: Data(),
            timeout: .seconds(600))
        guard result.exitCode == 0 else {
            let stderr = SSHTmuxRuntimeProvider.sanitizedStderr(String(decoding: result.stderr, as: UTF8.self))
            throw Failure.failed(stderr.isEmpty ? "It exited with status \(result.exitCode)." : stderr)
        }
        return command
    }
}
