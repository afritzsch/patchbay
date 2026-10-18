import SwiftUI

struct NewSessionSheet: View {
    @Environment(SessionStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Preferences.Keys.startAgent) private var startAgent = "claude"
    @State private var directory = ""
    @State private var name = ""
    @State private var prompt = ""
    @AppStorage(Preferences.Keys.newWorktree) private var newWorktree = false
    /// The folder's repository; nil outside one.
    @State private var repo: GitRepo?
    @State private var branch = ""
    @State private var base = ""
    @State private var fallbackBranch = "patchbay/" + UUID().uuidString.prefix(6).lowercased()
    @State private var isWorking = false
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                FolderPicker(directory: $directory)
                TextField("Name", text: $name, prompt: Text((directory as NSString).lastPathComponent))
            }
            if let repo {
                Section {
                    Toggle("New worktree", isOn: $newWorktree)
                    let others = store.agentSessions(inCheckoutOf: directory).count
                    if !newWorktree, agent != nil, others > 0 {
                        HStack(alignment: .firstTextBaseline) {
                            Label("\(others == 1 ? "An agent works" : "\(others) agents work") in this checkout already. "
                                  + "In a new worktree, this one gets its own copy and branch, so they can't change "
                                  + "each other's files.", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            Button("Use Worktree") { newWorktree = true }
                        }
                    }
                    if newWorktree {
                        TextField("Branch", text: $branch, prompt: Text(suggestedBranch))
                        if repo.branches.contains(branchName) {
                            LabeledContent("Based on", value: "Checks out the existing branch")
                        } else {
                            Picker("Based on", selection: $base) {
                                ForEach(repo.branches, id: \.self) { Text($0).tag($0) }
                            }
                        }
                        if let setup = repo.setup {
                            LabeledContent("Setup (.patchbay.json)") {
                                Text(setupSummary(setup)).textSelection(.enabled)
                            }
                        }
                        if let error {
                            Text(error).foregroundStyle(.red)
                        }
                    }
                }
            }
            Section {
                Picker("Start", selection: $startAgent) {
                    Text("Shell").tag("shell")
                    ForEach(Agent.all) { Text($0.name).tag($0.id) }
                }
            }
            if let agent, agent.promptStyle != .unsupported {
                PromptField(title: "First prompt", placeholder: "What should \(agent.name) do? (optional)", text: $prompt)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                if isWorking {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Start", action: start)
                        .disabled(directory.isEmpty)
                }
            }
        }
        .onAppear {
            directory = store.newSessionFolder ?? store.selectedSession?.cwd ?? store.recentDirectories.first ?? NSHomeDirectory()
            store.newSessionFolder = nil
        }
        .task(id: directory) {
            let directory = directory
            repo = await inBackground { Git.repository(at: directory) }
            base = repo?.defaultBase ?? ""
        }
    }

    private var agent: Agent? { Agent.named(startAgent) }

    private var suggestedBranch: String {
        let slug = Git.branchName(for: name)
        return slug.isEmpty ? fallbackBranch : slug
    }

    private var branchName: String { branch.isEmpty ? suggestedBranch : branch }

    private func start() {
        guard let repo, newWorktree else { return open(directory) }
        let branch = branchName
        let base = repo.branches.contains(branch) ? nil : base
        isWorking = true
        Task {
            error = await inBackground { repo.addWorktree(branch: branch, base: base) }
            isWorking = false
            if error == nil { open(repo.worktreePath(for: branch), setup: repo.setup?.setup) }
        }
    }

    private func open(_ folder: String, setup: String? = nil) {
        store.newSession(directory: folder, name: name.isEmpty ? nil : name, agent: agent, prompt: prompt, setup: setup)
        dismiss()
    }

    /// What a new worktree gets from `.patchbay.json`, shown before it runs: the setup is a command from the repository.
    private func setupSummary(_ setup: WorktreeSetup) -> String {
        var parts: [String] = []
        if let copy = setup.copy, !copy.isEmpty { parts.append("copies " + copy.joined(separator: ", ")) }
        if let command = setup.setup { parts.append("runs " + command) }
        return parts.joined(separator: "; ")
    }

}

/// A form section with a multi-line box for an agent's first prompt, shared by the new session and automation sheets.
struct PromptField: View {
    let title: String
    let placeholder: String
    @Binding var text: String

    var body: some View {
        Section(title) {
            TextField(title, text: $text, prompt: Text(placeholder), axis: .vertical)
                .labelsHidden()
                .multilineTextAlignment(.leading)
                .lineLimit(4...12)
        }
    }
}

/// One of the recent folders, or any other picked with Choose….
struct FolderPicker: View {
    @Environment(SessionStore.self) private var store
    @Binding var directory: String

