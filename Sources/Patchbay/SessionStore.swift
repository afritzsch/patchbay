import AppKit
import UserNotifications

enum MainMode {
    case panes, overview, history
}

enum DragPayload: Equatable {
    case session(UUID)
    case external(ExternalSession)
}

@MainActor @Observable
final class SessionStore {
    private(set) var sessions: [TerminalSession] = []
    /// The focused session. Selecting a session that isn't on screen puts it in the focused pane.
    var selectedID: UUID? {
        didSet {
            if selectedID != oldValue { reveal(selectedID, replacing: oldValue) }
            selectedSession?.markSeen()
        }
    }
    /// The panes in the main area.
    private(set) var layout: PaneLayout?
    /// What is being dragged from the sidebar or a pane header.
    @ObservationIgnored var dragged: DragPayload?
    /// Claude Code sessions running in other terminal apps.
    private(set) var externalSessions: [ExternalSession] = []
    /// The file selected in the Changes tab, whose diff is shown beside the panes.
    var selectedChange: ChangeSelection?
    /// What the main area shows.
    var mode: MainMode = .panes {
        didSet { if mode != .history { selectedSession?.markSeen() } }
    }
    var showOverview: Bool {
        get { mode == .overview }
        set { mode = newValue ? .overview : .panes }
    }
    var showHistory: Bool {
        get { mode == .history }
        set { mode = newValue ? .history : .panes }
    }
    let history = HistoryStore()
    let usage = UsageMonitor()
    /// Limits the history view to one session.
    var historySessionFilter: UUID?
    var renamingID: UUID?

    /// Overview grid: a fixed number of columns, or 0 to fit the window.
    var overviewColumns = UserDefaults.standard.integer(forKey: Keys.overviewColumns) {
        didSet { UserDefaults.standard.set(overviewColumns, forKey: Keys.overviewColumns) }
    }
    /// Relative column widths and row heights in the overview, as dragged by the user.
    var overviewColumnFractions = UserDefaults.standard.array(forKey: Keys.overviewColumnFractions) as? [Double] ?? []
    var overviewRowFractions = UserDefaults.standard.array(forKey: Keys.overviewRowFractions) as? [Double] ?? []

    func saveOverviewSizes() {
        UserDefaults.standard.set(overviewColumnFractions, forKey: Keys.overviewColumnFractions)
        UserDefaults.standard.set(overviewRowFractions, forKey: Keys.overviewRowFractions)
    }
    var showNewSessionSheet = false

    var fontSize: CGFloat = {
        let saved = UserDefaults.standard.double(forKey: Keys.fontSize)
        return saved > 0 ? saved : 13
    }() {
        didSet {
            UserDefaults.standard.set(fontSize, forKey: Keys.fontSize)
            for session in sessions { session.terminal.applyStyle(fontSize: fontSize) }
        }
    }

    private(set) var recentDirectories: [String] = UserDefaults.standard.stringArray(forKey: Keys.recentDirectories) ?? []

    @ObservationIgnored private var timers: [Timer] = []

    enum Keys {
        static let fontSize = "fontSize"
        static let recentDirectories = "recentDirectories"
        static let savedSessions = "savedSessions"
        static let savedLayout = "savedLayout"
        static let overviewColumns = "overviewColumns"
        static let overviewColumnFractions = "overviewColumnFractions"
        static let overviewRowFractions = "overviewRowFractions"
        static let restoreSessions = "restoreSessions"
        static let resumeClaude = "resumeClaude"
        static let notify = "notify"
        /// An agent's id, or "shell": what the new-session sheet starts.
        static let startAgent = "startAgent"
    }

    var selectedSession: TerminalSession? {
        sessions.first { $0.id == selectedID }
    }

    var attentionCount: Int {
        sessions.filter(\.needsAttention).count
    }

