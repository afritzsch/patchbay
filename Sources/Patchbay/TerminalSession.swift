import AppKit
import SwiftTerm

/// One terminal: a shell in a pseudo-terminal, plus what the shell integration and the agent's hooks report.
/// The state's properties read as the session's own (`session.status`) through `@dynamicMemberLookup`.
@MainActor @Observable @dynamicMemberLookup
final class TerminalSession: Identifiable {
    let id: UUID
    var customName: String?
    /// The terminal title; Claude Code sets it to a summary of the current task.
    var title = ""
    private(set) var state: SessionState
    /// The working tree's git state; nil outside a repository.
    var git: GitInfo?

    @ObservationIgnored let terminal: SessionTerminalView
    @ObservationIgnored private var lastOutput = Date()
    @ObservationIgnored private var lastInput = Date.distantPast
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

    init(id: UUID = UUID(), directory: String, name: String?, initialCommand: String?, agent: Agent? = nil,
         claudeSessionID: String? = nil, fontSize: CGFloat) {
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

/// Reads lines appended to a session's events file.
final class EventFileReader {
    private let handle: FileHandle?
    private var partial = Data()

    init(url: URL) {
        handle = try? FileHandle(forReadingFrom: url)
    }

    deinit {
        try? handle?.close()
    }

    func readNewLines() -> [String] {
        guard let handle, let data = try? handle.readToEnd(), !data.isEmpty else { return [] }
        partial.append(data)
        var lines: [String] = []
        while let newline = partial.firstIndex(of: UInt8(ascii: "\n")) {
            lines.append(String(decoding: partial[partial.startIndex..<newline], as: UTF8.self))
            partial.removeSubrange(partial.startIndex...newline)
        }
        return lines
    }
}
