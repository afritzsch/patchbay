import Foundation

/// What the app keeps in UserDefaults: the keys, and the defaults for those that have one.
enum Preferences {
    enum Keys {
        static let fontSize = "fontSize"
        static let recentDirectories = "recentDirectories"
        static let savedSessions = "savedSessions"
        static let savedLayout = "savedLayout"
        static let overviewColumns = "overviewColumns"
        static let overviewColumnFractions = "overviewColumnFractions"
        static let overviewRowFractions = "overviewRowFractions"
        static let restoreSessions = "restoreSessions"
        static let resumeClaude = "resumeClaude"
        static let notify = "notify"
        /// An agent's id, or "shell": what the new-session sheet starts.
        static let startAgent = "startAgent"
        static let customAgents = "customAgents"
        static let historyRetentionDays = "historyRetentionDays"
    }

    static let defaultFontSize: CGFloat = 13
    static let fontSizes: ClosedRange<CGFloat> = 9...28

    /// Must run before the store is made, whose properties read their saved values as they are initialized.
    static func register() {
        let defaults = UserDefaults.standard
        if let startClaude = defaults.object(forKey: "startClaude") as? Bool { // Replaced by startAgent.
            defaults.set(startClaude ? Agent.claude.id : "shell", forKey: Keys.startAgent)
            defaults.removeObject(forKey: "startClaude")
        }
        defaults.register(defaults: [
            Keys.restoreSessions: true, Keys.resumeClaude: true, Keys.notify: true, Keys.startAgent: Agent.claude.id,
            Keys.fontSize: defaultFontSize, Keys.historyRetentionDays: 90,
        ])
    }
}
