import AppKit
import SwiftUI
import RelayCore
import RelaySSH

/// Add or edit one of Relay's hosts. Creating offers two routes: import an
/// entry from `~/.ssh/config` (prefills the form for review), or fill the
/// form by hand.
///
/// New hosts sign in with a Relay key by default: synced through iCloud
/// Keychain, or kept in this Mac's Secure Enclave. Setting one up signs in
/// once (password, agent, key file) to add the key to the host.
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
    @State private var keyStorage: SSHKeyInfo.Storage = .iCloudKeychain
    @State private var bootstrap: Bootstrap = .password
    @State private var bootstrapPassword = ""
    @State private var bootstrapKeyPath = ""
    @State private var passphrase = ""
    @State private var setupState: SetupState = .idle
    @State private var testState: TestState = .idle
    @State private var saveError: String?
    @Environment(\.dismiss) private var dismiss

    enum AuthKind: Hashable { case relayKey, automatic, keyFile, password }

    /// How to sign in the one time a Relay key is added to the host.
    enum Bootstrap: Hashable { case password, automatic, keyFile }

    enum SetupState: Equatable {
        case idle
        case running
        case needsTrust(presentedKey: String)
        case failed(String)
    }

    enum TestState: Equatable {
        case idle
        case running
        case finished(SSHConnectionTest.Outcome)
    }

    private var original: SSHHost? {
        if case .edit(let host) = mode { return host }
        return nil
    }

    private var isEditing: Bool { original != nil }

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
                    Button {
                        Task { await save() }
                    } label: {
                        HStack(spacing: 6) {
                            if setupState == .running { ProgressView().controlSize(.small) }
                            Text(saveTitle)
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(candidate == nil || setupState == .running || relayKeyBlocked)
                }
            }
            .padding(.top, 16)
        }
        .padding(20)
        .frame(width: 520)
        .onAppear(perform: populate)
        .onChange(of: candidate) { testState = .idle }
        .onChange(of: setupInputs) { if setupState != .running { setupState = .idle } }
    }

    private var saveTitle: String {
        if authKind == .relayKey && !keyIsReady { return "Set Up Key & \(isEditing ? "Save" : "Add")" }
        return isEditing ? "Save" : "Add Host"
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

            Picker("Sign in with", selection: $authKind) {
                if model.keyStore != nil {
                    Text("Relay key").tag(AuthKind.relayKey)
                }
                Text("SSH agent & default keys").tag(AuthKind.automatic)
                Text("Key file").tag(AuthKind.keyFile)
                Text("Password").tag(AuthKind.password)
            }
            switch authKind {
            case .relayKey:
                relayKeyFields
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
                Text("Saved in your Keychain. Relay's built-in SSH client signs in with it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.columns)
        .textFieldStyle(.roundedBorder)

        if !inheritedOptions.isEmpty {
            if authKind == .relayKey {
                notice(systemImage: "exclamationmark.triangle.fill", tint: .orange) {
                    Text("Relay keys need a host Relay can reach directly, and your ssh config also sets \(inheritedOptions.joined(separator: ", ")) for it. Choose another way to sign in.")
                }
            } else {
                notice(systemImage: "info.circle", tint: .blue) {
                    Text("Also set for this host in your ssh config: \(inheritedOptions.joined(separator: ", ")). Relay keeps using them on this Mac, but they won't carry over to other devices.")
                }
            }
        }
        if authKind == .relayKey {
            relayKeyNotices
        }
        if let validationMessage {
            notice(systemImage: "exclamationmark.triangle.fill", tint: .orange) { Text(validationMessage) }
        }
        if let saveError {
            notice(systemImage: "exclamationmark.triangle.fill", tint: .orange) { Text(saveError) }
        }
        testResult
        if let original, original.auth.storedKeyID != nil, !model.needsConnection(original) {
            HostKeysSection(model: model, host: original)
                .padding(.top, 12)
        }
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

    // MARK: Relay key

    @ViewBuilder private var relayKeyFields: some View {
        LabeledContent("Keep the key") {
            Picker("", selection: $keyStorage) {
                storageOption(
                    "Sync with iCloud Keychain",
                    detail: "Recommended. Works on all your devices. End-to-end encrypted.")
                    .tag(SSHKeyInfo.Storage.iCloudKeychain)
                storageOption(
                    "Keep on this Mac only",
                    detail: "Made in the Secure Enclave; it can never leave this Mac. Your other devices need their own setup.")
                    .tag(SSHKeyInfo.Storage.secureEnclave)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
        }
        if keyIsReady, let key = currentKey {
            LabeledContent("Key") {
                Label {
                    Text("\(key.name) · \(String(key.fingerprint.prefix(19)))…")
                        .fontDesign(.monospaced)
                        .textSelection(.enabled)
                } icon: {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                }
            }
        } else {
            Picker("Sign in once with", selection: $bootstrap) {
                Text("Password").tag(Bootstrap.password)
                Text("SSH agent & default keys").tag(Bootstrap.automatic)
                Text("Key file").tag(Bootstrap.keyFile)
            }
            switch bootstrap {
            case .password:
                SecureField("Password", text: $bootstrapPassword, prompt: Text("used once, not saved"))
            case .automatic:
                EmptyView()
            case .keyFile:
                LabeledContent("Private key") {
                    PathField(path: $bootstrapKeyPath, prompt: "~/.ssh/id_ed25519", title: "Choose a private key")
                }
                if importsKeyFile && keyFileIsEncrypted {
                    SecureField("Passphrase", text: $passphrase, prompt: Text("unlocks the key to copy it"))
                }
            }
            Text(setupExplanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func storageOption(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 4)
    }

    private var setupExplanation: String {
        switch keyStorage {
        case .iCloudKeychain where importsKeyFile:
            return "Relay copies this key into iCloud Keychain and signs in with it from now on."
        case .iCloudKeychain:
            return "Relay signs in once to add your iCloud Keychain key to the host. If another of your devices already added it, no sign-in is needed."
        case .secureEnclave:
            return "Relay makes a key in this Mac's Secure Enclave and signs in once to add it to the host."
        }
    }

    @ViewBuilder private var relayKeyNotices: some View {
        if let original, model.needsConnection(original) {
            notice(systemImage: "link.badge.plus", tint: .orange) {
                Text("This host signs in with a Relay key that isn't on this Mac — it was set up on another device. Sign in once to connect it here.")
            }
        }
        if keyStorage == .iCloudKeychain {
            if !(model.keyStore?.canSync ?? false) {
                notice(systemImage: "exclamationmark.triangle.fill", tint: .orange) {
                    Text("This build of Relay isn't signed for iCloud Keychain, so it can't sync keys. Choose Keep on this Mac only.")
                }
            } else if FileManager.default.ubiquityIdentityToken == nil {
                notice(systemImage: "icloud.slash", tint: .orange) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("You're not signed in to iCloud, so this key would stay on this Mac. Sign in under System Settings ▸ Apple Account, then turn on iCloud ▸ Passwords & Keychain.")
                        Button("Open iCloud Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings:icloud") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                }
            } else if !keyIsReady {
                Text("Syncs through iCloud Keychain — make sure it's on: System Settings ▸ Apple Account ▸ iCloud ▸ Passwords & Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
            }
        }
        switch setupState {
        case .idle, .running:
            EmptyView()
        case .needsTrust(let presented):
            notice(systemImage: "questionmark.circle.fill", tint: .orange) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("You haven't connected to this host from Relay before, so its identity can't be checked yet. Make sure this is the right fingerprint:")
                    Text(KnownHosts.fingerprint(ofPublicKey: presented) ?? presented)
                        .font(.caption.monospaced())
                    Button("Trust Host & Continue") {
                        Task { await trustAndContinue(presented) }
                    }
                }
            }
        case .failed(let message):
            notice(systemImage: "exclamationmark.triangle.fill", tint: .orange) { Text(message) }
        }
    }

    /// The Relay key the host signs in with on this Mac, if it has it.
    private var currentKey: SSHKeyInfo? {
        original.flatMap { model.relayKey(for: $0) }
    }

    /// Nothing to set up: the host already signs in with a key of the
    /// chosen kind, and still points at the same machine.
    private var keyIsReady: Bool {
        guard authKind == .relayKey, let currentKey, currentKey.storage == keyStorage, let original else { return false }
        return original.hostname == hostname.trimmingCharacters(in: .whitespaces)
            && original.port == parsedPort
            && (original.user ?? "") == user.trimmingCharacters(in: .whitespaces)
    }

    /// Syncing with a key file to sign in copies that key (instead of
    /// adding Relay's shared one).
    private var importsKeyFile: Bool {
        keyStorage == .iCloudKeychain && bootstrap == .keyFile
    }

    private var keyFileIsEncrypted: Bool {
        let path = bootstrapKeyPath.trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty, let text = try? OpenSSHKeyFile.contents(ofFileAt: path) else { return false }
        return OpenSSHKeyFile.isEncrypted(text)
    }

    /// A Relay key can't be set up here at all.
    private var relayKeyBlocked: Bool {
        guard authKind == .relayKey else { return false }
        if !inheritedOptions.isEmpty { return true }
        if keyStorage == .iCloudKeychain && !(model.keyStore?.canSync ?? false) { return true }
        if keyStorage == .secureEnclave && !(model.keyStore?.canUseSecureEnclave ?? false) { return true }
        return false
    }

    /// Whatever, once changed, makes an earlier setup result stale.
    private var setupInputs: [String] {
        [hostname, port, user, "\(keyStorage)", "\(bootstrap)", bootstrapKeyPath, "\(authKind)"]
    }

    /// The host with the one-time sign-in as its auth.
    private func bootstrapHost(_ host: SSHHost) -> SSHHost {
        var host = host
        switch bootstrap {
        case .password: host.auth = .password
        case .automatic: host.auth = .automatic
        case .keyFile: host.auth = .keyFile(path: bootstrapKeyPath.trimmingCharacters(in: .whitespaces), certificatePath: nil)
        }
        return host
    }

    private func runSetup() async {
        guard let host = candidate, let setup = model.relayKeySetup() else { return }
        setupState = .running
        let request = RelayKeySetup.Request(
            host: bootstrapHost(host),
            password: bootstrap == .password ? bootstrapPassword : nil,
            storage: keyStorage,
            importKeyFile: importsKeyFile ? bootstrapKeyPath.trimmingCharacters(in: .whitespaces) : nil,
            passphrase: passphrase.isEmpty ? nil : passphrase)
        do {
            let outcome = try await setup.run(request)
            setupState = .idle
            await model.saveHost(outcome.host, password: nil)
            onSave?(outcome.host)
            dismiss()
        } catch RelayKeySetup.Failure.unknownHostKey(let presented) {
            setupState = .needsTrust(presentedKey: presented)
        } catch RelayKeySetup.Failure.signInFailed(let detail) where bootstrap == .password && bootstrapPassword.isEmpty {
            setupState = .failed("The host doesn't have this key yet, so Relay needs to sign in once: enter the password. \(detail)")
        } catch {
            setupState = .failed(error.localizedDescription)
        }
    }

    private func trustAndContinue(_ presented: String) async {
        guard let host = candidate else { return }
        do {
            try model.trustHostKey(presented, for: host)
        } catch {
            setupState = .failed("Couldn't save the host key: \(error.localizedDescription)")
            return
        }
        await runSetup()
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
        .disabled(testSubject == nil || testState == .running || relayKeyBlocked)
    }

    /// What Test Connection connects as: the host's own sign-in, or — for
    /// a Relay key not set up yet — the one-time sign-in.
    private var testSubject: (host: SSHHost, password: String?)? {
        guard var host = candidate else { return nil }
        switch authKind {
        case .relayKey:
            if keyIsReady, let currentKey {
                host.auth = .storedKey(id: currentKey.id)
                return (host, nil)
            }
            return (bootstrapHost(host), bootstrap == .password ? bootstrapPassword : nil)
        case .password:
            let typed = password.isEmpty ? (original.flatMap { SSHPasswordStore.load(alias: $0.alias) } ?? "") : password
            return (host, typed)
        case .automatic, .keyFile:
            return (host, nil)
        }
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
            case .untrustedHostKey(let presented):
                notice(systemImage: "questionmark.circle.fill", tint: .orange) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("You haven't connected to this host from Relay before, so its identity can't be checked yet. Make sure this is the right fingerprint:")
                        Text(KnownHosts.fingerprint(ofPublicKey: presented) ?? presented)
                            .font(.caption.monospaced())
                        Button("Trust Host & Connect") {
                            if let host = candidate { try? model.trustHostKey(presented, for: host) }
                            Task { await runTest(trustNewHostKey: false) }
                        }
                    }
                }
            case .changedHostKey(let detail):
                notice(systemImage: "xmark.shield.fill", tint: .red) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("This host's identity has changed since you last connected. That can mean the machine was reinstalled — or that someone is intercepting the connection. Relay won't connect until the old key is removed from known_hosts.")
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
            case .authenticationFailed(let detail):
                notice(systemImage: "lock.fill", tint: .orange) {
                    Text("The host refused the sign-in. \(detail)")
                }
            case .unreachable(let detail):
                notice(systemImage: "bolt.horizontal.circle", tint: .orange) {
                    Text("Couldn't connect.\n\(detail)")
                }
            case .keyNotOnThisDevice:
                notice(systemImage: "link.badge.plus", tint: .orange) {
                    Text("This host's Relay key isn't on this Mac. Sign in once to set it up here.")
                }
            case .passwordNotSupportedYet:
                notice(systemImage: "info.circle", tint: .blue) {
                    Text("Password hosts need Relay's built-in SSH client.")
                }
            }
        }
    }

    private func runTest(trustNewHostKey: Bool) async {
        guard let subject = testSubject else { return }
        testState = .running
        let outcome = await model.testConnection(subject.host, password: subject.password, trustNewHostKey: trustNewHostKey)
        // Ignore a result for settings the user has since changed.
        guard testSubject?.host == subject.host else { return }
        testState = .finished(outcome)
    }

    // MARK: Model

    private var parsedPort: Int? {
        Int(port.trimmingCharacters(in: .whitespaces))
    }

    /// The host the form describes, or nil while it's incomplete/invalid.
    /// (A Relay key not set up yet has a placeholder ID.)
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
        case .relayKey:
            auth = .storedKey(id: currentKey?.id ?? "pending")
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

    private var defaultStorage: SSHKeyInfo.Storage {
        (model.keyStore?.canSync ?? false) ? .iCloudKeychain : .secureEnclave
    }

    private func populate() {
        keyStorage = defaultStorage
        switch mode {
        case .create:
            authKind = model.keyStore != nil ? .relayKey : .automatic
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
            bootstrap = .automatic
        case .keyFile(let path, let certificate):
            authKind = .keyFile
            keyPath = path
            certificatePath = certificate ?? ""
            bootstrap = .keyFile
            bootstrapKeyPath = path
        case .password:
            authKind = .password
            bootstrap = .password
            bootstrapPassword = SSHPasswordStore.load(alias: host.alias) ?? ""
        case .storedKey:
            authKind = .relayKey
            keyStorage = model.relayKey(for: host)?.storage ?? defaultStorage
            bootstrap = .password
        }
    }

    /// An `~/.ssh/config` entry, set up with a Relay key that the entry's
    /// own sign-in adds (its key file is what Sync copies).
    private func applyImport(_ host: SSHHost) {
        fill(from: host)
        if model.keyStore != nil && host.inheritedOptions.isEmpty {
            authKind = .relayKey
        }
        tab = .form
    }

    private func save() async {
        saveError = nil
        if authKind == .relayKey && !keyIsReady {
            await runSetup()
            return
        }
        do {
            var host = try buildHost()
            if authKind == .relayKey, let currentKey { host.auth = .storedKey(id: currentKey.id) }
            await model.saveHost(host, password: authKind == .password ? password : nil)
            onSave?(host)
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }
}

