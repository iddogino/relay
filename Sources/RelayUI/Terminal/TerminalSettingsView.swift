import SwiftUI
import RelaySSH

/// Settings ▸ Terminal: whether terminals use the user's Ghostty config,
/// and a plain-text editor for the config files in effect (Relay's own
/// terminal config, and the Ghostty ones when used).
struct TerminalSettingsView: View {
    @State private var useGhostty = TerminalConfig.useGhosttyFiles
    @State private var grant = FolderGrants.ghostty
    @State private var files: [URL] = []
    @State private var selected: URL = TerminalConfig.relayConfigFile
    @State private var text = ""
    @State private var savedText = ""
    @State private var loadError: String?
    @State private var diagnostics: [String] = GhosttyRuntime.lastDiagnostics

    init(selecting file: URL? = nil) {
        _selected = State(initialValue: file ?? TerminalConfig.relayConfigFile)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                Toggle(isOn: Binding(get: { useGhostty }, set: { setUseGhostty($0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Use my Ghostty config files")
                        Text(ghosttyCaption)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if useGhostty, UserHome.isSandboxed {
                    Spacer()
                    Button("Choose Folder\u{2026}") {
                        Task {
                            if await grant.requestAccess() { apply(useGhostty: true) }
                        }
                    }
                }
            }

            Divider()

            HStack {
                Picker("Edit", selection: $selected) {
                    ForEach(files, id: \.self) { file in
                        Text(label(for: file)).tag(file)
                    }
                }
                .fixedSize()
                Spacer()
                Button("Revert") { load() }
                    .disabled(text == savedText)
                    .fixedSize()
                Button("Save") { save() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(text == savedText)
                    .fixedSize()
            }

            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .autocorrectionDisabled()
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.separator))
                .frame(minHeight: 220)

            if let loadError {
                Label(loadError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if !diagnostics.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(diagnostics, id: \.self) { message in
                        Label(message, systemImage: "exclamationmark.triangle")
                    }
                }
                .font(.caption)
                .foregroundStyle(.orange)
            } else {
                Text(editorCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(width: 560, height: 500)
        .onAppear { refreshFiles(); load() }
        .onChange(of: selected) { load() }
    }

    private var ghosttyCaption: String {
        if !useGhostty {
            return "Fonts, theme and keybinds from your Ghostty config. Off: Relay\u{2019}s defaults and its own config below."
        }
        if let folder = grant.folder {
            guard let first = TerminalConfig.ghosttyFiles.first else {
                return "No Ghostty config in \(UserHome.abbreviate(folder.path)). Choose the folder that has it."
            }
            return "From \(UserHome.abbreviate(first.deletingLastPathComponent().path)). Relay\u{2019}s own config below applies on top."
        }
        return "Relay needs access to your Ghostty config folder."
    }

    private var editorCaption: String {
        selected == TerminalConfig.relayConfigFile
            ? "Ghostty config syntax (ghostty.org/docs/config). Saving applies it to every terminal."
            : "Your Ghostty config — Ghostty itself uses it too. Saving applies it to every terminal."
    }

    private func label(for file: URL) -> String {
        // The folder is in the caption; the menu stays short.
        file == TerminalConfig.relayConfigFile ? "Relay terminal config" : "Ghostty \u{2014} \(file.lastPathComponent)"
    }

    private func setUseGhostty(_ on: Bool) {
        guard on, grant.needsGrant else {
            apply(useGhostty: on)
            return
        }
        Task {
            // Turning it on in the sandbox asks for the folder first.
            apply(useGhostty: await grant.requestAccess())
        }
    }

    private func apply(useGhostty on: Bool) {
        useGhostty = on
        TerminalConfig.useGhosttyFiles = on
        reloadTerminals()
        refreshFiles()
    }

    private func refreshFiles() {
        files = [TerminalConfig.relayConfigFile] + (useGhostty ? TerminalConfig.ghosttyFiles : [])
        if !files.contains(selected) { selected = TerminalConfig.relayConfigFile }
    }

    private func load() {
        loadError = nil
        if selected == TerminalConfig.relayConfigFile, !FileManager.default.fileExists(atPath: selected.path) {
            text = ""
        } else {
            do {
                text = try String(contentsOf: selected, encoding: .utf8)
            } catch {
                text = ""
                loadError = "Couldn\u{2019}t read \(label(for: selected)): \(error.localizedDescription)"
            }
        }
        savedText = text
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: selected.deletingLastPathComponent(), withIntermediateDirectories: true)
            // A Ghostty config is often a symlink into a dotfiles repo: write
            // through it rather than replacing it with a file.
            try text.write(to: selected, atomically: selected == TerminalConfig.relayConfigFile, encoding: .utf8)
            savedText = text
            loadError = nil
            reloadTerminals()
        } catch {
            loadError = "Couldn\u{2019}t save \(label(for: selected)): \(error.localizedDescription)"
        }
    }

    private func reloadTerminals() {
        GhosttyRuntime.shared.reloadConfig()
        diagnostics = GhosttyRuntime.lastDiagnostics
    }
}
