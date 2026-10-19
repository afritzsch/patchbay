import Foundation

/// What the app keeps in UserDefaults: the keys, and the defaults for those that have one.
enum Preferences {
    enum Keys {
        static let fontSize = "fontSize"
        static let recentDirectories = "recentDirectories"
        static let savedSessions = "savedSessions"
        static let savedLayout = "savedLayout"
        static let savedGroups = "savedGroups"
        static let overviewColumns = "overviewColumns"
        static let overviewColumnFractions = "overviewColumnFractions"
        static let overviewRowFractions = "overviewRowFractions"
        static let restoreSessions = "restoreSessions"
        static let resumeClaude = "resumeClaude"
        static let notify = "notify"
        /// An agent's id, or "shell": what the new-session sheet starts.
        static let startAgent = "startAgent"
        /// Whether the new-session sheet starts sessions in a git repository in a new worktree.
        static let newWorktree = "newWorktree"
        /// Claude's `--model` and `--effort` in the new-session sheet; empty for Claude's own default.
        static let claudeModel = "claudeModel"
        static let claudeEffort = "claudeEffort"
        static let customAgents = "customAgents"
        static let automations = "automations"
        /// Whether Claude in the app's terminals gets Patchbay's MCP tools.
        static let agentTools = "agentTools"
        static let historyRetentionDays = "historyRetentionDays"
        /// Whether the editor starts language servers for errors, completion and go to definition.
        static let languageServers = "languageServers"
        static let customLanguageServers = "customLanguageServers"
    }

    static let defaultFontSize: CGFloat = 13
    static let fontSizes: ClosedRange<CGFloat> = 9...28

    /// Must run before the store is made, whose properties read their saved values as they are initialized.
    static func register() {
        UserDefaults.standard.register(defaults: [
            Keys.restoreSessions: true, Keys.resumeClaude: true, Keys.notify: true, Keys.agentTools: true, Keys.languageServers: true, Keys.startAgent: Agent.claude.id,
            Keys.fontSize: defaultFontSize, Keys.historyRetentionDays: 90,
        ])
    }
}
