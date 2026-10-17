import Foundation

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

/// Lines in a session's events file: the shell integration's, then Claude Code's hooks.
enum SessionEvent: String, CaseIterable {
    case shellExec = "ShellExec"
    case shellPrompt = "ShellPrompt"
    case sessionStart = "SessionStart"
    case userPromptSubmit = "UserPromptSubmit"
    case preToolUse = "PreToolUse"
    case postToolUse = "PostToolUse"
    case permissionRequest = "PermissionRequest"
    case notification = "Notification"
    case stop = "Stop"
    case sessionEnd = "SessionEnd"

    static let hooks = allCases.filter { $0 != .shellExec && $0 != .shellPrompt }
}

/// What a session's shell and agent are doing, worked out from its events. A plain value with no terminal
/// attached, so the rules can be tested on their own.
struct SessionState: Equatable {
    /// What the session should do about a change; the state itself only holds values.
    enum Effect: Equatable {
        /// Worth keeping in the activity history.
        case record(HistoryKind, String, exitCode: Int? = nil, duration: Double? = nil)
        /// Deserves a notification.
        case alert(String)
        /// A command or tool finished, so the git state may have changed.
        case gitChanged
    }

    private(set) var status: SessionStatus = .starting
    private(set) var statusSince = Date()
    private(set) var cwd: String
    /// The agent running in the foreground, or nil for a plain shell.
    private(set) var agent: Agent?
    private(set) var claudeSessionID: String?
    private(set) var lastPrompt: String?
    /// Latest Claude notification, or what a finished command did.
    private(set) var message: String?
    private(set) var currentTool: String?
    /// The agent shows its permission prompt (from its hooks or seen on screen).
    private(set) var asksApproval = false
    /// What it asks to run ("Bash: npm test"), when its hooks say.
    private(set) var approvalRequest: String?
    /// Subagent calls (Task/Agent tool) that have started but not finished.
    private(set) var runningSubagents = 0
    /// Something happened the user hasn't looked at yet (Claude finished, a long command ended, a bell).
    var unseen = false
    /// The foreground command line and when it started, from `ShellExec` until `ShellPrompt`.
    private var command: Command?
    private var promptStarted: Date?

    private struct Command: Equatable {
        var line: String
        var started: Date
    }

    /// A session started with an agent counts as running it before its first event, so an early save keeps it.
    init(cwd: String, agent: Agent? = nil, claudeSessionID: String? = nil) {
        self.cwd = cwd
        self.agent = agent
        self.claudeSessionID = claudeSessionID
    }

    var isClaude: Bool { agent == .claude }

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

    private mutating func setStatus(_ new: SessionStatus, at now: Date) {
        guard new != status else { return }
        status = new
        statusSince = now
    }

