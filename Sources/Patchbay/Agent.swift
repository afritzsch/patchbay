import Foundation

/// A terminal coding agent. A session counts as running one while the command that starts it is in the foreground.
struct Agent: Identifiable, Codable, Hashable {
    /// How a first prompt is passed on the command line.
    enum PromptStyle: String, Codable {
        /// `command "prompt"`
        case argument
        /// `command -i "prompt"`
        case interactiveFlag
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
    // Codex's and Gemini's prompts are taken from their documentation, not yet tried in Patchbay.
    static let builtIn = [
        claude,
        Agent(id: "codex", name: "Codex", command: "codex", promptStyle: .argument,
              approval: Approval(prompt: "tell Codex what to do differently", allow: "y", deny: "esc")),
        Agent(id: "gemini", name: "Gemini", command: "gemini", promptStyle: .interactiveFlag,
              approval: Approval(prompt: "Allow once", allow: "1", deny: "esc")),
    ]

    /// Agents added in Settings, stored as JSON in UserDefaults.
    static var custom: [Agent] {
        get {
            UserDefaults.standard.data(forKey: Preferences.Keys.customAgents)
                .flatMap { try? JSONDecoder().decode([Agent].self, from: $0) } ?? []
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: Preferences.Keys.customAgents) }
    }

    static var all: [Agent] { builtIn + custom }

    /// Reports its status through Claude Code hooks. Other agents count as working while their output flows.
    var hasHooks: Bool { id == Agent.claude.id }

    static func named(_ id: String) -> Agent? {
        all.first { $0.id == id }
    }

    /// The agent a command line starts, if any: the line is the agent's command, optionally followed by arguments.
    static func running(_ commandLine: String) -> Agent? {
        all.first { !$0.command.isEmpty && (commandLine == $0.command || commandLine.hasPrefix($0.command + " ")) }
    }
}
