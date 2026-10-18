import SwiftUI

/// The Settings window (⌘,).
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
                Text("Codex, Gemini and Mistral Vibe are built in. Any command added here shows as working while it runs. "
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
