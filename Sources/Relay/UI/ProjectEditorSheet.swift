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

    // Folder autocomplete: one remote listing per parent directory, cached
    // for the sheet's lifetime; filtering as the user types is local.
    @State private var dirCache: [String: [String]] = [:]
    @State private var folderHighlight = 0
    @State private var folderSuggestionsDismissed = false
    @FocusState private var folderFocused: Bool

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
                    .focused($folderFocused)
                    .anchorPreference(key: FolderFieldBounds.self, value: .bounds) { $0 }
                    .onKeyPress(.downArrow) { moveFolderHighlight(1) }
                    .onKeyPress(.upArrow) { moveFolderHighlight(-1) }
                    .onKeyPress(.tab) { acceptHighlightedFolder() }
                    .onKeyPress(.return) { acceptHighlightedFolder() }
                    .onKeyPress(.escape) {
                        guard folderDropdownVisible else { return .ignored }
                        folderSuggestionsDismissed = true
                        return .handled
                    }
                    .onChange(of: path) {
                        folderSuggestionsDismissed = false
                        folderHighlight = 0
                    }
                    .task(id: folderFetchKey) { await fetchFolderListing() }

                Section {
                    LabeledContent("") {
                        Menu {
                            ForEach(HarnessCatalog.groups) { group in
                                Section(group.name) {
                                    ForEach(group.presets) { preset in
                                        Button(preset.title) {
                                            applyPreset(launch: preset.launch, cleanup: preset.cleanup)
                                        }
                                    }
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
                    Text("The default for new sessions — each session can pick a different harness at creation. The launch command starts the session; the shutdown command runs when it's archived. Both run in the project folder with RTERM_* variables set — including $RTERM_SESSION_SLUG, the session name slugified for branch/folder names.")
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
        // The suggestion dropdown floats above everything in the sheet,
        // anchored to the folder field via its reported bounds.
        .overlayPreferenceValue(FolderFieldBounds.self) { anchor in
            GeometryReader { geo in
                if let anchor, folderDropdownVisible {
                    let rect = geo[anchor]
                    FolderSuggestionList(
                        matches: folderMatches,
                        highlight: folderHighlight,
                        width: rect.width,
                        onPick: { acceptFolderSuggestion($0) })
                        .offset(x: rect.minX, y: rect.maxY + 2)
                }
            }
        }
    }

    // MARK: Folder autocomplete

    private var folderSplit: DirectoryCompletion.Split {
        DirectoryCompletion.split(path)
    }

    private func folderCacheKey(_ parent: String) -> String {
        "\(workspace?.opaqueID ?? "")|\(parent)"
    }

    private var folderFetchKey: String {
        folderCacheKey(folderSplit.parent)
    }

    private var folderMatches: [String] {
        guard let entries = dirCache[folderFetchKey] else { return [] }
        return DirectoryCompletion.matches(entries: entries, partial: folderSplit.partial)
    }

    private var folderDropdownVisible: Bool {
        folderFocused && !folderSuggestionsDismissed && !path.isEmpty && !folderMatches.isEmpty
    }

    private func moveFolderHighlight(_ delta: Int) -> KeyPress.Result {
        guard folderDropdownVisible else { return .ignored }
        folderHighlight = max(0, min(folderHighlight + delta, folderMatches.count - 1))
        return .handled
    }

    private func acceptHighlightedFolder() -> KeyPress.Result {
        guard folderDropdownVisible, folderMatches.indices.contains(folderHighlight) else {
            return .ignored
        }
        acceptFolderSuggestion(folderMatches[folderHighlight])
        return .handled
    }

    private func acceptFolderSuggestion(_ entry: String) {
        path = DirectoryCompletion.accept(input: path, entry: entry)
        folderHighlight = 0
        folderSuggestionsDismissed = false
    }

    /// Fetches (once) the child listing of the current parent directory.
    /// Failures just leave autocomplete silent — the field works like a
    /// plain text field. An empty path prefetches the login directory so
    /// the first keystroke already has suggestions.
    private func fetchFolderListing() async {
        guard let workspace else { return }
        let parent = folderSplit.parent
        let key = folderCacheKey(parent)
        guard dirCache[key] == nil else { return }
        // Tiny debounce so walking a path slash-by-slash doesn't stack
        // fetches for directories the user has already typed past.
        try? await Task.sleep(for: .milliseconds(200))
        guard !Task.isCancelled else { return }
        guard let entries = try? await model.provider.listChildDirectories(
            workspace: workspace, pathInput: parent) else { return }
        dirCache[key] = entries
    }

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

/// Reports the folder field's bounds so the suggestion dropdown can float
/// above the whole sheet instead of being clipped by the Form row.
private struct FolderFieldBounds: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

/// The autocomplete dropdown: keyboard-driven (↑/↓ move, Tab/Return accept,
/// Esc dismisses — focus never leaves the text field), clickable rows.
private struct FolderSuggestionList: View {
    let matches: [String]
    let highlight: Int
    let width: CGFloat
    let onPick: (String) -> Void

    private static let rowHeight: CGFloat = 22

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(matches.enumerated()), id: \.offset) { index, name in
                        HStack(spacing: 6) {
                            Image(systemName: "folder")
                                .font(.system(size: 10))
                                .foregroundStyle(index == highlight ? .primary : .secondary)
                            Text(name)
                                .font(.system(size: 12, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8)
                        .frame(height: Self.rowHeight)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .background(
                            index == highlight
                                ? AnyShapeStyle(Color.accentColor.opacity(0.22))
                                : AnyShapeStyle(.clear),
                            in: RoundedRectangle(cornerRadius: 4))
                        .onTapGesture { onPick(name) }
                        .id(index)
                    }
                }
                .padding(4)
            }
            .frame(width: width, height: min(CGFloat(matches.count) * Self.rowHeight + 8, 180))
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary, lineWidth: 1))
            .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
            .onChange(of: highlight) { _, index in
                proxy.scrollTo(index)
            }
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

    /// The harness picked for this one session.
    enum StartChoice: Equatable {
        case projectDefault
        case shell
        case preset(String)
        case custom
    }

    @State private var name = ""
    @State private var start: StartChoice = .projectDefault
    @State private var customLaunch = ""
    @State private var customCleanup = ""
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

    private var projectHasDefault: Bool {
        activeProject.launchCommand?.isEmpty == false
    }

    /// What the chosen harness will actually run, for the preview block.
    private var effectiveCommands: (launch: String?, cleanup: String?) {
        switch start {
        case .projectDefault:
            return (
                projectHasDefault ? activeProject.launchCommand : nil,
                activeProject.shutdownCommand?.isEmpty == false ? activeProject.shutdownCommand : nil
            )
        case .shell:
            return (nil, nil)
        case .preset(let id):
            guard let preset = HarnessCatalog.preset(id: id) else { return (nil, nil) }
            return (preset.launch, preset.cleanup)
        case .custom:
            let launch = customLaunch.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanup = customCleanup.trimmingCharacters(in: .whitespacesAndNewlines)
            return (launch.isEmpty ? nil : launch, cleanup.isEmpty ? nil : cleanup)
        }
    }

    private var startLabel: String {
        switch start {
        case .projectDefault: return "Project default"
        case .shell: return "Plain shell"
        case .preset(let id): return HarnessCatalog.preset(id: id)?.title ?? "Preset"
        case .custom: return "Custom command"
        }
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

            LabeledContent("Start with") {
                Menu {
                    if projectHasDefault {
                        Button("Project default") { start = .projectDefault }
                    }
                    Button("Plain shell") { start = .shell }
                    Divider()
                    ForEach(HarnessCatalog.groups) { group in
                        Section(group.name) {
                            ForEach(group.presets) { preset in
                                Button(preset.title) { start = .preset(preset.id) }
                            }
                        }
                    }
                    Divider()
                    Button("Custom command…") { start = .custom }
                } label: {
                    Text(startLabel)
                }
                .fixedSize()
            }
            .font(.callout)
            .onAppear { loadStartChoice(for: activeProject) }
            .onChange(of: chosenProjectID) {
                loadStartChoice(for: activeProject)
            }

            VStack(alignment: .leading, spacing: 6) {
                if start == .custom {
                    LabeledContent("Launch") {
                        CommandEditor(text: $customLaunch, prompt: "claude")
                    }
                    LabeledContent("Cleanup") {
                        CommandEditor(text: $customCleanup, prompt: "optional — runs on archive")
                    }
                } else if let launch = effectiveCommands.launch {
                    Text(launch)
                        .font(.caption)
                        .fontDesign(.monospaced)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                    if let cleanup = effectiveCommands.cleanup {
                        Text("On archive: \(cleanup)")
                            .font(.caption2)
                            .fontDesign(.monospaced)
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                } else {
                    Text("Opens a plain shell in \(activeProject.pathInput) on \(activeProject.workspace.opaqueID).")
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

    /// The provider-facing request for the current choice.
    private var sessionStart: SessionStart {
        switch start {
        case .projectDefault:
            return .projectDefault
        case .shell:
            return .shell
        case .preset(let id):
            guard let preset = HarnessCatalog.preset(id: id) else { return .shell }
            return .command(launch: preset.launch, cleanup: preset.cleanup)
        case .custom:
            let launch = customLaunch.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanup = customCleanup.trimmingCharacters(in: .whitespacesAndNewlines)
            if launch.isEmpty && cleanup.isEmpty { return .shell }
            return .command(launch: launch, cleanup: cleanup.isEmpty ? nil : cleanup)
        }
    }

    /// Seeds the picker with the project's last-used harness (falling back
    /// to the project default, or a plain shell when none is configured).
    private func loadStartChoice(for project: Project) {
        let hasDefault = project.launchCommand?.isEmpty == false
        guard let stored = model.lastStartChoice(for: project.id) else {
            start = hasDefault ? .projectDefault : .shell
            return
        }
        switch stored.kind {
        case "shell":
            start = .shell
        case "preset":
            if let id = stored.presetID, HarnessCatalog.preset(id: id) != nil {
                start = .preset(id)
            } else {
                start = hasDefault ? .projectDefault : .shell
            }
        case "custom":
            customLaunch = stored.customLaunch ?? ""
            customCleanup = stored.customCleanup ?? ""
            start = .custom
        default:
            start = hasDefault ? .projectDefault : .shell
        }
    }

    private func rememberStartChoice(for project: Project) {
        let stored: AppModel.StoredStartChoice
        switch start {
        case .projectDefault:
            stored = AppModel.StoredStartChoice(kind: "default")
        case .shell:
            stored = AppModel.StoredStartChoice(kind: "shell")
        case .preset(let id):
            stored = AppModel.StoredStartChoice(kind: "preset", presetID: id)
        case .custom:
            stored = AppModel.StoredStartChoice(
                kind: "custom",
                customLaunch: customLaunch.trimmingCharacters(in: .whitespacesAndNewlines),
                customCleanup: customCleanup.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        model.rememberStartChoice(stored, for: project.id)
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
                request: NewSessionRequest(displayName: trimmed, start: sessionStart))
            await MainActor.run {
                rememberStartChoice(for: target)
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