    var body: some View {
        HStack {
            Picker("Folder", selection: $directory) {
                ForEach(directoryChoices, id: \.self) { dir in
                    Text((dir as NSString).abbreviatingWithTildeInPath).tag(dir)
                }
            }
            Button("Choose…", action: chooseDirectory)
        }
    }

    private var directoryChoices: [String] {
        var dirs = store.recentDirectories
        if !directory.isEmpty, !dirs.contains(directory) { dirs.insert(directory, at: 0) }
        if !dirs.contains(NSHomeDirectory()) { dirs.append(NSHomeDirectory()) }
        return dirs
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: directory.isEmpty ? NSHomeDirectory() : directory)
        if panel.runModal() == .OK, let url = panel.url {
            directory = url.path
        }
    }
}

struct SettingsView: View {
    @AppStorage(Preferences.Keys.restoreSessions) private var restoreSessions = true
    @AppStorage(Preferences.Keys.resumeClaude) private var resumeClaude = true
    @AppStorage(Preferences.Keys.notify) private var notify = true
    @AppStorage(Preferences.Keys.agentTools) private var agentTools = true
    @AppStorage(Preferences.Keys.languageServers) private var languageServers = true
    @Environment(SessionStore.self) private var store
    @State private var customAgents = Agent.custom
    @State private var customServers = LanguageServerConfig.custom

    var body: some View {
        @Bindable var store = store
        Form {
            Toggle("Reopen sessions on launch", isOn: $restoreSessions)
            Toggle("Resume Claude conversations when reopening", isOn: $resumeClaude)
                .disabled(!restoreSessions)
            Toggle("Notify when an agent needs input or finishes", isOn: $notify)
            Toggle("Let Claude start and direct other sessions", isOn: $agentTools)
            Stepper("Font size: \(Int(store.fontSize)) pt", value: $store.fontSize, in: Preferences.fontSizes)
            Picker("Keep history for", selection: Bindable(store.history).retentionDays) {
                Text("7 days").tag(7)
                Text("30 days").tag(30)
                Text("90 days").tag(90)
                Text("1 year").tag(365)
                Text("Forever").tag(0)
            }
            LabeledContent("History") {
                Button("Clear History…") {
                    let info = "\(store.history.entries.count) entries will be deleted. Sessions and Claude conversations are not affected."
                    if Ask.confirm("Clear all history?", info, action: "Clear") { store.history.clear() }
                }
            }
            Section("Other agents") {
                ForEach($customAgents) { $agent in
                    VStack {
                        HStack {
                            TextField("Name", text: $agent.name)
                            TextField("Command", text: $agent.command)
                            Button("Remove", systemImage: "minus.circle") { customAgents.removeAll { $0.id == agent.id } }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.borderless)
                        }
                        let approval = Binding { agent.approval ?? Agent.Approval(prompt: "", allow: "1", deny: "esc") }
                            set: { agent.approval = $0 }
                        HStack {
                            TextField("Permission prompt text", text: approval.prompt)
                            TextField("Allow keys", text: approval.allow).frame(width: 70)
                            TextField("Deny keys", text: approval.deny).frame(width: 70)
                        }
                    }
                }
                Button("Add Agent") { customAgents.append(Agent(id: UUID().uuidString, name: "", command: "")) }
                Text("Codex and Gemini are built in. Any command added here shows as working while it runs. "
                     + "With text from its permission prompt, Patchbay sees it asking and can answer with the keys "
                     + "given (esc and enter stand for those keys).")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Language servers") {
                Toggle("Show errors, completions and definitions in the editor", isOn: $languageServers)
                ForEach(LanguageServerConfig.builtIn) { server in
                    LabeledContent(server.name) {
                        Text(server.command).font(.callout.monospaced()).foregroundStyle(.secondary)
                    }
                }
                ForEach($customServers) { $server in
                    HStack {
                        TextField("Name", text: $server.name)
                        TextField("Command", text: $server.command)
                        TextField("Extensions", text: Binding {
                            server.extensions.joined(separator: " ")
                        } set: {
                            server.extensions = $0.split { $0 == " " || $0 == "," }.map { $0.trimmingCharacters(in: ["."]) }
                        })
                        Button("Remove", systemImage: "minus.circle") { customServers.removeAll { $0.id == server.id } }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                    }
                }
                Button("Add Language Server") {
                    customServers.append(LanguageServerConfig(id: UUID().uuidString, name: "", command: "", extensions: []))
                }
                Text("A server starts when you edit a file of its language, in that file's repository, with your "
                     + "login shell's PATH; install the ones you need. Servers added here (extensions like "
                     + "\"py pyi\") come before the built-in ones.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            LabeledContent("Claude hooks") {
                Text("Loaded with --settings in this app's terminals; your ~/.claude settings are untouched.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: customAgents) { Agent.custom = customAgents }
        .onChange(of: customServers) { LanguageServerConfig.custom = customServers }
    }
}
