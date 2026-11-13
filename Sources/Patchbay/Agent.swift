import Foundation
import Synchronization

/// A terminal coding agent. A session counts as running one while the command that starts it is in the foreground.
struct Agent: Identifiable, Codable, Hashable {
    /// How a first prompt is passed on the command line.
    enum PromptStyle: String, Codable {
        /// `command "prompt"`
        case argument
        /// `command -i "prompt"`
        case interactiveFlag
        /// `command --prompt "prompt"`
        case promptFlag
        case unsupported
    }

    /// How the agent asks before running a tool, and the keys that answer it, typed into its terminal.
    struct Approval: Codable, Hashable {
        /// Text on screen while it asks (case-insensitive), as unlike its normal output as possible.
        var prompt: String
        /// Keys as typed; `esc` and `enter` stand for those keys.
        var allow: String
        var deny: String

        /// Whether the screen's text shows the prompt, also when narrow panes wrap it inside a box.
        func isShown(on screen: String) -> Bool {
            !prompt.isEmpty && Self.words(screen).localizedCaseInsensitiveContains(Self.words(prompt))
        }

        private static func words(_ text: String) -> String {
            text.split { $0.isWhitespace || ("\u{2500}"..."\u{257F}").contains($0) }.joined(separator: " ")
        }

        static func keys(_ text: String) -> String {
            switch text.lowercased() {
            case "esc": "\u{1b}"
            case "enter": "\r"
            default: text
            }
        }
    }

    var id: String
    var name: String
    var command: String
    var promptStyle: PromptStyle = .unsupported
    var approval: Approval?

    static let claude = Agent(id: "claude", name: "Claude Code", command: "claude", promptStyle: .argument,
                              approval: ClaudeCode.approval)
    /// Reports its status through a plugin Patchbay loads (see the OpenCode plugin in the shell integration), which
    /// writes the same event lines as Claude's hooks. Its permission prompt (OpenCode 2.3) preselects "Allow once":
    /// Enter allows, Esc rejects and ends the turn.
    static let opencode = Agent(id: "opencode", name: "OpenCode", command: "opencode", promptStyle: .promptFlag,
                                approval: Approval(prompt: "Permission required", allow: "enter", deny: "esc"))
    // Codex's, Gemini's, Mistral Vibe's and OpenCode's prompts are taken from their documentation or source, not yet
    // tried in Patchbay.
    static let builtIn = [
        claude,
        opencode,
        Agent(id: "codex", name: "Codex", command: "codex", promptStyle: .argument,
              approval: Approval(prompt: "tell Codex what to do differently", allow: "y", deny: "esc")),
        Agent(id: "gemini", name: "Gemini", command: "gemini", promptStyle: .interactiveFlag,
              approval: Approval(prompt: "Allow once", allow: "1", deny: "esc")),
        Agent(id: "vibe", name: "Mistral Vibe", command: "vibe", promptStyle: .argument,
              approval: Approval(prompt: "Permission for the", allow: "y", deny: "n")),
    ]

    /// Agents added in Settings, stored as JSON in UserDefaults.
    static var custom: [Agent] {
        get { savedCustom.withLock { $0 } }
        set {
            savedCustom.withLock { $0 = newValue }
            Preferences.save(newValue, forKey: Preferences.Keys.customAgents)
        }
    }

    /// Decoded once: context menus and every shell event look agents up.
    private static let savedCustom = Mutex(Preferences.load([Agent].self, forKey: Preferences.Keys.customAgents) ?? [])

    static var all: [Agent] { builtIn + custom }

    /// Reports its status through events in the session's events file: Claude Code's hooks, or OpenCode's plugin.
    /// Other agents count as working while their output flows.
    var hasHooks: Bool { id == Agent.claude.id || id == Agent.opencode.id }

    /// Whether Patchbay keeps its conversation IDs and can start it on one again (restore, History's resume).
    var resumesConversations: Bool { resumeFlag != nil }

    /// The flag that continues a conversation, followed by its ID.
    var resumeFlag: String? {
        switch id {
        case Agent.claude.id: "--resume"
        case Agent.opencode.id: OpenCode.sessionFlag
        default: nil
        }
    }

    /// The shell command that starts it with `arguments` and, when it takes one, a first prompt. With `resuming`,
    /// it continues that conversation (an agent without a `resumeFlag` ignores the ID).
    func commandLine(resuming conversation: String? = nil, arguments: [String] = [], prompt: String? = nil) -> String {
        var parts = [command]
        if let conversation, let resumeFlag { parts += [resumeFlag, ShellIntegration.quote(conversation)] }
        parts += arguments.map(ShellIntegration.quote)
        if let prompt, !prompt.isEmpty, promptStyle != .unsupported {
            switch promptStyle {
            case .interactiveFlag: parts.append("-i")
            case .promptFlag: parts.append("--prompt")
            default: break
            }
            parts.append(ShellIntegration.quote(prompt))
        }
        return parts.joined(separator: " ")
    }

    static func named(_ id: String) -> Agent? {
        all.first { $0.id == id }
    }

    /// The agent a command line starts, if any: the line is the agent's command, optionally followed by arguments.
    static func running(_ commandLine: String) -> Agent? {
        all.first { !$0.command.isEmpty && (commandLine == $0.command || commandLine.hasPrefix($0.command + " ")) }
    }
}
