import AppKit
import SwiftTerm

enum SessionStatus: Equatable {
    case starting
    /// Shell at its prompt.
    case idle
    /// Shell running a command.
    case running(String)
    /// Claude Code is open and waiting for a prompt.
    case claudeReady
    case claudeWorking
    /// Claude Code is blocked on the user (permission prompt, question).
    case claudeNeedsInput
    /// Claude Code finished its turn.
    case claudeDone
    case exited(Int32?)
}

/// One terminal: a shell in a pseudo-terminal, plus what the shell integration and Claude Code hooks report.
@MainActor @Observable
final class TerminalSession: Identifiable {
    let id: UUID
    var customName: String?
    var cwd: String
    /// The terminal title; Claude Code sets it to a summary of the current task.
    var title = ""
    private(set) var status: SessionStatus = .starting
    private(set) var statusSince = Date()
    private(set) var isClaude = false
    private(set) var claudeSessionID: String?
    private(set) var lastPrompt: String?
    /// Latest Claude notification, or what a finished command did.
    private(set) var message: String?
    private(set) var currentTool: String?
    /// Something happened the user hasn't looked at yet (Claude finished, a long command ended, a bell).
    var unseen = false

    @ObservationIgnored let terminal: SessionTerminalView
    @ObservationIgnored private(set) var lastOutput = Date()
    @ObservationIgnored private var eventReader: EventFileReader?
    /// Called with a short description when something happens that deserves a notification.
    @ObservationIgnored var onAlert: ((TerminalSession, String) -> Void)?
    /// Called for everything worth keeping in the activity history.
    @ObservationIgnored var onRecord: ((TerminalSession, HistoryKind, String, _ exitCode: Int?, _ duration: Double?) -> Void)?
    @ObservationIgnored private var promptStarted: Date?
    /// True while the user is looking at this session.
    @ObservationIgnored var isVisible: () -> Bool = { false }

    var displayName: String {
        if let customName, !customName.isEmpty { return customName }
        return (cwd as NSString).lastPathComponent.isEmpty ? cwd : (cwd as NSString).lastPathComponent
    }

    var needsAttention: Bool {
        status == .claudeNeedsInput || unseen
    }

    var isBusy: Bool {
        switch status {
        case .running, .claudeWorking, .claudeNeedsInput: true
        default: false
        }
    }

    var isAlive: Bool {
        if case .exited = status { return false }
        return true
    }

    /// A session started with Claude counts as Claude before its first hook event, so an early save keeps it.
    init(id: UUID = UUID(), directory: String, name: String?, initialCommand: String?, startsClaude: Bool = false,
         claudeSessionID: String? = nil, fontSize: CGFloat) {
        self.id = id
        self.cwd = directory
        self.customName = name
        self.isClaude = startsClaude
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
            setStatus(.running(payload))
            message = nil
        case "ShellPrompt":
            let fields = payload.split(separator: "\t", maxSplits: 1).map(String.init)
            if fields.count == 2 { cwd = fields[1] }
            if case .running(let command) = status {
                let exitCode = fields.first ?? "0"
                let duration = Date().timeIntervalSince(statusSince)
                onRecord?(self, .command, command, Int(exitCode), duration)
                if duration > 10, !isVisible(), !command.hasPrefix("claude") {
                    let text = exitCode == "0" ? "Finished: \(command)" : "Failed (exit \(exitCode)): \(command)"
                    message = text
                    unseen = true
                    onAlert?(self, text)
                }
            }
            isClaude = false
            currentTool = nil
            setStatus(.idle)
        case "SessionStart":
            let json = HookPayload(payload)
            isClaude = true
            claudeSessionID = json["session_id"] ?? claudeSessionID
            if let dir = json["cwd"] { cwd = dir }
            setStatus(.claudeReady)
        case "UserPromptSubmit":
            let json = HookPayload(payload)
            isClaude = true
            if let prompt = json["prompt"]?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty {
                lastPrompt = prompt
                claudeSessionID = json["session_id"] ?? claudeSessionID
                onRecord?(self, .prompt, prompt, nil, nil)
            }
            promptStarted = Date()
            message = nil
            currentTool = nil
            unseen = false
            setStatus(.claudeWorking)
        case "PreToolUse":
            isClaude = true
            currentTool = HookPayload(payload)["tool_name"]
            if status != .claudeNeedsInput { setStatus(.claudeWorking) }
        case "PostToolUse":
            isClaude = true
            currentTool = nil
            setStatus(.claudeWorking)
        case "Notification":
            isClaude = true
            let text = HookPayload(payload)["message"] ?? "Claude needs your attention"
            if text.localizedCaseInsensitiveContains("waiting for your input") {
                // The idle reminder after a finished turn, not a question.
                if status != .claudeDone { setStatus(.claudeReady) }
                return
            }
            message = text
            setStatus(.claudeNeedsInput)
            onRecord?(self, .claudeNeedsInput, text, nil, nil)
            onAlert?(self, text)
        case "Stop":
            isClaude = true
            currentTool = nil
            message = nil
            setStatus(.claudeDone)
            onRecord?(self, .claudeFinished, lastPrompt ?? "", nil, promptStarted.map { Date().timeIntervalSince($0) })
            promptStarted = nil
            if !isVisible() {
                unseen = true
                onAlert?(self, lastPrompt.map { "Done: \($0)" } ?? "Claude finished")
            }
        case "SessionEnd":
            isClaude = false
            currentTool = nil
            setStatus(.idle)
        default:
            break
        }
    }

    /// Claude's spinner redraws the screen continuously while it works, so a "working" session that has
    /// been silent for a while was interrupted (Esc/Ctrl-C fire no hook) and is waiting for the user.
    func checkForSilence() {
        if status == .claudeWorking, Date().timeIntervalSince(lastOutput) > 8 {
            currentTool = nil
            setStatus(.claudeReady)
        }
    }

    func markSeen() {
        if unseen { unseen = false }
    }

    private func outputReceived() {
        lastOutput = Date()
    }

    private func inputSent() {
        // Answering a permission prompt: either a tool runs (PostToolUse follows) or Claude stops,
        // which the silence check picks up.
        if status == .claudeNeedsInput {
            message = nil
            setStatus(.claudeWorking)
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
        isClaude = false
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