    /// `visible`: whether the user is looking at the session, so finishing needs no notification.
    mutating func apply(_ event: SessionEvent, payload: String, visible: @autoclosure () -> Bool,
                        now: Date = Date()) -> [Effect] {
        switch event {
        case .shellExec:
            command = Command(line: payload, started: now)
            agent = Agent.running(payload)
            // Agents with hooks report their status through them; the others count as working while their
            // output flows (see outputReceived and checkForSilence).
            setStatus(agent?.hasHooks == false ? .agentWorking : .running(payload), at: now)
            message = nil
            return []
        case .shellPrompt:
            let fields = payload.split(separator: "\t", maxSplits: 1).map(String.init)
            if fields.count == 2 { cwd = fields[1] }
            var effects: [Effect] = []
            if let command {
                let exitCode = fields.first ?? "0"
                let duration = now.timeIntervalSince(command.started)
                effects.append(.record(.command, command.line, exitCode: Int(exitCode), duration: duration))
                if duration > 10, Agent.running(command.line)?.hasHooks != true, !visible() {
                    let text = exitCode == "0" ? "Finished: \(command.line)" : "Failed (exit \(exitCode)): \(command.line)"
                    message = text
                    unseen = true
                    effects.append(.alert(text))
                }
            }
            command = nil
            agent = nil
            currentTool = nil
            asksApproval = false
            setStatus(.idle, at: now)
            return effects + [.gitChanged]
        case .sessionStart:
            let json = HookPayload(payload)
            claudeEvent()
            claudeSessionID = json["session_id"] ?? claudeSessionID
            if let dir = json["cwd"] { cwd = dir }
            setStatus(.agentReady, at: now)
            return []
        case .userPromptSubmit:
            let json = HookPayload(payload)
            claudeEvent()
            var effects: [Effect] = []
            if let prompt = json["prompt"]?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty {
                lastPrompt = prompt
                claudeSessionID = json["session_id"] ?? claudeSessionID
                effects.append(.record(.prompt, prompt))
            }
            promptStarted = now
            clearTurn()
            unseen = false
            setStatus(.agentWorking, at: now)
            return effects
        case .preToolUse:
            claudeEvent()
            currentTool = HookPayload(payload)["tool_name"]
            if ClaudeCode.isSubagentTool(currentTool) { runningSubagents += 1 }
            if status != .agentNeedsInput { setStatus(.agentWorking, at: now) }
            return []
        case .postToolUse:
            claudeEvent()
            if ClaudeCode.isSubagentTool(HookPayload(payload)["tool_name"]) { runningSubagents = max(0, runningSubagents - 1) }
            currentTool = nil
            asksApproval = false
            setStatus(.agentWorking, at: now)
            return [.gitChanged]
        case .permissionRequest:
            claudeEvent()
            asksApproval = true
            approvalRequest = ClaudeCode.requestSummary(HookPayload(payload))
            setStatus(.agentNeedsInput, at: now)
            return []
        case .notification:
            let json = HookPayload(payload)
            claudeEvent()
            if ClaudeCode.isIdleReminder(json) {
                if status != .agentDone, status != .agentNeedsInput, runningSubagents == 0 { setStatus(.agentReady, at: now) }
                return []
            }
            let text = (asksApproval ? approvalRequest.map { "Allow \($0)?" } : nil) ?? json["message"] ?? "Claude needs your attention"
            message = text
            setStatus(.agentNeedsInput, at: now)
            return [.record(.claudeNeedsInput, text), .alert(text)]
        case .stop:
            claudeEvent()
            clearTurn()
            setStatus(.agentDone, at: now)
            var effects: [Effect] = [.record(.claudeFinished, lastPrompt ?? "", duration: promptStarted.map { now.timeIntervalSince($0) }),
                                     .gitChanged]
            promptStarted = nil
            if !visible() {
                unseen = true
                effects.append(.alert(lastPrompt.map { "Done: \($0)" } ?? "Claude finished"))
            }
            return effects
        case .sessionEnd:
            agent = nil
            currentTool = nil
            runningSubagents = 0
            asksApproval = false
            setStatus(.idle, at: now)
            return []
        }
    }

    /// A Claude Code hook event: Claude is running, and its hooks (not the shell's command line) now track it.
    private mutating func claudeEvent() {
        agent = .claude
        command = nil
    }

    private mutating func clearTurn() {
        message = nil
        currentTool = nil
        runningSubagents = 0
        asksApproval = false
        approvalRequest = nil
    }

    /// Whether the permission prompt of an agent without hooks is on screen, checked when its output pauses.
    mutating func approvalPrompt(shown: Bool, now: Date = Date()) -> [Effect] {
        guard shown != asksApproval, let agent else { return [] }
        asksApproval = shown
        guard shown else {
            if status == .agentNeedsInput { setStatus(.agentWorking, at: now) } // Answered in the terminal.
            return []
        }
        setStatus(.agentNeedsInput, at: now)
        let text = "\(agent.name) asks for permission"
        message = text
        return [.alert(text)]
    }

    /// A working session that has been silent for a while was interrupted and is waiting for the user.
    /// The silence counts from the last output or the status change, whichever came later.
    mutating func checkForSilence(lastOutput: Date, now: Date = Date()) {
        if status == .agentWorking, runningSubagents == 0,
           now.timeIntervalSince(max(lastOutput, statusSince)) > ClaudeCode.interruptedAfterSilence {
            currentTool = nil
            setStatus(.agentReady, at: now)
        }
    }

    /// Without hooks, output that isn't the echo of typing means the agent is working again.
    mutating func outputReceived(sinceInput: TimeInterval, now: Date = Date()) {
        if status == .agentReady, agent?.hasHooks == false, sinceInput > 0.5 { setStatus(.agentWorking, at: now) }
    }

    /// Answering a permission prompt: either a tool runs (PostToolUse follows) or Claude stops, which the
    /// silence check picks up.
    mutating func inputSent(now: Date = Date()) {
        if status == .agentNeedsInput {
            message = nil
            asksApproval = false
            setStatus(.agentWorking, at: now)
        }
    }

    mutating func bellRang(visible: Bool) -> [Effect] {
        guard !visible, agent?.hasHooks != true else { return [] } // Claude's own bell duplicates its Notification hook.
        unseen = true
        message = "Bell"
        return [.alert("Bell")]
    }

    mutating func processExited(_ code: Int32?, now: Date = Date()) {
        agent = nil
        currentTool = nil
        asksApproval = false
        setStatus(.exited(code), at: now)
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
