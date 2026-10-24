import AppKit
import SwiftUI
import RelayCore

/// Add or edit one of Relay's hosts. Creating offers two routes: import an
/// entry from `~/.ssh/config` (prefills the form for review), or fill the
/// form by hand.
struct HostEditorSheet: View {
    enum Mode {
        case create
        case edit(SSHHost)
    }

    @Bindable var model: AppModel
    let mode: Mode
    /// Called after a successful save (the project editor selects the new
    /// host with it).
    var onSave: ((SSHHost) -> Void)?

    private enum Tab: Hashable { case importConfig, form }

    @State private var tab: Tab = .form
    @State private var alias = ""
    @State private var hostname = ""
    @State private var port = ""
    @State private var user = ""
    @State private var authKind: AuthKind = .automatic
    @State private var keyPath = ""
    @State private var certificatePath = ""
    @State private var password = ""
    @State private var hasStoredPassword = false
    @State private var inheritedOptions: [String] = []
    @State private var testState: TestState = .idle
    @State private var saveError: String?
    @Environment(\.dismiss) private var dismiss

    enum AuthKind: Hashable { case automatic, keyFile, password }

    enum TestState: Equatable {
        case idle
        case running
        case finished(SSHConnectionTest.Outcome)
    }

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(isEditing ? "Edit Host" : "Add Host")
                .font(.title3.weight(.semibold))
                .padding(.bottom, 14)

            if !isEditing {
                Picker("", selection: $tab) {
                    Text("Import from SSH Config").tag(Tab.importConfig)
                    Text("New Host").tag(Tab.form)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.bottom, 14)
            }

            switch tab {
            case .importConfig:
                SSHConfigImportList(
                    existing: Set(model.hosts.map(\.alias)),
                    onPick: applyImport)
                    .frame(height: 300)
            case .form:
                form
            }

