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

    var id: String
    var name: String
    var command: String
    var promptStyle: PromptStyle = .unsupported

    static let claude = Agent(id: "claude", name: "Claude Code", command: "claude", promptStyle: .argument)
    static let builtIn = [
        claude,
        Agent(id: "codex", name: "Codex", command: "codex", promptStyle: .argument),
        Agent(id: "gemini", name: "Gemini", command: "gemini", promptStyle: .interactiveFlag),
    ]

    /// Agents added in Settings, stored as JSON in UserDefaults.
    static var custom: [Agent] {
        get {
            UserDefaults.standard.data(forKey: "customAgents")
                .flatMap { try? JSONDecoder().decode([Agent].self, from: $0) } ?? []
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "customAgents") }
    }

    static var all: [Agent] { builtIn + custom }

    static func named(_ id: String) -> Agent? {
        all.first { $0.id == id }
    }

    /// The agent a command line starts, if any: the line is the agent's command, optionally followed by arguments.
    static func running(_ commandLine: String) -> Agent? {
        all.first { !$0.command.isEmpty && (commandLine == $0.command || commandLine.hasPrefix($0.command + " ")) }
    }
}
