import Foundation

/// Files the app keeps in Application Support so the terminals can report back what they are doing:
///
/// - a zsh `ZDOTDIR` wrapper that loads the user's own startup files unchanged, then reports the running
///   command and working directory, and wraps `claude` so it loads our hook settings;
/// - `claude-settings.json`, passed to Claude Code with `--settings`, whose hooks call
/// - `claude-hook.sh`, which appends each hook event to the session's events file;
/// - `mcp-config.json`, passed with `--mcp-config`, whose server `patchbay-mcp.sh` connects Claude to the app's
///   tools (`ControlServer`).
///
/// The user's own `~/.claude/settings.json` and shell config are never modified.
enum ShellIntegration {
    /// Named after the app so a second copy (e.g. a test build) doesn't share event files with this one.
    static let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Patchbay",
                                isDirectory: true)
    static let eventsDir = supportDir.appendingPathComponent("events", isDirectory: true)
    static let zdotDir = supportDir.appendingPathComponent("zsh", isDirectory: true)
    static let hookScript = supportDir.appendingPathComponent("claude-hook.sh")
    static let claudeSettings = supportDir.appendingPathComponent("claude-settings.json")
    static let mcpScript = supportDir.appendingPathComponent("patchbay-mcp.sh")
    static let mcpConfig = supportDir.appendingPathComponent("mcp-config.json")
    static let controlSocket = supportDir.appendingPathComponent("control.sock")
    /// Claude Code status line (configured in ~/.claude/settings.json); also saves plan usage for the app.
    static let statusLineScript = supportDir.appendingPathComponent("statusline.sh")

    /// The user's login shell, falling back to zsh.
    static let userShell: String = {
        if let pw = getpwuid(getuid()), let shell = pw.pointee.pw_shell {
            let path = String(cString: shell)
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return "/bin/zsh"
    }()

    static var shellIsZsh: Bool { (userShell as NSString).lastPathComponent == "zsh" }

    static func install() throws {
        let fm = FileManager.default
        try? fm.removeItem(at: eventsDir) // Event files of sessions from a previous run are stale.
        try fm.createDirectory(at: eventsDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: zdotDir, withIntermediateDirectories: true)

        try hookScriptSource.write(to: hookScript, atomically: true, encoding: .utf8)
        try mcpScriptSource.write(to: mcpScript, atomically: true, encoding: .utf8)
        try statusLineSource.write(to: statusLineScript, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: statusLineScript.path)

        let command = "/bin/sh '\(hookScript.path)'"
        let hooks = Dictionary(uniqueKeysWithValues: SessionEvent.hooks.map {
            ($0.rawValue, [["hooks": [["type": "command", "command": "\(command) \($0.rawValue)", "timeout": 5]]]])
        })
        // The tools that only look don't ask for permission.
        let readOnly = [AgentTool.listSessions, .readOutput, .waitFor, .listAutomations].map { "mcp__patchbay__\($0.rawValue)" }
        let settings = try JSONSerialization.data(withJSONObject: ["hooks": hooks, "permissions": ["allow": readOnly]],
                                                  options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try settings.write(to: claudeSettings, options: .atomic)
        let mcp = ["mcpServers": ["patchbay": ["command": "/bin/sh", "args": [mcpScript.path]]]]
        try JSONSerialization.data(withJSONObject: mcp, options: [.prettyPrinted, .withoutEscapingSlashes])
            .write(to: mcpConfig, options: .atomic)

        for (name, source) in zshFiles {
            try source.write(to: zdotDir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
    }

    static func eventsFile(for id: UUID) -> URL {
        eventsDir.appendingPathComponent("\(id.uuidString).events")
    }

    /// Environment for a session's shell. `initialCommand` is run once the shell has started.
    static func environment(sessionID: UUID, initialCommand: String?) -> [String] {
        var env = ProcessInfo.processInfo.environment
        // Leftovers when the app itself was started from a terminal or from inside Claude Code.
        for key in ClaudeCode.environmentKeys + ["TERM_SESSION_ID", "TERM_PROGRAM_VERSION", "ITERM_SESSION_ID",
                                         "ITERM_PROFILE", "TMUX", "TMUX_PANE", "STY"] {
            env.removeValue(forKey: key)
        }
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "Patchbay"
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }

        env["PATCHBAY_SESSION_ID"] = sessionID.uuidString
        env["PATCHBAY_EVENTS_DIR"] = eventsDir.path
        env["PATCHBAY_CLAUDE_SETTINGS"] = claudeSettings.path
        if UserDefaults.standard.bool(forKey: Preferences.Keys.agentTools) { env["PATCHBAY_MCP_CONFIG"] = mcpConfig.path }
        if shellIsZsh {
            env["PATCHBAY_USER_ZDOTDIR"] = env["ZDOTDIR"]
            env["ZDOTDIR"] = zdotDir.path
            if let initialCommand { env["PATCHBAY_INITIAL_COMMAND"] = initialCommand }
        }
        return env.map { "\($0.key)=\($0.value)" }
    }

    /// Quotes a string for the shell.
    static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Sources

    private static let hookScriptSource = #"""
    #!/bin/sh
    # Patchbay: forwards a Claude Code hook event ($1, JSON on stdin) to the app.
    # Must never block or fail Claude, so it prints nothing and always exits 0.
    if [ -z "$PATCHBAY_SESSION_ID" ] || [ ! -d "$PATCHBAY_EVENTS_DIR" ]; then
        cat >/dev/null
        exit 0
    fi
    payload=$(cat | tr '\n\r\t' '   ' | cut -c1-4000)
    printf '%s\t%s\n' "$1" "$payload" 2>/dev/null >> "$PATCHBAY_EVENTS_DIR/$PATCHBAY_SESSION_ID.events"
    exit 0
    """#

    /// Claude's MCP server for the app's tools: relays the agent's messages to the control socket, first saying
    /// which session it runs in.
    private static let mcpScriptSource = #"""
    #!/bin/sh
    # Patchbay: connects an agent in a Patchbay terminal to the app's tools (MCP over stdio).
    { printf '%s\n' "$PATCHBAY_SESSION_ID"; exec cat; } | exec nc -U \#(quote(controlSocket.path))
    """#

    private static let statusLineSource = #"""
    #!/bin/sh
    # Claude Code status line from Patchbay: model, folder and plan usage. Also saves the usage numbers
    # (rate_limits) to usage.json next to this script for the app's progress bars.
    # printf needs a decimal point locale.
    LC_ALL=C; export LC_ALL
    input=$(cat)
    dir=$(dirname "$0")
    get() { printf '%s' "$input" | plutil -extract "$1" raw -o - - 2>/dev/null; }

    if printf '%s' "$input" | plutil -extract rate_limits json -o "$dir/usage.json.$$" - 2>/dev/null; then
        mv -f "$dir/usage.json.$$" "$dir/usage.json"
    fi

    line=$(get model.display_name)
    folder=$(get workspace.current_dir)
    [ -n "$folder" ] && line="$line · $(basename "$folder")"
    five=$(get rate_limits.five_hour.used_percentage)
    week=$(get rate_limits.seven_day.used_percentage)
    [ -n "$five" ] && line="$line · 5h $(printf '%.0f' "$five")%"
    [ -n "$week" ] && line="$line · week $(printf '%.0f' "$week")%"
    printf '%s' "$line"
    """#

    /// zsh reads .zshenv, .zprofile, .zshrc and .zlogin from ZDOTDIR. Each of ours sources the user's
    /// own file with ZDOTDIR pointing at the user's directory; .zshrc then hands ZDOTDIR back for good.
    private static let zshFiles: [String: String] = [
        ".zshenv": #"""
        # Patchbay shell integration. Loads your own .zshenv unchanged.
        _pb_zdotdir=$ZDOTDIR
        ZDOTDIR=${PATCHBAY_USER_ZDOTDIR:-$HOME}
        [[ -f $ZDOTDIR/.zshenv ]] && source $ZDOTDIR/.zshenv
        PATCHBAY_USER_ZDOTDIR=$ZDOTDIR
        ZDOTDIR=$_pb_zdotdir
        """#,
        ".zprofile": #"""
        # Patchbay shell integration. Loads your own .zprofile unchanged.
        _pb_zdotdir=$ZDOTDIR
        ZDOTDIR=$PATCHBAY_USER_ZDOTDIR
        [[ -f $ZDOTDIR/.zprofile ]] && source $ZDOTDIR/.zprofile
        ZDOTDIR=$_pb_zdotdir
        """#,
        ".zshrc": #"""
        # Patchbay shell integration. Loads your own .zshrc unchanged, then reports the running
        # command and directory to the app and makes `claude` load the app's hook settings.
        ZDOTDIR=$PATCHBAY_USER_ZDOTDIR
        [[ -f $ZDOTDIR/.zshrc ]] && source $ZDOTDIR/.zshrc
        # Hand ZDOTDIR back so nested shells and .zlogin behave exactly as in any other terminal.
        if [[ $ZDOTDIR == $HOME ]]; then unset ZDOTDIR; fi
        unset _pb_zdotdir PATCHBAY_USER_ZDOTDIR

        _pb_emit() {
            print -r -- "$1"$'\t'"$2" >> "$PATCHBAY_EVENTS_DIR/$PATCHBAY_SESSION_ID.events"
        } 2>/dev/null
        # The event names are SessionEvent's.
        _pb_preexec() { _pb_emit ShellExec "${1//$'\n'/ }" }
        _pb_precmd() { _pb_emit ShellPrompt "$?"$'\t'"$PWD" }
        autoload -Uz add-zsh-hook
        add-zsh-hook preexec _pb_preexec
        precmd_functions=(_pb_precmd ${precmd_functions:#_pb_precmd})

        # An alias named claude (Claude's local installer adds one) becomes the command the function runs.
        _pb_claude='command claude'
        if (( ${+aliases[claude]} )); then
            _pb_claude=${aliases[claude]}
            [[ ${_pb_claude%% *} == claude ]] && _pb_claude="command $_pb_claude"
            unalias claude
        fi
        claude() {
            case $1 in
                \#(ClaudeCode.subcommandsWithoutSettings.joined(separator: "|")))
                    eval "$_pb_claude \"\$@\"" ;;
                *)
                    # --mcp-config takes several files, so an option must follow it.
                    eval "$_pb_claude ${PATCHBAY_MCP_CONFIG:+--mcp-config \"\$PATCHBAY_MCP_CONFIG\"} --settings \"\$PATCHBAY_CLAUDE_SETTINGS\" \"\$@\"" ;;
            esac
        }

        if [[ -n $PATCHBAY_INITIAL_COMMAND ]]; then
            _pb_initial=$PATCHBAY_INITIAL_COMMAND
            unset PATCHBAY_INITIAL_COMMAND
            _pb_run_initial() {
                add-zsh-hook -d precmd _pb_run_initial
                print -s -- "$_pb_initial"
                _pb_preexec "$_pb_initial"
                eval "$_pb_initial"
                _pb_precmd
                unset _pb_initial
            }
            add-zsh-hook precmd _pb_run_initial
        fi
        """#,
        ".zlogin": #"""
        # Patchbay shell integration. Not normally read: .zshrc hands ZDOTDIR back first.
        [[ -f ${PATCHBAY_USER_ZDOTDIR:-$HOME}/.zlogin ]] && source ${PATCHBAY_USER_ZDOTDIR:-$HOME}/.zlogin
        """#,
    ]
}
