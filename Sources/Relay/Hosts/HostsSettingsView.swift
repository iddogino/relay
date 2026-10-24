import SwiftUI
import RelayCore

/// The "built-in SSH client" switch (read by `BuiltInSSHRouter` per
/// command, so flipping it applies to the next command).
enum BuiltInSSHSetting {
    static let defaultsKey = "builtInSSHClient"
}

/// Settings ▸ Hosts: Relay's host list.
struct HostsSettingsView: View {
    @Bindable var model: AppModel

    @AppStorage(BuiltInSSHSetting.defaultsKey) private var builtInSSH = false
    @State private var selection: String?
    @State private var editor: EditorRequest?
    @State private var confirmRemove: SSHHost?

    private var selectedHost: SSHHost? {
        model.hosts.first { $0.alias == selection }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            List(model.hosts, selection: $selection) { host in
                HostRow(host: host, projectCount: model.projects(on: host).count)
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
                Spacer()
                Text("Relay connects with these settings. Anything else in your ~/.ssh/config still applies on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }

            Divider()
                .padding(.vertical, 4)

            Toggle(isOn: $builtInSSH) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Use Relay\u{2019}s built-in SSH client (beta)")
                    Text("For background work — session lists, status, machine load. Terminals still use ssh. Hosts it can\u{2019}t handle yet (ProxyJump, certificates, unknown host keys) keep using ssh automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(20)
        .frame(width: 560, height: 440)
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

    var body: some View {
        HStack {
            Image(systemName: "server.rack")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(host.alias).fontWeight(.medium)
                Text(host.summary + authCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
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
        }
    }
}
