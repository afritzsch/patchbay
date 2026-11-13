import Foundation

/// What the app assumes about OpenCode (V2) beyond its documented plugin API, checked against OpenCode 2.3.0.
/// Each of these can change with an OpenCode release without any error, so recheck them after an update.
enum OpenCode {
    /// Undocumented (found in the binary, confirmed with a probe plugin). Its JSON is merged into the user's global
    /// and project config, so `{"plugins": [dir]}` loads our plugin without touching their files. If it goes away,
    /// `OPENCODE_CONFIG=<file>` is the fallback (also in the binary, untested).
    static let configEnvironmentKey = "OPENCODE_CONFIG_CONTENT"

    /// Starts the TUI with a private server (a child process of the terminal's shell) instead of the shared background
    /// service. A plugin runs in the server's process, so only a private server sees the pane's `PATCHBAY_*`
    /// environment and only this pane's sessions.
    static let standaloneFlag = "--standalone"

    /// Connects to an existing server instead. The user's own choice: the zsh `opencode` function leaves it alone.
    static let serverFlag = "--server"

    /// Resumes a conversation (`opencode --session <id>`; creates it if it doesn't exist).
    static let sessionFlag = "--session"

    /// Starts the TUI with a prompt (`opencode --prompt "text"`). Whether it submits or only pre-fills the input
    /// is for `Agent.promptStyle` to settle.
    static let promptFlag = "--prompt"

    /// The first argument of an `opencode` call that doesn't open an interactive UI, so the zsh function neither adds
    /// `--standalone` nor our plugin to it. From `opencode --help` (2.3.0); `mini`, the minimal interactive
    /// interface, is not here on purpose: it takes `--standalone` like the TUI and uses a server the same way.
    static let subcommands = [
        "upgrade", "update", "uninstall", "acp", "api", "debug", "auth", "mcp", "plugin", "models", "stats", "run",
        "session", "service", "reload", "pair", "serve",
        "-v", "--version", "-h", "--help", "--wizard", "--completions",
    ]
}
