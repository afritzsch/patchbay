import Foundation
import Synchronization

/// What the app assumes about Claude Code beyond its documented hooks. Each of these can change with a Claude Code
/// release without any error, so check them after an update.
enum ClaudeCode {
    /// Subcommands that don't start a conversation, so the zsh `claude` function doesn't add `--settings` to them.
    static let subcommandsWithoutSettings = [
        "agents", "attach", "auth", "auto-mode", "doctor", "gateway", "import", "install", "kill", "logs", "mcp",
        "plugin", "plugins", "purge", "respawn", "rm", "setup-token", "stop", "ultrareview", "update", "upgrade",
        "-v", "--version", "-h", "--help",
    ]

    /// Environment variables a Claude session sets for its children. Left over when the app was started from
    /// inside Claude Code, they would make the shells' `claude` think it is nested.
    static let environmentKeys = [
        "CLAUDECODE", "CLAUDE_PID", "CLAUDE_EFFORT", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SSE_PORT",
        "CLAUDE_CODE_EXECPATH", "CLAUDE_CODE_SESSION_ID", "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_SESSION_ATTENDED",
        "CLAUDE_CODE_MESSAGING_SOCKET", "CLAUDE_CODE_MESSAGING_TOKEN",
    ]

    /// Command-line options kept when a session from another terminal is resumed here, with and without a value.
    static let carriedValueOptions: Set<String> = ["--model", "--permission-mode", "--add-dir", "--effort", "--agent", "--fallback-model"]
    static let carriedFlagOptions: Set<String> = ["--dangerously-skip-permissions", "--verbose", "--ide"]

    /// The terminal title before Claude has a task to name it after.
    static let untitled = "Claude Code"

    /// Tools that run a subagent, which can be quiet for a long time while it works.
    static func isSubagentTool(_ name: String?) -> Bool { name == "Task" || name == "Agent" }

    /// The reminder Claude sends some time after a finished turn, as opposed to a question for the user.
    static func isIdleReminder(_ notification: HookPayload) -> Bool {
        notification["notification_type"] == "idle_prompt"
            || notification["message"]?.localizedCaseInsensitiveContains("waiting for your input") == true
    }

    /// Claude's spinner redraws the screen while it works, so a working session silent for this long was
    /// interrupted (Esc and Ctrl-C fire no hook).
    static let interruptedAfterSilence: TimeInterval = 8
}

enum ClaudeTranscripts {
    /// Whether Claude has saved a conversation that `--resume` can open; a session nobody has typed into
    /// yet hasn't, and resuming it fails.
    static func exist(for sessionID: String) -> Bool {
        if let known = checked.withLock({ $0[sessionID] }), known.exists || Date().timeIntervalSince(known.at) < 10 {
            return known.exists
        }
        let projects = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/projects")
        let folders = (try? FileManager.default.contentsOfDirectory(atPath: projects.path)) ?? []
        let exists = folders.contains {
            FileManager.default.fileExists(atPath: projects.appendingPathComponent("\($0)/\(sessionID).jsonl").path)
        }
        checked.withLock { $0[sessionID] = (exists, Date()) }
        return exists
    }

    /// The history view asks for every row it draws. A transcript found stays found; a missing one is looked
    /// for again after a few seconds, since it appears with the first prompt.
    private static let checked = Mutex<[String: (exists: Bool, at: Date)]>([:])
}
