import SwiftUI

struct NewSessionSheet: View {
    @Environment(SessionStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Preferences.Keys.startAgent) private var startAgent = Agent.claude.id
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
