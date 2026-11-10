import SwiftUI
import RelayCore
import RelaySSH

/// Settings ▸ Hosts: Relay's host list.
struct HostsSettingsView: View {
    @Bindable var model: AppModel

    @State private var sshFolder = FolderGrants.ssh
    @State private var selection: String?
    @State private var editor: EditorRequest?
    @State private var confirmRemove: SSHHost?
    @State private var thisMacSetup = false

    private var selectedHost: SSHHost? {
        model.hosts.first { $0.alias == selection }
    }

    var body: some View {
        content
            .sheet(item: $editor) { request in
                HostEditorSheet(model: model, mode: request.mode) { saved in
                    selection = saved.alias
                }
            }
            .confirmationDialog(
                "Remove \(confirmRemove?.alias ?? "")?",
                isPresented: Binding(get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } }),
                presenting: confirmRemove
            ) { host in
                Button("Remove", role: .destructive) {
                    Task { await model.removeHost(host) }
                }
            } message: { _ in
                Text("Relay forgets this host's settings (and any saved password). Nothing changes on the machine itself.")
            }
    }

    #if os(iOS)
    /// A list of hosts: tap one to edit it, swipe to remove it.
    private var content: some View {
        List {
            Section {
                ForEach(model.hosts) { host in
                    Button {
                        edit(host)
                    } label: {
                        HostRow(
                            host: host, projectCount: model.projects(on: host).count,
                            key: model.relayKey(for: host), problem: model.connectionProblem(host))
                    }
                    .foregroundStyle(.primary)
                    .swipeActions {
                        if model.projects(on: host).isEmpty {
                            Button("Remove", role: .destructive) { confirmRemove = host }
                        }
                    }
                }
            } footer: {
                if !model.hosts.isEmpty {
                    Text("Relay connects with exactly these settings. A host in use by a project can\u{2019}t be removed.")
                }
            }
        }
        .overlay {
            if model.hosts.isEmpty {
                ContentUnavailableView(
                    "No Hosts",
                    systemImage: "server.rack",
                    description: Text("Add a machine you reach over SSH."))
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    editor = EditorRequest(mode: .create)
                } label: {
                    Label("Add Host", systemImage: "plus")
                }
            }
        }
    }
    #else
    @ViewBuilder
    private var content: some View {
        // Once per render: each check reads known_hosts.
        let thisMacAlias = model.thisMacHost?.alias
        VStack(alignment: .leading, spacing: 8) {
            List(model.hosts, selection: $selection) { host in
                HostRow(
                    host: host, projectCount: model.projects(on: host).count,
                    key: model.relayKey(for: host), problem: model.connectionProblem(host),
                    isThisMac: host.alias == thisMacAlias)
                    .tag(host.alias)
                    .contextMenu {
                        Button("Edit…") { edit(host) }
                        Button("Remove…") { confirmRemove = host }
                            .disabled(!model.projects(on: host).isEmpty)
                    }
            }
            .listStyle(.bordered)
            .contextMenu(forSelectionType: String.self) { _ in } primaryAction: { aliases in
                if let alias = aliases.first, let host = model.hosts.first(where: { $0.alias == alias }) {
                    edit(host)
                }
            }
            .overlay {
                if model.hosts.isEmpty {
                    ContentUnavailableView(
                        "No Hosts",
                        systemImage: "server.rack",
                        description: Text("Add a machine you reach over SSH — or import one from ~/.ssh/config."))
                }
            }

            HStack(spacing: 8) {
                Button {
                    editor = EditorRequest(mode: .create)
                } label: {
                    Image(systemName: "plus")
                }
                .help("Add Host")
                Button {
                    if let host = selectedHost { confirmRemove = host }
                } label: {
                    Image(systemName: "minus")
                }
                .help(removeHelp)
                .disabled(selectedHost.map { !model.projects(on: $0).isEmpty } ?? true)
                Button("Edit…") {
                    if let host = selectedHost { edit(host) }
                }
                .disabled(selectedHost == nil)
                if thisMacAlias == nil {
                    Button("Add This Mac\u{2026}") { thisMacSetup = true }
                }
                Spacer()
                Text("Relay connects with exactly these settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }

            Divider()
                .padding(.vertical, 4)

            SSHFolderAccessRow(grant: sshFolder) {
                // Key files and known hosts may be readable now.
                model.builtInSSH?.hostsChanged()
            }
        }
        .padding(20)
        .frame(width: 560, height: 500)
        .sheet(isPresented: $thisMacSetup) {
            ThisMacSetupSheet(model: model)
        }
    }
    #endif

    private var removeHelp: String {
        guard let host = selectedHost else { return "Remove Host" }
        let count = model.projects(on: host).count
        return count == 0 ? "Remove Host" : "In use by \(count) project\(count == 1 ? "" : "s")"
    }

    private func edit(_ host: SSHHost) {
        editor = EditorRequest(mode: .edit(host))
    }

    private struct EditorRequest: Identifiable {
        let id = UUID()
        let mode: HostEditorSheet.Mode
    }
}

private struct HostRow: View {
    let host: SSHHost
    let projectCount: Int
    let key: SSHKeyInfo?
    /// Why Relay can't connect to it from this Mac, if it can't.
    let problem: String?
    /// The host is this Mac (reached over loopback here).
    var isThisMac = false

    var body: some View {
        HStack {
            Image(systemName: isThisMac ? "laptopcomputer" : "server.rack")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(host.alias).fontWeight(.medium)
                    if isThisMac {
                        Text("This Mac")
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                            .help("Relay reaches this host over loopback: its identity is this Mac\u{2019}s own.")
                    }
                }
                Text(host.summary + authCaption + (host.proxyJump.map { " · through \($0)" } ?? ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let problem {
                Label("Needs connection", systemImage: "link.badge.plus")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help(problem + " Edit the host to fix it.")
            }
            if projectCount > 0 {
                Text("\(projectCount) project\(projectCount == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    private var authCaption: String {
        switch host.auth {
        case .automatic: return ""
        case .keyFile(let path, _): return " · \((path as NSString).lastPathComponent)"
        case .password: return " · password"
        case .storedKey:
            switch key?.storage {
            case .iCloudKeychain: return " · Relay key (iCloud Keychain)"
            case .secureEnclave: return " · Relay key (this Mac)"
            case nil: return " · Relay key"
            }
        }
    }
}

/// Access to `~/.ssh` — where Relay reads your SSH config (to import
/// hosts), key files and known hosts. Only the App Sandbox build asks.
private struct SSHFolderAccessRow: View {
    let grant: FolderGrant
    let changed: () -> Void

    var body: some View {
        if UserHome.isSandboxed {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(grant.needsGrant ? "Relay can\u{2019}t read your .ssh folder" : "Relay can read your .ssh folder")
                    Text("For importing hosts from your SSH config, and hosts that sign in with a key file there. Relay never changes it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if grant.needsGrant {
                    Button("Allow Access…") {
                        Task {
                            if await grant.requestAccess() { changed() }
                        }
                    }
                } else {
                    Button("Revoke") {
                        grant.revoke()
                        changed()
                    }
                }
            }
        }
    }
}