/// The Relay keys in a host's authorized_keys — from this and other
/// devices — with a way to take one off (say, a lost device's).
private struct HostKeysSection: View {
    @Bindable var model: AppModel
    let host: SSHHost

    @State private var keys: [SSHKeyInstaller.AuthorizedKey]?
    @State private var error: String?
    @State private var removing: SSHKeyInstaller.AuthorizedKey?
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 6) {
                if let error {
                    Text(error).font(.caption).foregroundStyle(.orange)
                } else if let keys {
                    let relayKeys = keys.filter(\.isRelayKey)
                    if relayKeys.isEmpty {
                        Text("No Relay keys on this host.").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(relayKeys, id: \.self) { key in
                        row(key)
                    }
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.top, 4)
        } label: {
            Text("Relay keys on this host").font(.callout)
        }
        .onChange(of: expanded) { if expanded { Task { await load() } } }
        .confirmationDialog(
            "Remove this key from \(host.alias)?",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            presenting: removing
        ) { key in
            Button("Remove Key", role: .destructive) { Task { await remove(key) } }
        } message: { key in
            Text("\(origin(of: key)) won't be able to sign in to \(host.alias) with it anymore.")
        }
    }

    private func row(_ key: SSHKeyInstaller.AuthorizedKey) -> some View {
        let inUse = model.relayKey(for: host)?.publicKeyBlob == key.publicKeyBlob
        return HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(origin(of: key))
                Text(KnownHosts.fingerprint(ofPublicKey: key.publicKey) ?? "")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if inUse {
                Text("This Mac signs in with it").font(.caption).foregroundStyle(.secondary)
            } else {
                Button("Remove…") { removing = key }
                    .controlSize(.small)
            }
        }
    }

    private func origin(of key: SSHKeyInstaller.AuthorizedKey) -> String {
        if let local = model.keyStore?.keys().first(where: { $0.publicKeyBlob == key.publicKeyBlob }) {
            return local.storage == .iCloudKeychain ? "\(local.name) (iCloud Keychain)" : "This Mac's Secure Enclave key"
        }
        // "relay (<where>)": another device's key.
        let label = key.comment.dropFirst("relay (".count).dropLast()
        return "\(label)"
    }

    private func load() async {
        error = nil
        do {
            keys = try await model.authorizedKeys(on: host)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func remove(_ key: SSHKeyInstaller.AuthorizedKey) async {
        do {
            try await model.removeAuthorizedKey(key, from: host)
        } catch {
            self.error = error.localizedDescription
        }
        await load()
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
