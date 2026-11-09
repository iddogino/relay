import AppKit
import SwiftUI
import RelayCore

/// "Add This Mac…": runs sessions on this Mac, through its own SSH server.
struct ThisMacSetupSheet: View {
    @Bindable var model: AppModel
    /// Inside the Add Host sheet: no title or description of its own.
    var embedded = false
    /// When set, finishing hands the new host back (the project editor
    /// selects it) instead of offering Add Project….
    var onDone: ((SSHHost) -> Void)?
    @State private var setup: ThisMacSetup
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow

    init(model: AppModel, embedded: Bool = false, onDone: ((SSHHost) -> Void)? = nil) {
        self.model = model
        self.embedded = embedded
        self.onDone = onDone
        _setup = State(initialValue: ThisMacSetup(model: model))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !embedded {
                Text("Add This Mac")
                    .font(.headline)
                    .padding([.horizontal, .top], 20)
            }
            Text("Relay runs this Mac\u{2019}s sessions the way it runs any host\u{2019}s: in tmux, over SSH. They keep running when Relay quits, and your other devices see this Mac\u{2019}s projects too.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, embedded ? 0 : 20)
                .padding(.top, embedded ? 0 : 4)
            Form {
                content
                if let error = setup.errorMessage {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(embedded ? .hidden : .automatic)
            .padding(.horizontal, embedded ? -20 : 0)
            HStack {
                Spacer()
                buttons
            }
            .padding([.horizontal, .bottom], embedded ? 0 : 20)
        }
        .frame(width: embedded ? nil : 520)
        .task { await setup.start() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Back from System Settings: Remote Login may be on now.
            if setup.step == .remoteLoginOff { Task { await setup.start() } }
        }
    }

    @ViewBuilder private var content: some View {
        switch setup.step {
        case .checking:
            Section { ProgressView("Checking Remote Login\u{2026}").controlSize(.small) }

        case .unavailable:
            Section {
                Label("This build of Relay can\u{2019}t run sessions on this Mac.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }

        case .remoteLoginOff:
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Turn on Remote Login", systemImage: "switch.2")
                        .font(.body.weight(.medium))
                    Text("In System Settings \u{25B8} General \u{25B8} Sharing, turn on Remote Login. To let sessions open Desktop, Documents and other protected folders, also turn on \u{201C}Allow full disk access for remote users\u{201D} (click \u{24D8} next to it).")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if setup.port != 22 {
                        Text("This build looks for SSH on port \(String(setup.port)).")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Button("Open Sharing Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.Sharing-Settings.extension") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        Button("Check Again") { Task { await setup.start() } }
                    }
                }
            }

        case .details:
            Section {
                TextField("Name", text: $setup.alias)
                if model.hosts.contains(where: { $0.alias == setup.alias }) {
                    Text("Another host already has this name.").font(.caption).foregroundStyle(.red)
                }
                TextField("User", text: $setup.user)
            } header: {
                Text("Host")
            }
            Section {
                Picker("Address", selection: $setup.address) {
                    ForEach(setup.candidates) { candidate in
                        Text(candidate.address).tag(candidate.address)
                    }
                    if !setup.candidates.contains(where: { $0.address == setup.address }) {
                        Text(setup.address).tag(setup.address)
                    }
                }
                TextField("Or type an address", text: $setup.address)
                if setup.addressIsLoopback {
                    Text("Your other devices can\u{2019}t reach this Mac at a loopback address. Use a name or address on your network or tailnet.")
                        .font(.caption).foregroundStyle(.red)
                }
            } header: {
                Text("How your other devices reach this Mac")
            } footer: {
                footer(addressCaption)
            }
            Section {
                SecureField("Password for \(setup.user)", text: $setup.password)
                    .onSubmit { if setup.canConnect { Task { await setup.connect() } } }
            } header: {
                Text("Sign in once")
            } footer: {
                footer(signInCaption)
            }

        case .working(let what):
            Section { ProgressView(what).controlSize(.small) }

        case .needsTmux(let platform):
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label("tmux isn\u{2019}t installed on this Mac", systemImage: "shippingbox")
                        .font(.body.weight(.medium))
                    Text("Relay keeps sessions in tmux. It can install its own copy for you, just for your account (in ~/.relay, no administrator password).")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if platform.packageInstallIsUnattended, let command = platform.packageInstallCommand {
                        Text("Or install it with Homebrew: \(command)")
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            }

        case .done(let host):
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Label("\u{201C}\(host.alias)\u{201D} is this Mac", systemImage: "checkmark.circle.fill")
                        .font(.body.weight(.medium))
                        .foregroundStyle(.green)
                    Text("Relay connects to it over loopback here, and as \(host.hostname) from your other devices.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let tmux = setup.installedTmux {
                        Text("Installed \(tmux).").foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder private var buttons: some View {
        switch setup.step {
        case .details:
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Add This Mac") { Task { await setup.connect() } }
                .keyboardShortcut(.defaultAction)
                .disabled(!setup.canConnect)
        case .needsTmux(let platform):
            Button("Not Now") { dismiss() }
                .keyboardShortcut(.cancelAction)
            if platform.packageInstallIsUnattended {
                Button("Use Homebrew") { Task { await setup.installTmux(.packageManager) } }
            }
            Button("Install tmux") { Task { await setup.installTmux(.bundled) } }
                .keyboardShortcut(.defaultAction)
                .disabled(!(AppModel.tmuxBundle?.supports(platform) ?? false))
        case .done(let host) where onDone != nil:
            Button("Use This Mac") { onDone?(host) }
                .keyboardShortcut(.defaultAction)
        case .done(let host):
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Add Project\u{2026}") {
                dismiss()
                openWindow(id: "main")
                NSApp.activate()
                model.projectEditor = ProjectEditorContext(mode: .create(workspace: host.workspace))
            }
            .keyboardShortcut(.defaultAction)
        case .checking, .unavailable, .remoteLoginOff, .working:
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
    }

    private func footer(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var addressCaption: String {
        let caption = setup.candidates.first { $0.address == setup.address }?.caption
            ?? (setup.candidates.isEmpty && setup.address.isEmpty
                ? "Relay found no network address for this Mac. Type the name your other devices reach it at"
                : nil)
            ?? "Any name or address your other devices can reach this Mac at"
        return caption + ". This Mac itself always connects over loopback."
    }

    private var signInCaption: String {
        switch setup.keyStorage {
        case .iCloudKeychain?:
            return "Your Mac account password, used once to add a Relay key to this Mac. The key syncs through iCloud Keychain, so your other devices can sign in too."
        case .secureEnclave?:
            return "Your Mac account password, used once to add a Relay key to this Mac. This build keeps the key in this Mac\u{2019}s Secure Enclave, so other devices will need their own sign-in."
        case nil:
            return "Your Mac account password. Relay saves it in the Keychain to sign in."
        }
    }
}
