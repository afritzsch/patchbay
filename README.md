# Patchbay

A Mac app for running several Claude Code sessions (and Codex, Gemini, other agents and plain shells) side by side,
with a sidebar that shows what each one is doing.

![Patchbay with three Claude Code sessions (working, waiting for permission, done) and a dev server](docs/screenshot.png)

- **Sidebar**: every session with its status (*Working · Bash*, *Waiting for agent*, *Needs your input*, *Done*,
  *Running `npm test`*, *Idle*) and how long it's been in that state. Agent sessions are titled by your last
  prompt (or the name you chose), with the question the agent is asking, if any, and the folder below. Drag to
  reorder, right-click to rename / open a sibling shell / show in Finder.
- **Git state**: the folder line also shows the branch, changed files (`●3`) and commits ahead / behind
  (`↑1 ↓2`), in the sidebar, pane headers and overview cards.
- **Changes**: the *Changes* tab in the sidebar is source control for the focused session's repository: stage,
  unstage, discard (asks first) and commit (⌘↩). Click a file to see its diff beside the panes.
- **Split panes**: drag a session from the sidebar (or a pane by its title bar) onto a pane: an edge splits,
  the centre swaps. Drag the dividers to resize (double-click to even out). The × on a pane removes it from the
  screen while the session keeps running.
- **Overview** (⇧⌘O): every session as a live terminal card in a grid. Drag the gaps to resize, pick the number
  of columns in the toolbar. Cards needing you have an orange border. Double-click a header to open it in the panes.
- **Bring in Claude sessions from other terminals**: sessions running in Terminal, iTerm etc. are listed under
  *Claude in Other Terminals*. Drag one onto a pane or into the session list, or click its arrow: Claude quits
  there and the same conversation resumes here (`claude --resume`, keeping options like `--model`). A running
  process can't be moved between apps, so a task in progress is interrupted (you're asked first).
- **Drop from Finder**: a folder dropped on the sidebar opens a session there, on a pane's edge a split. Files
  dropped on a pane are typed in as escaped paths.
- **Claude usage**: bars at the bottom of the sidebar for your plan's 5-hour and weekly limits, with reset times
  (Pro/Max only). Claude Code only hands these numbers to its status line, so point `statusLine` in
  `~/.claude/settings.json` at the app's `statusline.sh`.
- **History** (⇧⌘H): a searchable timeline by day of prompts, finished turns, shell commands with exit code and
  duration, and sessions opened, closed or moved in. Jump to a session, resume a closed conversation or run a
  command again. Kept in `~/Library/Application Support/Patchbay/history.jsonl`, 90 days by default (Settings).
- **Attention**: sessions that need input or finished while you weren't looking get an orange dot, a dock badge
  and a notification; ⌘J jumps to the next one. Long shell commands (>10 s) finishing in the background count too.
- **Restore**: on relaunch the pane layout, folders and Claude conversations come back. Both can be turned off
  in Settings (⌘,).

## Build & install

Requires macOS 15+ and Xcode (Swift 6).

```sh
./build.sh            # builds build/Patchbay.app
./build.sh --install  # also copies it to ~/Applications and opens it
```

You can also open `Package.swift` in Xcode.

## Shortcuts

| | |
|---|---|
| ⌘N | New session… (folder, name, shell or agent, optional first prompt) |
| ⌘T | New shell in the current session's folder |
| ⌘W | Close session (asks if an agent or a command is still running) |
| ⌘1…⌘9, ⇧⌘] / ⇧⌘[ | Switch sessions |
| ⌘J | Next session that needs you |
| ⌘D / ⇧⌘D | Split right / down (new shell in the same folder) |
| ⌘] / ⌘[ | Next / previous pane |
| ⌥⌘W | Remove pane (session keeps running) |
| ⌃⌘= | Even out panes |
| ⇧⌘O | Toggle overview |
| ⇧⌘H | Toggle history |
| ⌘R | Rename session |
| ⌘= / ⌘- / ⌘0 | Font size |

## How status tracking works

Nothing in your own config is modified. The app keeps its files in `~/Library/Application Support/Patchbay/`:

- `zsh/`: a `ZDOTDIR` wrapper. Each session's zsh loads your own startup files unchanged, then adds hooks that
  report the running command, exit code and directory, and a `claude` function that adds
  `--settings claude-settings.json`.
- `claude-settings.json`: Claude Code hooks (`SessionStart`, `UserPromptSubmit`, `Pre/PostToolUse`,
  `Notification`, `Stop`, `SessionEnd`), merged by Claude with your own settings.
- `claude-hook.sh`: what each hook runs. It appends the event to `events/<session>.events`, which the app reads.
- `statusline.sh`: the status line mentioned under *Claude usage*; also saves the usage numbers for the app.

Esc/Ctrl-C in Claude fires no hook, so a "working" session whose screen is silent for 8 s is shown as waiting
for a prompt again (unless a subagent is running: *Waiting for agent*).

Other agents: Codex and Gemini are built in, and Settings → Other agents adds any command. They have no hooks, so
they show *Working* while output flows and *Waiting for prompt* after 8 s of silence. Reopened sessions restart
them fresh.

Limitations: the integration is zsh-only (other shells get a plain terminal). A `claude` alias keeps working:
the wrapper runs the alias's command with the app's settings added.

Terminal emulation is [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm).
