import SwiftUI

/// Source control for the focused session's repository, like VS Code's: staged and unstaged files, and a commit box.
struct ChangesView: View {
    @Environment(SessionStore.self) private var store
    @State private var message = ""
    @State private var error: String?
    @State private var discarding: GitChange?

    private var changes: [GitChange] { store.selectedSession?.git?.changes ?? [] }
    private var staged: [GitChange] { changes.filter(\.isStaged) }
    private var unstaged: [GitChange] { changes.filter(\.isUnstaged) }

    var body: some View {
        @Bindable var store = store
        if let git = store.selectedSession?.git {
            VStack(spacing: 0) {
                commitBox(git)
                List(selection: $store.selectedChange) {
                    if !staged.isEmpty {
                        Section {
                            ForEach(staged) { row($0, staged: true, root: git.root) }
                        } header: {
                            header("Staged Changes", count: staged.count, icon: "minus", help: "Unstage All") {
                                Git.unstage(["."], in: git.root)
                            }
                        }
                    }
                    if !unstaged.isEmpty {
                        Section {
                            ForEach(unstaged) { row($0, staged: false, root: git.root) }
                        } header: {
                            header("Changes", count: unstaged.count, icon: "plus", help: "Stage All") {
                                Git.stage(["."], in: git.root)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                .overlay {
                    if changes.isEmpty { ContentUnavailableView("No Changes", systemImage: "checkmark.circle") }
                }
            }
            .onChange(of: git.root) { store.selectedChange = nil }
            .onAppear { store.watchingChanges = true }
            .onDisappear {
                store.watchingChanges = false
                store.selectedChange = nil
            }
            .confirmationDialog(
                "Discard changes to \(discarding?.path ?? "")?",
                isPresented: Binding(get: { discarding != nil }, set: { if !$0 { discarding = nil } }),
                presenting: discarding
            ) { change in
                Button("Discard Changes", role: .destructive) {
                    Task { await apply { Git.discard(change, in: git.root) } }
                }
            } message: { _ in
                Text("This can't be undone.")
            }
        } else {
            ContentUnavailableView("Not a Git Repository", systemImage: "arrow.triangle.branch",
                                   description: Text("The focused session isn't in one."))
        }
    }

    private func commitBox(_ git: GitInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            GitBadge(git: git).font(.caption).foregroundStyle(.secondary)
            TextField("Message", text: $message, axis: .vertical)
                .lineLimit(1...6)
                .textFieldStyle(.roundedBorder)
            Button {
                let text = message
                Task {
                    await apply { Git.commit(text, in: git.root) }
                    if error == nil { message = "" }
                }
            } label: {
                Text("Commit").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(staged.isEmpty || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .help(staged.isEmpty ? "Stage changes to commit them (⌘↩)" : "Commit \(staged.count) staged files (⌘↩)")
            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(6)
                    .textSelection(.enabled)
            }
        }
        .padding(10)
    }

    private func header(_ title: String, count: Int, icon: String, help: String,
                        action: @escaping @Sendable () -> String?) -> some View {
        HStack {
            Text(title)
            Text("\(count)").monospacedDigit()
            Spacer()
            if store.selectedSession?.git != nil {
                Button {
                    Task { await apply(action) }
                } label: {
                    Image(systemName: icon)
                }
                .buttonStyle(.borderless)
                .help(help)
            }
        }
    }

    private func row(_ change: GitChange, staged: Bool, root: String) -> some View {
        let letter = staged ? change.index : change.worktree
        let name = (change.path as NSString).lastPathComponent
        let folder = (change.path as NSString).deletingLastPathComponent
        return HStack(spacing: 6) {
            Text(letter == "?" ? "U" : String(letter))
                .font(.caption.monospaced().bold())
                .foregroundStyle(color(of: letter))
                .frame(width: 12)
            Text(name).lineLimit(1)
            Text(folder)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 4)
            if !staged {
                Button {
                    discarding = change
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.borderless)
                .help("Discard changes")
            }
            Button {
                Task {
                    await apply { staged ? Git.unstage([change.path], in: root) : Git.stage([change.path], in: root) }
                }
            } label: {
                Image(systemName: staged ? "minus" : "plus")
            }
            .buttonStyle(.borderless)
            .help(staged ? "Unstage" : "Stage")
        }
        .tag(ChangeSelection(path: change.path, staged: staged, untracked: change.worktree == "?"))
        .help(change.path)
    }

    private func color(of letter: Character) -> Color {
        switch letter {
        case "A", "?": .green
        case "D", "U": .red
        case "R", "C": .blue
        default: .orange
        }
    }

    /// Runs a git action off the main thread and shows its error if it failed; the store then refreshes the list.
    private func apply(_ work: @escaping @Sendable () -> String?) async {
        error = await inBackground(work)
        store.selectedSession?.gitStale = true
    }
}