            HStack {
                if tab == .form {
                    testButton
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if tab == .form {
                    Button(isEditing ? "Save" : "Add Host") { Task { await save() } }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(candidate == nil)
                }
            }
            .padding(.top, 16)
        }
        .padding(20)
        .frame(width: 500)
        .onAppear(perform: populate)
        .onChange(of: candidate) { testState = .idle }
    }

    // MARK: Form

    @ViewBuilder private var form: some View {
        Form {
            TextField("Name", text: $alias, prompt: Text("my-server"))
                .disabled(isEditing)
                .help(isEditing ? "A host's name identifies it to its projects and can't change." : "How the host appears in Relay.")
            TextField("Hostname", text: $hostname, prompt: Text("server.example.com or 10.0.0.5"))
            TextField("Port", text: $port, prompt: Text("22"))
            TextField("User", text: $user, prompt: Text(NSUserName()))

            Picker("Authentication", selection: $authKind) {
                Text("Automatic (SSH agent & default keys)").tag(AuthKind.automatic)
                Text("Key File").tag(AuthKind.keyFile)
                Text("Password").tag(AuthKind.password)
            }
            switch authKind {
            case .automatic:
                EmptyView()
            case .keyFile:
                LabeledContent("Private key") {
                    PathField(path: $keyPath, prompt: "~/.ssh/id_ed25519", title: "Choose a private key")
                }
                LabeledContent("Certificate") {
                    PathField(path: $certificatePath, prompt: "optional", title: "Choose an SSH certificate")
                }
            case .password:
                SecureField("Password", text: $password,
                            prompt: Text(hasStoredPassword ? "Saved in Keychain" : ""))
                Text("Saved in your Keychain. Password sign-in works in the terminal now; background features (session list, status) need Relay's built-in SSH client, coming next — use a key until then.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.columns)
        .textFieldStyle(.roundedBorder)

        if !inheritedOptions.isEmpty {
            notice(systemImage: "info.circle", tint: .blue) {
                Text("Also set for this host in your ssh config: \(inheritedOptions.joined(separator: ", ")). Relay keeps using them on this Mac, but they won't carry over to other devices.")
            }
        }
        if let validationMessage {
            notice(systemImage: "exclamationmark.triangle.fill", tint: .orange) { Text(validationMessage) }
        }
        if let saveError {
            notice(systemImage: "exclamationmark.triangle.fill", tint: .orange) { Text(saveError) }
        }
        testResult
    }

    private func notice<Content: View>(systemImage: String, tint: Color, @ViewBuilder content: () -> Content) -> some View {
        Label {
            content()
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage).foregroundStyle(tint)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .padding(.top, 12)
    }

    // MARK: Test connection

    private var testButton: some View {
        Button {
            Task { await runTest(trustNewHostKey: false) }
        } label: {
            HStack(spacing: 6) {
                if testState == .running { ProgressView().controlSize(.small) }
                Text("Test Connection")
            }
        }
        .disabled(candidate == nil || testState == .running)
    }

    @ViewBuilder private var testResult: some View {
        if case .finished(let outcome) = testState {
            switch outcome {
            case .ok(let version):
                notice(systemImage: "checkmark.circle.fill", tint: .green) { Text("Connected — \(version).") }
            case .noTmux:
                notice(systemImage: "exclamationmark.triangle.fill", tint: .orange) {
                    Text("Connected, but tmux isn't installed there. Install tmux 3.2 or newer to run sessions.")
                }
            case .unknownHostKey(let detail):
                notice(systemImage: "questionmark.circle.fill", tint: .orange) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("You haven't connected to this host before, so its identity can't be checked yet.")
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                        Button("Trust Host & Connect") { Task { await runTest(trustNewHostKey: true) } }
                    }
                }
            case .changedHostKey(let detail):
                notice(systemImage: "xmark.shield.fill", tint: .red) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("This host's identity has changed since you last connected. That can mean the machine was reinstalled — or that someone is intercepting the connection. Relay won't connect until the old key is removed from ~/.ssh/known_hosts.")
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
            case .authenticationFailed(let detail):
                notice(systemImage: "lock.fill", tint: .orange) {
                    Text("The host refused the sign-in. Check the user and key.\n\(detail)")
                }
            case .unreachable(let detail):
                notice(systemImage: "bolt.horizontal.circle", tint: .orange) {
                    Text("Couldn't connect.\n\(detail)")
                }
            case .passwordNotSupportedYet:
                notice(systemImage: "info.circle", tint: .blue) {
                    Text("Password hosts can't be tested until Relay's built-in SSH client lands.")
                }
            }
        }
    }

    private func runTest(trustNewHostKey: Bool) async {
        guard let host = candidate else { return }
        testState = .running
        let outcome = await SSHConnectionTest.run(host: host, trustNewHostKey: trustNewHostKey)
        // Ignore a result for settings the user has since changed.
        guard candidate == host else { return }
        testState = .finished(outcome)
    }

    // MARK: Model

    /// The host the form describes, or nil while it's incomplete/invalid.
    private var candidate: SSHHost? {
        try? buildHost()
    }

    private var validationMessage: String? {
        guard !alias.isEmpty, !hostname.isEmpty else { return nil }
        do {
            _ = try buildHost()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func buildHost() throws -> SSHHost {
        let trimmedAlias = alias.trimmingCharacters(in: .whitespaces)
        let trimmedHost = hostname.trimmingCharacters(in: .whitespaces)
        let trimmedPort = port.trimmingCharacters(in: .whitespaces)
        let trimmedUser = user.trimmingCharacters(in: .whitespaces)
        guard !trimmedAlias.isEmpty else { throw SSHHost.ValidationError.alias }
        if !isEditing, model.hosts.contains(where: { $0.alias == trimmedAlias }) {
            throw DuplicateAlias()
        }
        var parsedPort: Int?
        if !trimmedPort.isEmpty {
            guard let value = Int(trimmedPort) else { throw SSHHost.ValidationError.port }
            parsedPort = value
        }
        let auth: SSHHostAuth
        switch authKind {
        case .automatic:
            auth = .automatic
        case .keyFile:
            let cert = certificatePath.trimmingCharacters(in: .whitespaces)
            auth = .keyFile(path: keyPath.trimmingCharacters(in: .whitespaces),
                            certificatePath: cert.isEmpty ? nil : cert)
        case .password:
            auth = .password
        }
        let host = SSHHost(
            alias: trimmedAlias,
            hostname: trimmedHost,
            port: parsedPort,
            user: trimmedUser.isEmpty ? nil : trimmedUser,
            auth: auth,
            inheritedOptions: inheritedOptions)
        try host.validate()
        return host
    }

    private struct DuplicateAlias: LocalizedError {
        var errorDescription: String? { "There's already a host with this name." }
    }

    private func populate() {
        switch mode {
        case .create:
            tab = SSHConfigDiscovery.discoverAliases().contains { alias in
                !model.hosts.contains { $0.alias == alias }
            } ? .importConfig : .form
        case .edit(let host):
            fill(from: host)
            hasStoredPassword = SSHPasswordStore.hasPassword(alias: host.alias)
        }
    }

    private func fill(from host: SSHHost) {
        alias = host.alias
        hostname = host.hostname
        port = host.port.map(String.init) ?? ""
        user = host.user ?? ""
        inheritedOptions = host.inheritedOptions
        switch host.auth {
        case .automatic:
            authKind = .automatic
        case .keyFile(let path, let certificate):
            authKind = .keyFile
            keyPath = path
            certificatePath = certificate ?? ""
        case .password:
            authKind = .password
        }
    }

    private func applyImport(_ host: SSHHost) {
        fill(from: host)
        tab = .form
    }

    private func save() async {
        saveError = nil
        do {
            let host = try buildHost()
            await model.saveHost(host, password: authKind == .password ? password : nil)
            onSave?(host)
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }
}

/// A path text field with a Choose… button (opens in ~/.ssh, hidden files
/// shown). Paths under the home folder are stored as `~/…`.
private struct PathField: View {
    @Binding var path: String
    let prompt: String
    let title: String

    var body: some View {
        HStack(spacing: 6) {
            TextField("", text: $path, prompt: Text(prompt))
                .labelsHidden()
                .fontDesign(.monospaced)
            Button("Choose…", action: choose)
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        let home = FileManager.default.homeDirectoryForCurrentUser
        panel.directoryURL = home.appendingPathComponent(".ssh", isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let homePath = home.path.hasSuffix("/") ? home.path : home.path + "/"
        path = url.path.hasPrefix(homePath) ? "~/" + url.path.dropFirst(homePath.count) : url.path
    }
}

/// The `~/.ssh/config` aliases Relay doesn't have yet, each resolved the
/// way ssh would connect.
private struct SSHConfigImportList: View {
    let existing: Set<String>
    let onPick: (SSHHost) -> Void

    @State private var entries: [SSHHost]?

    var body: some View {
        Group {
            if let entries {
                if entries.isEmpty {
                    ContentUnavailableView(
                        "Nothing to Import",
                        systemImage: "checkmark.circle",
                        description: Text("Every host in ~/.ssh/config is already in Relay."))
                } else {
                    List(entries) { host in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(host.alias).fontWeight(.medium)
                                Text(host.summary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if !host.inheritedOptions.isEmpty {
                                    Text(host.inheritedOptions.joined(separator: " · "))
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }
                            Spacer()
                            Button("Import…") { onPick(host) }
                        }
                        .padding(.vertical, 2)
                    }
                    .listStyle(.bordered)
                }
            } else {
                ProgressView("Reading ~/.ssh/config…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            let aliases = SSHConfigDiscovery.discoverAliases().filter {
                !existing.contains($0) && SSHHost.isValidAlias($0)
            }
            var resolved: [SSHHost] = []
            for alias in aliases {
                resolved.append(await SSHConfigImporter.importHost(alias: alias))
            }
            entries = resolved
        }
    }
}
