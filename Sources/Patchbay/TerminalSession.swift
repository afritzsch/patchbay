import AppKit
import SwiftTerm

/// One terminal: a shell in a pseudo-terminal, plus what the shell integration and the agent's hooks report.
/// The state's properties read as the session's own (`session.status`) through `@dynamicMemberLookup`.
@MainActor @Observable @dynamicMemberLookup
final class TerminalSession: Identifiable {
    let id: UUID
    var customName: String?
    /// The sidebar group it is in; set through `SessionStore.move(_:to:at:)`, which keeps the order right.
    var groupID: UUID?
    /// The terminal title; Claude Code sets it to a summary of the current task.
    var title = ""
    private(set) var state: SessionState
    /// The working tree's git state; nil outside a repository.
    var git: GitInfo?
    /// Comments on its diff, waiting to be sent to the agent.
    var reviewComments: [ReviewComment] = []
    /// The session whose agent opened this one (`new_session`); only that agent may type into it or close it.
    var startedBy: UUID?

    @ObservationIgnored let terminal: SessionTerminalView
    @ObservationIgnored private var lastOutput = Date()
    @ObservationIgnored private var lastInput = Date.distantPast
    @ObservationIgnored private var screenChecked = Date.distantPast
    @ObservationIgnored private var eventReader: EventFileReader?
    /// For shells without the integration: typed in once the shell first prints something.
    @ObservationIgnored private var pendingCommand: String?
    /// Called with a short description when something happens that deserves a notification.
    @ObservationIgnored var onAlert: ((TerminalSession, String) -> Void)?
    /// Called for everything worth keeping in the activity history.
    @ObservationIgnored var onRecord: ((TerminalSession, HistoryKind, String, _ exitCode: Int?, _ duration: Double?) -> Void)?
    /// Git state may have changed (a command finished, Claude's turn ended); the store refreshes it soon.
    @ObservationIgnored var gitStale = true
    /// True while the user is looking at this session.
    @ObservationIgnored var isVisible: () -> Bool = { false }

    subscript<T>(dynamicMember keyPath: KeyPath<SessionState, T>) -> T { state[keyPath: keyPath] }

    var displayName: String {
        if let customName, !customName.isEmpty { return customName }
        let folder = (state.cwd as NSString).lastPathComponent
        return folder.isEmpty ? state.cwd : folder
    }

    init(id: UUID, directory: String, name: String?, initialCommand: String?, agent: Agent?,
         claudeSessionID: String?, fontSize: CGFloat) {
        self.id = id
        self.customName = name
        state = SessionState(cwd: directory, agent: agent, claudeSessionID: claudeSessionID)
        terminal = SessionTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        terminal.applyStyle(fontSize: fontSize)
        terminal.processDelegate = self
        terminal.onOutput = { [weak self] in self?.outputReceived() }
        terminal.onInput = { [weak self] in self?.inputSent() }
        terminal.onBell = { [weak self] in self?.bellRang() }

        let eventsFile = ShellIntegration.eventsFile(for: id)
        FileManager.default.createFile(atPath: eventsFile.path, contents: nil)
        eventReader = EventFileReader(url: eventsFile)

        let shell = ShellIntegration.userShell
        if !ShellIntegration.shellIsZsh { pendingCommand = initialCommand }
        terminal.startProcess(
            executable: shell,
            args: [],
            environment: ShellIntegration.environment(sessionID: id, initialCommand: initialCommand),
            execName: "-" + (shell as NSString).lastPathComponent,
            currentDirectory: directory
        )
    }

    func close() {
        if terminal.process.running {
            kill(terminal.process.shellPid, SIGHUP)
            terminal.terminate()
        }
        eventReader = nil
        try? FileManager.default.removeItem(at: ShellIntegration.eventsFile(for: id))
    }

    /// Changes the state, telling observers only when something actually changed: views redraw on every write.
    private func update<Result>(_ change: (inout SessionState) -> Result) -> Result {
        var next = state
        let result = change(&next)
        if next != state { state = next }
        return result
    }

    private func perform(_ effects: [SessionState.Effect]) {
        for effect in effects {
            switch effect {
            case .record(let kind, let text, let exitCode, let duration): onRecord?(self, kind, text, exitCode, duration)
            case .alert(let text): onAlert?(self, text)
            case .gitChanged: gitStale = true
            }
        }
    }

    /// Reads new events from the shell integration and Claude Code hooks. Called periodically.
    func pollEvents() {
        guard let eventReader else { return }
        for line in eventReader.readNewLines() {
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard let event = parts.first.flatMap({ SessionEvent(rawValue: String($0)) }) else { continue }
            let payload = parts.count > 1 ? String(parts[1]) : ""
            perform(update { $0.apply(event, payload: payload, visible: isVisible()) })
        }
    }

