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
                    LabeledContent("") {
                        Menu {
                            Section("Claude Code") {
                                Button("claude") {
                                    applyPreset(launch: "claude", cleanup: nil)
                                }
                                Button("claude in a new worktree") {
                                    // claude --worktree=NAME puts the tree at
                                    // .claude/worktrees/NAME on a LOCKED
                                    // branch named worktree-NAME (verified
                                    // empirically), hence the unlock.
                                    applyPreset(
                                        launch: #"claude --worktree="$RTERM_SESSION_SLUG""#,
                                        cleanup: #"git worktree unlock ".claude/worktrees/$RTERM_SESSION_SLUG" 2>/dev/null; git worktree remove ".claude/worktrees/$RTERM_SESSION_SLUG" && git branch -d "worktree-$RTERM_SESSION_SLUG""#)
                                }
                            }
                            ForEach(Self.wrapperAgents, id: \.command) { agent in
                                Section(agent.name) {
                                    Button(agent.command) {
                                        applyPreset(launch: agent.command, cleanup: nil)
                                    }
                                    Button("\(agent.command) in a new worktree") {
                                        applyPreset(
                                            launch: Self.worktreeLaunch(running: agent.command),
                                            cleanup: Self.worktreeCleanup)
                                    }
                                }
                            }
                            Section("Git worktree") {
                                Button("worktree + shell (with cleanup)") {
                                    applyPreset(
                                        launch: Self.worktreeLaunch(running: #""$SHELL""#),
                                        cleanup: Self.worktreeCleanup)
                                }
                            }
                        } label: {
                            Label("Presets", systemImage: "sparkles")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(.top, 12)
                    .padding(.bottom, 6)
                    LabeledContent("Launch command") {
                        CommandEditor(text: $launchCommand, prompt: "claude")
                    }
                    LabeledContent("Shutdown command") {
                        CommandEditor(text: $shutdownCommand, prompt: "optional")
                    }
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

    /// Agents without a native worktree flag get the generic git-worktree
    /// wrapper.
    private static let wrapperAgents: [(name: String, command: String)] = [
        ("Codex", "codex"),
        ("Pi", "pi"),
        ("OpenCode", "opencode"),
    ]

    /// Launch: fresh worktree named after the session, run `command` in it.
    /// `git worktree add` with a plain path creates a branch named after its
    /// basename — the slug — which is what the cleanup deletes.
    private static func worktreeLaunch(running command: String) -> String {
        #"git worktree add ".worktrees/$RTERM_SESSION_SLUG" && cd ".worktrees/$RTERM_SESSION_SLUG" && exec "# + command
    }

    private static let worktreeCleanup =
        #"git worktree remove ".worktrees/$RTERM_SESSION_SLUG" && git branch -d "$RTERM_SESSION_SLUG""#

    /// Presets always set the launch command; the cleanup only fills an
    /// empty shutdown field (never clobbers something the user wrote).
    private func applyPreset(launch: String, cleanup: String?) {
        launchCommand = launch
        if let cleanup, shutdownCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            shutdownCommand = cleanup
        }
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

/// Multi-line command input: a bordered TextEditor that wraps long
/// commands. (TextField's vertical axis doesn't reflow reliably on macOS —
/// long presets were clipping to one line.)
private struct CommandEditor: View {
    @Binding var text: String
    let prompt: String

    var body: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $text)
                .font(.system(size: 12, design: .monospaced))
                .autocorrectionDisabled()
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 4)
                .padding(.vertical, 3)
            if text.isEmpty {
                Text(prompt)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .allowsHitTesting(false)
            }
        }
        .frame(height: 56)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary, lineWidth: 1))
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
