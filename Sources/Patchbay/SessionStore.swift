import AppKit
import UserNotifications

enum MainMode {
    case panes, overview, history
}

enum SidebarTab {
    case sessions, changes, automations
}

enum DragPayload: Equatable {
    case session(UUID)
    case external(ExternalSession)
}

/// A named section of the sidebar. Its sessions are kept together in `SessionStore.sessions`.
struct SessionGroup: Codable, Identifiable {
    /// The Pinned group's, which is kept above the others.
    static let pinnedID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    var id = UUID()
    var name: String
    var isExpanded = true
}

@MainActor @Observable
final class SessionStore {
    /// In sidebar order: the groups' sessions in the groups' order, then the ungrouped ones.
    private(set) var sessions: [TerminalSession] = []
    var groups: [SessionGroup] = [] {
        didSet { save() }
    }
    /// Sessions started on a schedule (`Automations.swift`).
    var automations = Preferences.load([Automation].self, forKey: Preferences.Keys.automations) ?? [] {
        didSet { Preferences.save(automations, forKey: Preferences.Keys.automations) }
    }
    /// The sessions picked with ⌘- or ⇧-click in the sidebar for a bulk action; empty, never one, otherwise.
    var multiSelection: Set<UUID> = []
    /// The focused session. Selecting a session that isn't on screen puts it in the focused pane.
    var selectedID: UUID? {
        didSet {
            if selectedID != oldValue {
                multiSelection = []
                reveal(selectedID, replacing: oldValue)
            }
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
    /// A file and 1-based line for the diff inspector to open in its editor, e.g. after ⌘-clicking a definition.
    var editorTarget: (path: String, line: Int)?
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
        set {
            historySessionFilter = nil
            mode = newValue ? .history : .panes
        }
    }
    let history = HistoryStore()
    let languageServers = LanguageServers()
    let usage = UsageMonitor()
    /// Limits the history view to one session.
    var historySessionFilter: UUID?
    var renamingID: UUID?

    /// Overview grid: a fixed number of columns, or 0 to fit the window.
    var overviewColumns = UserDefaults.standard.integer(forKey: Preferences.Keys.overviewColumns) {
        didSet { UserDefaults.standard.set(overviewColumns, forKey: Preferences.Keys.overviewColumns) }
    }
    /// Relative column widths and row heights in the overview, as dragged by the user.
    var overviewColumnFractions = UserDefaults.standard.array(forKey: Preferences.Keys.overviewColumnFractions) as? [Double] ?? [] {
        didSet { UserDefaults.standard.set(overviewColumnFractions, forKey: Preferences.Keys.overviewColumnFractions) }
    }
    var overviewRowFractions = UserDefaults.standard.array(forKey: Preferences.Keys.overviewRowFractions) as? [Double] ?? [] {
        didSet { UserDefaults.standard.set(overviewRowFractions, forKey: Preferences.Keys.overviewRowFractions) }
    }
    var sidebarTab = SidebarTab.sessions
    /// The automation open in the automation sheet.
    var editingAutomation: Automation?
    var showNewSessionSheet = false
    /// The folder the new-session sheet starts with, instead of the focused session's.
    var newSessionFolder: String?

    /// Opens the new-session sheet for `folder` with "New worktree" on.
    func newWorktreeSession(in folder: String) {
        UserDefaults.standard.set(true, forKey: Preferences.Keys.newWorktree)
        newSessionFolder = folder
        showNewSessionSheet = true
    }

    var fontSize = CGFloat(UserDefaults.standard.double(forKey: Preferences.Keys.fontSize)) {
        didSet {
            UserDefaults.standard.set(fontSize, forKey: Preferences.Keys.fontSize)
            for session in sessions { session.terminal.applyStyle(fontSize: fontSize) }
        }
    }

    private(set) var recentDirectories: [String] = UserDefaults.standard.stringArray(forKey: Preferences.Keys.recentDirectories) ?? []

    var selectedSession: TerminalSession? { session(selectedID) }

    func session(_ id: UUID?) -> TerminalSession? {
        sessions.first { $0.id == id }
    }

    var attentionCount: Int {
        sessions.filter(\.needsAttention).count
    }

    /// Answers the agents' Patchbay tools (`AgentTools.swift`).
    @ObservationIgnored private var controlServer: ControlServer?

    init() {
        do {
            try ShellIntegration.install()
        } catch {
            NSLog("Patchbay: shell integration not installed: \(error)")
        }
        controlServer = ControlServer { [unowned self] line, caller in await handleMCP(line, caller: caller) }
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scanExternalSessions()
                self?.usage.reload()
            }
        }
        // Sessions mark their git state stale when a command or tool finishes; this catches changes made elsewhere.
        Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshGit(all: true) }
        }
        if UserDefaults.standard.bool(forKey: Preferences.Keys.restoreSessions) { restore() }
    }

    // MARK: - Sessions

    /// `restoring`: reopened from the last run, so it isn't focused, and isn't new to the recent folders or the history.
    /// `select`: focus it (an agent's `new_session` doesn't, so the user's focus stays where it is).
    @discardableResult
    func newSession(id: UUID = UUID(), directory: String, name: String? = nil, agent: Agent?, prompt: String? = nil,
                    setup: String? = nil, resumeClaudeID: String? = nil, claudeArgs: [String] = [], restoring: Bool = false,
                    select: Bool = true, splitting target: UUID? = nil, zone: DropZone = .right) -> TerminalSession {
        let resume = resumeClaudeID.map { ["--resume", $0] } ?? []
        var command = agent?.commandLine(arguments: resume + claudeArgs, prompt: prompt)
        if let setup { command = [setup, command].compactMap { $0 }.joined(separator: " && ") }
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
        if let prompt, !prompt.isEmpty, agent?.promptStyle ?? .unsupported != .unsupported { session.promptSent(prompt) }
        sessions.append(session)
        if let target, let layout, layout.contains(target) {
            self.layout = layout.inserting(session.id, at: target, zone: zone)
        }
        if !restoring {
            rememberDirectory(dir)
            if select {
                selectedID = session.id
                if mode == .history { mode = .panes }
            } else if selectedID == nil { // Nothing on screen to keep: show it rather than an empty window.
                selectedID = session.id
            }
            record(.sessionOpened, session, text: agent.map { resumeClaudeID != nil ? "Resumed Claude conversation" : "Started \($0.name)" } ?? "Opened shell")
        }
        save()
        return session
    }

    func record(_ kind: HistoryKind, _ session: TerminalSession, text: String, exitCode: Int? = nil, duration: Double? = nil) {
        history.record(HistoryEntry(kind: kind, sessionID: session.id, sessionName: session.displayName,
                                    directory: session.cwd, text: text, agent: session.agent?.name,
                                    claudeSessionID: session.claudeSessionID,
                                    exitCode: exitCode, duration: duration))
    }

    /// Opens the history, optionally for one session only.
    func showHistory(for session: TerminalSession?) {
        historySessionFilter = session?.id
        mode = .history
    }

    /// What the new-session sheet started last: an agent, or nil for a plain shell.
    var lastAgent: Agent? {
        UserDefaults.standard.string(forKey: Preferences.Keys.startAgent).flatMap(Agent.named)
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
        record(.sessionClosed, session, text: session.agent.map { "Closed (\($0.name) was running)" } ?? "Closed")
        session.close()
        sessions.remove(at: index)
        tidyGroups()
        if multiSelection.remove(session.id) != nil, multiSelection.count < 2 { multiSelection = [] }
        removePane(session.id)
        if selectedID == session.id { // No panes left: show the next session in the sidebar.
            selectedID = sessions.isEmpty ? nil : sessions[min(index, sessions.count - 1)].id
        }
        save()
    }

    // MARK: - Sessions in other terminals

    /// The Claude session running in `folder` in another terminal, if any.
    func externalSession(in folder: String) -> ExternalSession? {
        let path = (folder as NSString).standardizingPath
        return externalSessions.first { ($0.cwd as NSString).standardizingPath == path }
    }

    /// Off the main thread: the scan reads files and walks process trees.
    private func scanExternalSessions() {
        Task {
            let found = await inBackground { ExternalSessionScanner.scan() }.filter { !movingPIDs.contains($0.pid) }
            if found != externalSessions { externalSessions = found }
        }
    }

    /// Whether a Claude conversation is open in a session here or in another terminal; resuming it a second
    /// time would corrupt it.
    func isRunning(claudeConversation id: String) -> Bool {
        sessions.contains { $0.isClaude && $0.claudeSessionID == id } || externalSessions.contains { $0.sessionID == id }
    }

    @ObservationIgnored private var movingPIDs: Set<pid_t> = []

    /// Moves a Claude session from another terminal into this app: quits it there, then resumes the same
    /// conversation here (in a split of `target` when given).
    func bringIn(_ external: ExternalSession, splitting target: UUID?, zone: DropZone) {
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
    /// The Changes tab is showing: the focused session's git state is refreshed every second.
    @ObservationIgnored var watchingChanges = false

    /// Sessions running an agent in the checkout that contains `directory`. Each worktree is a checkout of its own,
    /// also one inside the repository's folder, so the deepest checkout counts.
    func agentSessions(inCheckoutOf directory: String) -> [TerminalSession] {
        let roots = Set(sessions.compactMap(\.git?.root)).filter { directory == $0 || directory.hasPrefix($0 + "/") }
        guard let root = roots.max(by: { $0.count < $1.count }) else { return [] }
        return sessions.filter { $0.agent != nil && $0.git?.root == root }
    }

    /// Opens a file of the focused session's repository in the inspector's editor, changed or not.
    func openInEditor(path: String, line: Int) {
        let change = selectedSession?.git?.changes.first { $0.path == path }
        editorTarget = (path, line)
        selectedChange = ChangeSelection(path: path, staged: false, untracked: change?.isUntracked == true)
    }

    /// Reads the git state of the stale sessions' folders (every session's with `all`) off the main thread;
    /// one `git` run per distinct folder.
    private func refreshGit(all: Bool = false) {
        let refreshing = sessions.filter { all || $0.gitStale }
        guard !gitRefreshInFlight, !refreshing.isEmpty else { return }
        gitRefreshInFlight = true
        for session in refreshing { session.gitStale = false }
        let directories = Set(refreshing.map(\.cwd))
        Task {
            let infos = await inBackground {
                directories.reduce(into: [String: GitInfo]()) { $0[$1] = Git.info(at: $1) }
            }
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
        show(id)
        save()
    }

    /// Removes a pane from the screen; its session keeps running in the sidebar.
    func closePane(_ id: UUID) {
        guard let layout, layout.sessionIDs.count > 1 else { return }
        removePane(id)
        save()
    }

    /// Takes `id`'s pane out of the layout; when it was focused, the neighbouring pane gets the focus.
    private func removePane(_ id: UUID) {
        let order = layout?.sessionIDs ?? []
        layout = layout?.removing(id)
        if selectedID == id, let index = order.firstIndex(of: id), let remaining = layout?.sessionIDs {
            selectedID = remaining[min(index, remaining.count - 1)]
        }
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
        show(ids[(current + offset + ids.count) % ids.count])
    }

    var paneCount: Int { layout?.sessionIDs.count ?? 0 }

    /// Replaces the panes with these sessions, in an even grid.
    func showAsPanes(_ ids: [UUID]) {
        guard let first = ids.first else { return }
        layout = .grid(ids)
        show(first)
        save()
    }

    func rename(_ session: TerminalSession, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        session.customName = trimmed.isEmpty ? nil : trimmed
        save()
    }

    // MARK: - Groups

    /// Puts these sessions in a new group and asks for its name.
    func newGroup(with ids: [UUID]) {
        let group = SessionGroup(name: "Group \(groups.count + 1)")
        groups.append(group)
        move(ids, to: group.id)
        renamingID = group.id
    }

    /// Moves a session into the Pinned group, or out of it into Ungrouped.
    func togglePin(_ session: TerminalSession) {
        guard session.groupID != SessionGroup.pinnedID else { return move([session.id], to: nil) }
        if groups.first?.id != SessionGroup.pinnedID {
            groups.insert(SessionGroup(id: SessionGroup.pinnedID, name: "Pinned"), at: 0)
        }
        move([session.id], to: SessionGroup.pinnedID)
    }

    /// Moves sessions into a group (nil: out of their groups), before the group's `index`-th session or at its end.
    func move(_ ids: [UUID], to group: UUID?, at index: Int? = nil) {
        let anchor = index.flatMap { sessions.filter { $0.groupID == group }.dropFirst($0).first { !ids.contains($0.id) } }
        let moving = sessions.filter { ids.contains($0.id) }
        sessions.removeAll { ids.contains($0.id) }
        for session in moving { session.groupID = group }
        sessions.insert(contentsOf: moving, at: anchor.flatMap { anchor in sessions.firstIndex { $0 === anchor } } ?? sessions.count)
        tidyGroups()
        multiSelection = []
        save()
    }

    func renameGroup(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[index].name = trimmed
    }

    /// Drops groups left empty and sorts the sessions into their groups' order (a stable sort, so each keeps its place).
    private func tidyGroups() {
        groups.removeAll { group in !sessions.contains { $0.groupID == group.id } }
        let order = Dictionary(uniqueKeysWithValues: groups.enumerated().map { ($1.id, $0) })
        let rank = { (session: TerminalSession) in session.groupID.flatMap { order[$0] } ?? order.count }
        sessions.sort { rank($0) < rank($1) }
    }

    // MARK: - Navigation

    /// Focuses a session in the panes, leaving the overview or history.
    func show(_ id: UUID) {
        multiSelection = []
        selectedID = id
        mode = .panes
    }

    func select(index: Int) {
        guard sessions.indices.contains(index) else { return }
        show(sessions[index].id)
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
        refreshGit()
        updateDockBadge()
    }

    private func tick() {
        for session in sessions {
            session.checkForSilence()
            session.checkForApprovalPrompt()
            if session.unseen, session.isVisible() { session.markSeen() }
        }
        if watchingChanges { selectedSession?.gitStale = true }
        runDueAutomations()
        save() // Directories and Claude session IDs change as the sessions run; unchanged state isn't written.
    }

    private func updateDockBadge() {
        let label = attentionCount > 0 ? "\(attentionCount)" : nil
        if NSApp.dockTile.badgeLabel != label { NSApp.dockTile.badgeLabel = label }
    }

    // MARK: - Notifications

    private static var notificationsAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    private func notify(_ session: TerminalSession, _ text: String) {
        guard Self.notificationsAvailable, UserDefaults.standard.bool(forKey: Preferences.Keys.notify), !session.isVisible()
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
        var groupID: UUID?
        var startedBy: UUID?
    }

    @ObservationIgnored private var lastSaved: [Data?] = []

    func save() {
        let saved = sessions.filter(\.isAlive).map {
            SavedSession(id: $0.id, name: $0.customName, directory: $0.cwd, agentID: $0.agent?.id,
                         claudeSessionID: $0.isClaude ? $0.claudeSessionID : nil, groupID: $0.groupID,
                         startedBy: $0.startedBy)
        }
        let state = [try? JSONEncoder().encode(saved), layout.flatMap { try? JSONEncoder().encode($0) },
                     try? JSONEncoder().encode(groups)]
        guard state != lastSaved else { return }
        lastSaved = state
        UserDefaults.standard.set(state[0], forKey: Preferences.Keys.savedSessions)
        UserDefaults.standard.set(state[1], forKey: Preferences.Keys.savedLayout)
        UserDefaults.standard.set(state[2], forKey: Preferences.Keys.savedGroups)
    }

    private func restore() {
        guard let saved = Preferences.load([SavedSession].self, forKey: Preferences.Keys.savedSessions) else { return }
        // Read before creating sessions: each new session saves, which would overwrite it.
        let savedLayout = Preferences.load(PaneLayout.self, forKey: Preferences.Keys.savedLayout)
        let savedGroups = Preferences.load([SessionGroup].self, forKey: Preferences.Keys.savedGroups) ?? []
        let resume = UserDefaults.standard.bool(forKey: Preferences.Keys.resumeClaude)
        for item in saved {
            var agent = item.agentID.flatMap(Agent.named)
            if agent == .claude, !resume { agent = nil }
            let claudeID = item.claudeSessionID.flatMap { resume && ClaudeTranscripts.exist(for: $0) ? $0 : nil }
            let session = newSession(id: item.id ?? UUID(), directory: item.directory, name: item.name,
                                     agent: agent, resumeClaudeID: claudeID, restoring: true)
            session.groupID = item.groupID
            session.startedBy = item.startedBy
        }
        groups = savedGroups
        tidyGroups()
        layout = savedLayout?.keeping(Set(sessions.map(\.id)))
        selectedID = layout?.sessionIDs.first ?? sessions.first?.id
    }

    private func rememberDirectory(_ dir: String) {
        recentDirectories.removeAll { $0 == dir }
        recentDirectories.insert(dir, at: 0)
        recentDirectories = Array(recentDirectories.prefix(10))
        UserDefaults.standard.set(recentDirectories, forKey: Preferences.Keys.recentDirectories)
    }
}
