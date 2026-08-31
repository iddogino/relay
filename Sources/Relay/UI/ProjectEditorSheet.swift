import SwiftUI
import RelayCore

struct ProjectEditorSheet: View {
    @Bindable var model: AppModel
    let context: ProjectEditorContext
    /// True when hosted inside another sheet (CreateSheet), which supplies
    /// the chrome: title, outer padding, and width.
    var embedded = false

    @State private var name: String = ""
    @State private var path: String = ""
    @State private var launchCommand: String = ""
    @State private var shutdownCommand: String = ""
    /// The host the project lives on. Picked at creation; fixed afterwards
    /// (a project's sessions live on its host — moving it is meaningless).
    @State private var workspace: WorkspaceRef?
    @State private var validating = false
    @State private var validationError: String?
    @FocusState private var nameFocused: Bool
    @Environment(\.dismiss) private var dismiss

    private var isEditing: Bool {
        if case .edit = context.mode { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !embedded {
                Text(isEditing ? "Project Settings" : "Add Project")
                    .font(.title3.weight(.semibold))
                    .padding(.bottom, 14)
            }

            Form {
                TextField("Name", text: $name, prompt: Text("My iOS App"))
                    .focused($nameFocused)
                if isEditing {
                    LabeledContent("Host") {
                        Text(workspace?.opaqueID ?? "")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Picker("Host", selection: $workspace) {
                        ForEach(model.remotes) { remote in
                            Text(remote.displayName).tag(Optional(remote.id))
                        }
                    }
                }
                TextField("Folder", text: $path, prompt: Text("~/code/my-app"))
                    .fontDesign(.monospaced)

                Section {
                    TextField("Launch command", text: $launchCommand, prompt: Text("claude"), axis: .vertical)
                        .lineLimit(1...4)
                        .fontDesign(.monospaced)
                    LabeledContent("") {
                        Menu {
                            Section("Claude Code") {
                                Button("claude") {
                                    launchCommand = "claude"
                                }
                                Button("claude in a new worktree") {
                                    launchCommand = #"claude --worktree="$RTERM_SESSION_SLUG""#
                                }
                            }
                            Section("Codex") {
                                Button("codex") {
                                    launchCommand = "codex"
                                }
                            }
                            Section("Git worktree") {
                                Button("worktree + shell (with cleanup)") {
                                    launchCommand = #"git worktree add ".worktrees/$RTERM_SESSION_SLUG" && cd ".worktrees/$RTERM_SESSION_SLUG" && exec "$SHELL""#
                                    if shutdownCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                        shutdownCommand = #"git worktree remove ".worktrees/$RTERM_SESSION_SLUG" && git branch -d "$RTERM_SESSION_SLUG""#
                                    }
                                }
                            }
                        } label: {
                            Label("Presets", systemImage: "sparkles")
                                .font(.caption)
                        }
                        .controlSize(.small)
                        .fixedSize()
                    }
                    TextField("Shutdown command", text: $shutdownCommand, prompt: Text("optional"), axis: .vertical)
                        .lineLimit(1...4)
                        .fontDesign(.monospaced)
                } footer: {
                    Text("The launch command starts each new session; the shutdown command runs when a session is archived. Both run in the project folder with RTERM_* variables set — including $RTERM_SESSION_SLUG, the session name slugified for branch/folder names.")
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
                .disabled(validating || workspace == nil || name.trimmingCharacters(in: .whitespaces).isEmpty || path.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.top, 16)
        }
        .padding(embedded ? 0 : 20)
        .frame(width: embedded ? nil : 480)
        .onAppear(perform: populate)
        .task { nameFocused = true }
    }

    private func populate() {
        switch context.mode {
        case .create(let preselected):
            workspace = preselected ?? model.remotes.first?.id
        case .edit(let project):
            workspace = project.workspace
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
        case .create:
            guard let workspace else { return }
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
    /// The default project (the picker's initial selection when shown).
    let project: Project
    /// True when hosted inside another sheet (CreateSheet), which supplies
    /// the chrome: title, outer padding, and width.
    var embedded = false
    /// Shows a project picker instead of pinning the passed project.
    var allowsProjectChoice = false

    @State private var name = ""
    @State private var runLaunchCommand = true
    @State private var creating = false
    @State private var errorMessage: String?
    @State private var chosenProjectID: ProjectID?
    @FocusState private var nameFocused: Bool
    @Environment(\.dismiss) private var dismiss

    private var activeProject: Project {
        guard allowsProjectChoice, let id = chosenProjectID,
              let chosen = model.projects.first(where: { $0.id == id }) else { return project }
        return chosen
    }

    /// Project names can repeat across hosts; disambiguate only when they do.
    private func pickerLabel(for candidate: Project) -> String {
        let collides = model.projects.contains {
            $0.id != candidate.id && $0.name == candidate.name
        }
        return collides ? "\(candidate.name) — \(candidate.workspace.opaqueID)" : candidate.name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !embedded {
                Text("New Session")
                    .font(.title3.weight(.semibold))
            }

            if allowsProjectChoice {
                Picker("Project", selection: $chosenProjectID) {
                    ForEach(model.projects) { candidate in
                        Text(pickerLabel(for: candidate)).tag(Optional(candidate.id))
                    }
                }
                .onAppear {
                    if chosenProjectID == nil { chosenProjectID = project.id }
                }
            }

            TextField("Name", text: $name, prompt: Text("fix auth flow"))
                .textFieldStyle(.roundedBorder)
                .focused($nameFocused)
                .onSubmit { Task { await create() } }
                .task { nameFocused = true }

            VStack(alignment: .leading, spacing: 4) {
                if let launch = activeProject.launchCommand, !launch.isEmpty {
                    Toggle(isOn: $runLaunchCommand) {
                        Text("Run the project launch command")
                            .font(.caption)
                    }
                    .toggleStyle(.checkbox)
                    if runLaunchCommand {
                        Text(launch)
                            .font(.caption)
                            .fontDesign(.monospaced)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .padding(6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                    } else {
                        Text("Opens a plain shell in \(activeProject.pathInput) on \(activeProject.workspace.opaqueID).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Opens a shell in \(activeProject.pathInput) on \(activeProject.workspace.opaqueID).")
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
        .padding(embedded ? 0 : 20)
        .frame(width: embedded ? nil : 400)
    }

    private func create() async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !creating else { return }
        let target = activeProject
        creating = true
        defer { creating = false }
        errorMessage = nil
        do {
            let session = try await model.provider.createSession(
                for: target,
                request: NewSessionRequest(displayName: trimmed, runLaunchCommand: runLaunchCommand))
            await MainActor.run {
                model.noteCreatedSession(session, project: target)
                dismiss()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// The sidebar +'s sheet: one entry point for both kinds of creation, a
/// segmented switch between a new session (the common reach) and a new
/// project. Both segments embed the standalone sheets so the logic lives
/// in one place.
struct CreateSheet: View {
    @Bindable var model: AppModel

    private enum Tab {
        case session, project
    }

    @State private var tab: Tab

    init(model: AppModel) {
        self.model = model
        // No projects yet → session creation is impossible; lead with project.
        _tab = State(initialValue: model.projects.isEmpty ? .project : .session)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("Create", selection: $tab) {
                Text("New Session").tag(Tab.session)
                Text("New Project").tag(Tab.project)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch tab {
            case .session:
                if let defaultProject = model.selectedProject ?? model.projects.first {
                    NewSessionSheet(
                        model: model,
                        project: defaultProject,
                        embedded: true,
                        allowsProjectChoice: true)
                } else {
                    Text("Add a project first — sessions live inside projects.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 20)
                }
            case .project:
                ProjectEditorSheet(
                    model: model,
                    context: ProjectEditorContext(mode: .create(workspace: nil)),
                    embedded: true)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}
