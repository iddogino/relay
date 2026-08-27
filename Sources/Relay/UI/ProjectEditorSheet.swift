import SwiftUI
import RelayCore

struct ProjectEditorSheet: View {
    @Bindable var model: AppModel
    let context: ProjectEditorContext

    @State private var name: String = ""
    @State private var path: String = ""
    @State private var launchCommand: String = ""
    @State private var shutdownCommand: String = ""
    @State private var validating = false
    @State private var validationError: String?
    @FocusState private var nameFocused: Bool
    @Environment(\.dismiss) private var dismiss

    private var workspace: WorkspaceRef {
        switch context.mode {
        case .create(let workspace): return workspace
        case .edit(let project): return project.workspace
        }
    }

    private var isEditing: Bool {
        if case .edit = context.mode { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(isEditing ? "Project Settings" : "Add Project")
                .font(.title3.weight(.semibold))
                .padding(.bottom, 14)

            Form {
                TextField("Name", text: $name, prompt: Text("My iOS App"))
                    .focused($nameFocused)
                LabeledContent("Remote") {
                    Text(workspace.opaqueID)
                        .foregroundStyle(.secondary)
                }
                TextField("Folder", text: $path, prompt: Text("~/code/my-app"))
                    .fontDesign(.monospaced)

                Section {
                    TextField("Launch command", text: $launchCommand, prompt: Text("claude"), axis: .vertical)
                        .lineLimit(1...4)
                        .fontDesign(.monospaced)
                    TextField("Shutdown command", text: $shutdownCommand, prompt: Text("optional"), axis: .vertical)
                        .lineLimit(1...4)
                        .fontDesign(.monospaced)
                } footer: {
                    Text("The launch command starts each new session (RTERM_* variables describe the session). The shutdown command runs when a session is archived.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.columns)
            .textFieldStyle(.roundedBorder)

            if let validationError {
                Label {
                    Text(validationError)
                        .font(.callout)
                        .textSelection(.enabled)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                .padding(.top, 12)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    Task { await validateAndSave() }
                } label: {
                    HStack(spacing: 6) {
                        if validating {
                            ProgressView().controlSize(.small)
                        }
                        Text(isEditing ? "Validate & Save" : "Validate & Add")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(validating || name.trimmingCharacters(in: .whitespaces).isEmpty || path.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.top, 16)
        }
        .padding(20)
        .frame(width: 480)
        .onAppear(perform: populate)
        .task { nameFocused = true }
    }

    private func populate() {
        if case .edit(let project) = context.mode {
            name = project.name
            path = project.pathInput
            launchCommand = project.launchCommand ?? ""
            shutdownCommand = project.shutdownCommand ?? ""
        }
    }

    private func validateAndSave() async {
        validating = true
        validationError = nil
        defer { validating = false }

        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedPath = path.trimmingCharacters(in: .whitespaces)
        let launch = launchCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        let shutdown = shutdownCommand.trimmingCharacters(in: .whitespacesAndNewlines)

        var candidate: Project
        switch context.mode {
        case .create(let workspace):
            candidate = Project(
                name: trimmedName,
                workspace: workspace,
                pathInput: trimmedPath,
                resolvedPath: "",
                launchCommand: launch.isEmpty ? nil : launch,
                shutdownCommand: shutdown.isEmpty ? nil : shutdown)
        case .edit(let existing):
            candidate = existing
            candidate.name = trimmedName
            candidate.pathInput = trimmedPath
            candidate.launchCommand = launch.isEmpty ? nil : launch
            candidate.shutdownCommand = shutdown.isEmpty ? nil : shutdown
        }

        do {
            let validation = try await model.provider.validate(project: candidate)
            candidate.resolvedPath = validation.resolvedPath
            candidate.runtimeMetadata = validation.runtimeMetadata
            if isEditing {
                model.updateProject(candidate)
            } else {
                model.addProject(candidate)
            }
            dismiss()
        } catch {
            validationError = error.localizedDescription
        }
    }
}

struct NewSessionSheet: View {
    @Bindable var model: AppModel
    let project: Project

    @State private var name = ""
    @State private var creating = false
    @State private var errorMessage: String?
    @FocusState private var nameFocused: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Session")
                .font(.title3.weight(.semibold))

            TextField("Name", text: $name, prompt: Text("fix auth flow"))
                .textFieldStyle(.roundedBorder)
                .focused($nameFocused)
                .onSubmit { Task { await create() } }
                .task { nameFocused = true }

            VStack(alignment: .leading, spacing: 4) {
                if let launch = project.launchCommand, !launch.isEmpty {
                    Text("Launches with the project command:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(launch)
                        .font(.caption)
                        .fontDesign(.monospaced)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                } else {
                    Text("Opens a shell in \(project.pathInput) on \(project.workspace.opaqueID).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let errorMessage {
                Label {
                    Text(errorMessage)
                        .font(.callout)
                        .textSelection(.enabled)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    Task { await create() }
                } label: {
                    HStack(spacing: 6) {
                        if creating {
                            ProgressView().controlSize(.small)
                        }
                        Text("Create")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(creating || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private func create() async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !creating else { return }
        creating = true
        defer { creating = false }
        errorMessage = nil
        do {
            let session = try await model.provider.createSession(
                for: project,
                request: NewSessionRequest(displayName: trimmed))
            await MainActor.run {
                model.noteCreatedSession(session, project: project)
                dismiss()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
