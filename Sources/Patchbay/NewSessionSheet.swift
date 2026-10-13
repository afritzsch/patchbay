import SwiftUI

struct NewSessionSheet: View {
    @Environment(SessionStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SessionStore.Keys.startClaude) private var startClaude = true
    @State private var directory = ""
    @State private var name = ""
    @State private var prompt = ""

    var body: some View {
        Form {
            Section {
                HStack {
                    Picker("Folder", selection: $directory) {
                        ForEach(directoryChoices, id: \.self) { dir in
                            Text((dir as NSString).abbreviatingWithTildeInPath).tag(dir)
                        }
                    }
                    Button("Choose…", action: chooseDirectory)
                }
                TextField("Name", text: $name, prompt: Text((directory as NSString).lastPathComponent))
            }
            Section {
                Toggle("Start Claude Code", isOn: $startClaude)
                if startClaude {
                    TextField("First prompt", text: $prompt, prompt: Text("Optional"), axis: .vertical)
                        .lineLimit(2...5)
                }
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
                Button("Start") {
                    store.newSession(directory: directory, name: name.isEmpty ? nil : name,
                                     claude: startClaude, prompt: startClaude ? prompt : nil)
                    dismiss()
                }
                .disabled(directory.isEmpty)
            }
        }
        .onAppear {
            directory = store.selectedSession?.cwd ?? store.recentDirectories.first ?? NSHomeDirectory()
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
    @AppStorage(SessionStore.Keys.restoreSessions) private var restoreSessions = true
    @AppStorage(SessionStore.Keys.resumeClaude) private var resumeClaude = true
    @AppStorage(SessionStore.Keys.notify) private var notify = true
    @Environment(SessionStore.self) private var store

    var body: some View {
        @Bindable var store = store
        Form {
            Toggle("Reopen sessions on launch", isOn: $restoreSessions)
            Toggle("Resume Claude conversations when reopening", isOn: $resumeClaude)
                .disabled(!restoreSessions)
            Toggle("Notify when Claude needs input or finishes", isOn: $notify)
            Stepper("Font size: \(Int(store.fontSize)) pt", value: $store.fontSize, in: 9...28)
            Picker("Keep history for", selection: Bindable(store.history).retentionDays) {
                Text("7 days").tag(7)
                Text("30 days").tag(30)
                Text("90 days").tag(90)
                Text("1 year").tag(365)
                Text("Forever").tag(0)
            }
            LabeledContent("History") {
                Button("Clear History…") {
                    let alert = NSAlert()
                    alert.messageText = "Clear all history?"
                    alert.informativeText = "\(store.history.entries.count) entries will be deleted. Sessions and Claude conversations are not affected."
                    alert.addButton(withTitle: "Clear")
                    alert.addButton(withTitle: "Cancel")
                    if alert.runModal() == .alertFirstButtonReturn { store.history.clear() }
                }
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
    }
}
