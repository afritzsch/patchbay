import AppKit
import SwiftTerm

enum SessionStatus: Equatable {
    case starting
    /// Shell at its prompt.
    case idle
    /// Shell running a command.
    case running(String)
    /// An agent is open and waiting for a prompt.
    case agentReady
    case agentWorking
    /// An agent is blocked on the user (permission prompt, question).
    case agentNeedsInput
    /// An agent finished its turn.
    case agentDone
    case exited(Int32?)
}

/// One terminal: a shell in a pseudo-terminal, plus what the shell integration and the agent's hooks report.
@MainActor @Observable
final class TerminalSession: Identifiable {
    let id: UUID
    var customName: String?
    var cwd: String
    /// The terminal title; Claude Code sets it to a summary of the current task.
    var title = ""
    private(set) var status: SessionStatus = .starting
    private(set) var statusSince = Date()
    /// The agent running in the foreground, or nil for a plain shell.
    private(set) var agent: Agent?
    var isClaude: Bool { agent == .claude }
    private(set) var claudeSessionID: String?
    private(set) var lastPrompt: String?
    /// Latest Claude notification, or what a finished command did.
    private(set) var message: String?
    private(set) var currentTool: String?
    /// Subagent calls (Task/Agent tool) that have started but not finished.
    private(set) var runningSubagents = 0
    /// Something happened the user hasn't looked at yet (Claude finished, a long command ended, a bell).
    var unseen = false
    /// The working tree's git state; nil outside a repository.
    var git: GitInfo?

    @ObservationIgnored let terminal: SessionTerminalView
    @ObservationIgnored private(set) var lastOutput = Date()
    @ObservationIgnored private var eventReader: EventFileReader?
    /// Called with a short description when something happens that deserves a notification.
    @ObservationIgnored var onAlert: ((TerminalSession, String) -> Void)?
    /// Called for everything worth keeping in the activity history.
    @ObservationIgnored var onRecord: ((TerminalSession, HistoryKind, String, _ exitCode: Int?, _ duration: Double?) -> Void)?
    @ObservationIgnored private var promptStarted: Date?
    /// Git state may have changed (a command finished, Claude's turn ended); the store refreshes it soon.
    @ObservationIgnored var gitStale = true
    /// The foreground command line and when it started, from `ShellExec` until `ShellPrompt`.
    @ObservationIgnored private var command: (line: String, started: Date)?
    @ObservationIgnored private var lastInput = Date.distantPast
    /// True while the user is looking at this session.
    @ObservationIgnored var isVisible: () -> Bool = { false }

    var displayName: String {
        if let customName, !customName.isEmpty { return customName }
        return (cwd as NSString).lastPathComponent.isEmpty ? cwd : (cwd as NSString).lastPathComponent
    }

    var needsAttention: Bool {
        status == .agentNeedsInput || unseen
    }

    var isBusy: Bool {
        switch status {
        case .running, .agentWorking, .agentNeedsInput: true
        default: false
        }
    }

    var isAlive: Bool {
        if case .exited = status { return false }
        return true
    }