    func checkForSilence() {
        update { $0.checkForSilence(lastOutput: lastOutput) }
    }

    /// Looks for the permission prompt of an agent without hooks on screen, once its output pauses.
    func checkForApprovalPrompt() {
        guard let agent = state.agent, !agent.hasHooks, let approval = agent.approval,
              lastOutput > screenChecked, Date().timeIntervalSince(lastOutput) > 0.5 else { return }
        screenChecked = Date()
        let screen = terminal.getTerminal()
        let text = (0..<screen.rows).compactMap { screen.getLine(row: $0)?.translateToString(trimRight: true) }
        perform(update { $0.approvalPrompt(shown: approval.isShown(on: text.joined(separator: "\n"))) })
    }

    /// Answers the permission prompt by typing the agent's own keys, as the user would.
    func answerApproval(allow: Bool) {
        guard state.asksApproval, let approval = state.agent?.approval else { return }
        terminal.send(txt: Agent.Approval.keys(allow ? approval.allow : approval.deny))
    }

    /// Types the review comments into the terminal as one paste, without pressing Return, and focuses it.
    func sendReviewComments() {
        paste(ReviewComment.message(reviewComments))
        reviewComments = []
        terminal.window?.makeFirstResponder(terminal)
    }

    /// Types text into the terminal as one paste, without pressing Return.
    func paste(_ text: String) {
        // Without bracketed paste, each newline would press Return.
        terminal.send(txt: terminal.getTerminal().bracketedPasteMode
            ? "\u{1b}[200~\(text)\u{1b}[201~"
            : text.replacingOccurrences(of: "\n", with: " "))
    }

    /// Pastes text and presses Return.
    func submit(_ text: String) {
        paste(text)
        terminal.send(txt: "\r")
        promptSent(text)
    }

    func promptSent(_ text: String) {
        update { $0.promptSent(text) }
    }

    func markSeen() {
        update { $0.unseen = false }
    }

    private func outputReceived() {
        lastOutput = Date()
        if let pendingCommand {
            self.pendingCommand = nil
            terminal.send(txt: pendingCommand + "\n")
        }
        update { $0.outputReceived(sinceInput: Date().timeIntervalSince(lastInput)) }
    }

    private func inputSent() {
        lastInput = Date()
        update { $0.inputSent() }
    }

    private func bellRang() {
        perform(update { $0.bellRang(visible: isVisible()) })
    }
}

extension TerminalSession: @preconcurrency LocalProcessTerminalViewDelegate {
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        // Claude Code prefixes its title with a spinner glyph.
        var cleaned = Substring(title)
        while let first = cleaned.first, !first.isLetter, !first.isNumber { cleaned = cleaned.dropFirst() }
        let text = cleaned.trimmingCharacters(in: .whitespaces)
        self.title = text == ClaudeCode.untitled ? "" : text
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        update { $0.processExited(exitCode) }
    }
}

/// Reads lines appended to a session's events file, and starts the file over once it has read `limit` bytes:
/// hook payloads are up to 4 KB each, so a busy agent would otherwise fill the disk while the app runs.
final class EventFileReader {
    private let url: URL
    private let limit: UInt64
    private var handle: FileHandle?
    /// The file before it was started over, kept for one more read: a writer may have opened it just before.
    private var retired: FileHandle?
    private var partial = Data()

    init(url: URL, limit: UInt64 = 1 << 20) {
        self.url = url
        self.limit = limit
        handle = try? FileHandle(forReadingFrom: url)
    }

    func readNewLines() -> [String] {
        partial += (try? retired?.readToEnd()) ?? Data()
        retired = nil
        partial += (try? handle?.readToEnd()) ?? Data()
        // The writers (`>>` in the hook script and zsh) open the path for each line, so a new file at the path
        // gets the next ones. O_CREAT without O_TRUNC keeps a line a writer already put in the new file.
        if let handle, (try? handle.offset()) ?? 0 >= limit, unlink(url.path) == 0 {
            retired = handle
            let descriptor = open(url.path, O_RDONLY | O_CREAT, 0o644)
            self.handle = descriptor < 0 ? nil : FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        }
        return partial.takeLines().map { String(decoding: $0, as: UTF8.self) }
    }
}

extension Data {
    /// Takes the complete lines off the front, without their newlines; an unfinished last line stays.
    mutating func takeLines() -> [Data] {
        guard let last = lastIndex(of: UInt8(ascii: "\n")) else { return [] }
        let lines = self[..<last].split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false).map { Data($0) }
        self = Data(self[index(after: last)...])
        return lines
    }
}