    init() {
        if let startClaude = UserDefaults.standard.object(forKey: "startClaude") as? Bool { // Replaced by startAgent.
            UserDefaults.standard.set(startClaude ? "claude" : "shell", forKey: Keys.startAgent)
            UserDefaults.standard.removeObject(forKey: "startClaude")
        }
        UserDefaults.standard.register(defaults: [
            Keys.restoreSessions: true, Keys.resumeClaude: true, Keys.notify: true, Keys.startAgent: "claude",
        ])
        do {
            try ShellIntegration.install()
        } catch {
            NSLog("Patchbay: shell integration not installed: \(error)")
        }
        timers.append(Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        })
        timers.append(Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        })
        timers.append(Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scanExternalSessions()
                self?.refreshGit()
            }
        })
        if UserDefaults.standard.bool(forKey: Keys.restoreSessions) { restore() }
    }

    // MARK: - Sessions

    @discardableResult
    func newSession(id: UUID = UUID(), directory: String, name: String? = nil, agent: Agent?, prompt: String? = nil,
                    resumeClaudeID: String? = nil, claudeArgs: [String] = [], select: Bool = true,
                    splitting target: UUID? = nil, zone: DropZone = .right) -> TerminalSession {
        var command: String?
        if let agent {
            var parts = [agent.command]
            if let resumeClaudeID { parts += ["--resume", ShellIntegration.quote(resumeClaudeID)] }
            parts += claudeArgs.map(ShellIntegration.quote)
            if let prompt, !prompt.isEmpty, agent.promptStyle != .unsupported {
                if agent.promptStyle == .interactiveFlag { parts.append("-i") }
                parts.append(ShellIntegration.quote(prompt))
            }
            command = parts.joined(separator: " ")
        }
        let dir = FileManager.default.fileExists(atPath: directory) ? directory : NSHomeDirectory()
        let session = TerminalSession(id: id, directory: dir, name: name, initialCommand: command, agent: agent,
                                      claudeSessionID: resumeClaudeID, fontSize: fontSize)
        session.isVisible = { [weak self, weak session] in
            guard let self, let session else { return false }
            // In the overview, only the card being worked in counts; the others are small and easy to miss.
            let onScreen = switch self.mode {
            case .panes: self.layout?.contains(session.id) == true
            case .overview: self.selectedID == session.id
            case .history: false
            }
            return NSApp.isActive && onScreen && NSApp.keyWindow != nil
        }
        session.onAlert = { [weak self] session, text in self?.notify(session, text) }
        session.onRecord = { [weak self] session, kind, text, exitCode, duration in
            self?.record(kind, session, text: text, exitCode: exitCode, duration: duration)
        }
        sessions.append(session)
        rememberDirectory(dir)
        if let target, let layout, layout.contains(target) {
            self.layout = layout.inserting(session.id, at: target, zone: zone)
        }
        if select {
            selectedID = session.id
            if mode == .history { mode = .panes }
            record(.sessionOpened, session, text: agent.map { resumeClaudeID != nil ? "Resumed Claude conversation" : "Started \($0.name)" } ?? "Opened shell")
        }
        save()
        return session
    }

    func record(_ kind: HistoryKind, _ session: TerminalSession, text: String, exitCode: Int? = nil, duration: Double? = nil) {
        history.record(HistoryEntry(kind: kind, sessionID: session.id, sessionName: session.displayName,
                                    directory: session.cwd, text: text, claudeSessionID: session.claudeSessionID,
                                    exitCode: exitCode, duration: duration))
    }

    /// Opens the history, optionally for one session only.
    func showHistory(for session: TerminalSession?) {
        historySessionFilter = session?.id
        mode = .history
    }

    /// What the new-session sheet started last: an agent, or nil for a plain shell.
    var lastAgent: Agent? {
        UserDefaults.standard.string(forKey: Keys.startAgent).flatMap(Agent.named)
    }

    /// The agent for "New … Session in This Folder" menu items: the last one, Claude if that was a plain shell.
    var menuAgent: Agent { lastAgent ?? .claude }

    /// A new shell in the current session's directory.
    func newShellHere() {
        newSession(directory: selectedSession?.cwd ?? NSHomeDirectory(), agent: nil)
    }

    /// A new shell in the focused session's folder, in a new pane beside it.
    func split(_ zone: DropZone) {
        guard let current = selectedSession else {
            newSession(directory: NSHomeDirectory(), agent: nil)
            return
        }
        newSession(directory: current.cwd, agent: nil, splitting: current.id, zone: zone)
    }

    func close(_ session: TerminalSession) {
        guard let index = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        let paneOrder = layout?.sessionIDs ?? []
        record(.sessionClosed, session, text: session.agent.map { "Closed (\($0.name) was running)" } ?? "Closed")
        session.close()
        sessions.remove(at: index)
        layout = layout?.removing(session.id)
        if selectedID == session.id {
            // Focus a neighbouring pane; with no panes left, show the next session in the sidebar.
            if let paneIndex = paneOrder.firstIndex(of: session.id), let remaining = layout?.sessionIDs, !remaining.isEmpty {
                selectedID = remaining[min(paneIndex, remaining.count - 1)]
            } else {
                selectedID = sessions.isEmpty ? nil : sessions[min(index, sessions.count - 1)].id
            }
        }
        save()
    }

    /// Opens a session for each folder dropped from Finder or a terminal's title-bar folder icon
    /// (a file opens its folder).
    func open(droppedURLs urls: [URL]) {
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            let folder = isDirectory.boolValue ? url.path : url.deletingLastPathComponent().path
            openFolder(folder, splitting: nil, zone: .right)
        }
    }

    /// A dropped folder where Claude is already running in another terminal offers to bring that session in.
    private func openFolder(_ folder: String, splitting target: UUID?, zone: DropZone) {
        let path = (folder as NSString).standardizingPath
        if let external = externalSessions.first(where: { ($0.cwd as NSString).standardizingPath == path }) {
            let alert = NSAlert()
            alert.messageText = "Claude Code is running in “\(external.displayName)” in \(external.hostApp ?? "another terminal")"
            alert.informativeText = "Move that session here, or start a new one in this folder?"
            alert.addButton(withTitle: "Move It Here")
            alert.addButton(withTitle: "New Session")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                bringIn(external, splitting: target, zone: zone, confirmed: true)
                return
            case .alertSecondButtonReturn:
                break
            default:
                return
            }
        }
        newSession(directory: folder, agent: lastAgent, splitting: target, zone: zone)
    }

    /// Handles something dragged into the sidebar list at `index`.
    func dropInSidebar(at index: Int) {
        defer { dragged = nil }
        switch dragged {
        case .session(let id):
            guard let from = sessions.firstIndex(where: { $0.id == id }) else { return }
            move(from: IndexSet(integer: from), to: index)
        case .external(let external):
            DispatchQueue.main.async { self.bringIn(external, splitting: nil, zone: .right) }
        case nil:
            break
        }
    }

    // MARK: - Sessions in other terminals

    private func scanExternalSessions() {
        let found = ExternalSessionScanner.scan().filter { !movingPIDs.contains($0.pid) }
        if found != externalSessions { externalSessions = found }
    }

    @ObservationIgnored private var movingPIDs: Set<pid_t> = []

    /// Moves a Claude session from another terminal into this app: quits it there, then resumes the same
    /// conversation here (in a split of `target` when given).
    func bringIn(_ external: ExternalSession, splitting target: UUID?, zone: DropZone, confirmed: Bool = false) {
        if !confirmed {
            let alert = NSAlert()
            alert.messageText = "Move “\(external.displayName)” into Patchbay?"
            var info = "Claude Code will quit in \(external.hostApp ?? "the other terminal") and the conversation "
                + "continues here (claude --resume)."
            if external.busy {
                info += "\n\nClaude is working right now; moving it interrupts the current step. You can ask it to carry on afterwards."
            }
            alert.informativeText = info
            alert.addButton(withTitle: "Move")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        movingPIDs.insert(external.pid)
        externalSessions.removeAll { $0.pid == external.pid }
        ExternalSessionScanner.terminate(external) { [weak self] ended in
            guard let self else { return }
            self.movingPIDs.remove(external.pid)
            guard ended else { NSSound.beep(); return } // Resuming while it still runs would corrupt the conversation.
            let target = target.flatMap { self.layout?.contains($0) == true ? $0 : nil }
            let session = self.newSession(directory: external.cwd, agent: .claude,
                                          resumeClaudeID: external.hasTranscript ? external.sessionID : nil,
                                          claudeArgs: external.carriedArgs, splitting: target, zone: zone)
            self.record(.movedIn, session, text: "Moved in from \(external.hostApp ?? "another terminal")")
        }
    }

    // MARK: - Git

    @ObservationIgnored private var gitRefreshInFlight = false

    /// Reads the git state of every session's folder off the main thread; one `git` run per distinct folder.
    private func refreshGit() {
        guard !gitRefreshInFlight else { return }
        gitRefreshInFlight = true
        for session in sessions { session.gitStale = false }
        let directories = Set(sessions.map(\.cwd))
        Task {
            let infos = await Task.detached {
                directories.reduce(into: [String: GitInfo]()) { $0[$1] = Git.info(at: $1) }
            }.value
            for session in sessions where directories.contains(session.cwd) && session.git != infos[session.cwd] {
                session.git = infos[session.cwd]
            }
            gitRefreshInFlight = false
        }
    }

    // MARK: - Panes

    /// Clicking into a pane's terminal focuses that session.
    func terminalBecameFirstResponder(_ responder: NSResponder?) {
        guard let terminal = responder as? SessionTerminalView,
              let session = sessions.first(where: { $0.terminal === terminal }),
              selectedID != session.id else { return }
        selectedID = session.id
    }

    /// Shows `id` in the focused pane (the one `previous` was in) unless it's already on screen.
    private func reveal(_ id: UUID?, replacing previous: UUID?) {
        guard let id else { return }
        guard let layout else {
            self.layout = .pane(id)
            return
        }
        if layout.contains(id) { return }
        let target = previous.flatMap { layout.contains($0) ? $0 : nil } ?? layout.sessionIDs[0]
        self.layout = layout.replacing(target, with: id)
    }

    /// Handles a session dropped on a pane: the centre swaps/replaces, an edge splits.
    func drop(session id: UUID, on target: UUID, zone: DropZone) {
        guard var layout, id != target else { return }
        if zone == .center {
            layout = layout.contains(id) ? layout.swapping(id, target) : layout.replacing(target, with: id)
        } else {
            layout = layout.removing(id) ?? .pane(target)
            layout = layout.inserting(id, at: target, zone: zone)
        }
        self.layout = layout
        selectedID = id
        showOverview = false
        save()
    }

    /// Opens a new session for a folder dropped on a pane edge.
    func drop(folder: String, on target: UUID, zone: DropZone) {
        openFolder(folder, splitting: target, zone: zone)
    }

    /// Removes a pane from the screen; its session keeps running in the sidebar.
    func closePane(_ id: UUID) {
        guard let layout, layout.sessionIDs.count > 1 else { return }
        let order = layout.sessionIDs
        self.layout = layout.removing(id)
        if selectedID == id, let remaining = self.layout?.sessionIDs, let index = order.firstIndex(of: id) {
            selectedID = remaining[min(index, remaining.count - 1)]
        }
        save()
    }

    func setFractions(_ fractions: [Double], forSplit id: UUID) {
        layout = layout?.settingFractions(fractions, forSplit: id)
    }

    func equalizePanes() {
        layout = layout?.equalized()
        save()
    }

    /// Moves focus through the panes in reading order.
    func focusAdjacentPane(_ offset: Int) {
        guard let ids = layout?.sessionIDs, ids.count > 1 else { return }
        let current = ids.firstIndex { $0 == selectedID } ?? 0
        selectedID = ids[(current + offset + ids.count) % ids.count]
        showOverview = false
    }

    var paneCount: Int { layout?.sessionIDs.count ?? 0 }

    /// Asks before closing a session that is still doing something.
    func confirmAndClose(_ session: TerminalSession) {
        if session.isBusy || session.agent != nil {
            let alert = NSAlert()
            alert.messageText = "Close “\(session.displayName)”?"
            alert.informativeText = session.agent.map { "\($0.name) is still running in this session." }
                ?? "A command is still running in this session."
            alert.addButton(withTitle: "Close")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        close(session)
    }

    func move(from source: IndexSet, to destination: Int) {
        sessions.move(fromOffsets: source, toOffset: destination)
        save()
    }

    func rename(_ session: TerminalSession, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        session.customName = trimmed.isEmpty ? nil : trimmed
        save()
    }

    // MARK: - Navigation

    func select(index: Int) {
        guard sessions.indices.contains(index) else { return }
        selectedID = sessions[index].id
        showOverview = false
    }

    func selectAdjacent(_ offset: Int) {
        guard !sessions.isEmpty else { return }
        let current = sessions.firstIndex { $0.id == selectedID } ?? 0
        select(index: (current + offset + sessions.count) % sessions.count)
    }

    /// Cycles through the sessions that need attention, starting after the current one.
    func selectNextNeedingAttention() {
        guard !sessions.isEmpty else { return }
        let current = sessions.firstIndex { $0.id == selectedID } ?? -1
        for step in 1...sessions.count {
            let index = (current + step) % sessions.count
            if sessions[index].needsAttention {
                select(index: index)
                return
            }
        }
        NSSound.beep()
    }

    func appBecameActive() {
        for session in sessions where session.isVisible() { session.markSeen() }
    }

    // MARK: - Polling

    private func poll() {
        for session in sessions { session.pollEvents() }
        if sessions.contains(where: \.gitStale) { refreshGit() }
        updateDockBadge()
    }

    private func tick() {
        for session in sessions {
            session.checkForSilence()
            if session.unseen, session.isVisible() { session.markSeen() }
        }
        save() // Directories and Claude session IDs change as the sessions run; unchanged state isn't written.
    }

    private var lastBadge = -1
    private func updateDockBadge() {
        let count = attentionCount
        guard count != lastBadge else { return }
        lastBadge = count
        NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
    }

    // MARK: - Notifications

    private static var notificationsAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    static func requestNotificationPermission() {
        guard notificationsAvailable else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notify(_ session: TerminalSession, _ text: String) {
        guard Self.notificationsAvailable, UserDefaults.standard.bool(forKey: Keys.notify), !session.isVisible()
        else { return }
        let content = UNMutableNotificationContent()
        content.title = session.displayName
        content.body = text
        content.sound = .default
        content.userInfo = ["session": session.id.uuidString]
        content.threadIdentifier = session.id.uuidString
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Persistence

    private struct SavedSession: Codable {
        var id: UUID?
        var name: String?
        var directory: String
        /// The agent running in it, restored by starting it again (Claude resumes `claudeSessionID` when there's a conversation).
        var agentID: String?
        var claudeSessionID: String?
        /// Saved by older versions instead of `agentID`.
        var claude: Bool?
    }

    @ObservationIgnored private var lastSaved: [Data?] = []

    func save() {
        let saved = sessions.filter(\.isAlive).map {
            SavedSession(id: $0.id, name: $0.customName, directory: $0.cwd, agentID: $0.agent?.id,
                         claudeSessionID: $0.isClaude ? $0.claudeSessionID : nil)
        }
        let state = [try? JSONEncoder().encode(saved), layout.flatMap { try? JSONEncoder().encode($0) }]
        guard state != lastSaved else { return }
        lastSaved = state
        UserDefaults.standard.set(state[0], forKey: Keys.savedSessions)
        UserDefaults.standard.set(state[1], forKey: Keys.savedLayout)
    }

    private func restore() {
        guard let data = UserDefaults.standard.data(forKey: Keys.savedSessions),
              let saved = try? JSONDecoder().decode([SavedSession].self, from: data) else { return }
        // Read before creating sessions: each new session saves, which would overwrite it.
        let savedLayout = UserDefaults.standard.data(forKey: Keys.savedLayout)
            .flatMap { try? JSONDecoder().decode(PaneLayout.self, from: $0) }
        let resume = UserDefaults.standard.bool(forKey: Keys.resumeClaude)
        for item in saved {
            let wasClaude = item.claude ?? (item.claudeSessionID != nil)
            var agent = (item.agentID ?? (wasClaude ? Agent.claude.id : nil)).flatMap(Agent.named)
            if agent == .claude, !resume { agent = nil }
            let claudeID = item.claudeSessionID.flatMap { resume && ClaudeTranscripts.exist(for: $0) ? $0 : nil }
            newSession(id: item.id ?? UUID(), directory: item.directory, name: item.name,
                       agent: agent, resumeClaudeID: claudeID, select: false)
        }
        layout = savedLayout?.keeping(Set(sessions.map(\.id)))
        selectedID = layout?.sessionIDs.first ?? sessions.first?.id
    }

    private func rememberDirectory(_ dir: String) {
        recentDirectories.removeAll { $0 == dir }
        recentDirectories.insert(dir, at: 0)
        recentDirectories = Array(recentDirectories.prefix(10))
        UserDefaults.standard.set(recentDirectories, forKey: Keys.recentDirectories)
    }
}
