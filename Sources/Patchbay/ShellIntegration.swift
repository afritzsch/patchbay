import Foundation

/// Files the app keeps in Application Support so the terminals can report back what they are doing:
///
/// - a zsh `ZDOTDIR` wrapper that loads the user's own startup files unchanged, then reports the running
///   command and working directory, and wraps `claude` so it loads our hook settings and `opencode` so it loads
///   our plugin;
/// - `claude-settings.json`, passed to Claude Code with `--settings`, whose hooks call
/// - `claude-hook.sh`, which appends each hook event to the session's events file;
/// - `mcp-config.json`, passed with `--mcp-config`, whose server `patchbay-mcp.sh` connects Claude to the app's
///   tools (`ControlServer`);
/// - `opencode-plugin/server.ts`, an OpenCode server plugin that writes the same kind of event lines. It is loaded
///   through `OPENCODE_CONFIG_CONTENT` (`PATCHBAY_OPENCODE_CONFIG`, set by the `opencode` function).
///
/// The user's own `~/.claude/settings.json`, OpenCode config and shell config are never modified.
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
    /// A local plugin directory: OpenCode loads `server.ts` from its root.
    static let opencodePluginDir = supportDir.appendingPathComponent("opencode-plugin", isDirectory: true)
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
        try fm.createDirectory(at: opencodePluginDir, withIntermediateDirectories: true)

        try opencodePluginSource.write(to: opencodePluginDir.appendingPathComponent("server.ts"),
                                       atomically: true, encoding: .utf8)
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
        if let config = try? JSONSerialization.data(withJSONObject: ["plugins": [opencodePluginDir.path]],
                                                    options: [.withoutEscapingSlashes]) {
            env["PATCHBAY_OPENCODE_CONFIG"] = String(decoding: config, as: UTF8.self)
        }
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

    /// OpenCode's counterpart of the hooks: a server plugin that turns session events into the same
    /// `Name<TAB>{json}` lines `claude-hook.sh` writes, with Claude-style payload keys, so `SessionState` reads both
    /// alike. The event types and payloads are OpenCode's V2 (`OpenCode.swift` lists what else is assumed).
    /// Only root sessions count; a subagent shows up as a running "task" tool.
    private static let opencodePluginSource = #"""
    import { appendFileSync } from "node:fs"
    import { Plugin } from "@opencode/plugin"

    // Patchbay: reports this OpenCode server's session events to the app, one "Name<TAB>{json}" line each, in the
    // terminal's events file. Does nothing outside a Patchbay terminal. Never throws into OpenCode.
    const types = [
      "session.created", "session.execution.started", "session.execution.interrupted", "session.execution.failed",
      "session.execution.succeeded", "session.inbox.enqueued", "session.tool.input.started", "session.tool.success",
      "session.tool.failed", "session.idle", "permission.asked", "permission.replied", "form.created", "form.replied", "form.cancelled",
    ] as const

    export default Plugin.define({
      id: "patchbay",
      setup(ctx) {
        const terminal = process.env.PATCHBAY_SESSION_ID
        const dir = process.env.PATCHBAY_EVENTS_DIR
        if (!terminal || !dir) return
        // OpenCode loads a plugin once per location (directory) and every instance sees the events of all of
        // them, so only the first, the terminal's own, reports; the others would repeat every event.
        const shared = globalThis as { patchbayReporting?: boolean }
        if (shared.patchbayReporting) return
        shared.patchbayReporting = true
        const file = `${dir}/${terminal}.events`
        const emit = (name: string, payload: object) => {
          try {
            appendFileSync(file, `${name}\t${JSON.stringify(payload).slice(0, 4000)}\n`)
          } catch {}
        }
        const cut = (text: unknown, length: number) => String(text ?? "").slice(0, length)

        const parents = new Map<string, string | undefined>() // session ID -> parent ID
        const busyChildren = new Set<string>()
        const busy = new Set<string>() // root sessions in a turn
        const toolNames = new Map<string, string>() // tool call ID -> tool name
        const isChild = async (id: string) => {
          if (!parents.has(id)) {
            try {
              parents.set(id, (await ctx.session.get({ sessionID: id })).parentID ?? undefined)
            } catch {
              return false
            }
          }
          return parents.get(id) !== undefined
        }

        const handle = async (event: any) => {
          const data = event.data
          const id: string = data.sessionID ?? data.form?.sessionID
          const base = { session_id: id }
          switch (event.type) {
            case "session.created":
              parents.set(id, data.parentID)
              return
            // A question for the user matters in any session, so a subagent's isn't missed.
            case "permission.asked": {
              const resource = data.resources?.[0]
              const cwd = event.location?.directory ?? ctx.location.directory
              emit("PermissionRequest", { ...base, tool_name: data.action, command: cut(resource, 1000), cwd })
              emit("Notification", { ...base, message: cut(data.message ?? `OpenCode asks to ${data.action} ${resource ?? ""}`.trim(), 500) })
              return
            }
            case "form.created":
              emit("Notification", { ...base, message: cut(data.form.title ?? "OpenCode has a question", 500) })
              return
            case "permission.replied":
            case "form.replied":
            case "form.cancelled":
              emit("AgentResumed", base)
              return
          }

          if (await isChild(id)) {
            const done = ["session.idle", "session.execution.succeeded", "session.execution.interrupted",
                          "session.execution.failed"]
            if (!done.includes(event.type)) {
              if (!busyChildren.has(id)) emit("PreToolUse", { ...base, tool_name: "task" })
              busyChildren.add(id)
            } else if (busyChildren.delete(id)) {
              emit("PostToolUse", { ...base, tool_name: "task" })
            }
            return
          }

          switch (event.type) {
            case "session.execution.started":
              busy.add(id)
              return
            case "session.inbox.enqueued":
              if (data.item.type === "user") emit("UserPromptSubmit", { ...base, prompt: cut(data.item.payload.text, 2000) })
              return
            case "session.tool.input.started":
              toolNames.set(data.id, data.name)
              emit("PreToolUse", { ...base, tool_name: data.name })
              return
            case "session.tool.success":
            case "session.tool.failed":
              emit("PostToolUse", { ...base, tool_name: toolNames.get(data.id) ?? "tool" })
              toolNames.delete(data.id)
              return
            // OpenCode 2.3 ends a turn with session.execution.succeeded and sends no session.idle; both count,
            // once per turn.
            case "session.execution.succeeded":
            case "session.idle":
              if (busy.delete(id)) emit("Stop", base)
              return
            case "session.execution.interrupted":
              busy.delete(id)
              emit("AgentReady", base)
              return
            case "session.execution.failed":
              busy.delete(id)
              emit("AgentReady", { ...base, message: cut(data.error?.message, 500) })
              return
          }
        }

        emit("SessionStart", { cwd: ctx.location.directory })
        const controller = new AbortController()
        void (async () => {
          try {
            for await (const event of ctx.event.subscribe({ types: [...types], signal: controller.signal })) {
              try {
                await handle(event)
              } catch {}
            }
          } catch {}
        })()
        return () => {
          controller.abort()
          shared.patchbayReporting = false
        }
      },
    })
    """#

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

        # Same for opencode. Its plugin runs in the server process, so the TUI gets a private server
        # (--standalone: a child of this shell, which inherits PATCHBAY_*) and the plugin comes in through
        # OPENCODE_CONFIG_CONTENT, which OpenCode merges with the user's own config.
        _pb_opencode='command opencode'
        if (( ${+aliases[opencode]} )); then
            _pb_opencode=${aliases[opencode]}
            [[ ${_pb_opencode%% *} == opencode ]] && _pb_opencode="command $_pb_opencode"
            unalias opencode
        fi
        opencode() {
            case $1 in
                \#(OpenCode.subcommands.joined(separator: "|")))
                    eval "$_pb_opencode \"\$@\"" ;;
                *)
                    # The user's own choices win. A OPENCODE_CONFIG_CONTENT of theirs can't be merged with ours
                    # in shell, and --server or --standalone is theirs to decide. Without the plugin the
                    # session's status falls back to what its output shows.
                    local _pb_arg
                    for _pb_arg in "$@"; do
                        [[ $_pb_arg == (--server|--server=*|--standalone) ]] && { eval "$_pb_opencode \"\$@\""; return; }
                    done
                    if [[ -n $OPENCODE_CONFIG_CONTENT || -z $PATCHBAY_OPENCODE_CONFIG ]]; then
                        eval "$_pb_opencode \"\$@\""
                    else
                        # The assignment is part of the evaluated command: before `eval` it wouldn't be exported.
                        eval "\#(OpenCode.configEnvironmentKey)=\$PATCHBAY_OPENCODE_CONFIG $_pb_opencode \#(OpenCode.standaloneFlag) \"\$@\""
                    fi ;;
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
