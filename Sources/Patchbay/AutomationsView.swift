import SwiftUI

/// The sidebar's Automations tab: sessions started on a schedule.
struct AutomationsView: View {
    @Environment(SessionStore.self) private var store
    @State private var editing: Automation?

    var body: some View {
        List {
            ForEach(store.automations) { automation in
                AutomationRow(automation: automation)
                    .contentShape(.rect)
                    .onTapGesture(count: 2) { editing = automation }
                    .contextMenu {
                        Button("Run Now") { store.run(automation) }
                        Button("Edit…") { editing = automation }
                        if let id = automation.lastSessionID, store.session(id) != nil {
                            Button("Show Last Run") { store.show(id) }
                        }
                        Divider()
                        Button("Delete", role: .destructive) { store.deleteAutomation(automation.id) }
                    }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if store.automations.isEmpty {
                ContentUnavailableView("No Automations", systemImage: "clock.arrow.2.circlepath",
                                       description: Text("Start an agent with a prompt, or a shell command, on a schedule."))
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Divider()
                Button {
                    editing = Automation(folder: store.selectedSession?.cwd ?? NSHomeDirectory())
                } label: {
                    Label("New Automation", systemImage: "plus")
                }
                .buttonStyle(.borderless)
            }
            .padding(10)
            .background(.bar)
        }
        .sheet(item: $editing) { AutomationSheet(automation: $0) }
    }
}

struct AutomationRow: View {
    @Environment(SessionStore.self) private var store
    let automation: Automation

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(automation.title).lineLimit(2)
                Text(automation.schedule)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let next = automation.nextRun {
                    Text("Next: \(next.formatted(.dateTime.weekday().hour().minute()))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let error = automation.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                HStack(spacing: 6) {
                    AgentBadge(name: automation.agentName)
                    Text((automation.folder as NSString).abbreviatingWithTildeInPath)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                .font(.caption2)
            }
            Spacer(minLength: 4)
            Toggle("Enabled", isOn: Binding(get: { automation.isEnabled }, set: {
                var automation = automation
                automation.isEnabled = $0
                store.saveAutomation(automation)
            }))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
        }
        .padding(.vertical, 3)
    }
}

struct AutomationSheet: View {
    @Environment(SessionStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var automation: Automation
    @State private var isRepo = false

    init(automation: Automation) {
        _automation = State(initialValue: automation)
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $automation.name, prompt: Text("Optional"))
                FolderPicker(directory: $automation.folder)
                if isRepo {
                    Toggle("New worktree for each run", isOn: $automation.newWorktree)
                }
            }
            Section {
                Picker("Start", selection: $automation.agentID) {
                    Text("Shell").tag("shell")
                    ForEach(Agent.all.filter { $0.promptStyle != .unsupported }) { Text($0.name).tag($0.id) }
                }
            }
            if let agent = Agent.named(automation.agentID) {
                PromptField(title: "First prompt", placeholder: "What should \(agent.name) do?", text: $automation.prompt)
            } else {
                PromptField(title: "Command", placeholder: "What should the shell run?", text: $automation.prompt)
            }
            Section {
                Picker("Repeat", selection: $automation.frequency) {
                    Text("Hourly").tag(Automation.Frequency.hourly)
                    Text("Daily").tag(Automation.Frequency.daily)
                    Text("Weekdays").tag(Automation.Frequency.weekdays)
                    Text("Weekly").tag(Automation.Frequency.weekly)
                }
                if automation.frequency == .weekly {
                    Picker("On", selection: $automation.weekday) {
                        ForEach(1...7, id: \.self) { Text(Calendar.current.weekdaySymbols[$0 - 1]).tag($0) }
                    }
                }
                if automation.frequency == .hourly {
                    Stepper(String(format: "At :%02d past the hour", automation.minute), value: $automation.minute, in: 0...55, step: 5)
                } else {
                    DatePicker("At", selection: time, displayedComponents: .hourAndMinute)
                }
            } footer: {
                Text("Runs while Patchbay is open. A run missed while it was closed or the Mac slept starts once it's back.")
                    .foregroundStyle(.secondary)
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
                Button("Save") {
                    store.saveAutomation(automation)
                    dismiss()
                }
                .disabled(automation.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .task(id: automation.folder) {
            let folder = automation.folder
            isRepo = await inBackground { Git.repository(at: folder) != nil }
        }
    }

    private var time: Binding<Date> {
        Binding {
            Calendar.current.date(from: DateComponents(hour: automation.hour, minute: automation.minute)) ?? Date()
        } set: {
            let time = Calendar.current.dateComponents([.hour, .minute], from: $0)
            automation.hour = time.hour ?? 0
            automation.minute = time.minute ?? 0
        }
    }
}
