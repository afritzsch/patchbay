import SwiftUI

/// Everything that happened across sessions, newest first, grouped by day.
struct HistoryView: View {
    @Environment(SessionStore.self) private var store
    @State private var search = ""
    @State private var groups = Set(HistoryGroup.allCases)
    /// Rows drawn at most: a list of all 20,000 entries would make every search keystroke slow.
    private static let shownLimit = 2000

    var body: some View {
        let entries = filtered
        VStack(spacing: 0) {
            filterBar(matching: entries.count)
            Divider()
            if entries.isEmpty {
                ContentUnavailableView {
                    Label(store.history.entries.isEmpty ? "No History Yet" : "Nothing Matches", systemImage: "clock")
                } description: {
                    Text(store.history.entries.isEmpty
                         ? "Prompts, Claude's answers and questions, commands and sessions show up here as you work."
                         : "Try another search, session or filter.")
                }
                .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(Self.days(Array(entries.prefix(Self.shownLimit))), id: \.day) { day in
                        Section(Self.dayTitle(day.day)) {
                            ForEach(day.entries) { entry in
                                HistoryRow(entry: entry, session: store.sessions.first { $0.id == entry.sessionID })
                            }
                        }
                    }
                    if entries.count > Self.shownLimit {
                        Text("Showing the latest \(Self.shownLimit). Search or filter to find older entries.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .listStyle(.inset)
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Search prompts, commands, folders")
    }

    private func filterBar(matching count: Int) -> some View {
        @Bindable var store = store
        return HStack(spacing: 12) {
            Picker("Session", selection: $store.historySessionFilter) {
                Text("All Sessions").tag(UUID?.none)
                Divider()
                ForEach(sessionChoices, id: \.id) { choice in
                    Text(choice.name).tag(UUID?.some(choice.id))
                }
            }
            .fixedSize()
            HStack(spacing: 4) {
                ForEach(HistoryGroup.allCases) { group in
                    Toggle(group.rawValue, isOn: Binding(
                        get: { groups.contains(group) },
                        set: { if $0 { groups.insert(group) } else { groups.remove(group) } }
                    ))
                    .toggleStyle(.button)
                }
            }
            .controlSize(.small)
            Spacer()
            Text("\(count) of \(store.history.entries.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var filtered: [HistoryEntry] {
        let query = search.trimmingCharacters(in: .whitespaces)
        return store.history.entries.reversed().filter { entry in
            groups.contains(entry.kind.group)
                && (store.historySessionFilter == nil || entry.sessionID == store.historySessionFilter)
                && (query.isEmpty
                    || entry.text.localizedCaseInsensitiveContains(query)
                    || entry.sessionName.localizedCaseInsensitiveContains(query)
                    || entry.directory.localizedCaseInsensitiveContains(query))
        }
    }

    private static func days(_ entries: [HistoryEntry]) -> [(day: Date, entries: [HistoryEntry])] {
        let calendar = Calendar.current
        var result: [(day: Date, entries: [HistoryEntry])] = []
        for entry in entries {
            let day = calendar.startOfDay(for: entry.date)
            if result.last?.day == day {
                result[result.count - 1].entries.append(entry)
            } else {
                result.append((day, [entry]))
            }
        }
        return result
    }

    /// Open sessions first (current names), then closed ones by their last recorded name.
    private var sessionChoices: [(id: UUID, name: String)] {
        var choices = store.sessions.map { (id: $0.id, name: $0.displayName) }
        var seen = Set(choices.map(\.id))
        for entry in store.history.entries.reversed() where !seen.contains(entry.sessionID) {
            seen.insert(entry.sessionID)
            choices.append((entry.sessionID, "\(entry.sessionName) (closed)"))
        }
        return choices
    }

    static func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
    }
}

private struct HistoryRow: View {
    @Environment(SessionStore.self) private var store
    let entry: HistoryEntry
    /// The session, if it's still open.
    let session: TerminalSession?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(entry.date, format: .dateTime.hour().minute())
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
                .padding(.top, 2)
            Image(systemName: symbol)
                .foregroundStyle(color)
                .frame(width: 16)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(entry.sessionName)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.primary.opacity(0.07), in: .rect(cornerRadius: 3))
                    Text(label)
                        .font(.caption)
                        .foregroundStyle(color)
                    if session == nil {
                        Text("closed").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                if !entry.text.isEmpty {
                    Text(entry.text)
                        .font(entry.kind == .command ? .system(.body, design: .monospaced) : .body)
                        .foregroundStyle(entry.kind == .claudeFinished ? .secondary : .primary)
                        .lineLimit(entry.kind == .prompt ? 6 : 2)
                        .textSelection(.enabled)
                }
                Text((entry.directory as NSString).abbreviatingWithTildeInPath)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .contentShape(.rect)
        .onTapGesture(count: 2) { goToSession() }
        .contextMenu { menu }
    }

    private var label: String {
        switch entry.kind {
        case .prompt: return "Prompt"
        case .claudeFinished: return "Claude finished" + (entry.duration.map { " · took \(Self.duration($0))" } ?? "")
        case .claudeNeedsInput: return "Claude asked"
        case .command:
            var text = failedCode.map { "Command failed (exit \($0))" } ?? "Command"
            if let duration = entry.duration, duration >= 1 { text += " · \(Self.duration(duration))" }
            return text
        case .sessionOpened, .sessionClosed, .movedIn: return "Session"
        }
    }

    /// A command's exit code when it failed.
    private var failedCode: Int? { entry.exitCode.flatMap { $0 == 0 ? nil : $0 } }

    private var symbol: String {
        switch entry.kind {
        case .prompt: "text.bubble"
        case .claudeFinished: "checkmark.circle.fill"
        case .claudeNeedsInput: "exclamationmark.bubble.fill"
        case .command: failedCode == nil ? "chevron.right.square" : "xmark.square"
        case .sessionOpened: "plus.circle"
        case .sessionClosed: "minus.circle"
        case .movedIn: "arrow.down.forward.square"
        }
    }

    private var color: Color {
        switch entry.kind {
        case .prompt: .purple
        case .claudeFinished: .green
        case .claudeNeedsInput: .orange
        case .command: failedCode == nil ? .blue : .red
        case .sessionOpened, .sessionClosed, .movedIn: .secondary
        }
    }

    /// The Claude conversation can be resumed when nothing runs it, here or in another terminal.
    private var canResume: Bool {
        guard let id = entry.claudeSessionID, [.prompt, .claudeFinished, .claudeNeedsInput].contains(entry.kind) else {
            return false
        }
        return !store.isRunning(claudeConversation: id) && ClaudeTranscripts.exist(for: id)
    }

    @ViewBuilder
    private var menu: some View {
        if session != nil {
            Button("Go to Session") { goToSession() }
        }
        if canResume, let id = entry.claudeSessionID {
            Button("Resume This Conversation") {
                store.newSession(directory: entry.directory, name: entry.sessionName, agent: .claude, resumeClaudeID: id)
            }
        }
        if entry.kind == .command, let session, !session.isBusy {
            Button("Run Again in “\(session.displayName)”") {
                goToSession()
                session.terminal.send(txt: entry.text + "\n")
            }
        }
        Button("Copy") { copyToPasteboard(entry.text.isEmpty ? entry.directory : entry.text) }
        Divider()
        Button("Show Only This Session") { store.historySessionFilter = entry.sessionID }
        Button("New Shell in This Folder") { store.newSession(directory: entry.directory, agent: nil) }
        Button("New \(store.menuAgent.name) Session in This Folder") { store.newSession(directory: entry.directory, agent: store.menuAgent) }
    }

    private func goToSession() {
        if let session { store.show(session.id) }
    }

    static func duration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \(s % 3600 / 60)m"
    }
}