    /// A session started with an agent counts as running it before its first event, so an early save keeps it.
    init(id: UUID = UUID(), directory: String, name: String?, initialCommand: String?, agent: Agent? = nil,
         claudeSessionID: String? = nil, fontSize: CGFloat) {
        self.id = id
        self.cwd = directory
        self.customName = name
        self.agent = agent
        self.claudeSessionID = claudeSessionID
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
        terminal.startProcess(
            executable: shell,
            args: [],
            environment: ShellIntegration.environment(sessionID: id, initialCommand: initialCommand),
            execName: "-" + (shell as NSString).lastPathComponent,
            currentDirectory: directory
        )
        if let initialCommand, !ShellIntegration.shellIsZsh {
            // Other shells have no integration; type the command once the shell is up.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.terminal.send(txt: initialCommand + "\n")
            }
        }
    }

    func close() {
        if terminal.process.running {
            kill(terminal.process.shellPid, SIGHUP)
            terminal.terminate()
        }
        eventReader = nil
        try? FileManager.default.removeItem(at: ShellIntegration.eventsFile(for: id))
    }

    // MARK: - Status

    private func setStatus(_ new: SessionStatus) {
        guard new != status else { return }
        status = new
        statusSince = Date()
    }

    /// Reads new events from the shell integration and Claude Code hooks. Called periodically.
    func pollEvents() {
        guard let eventReader else { return }
        for line in eventReader.readNewLines() {
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard let event = parts.first.map(String.init) else { continue }
            handle(event: event, payload: parts.count > 1 ? String(parts[1]) : "")
        }
    }

    private func handle(event: String, payload: String) {
        switch event {
        case "ShellExec":
            command = (payload, Date())
            lastOutput = Date() // So a quiet agent isn't taken for idle right away.
            agent = Agent.running(payload)
            // Claude reports its status through hooks; other agents have none, so they count as working
            // while their output flows (see outputReceived and checkForSilence).
            setStatus(agent == nil || isClaude ? .running(payload) : .agentWorking)
            message = nil
        case "ShellPrompt":
            let fields = payload.split(separator: "\t", maxSplits: 1).map(String.init)
            if fields.count == 2 { cwd = fields[1] }
            if let command {
                let exitCode = fields.first ?? "0"
                let duration = Date().timeIntervalSince(command.started)
                onRecord?(self, .command, command.line, Int(exitCode), duration)
                if duration > 10, !isVisible(), Agent.running(command.line) != .claude {
                    let text = exitCode == "0" ? "Finished: \(command.line)" : "Failed (exit \(exitCode)): \(command.line)"
                    message = text
                    unseen = true
                    onAlert?(self, text)
                }
            }
            command = nil
            agent = nil
            currentTool = nil
            gitStale = true
            setStatus(.idle)
        case "SessionStart":
            let json = HookPayload(payload)
            claudeEvent()
            claudeSessionID = json["session_id"] ?? claudeSessionID
            if let dir = json["cwd"] { cwd = dir }
            setStatus(.agentReady)
        case "UserPromptSubmit":
            let json = HookPayload(payload)
            claudeEvent()
            if let prompt = json["prompt"]?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty {
                lastPrompt = prompt
                claudeSessionID = json["session_id"] ?? claudeSessionID
                onRecord?(self, .prompt, prompt, nil, nil)
            }
            promptStarted = Date()
            message = nil
            currentTool = nil
            runningSubagents = 0
            unseen = false
            setStatus(.agentWorking)
        case "PreToolUse":
            claudeEvent()
            currentTool = HookPayload(payload)["tool_name"]
            if Self.isSubagentTool(currentTool) { runningSubagents += 1 }
            if status != .agentNeedsInput { setStatus(.agentWorking) }
        case "PostToolUse":
            claudeEvent()
            if Self.isSubagentTool(HookPayload(payload)["tool_name"]) { runningSubagents = max(0, runningSubagents - 1) }
            currentTool = nil
            setStatus(.agentWorking)
        case "Notification":
            claudeEvent()
            let text = HookPayload(payload)["message"] ?? "Claude needs your attention"
            if text.localizedCaseInsensitiveContains("waiting for your input") {
                // The idle reminder after a finished turn, not a question.
                if status != .agentDone, runningSubagents == 0 { setStatus(.agentReady) }
                return
            }
            message = text
            setStatus(.agentNeedsInput)
            onRecord?(self, .claudeNeedsInput, text, nil, nil)
            onAlert?(self, text)
        case "Stop":
            claudeEvent()
            currentTool = nil
            runningSubagents = 0
            message = nil
            gitStale = true
            setStatus(.agentDone)
            onRecord?(self, .claudeFinished, lastPrompt ?? "", nil, promptStarted.map { Date().timeIntervalSince($0) })
            promptStarted = nil
            if !isVisible() {
                unseen = true
                onAlert?(self, lastPrompt.map { "Done: \($0)" } ?? "Claude finished")
            }
        case "SessionEnd":
            agent = nil
            currentTool = nil
            runningSubagents = 0
            setStatus(.idle)
        default:
            break
        }
    }

    private static func isSubagentTool(_ name: String?) -> Bool { name == "Task" || name == "Agent" }

    /// A Claude Code hook event: Claude is running, and its hooks (not the shell's command line) now track it.
    private func claudeEvent() {
        agent = .claude
        command = nil
    }

    /// Claude's spinner redraws the screen continuously while it works, so a "working" session that has
    /// been silent for a while was interrupted (Esc/Ctrl-C fire no hook) and is waiting for the user.
    func checkForSilence() {
        if status == .agentWorking, runningSubagents == 0, Date().timeIntervalSince(lastOutput) > 8 {
            currentTool = nil
            setStatus(.agentReady)
        }
    }

    func markSeen() {
        if unseen { unseen = false }
    }

    private func outputReceived() {
        lastOutput = Date()
        // Without hooks, output that isn't the echo of typing means the agent is working again.
        if status == .agentReady, agent != nil, !isClaude, Date().timeIntervalSince(lastInput) > 0.5 {
            setStatus(.agentWorking)
        }
    }

    private func inputSent() {
        lastInput = Date()
        // Answering a permission prompt: either a tool runs (PostToolUse follows) or Claude stops,
        // which the silence check picks up.
        if status == .agentNeedsInput {
            message = nil
            setStatus(.agentWorking)
        }
    }

    private func bellRang() {
        guard !isVisible(), !isClaude else { return } // Claude's own bell duplicates its Notification hook.
        unseen = true
        message = "Bell"
        onAlert?(self, "Bell")
    }
}

extension TerminalSession: @preconcurrency LocalProcessTerminalViewDelegate {
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        // Claude Code prefixes its title with a spinner glyph and uses "Claude Code" when it has no task yet.
        var cleaned = Substring(title)
        while let first = cleaned.first, !first.isLetter, !first.isNumber { cleaned = cleaned.dropFirst() }
        let text = cleaned.trimmingCharacters(in: .whitespaces)
        self.title = text == "Claude Code" ? "" : text
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        agent = nil
        currentTool = nil
        setStatus(.exited(exitCode))
    }
}

/// Fields of a Claude Code hook payload. The hook script truncates long payloads, so when the JSON
/// doesn't parse, string fields are picked out with a pattern instead.
struct HookPayload {
    private var fields: [String: String] = [:]
    private let raw: String

    init(_ raw: String) {
        self.raw = raw
        if let data = raw.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for (key, value) in object {
                if let s = value as? String { fields[key] = s }
            }
        }
    }

    subscript(key: String) -> String? {
        if let value = fields[key] { return value }
        guard let regex = try? NSRegularExpression(pattern: "\"\(key)\"\\s*:\\s*\"((?:[^\"\\\\]|\\\\.)*)")
        else { return nil }
        let range = NSRange(raw.startIndex..., in: raw)
        guard let match = regex.firstMatch(in: raw, range: range),
              let valueRange = Range(match.range(at: 1), in: raw) else { return nil }
        let escaped = String(raw[valueRange])
        // Decode JSON escapes by parsing the value as a complete string; a cut-off escape falls back to raw.
        if let data = "\"\(escaped)\"".data(using: .utf8),
           let decoded = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) as? String {
            return decoded
        }
        return escaped
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
