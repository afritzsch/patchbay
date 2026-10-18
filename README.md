# Patchbay

A Mac app for running several Claude Code sessions (and Codex, Gemini, other agents and plain shells) side by side,
with a sidebar that shows what each one is doing.

![Patchbay with three Claude Code sessions (working, waiting for permission, done) and a dev server](docs/screenshot.png)

- **Sidebar**: every session with its status (*Working · Bash*, *Needs your input*, *Done*, *Running `npm test`*,
  …), titled by your last prompt, with its folder, git branch, changed files and commits ahead / behind.
  ⌘/⇧-click to select several; collapsible groups keep related sessions together.
- **Split panes and overview**: drag sessions onto a pane's edge to split or its centre to swap. ⇧⌘O shows every
  session as a live card in a grid.
- **Attention**: sessions that need you or finished in the background get an orange dot, a dock badge and a
  notification; ⌘J jumps to the next one. Permission requests can be allowed or denied from the sidebar (⌘Y / ⇧⌘Y).
- **Changes**: source control for the focused session's repository: stage, commit, diffs beside the panes. Comment
  on diff lines and send the comments to the agent. An editor with find and replace and, when a language server is
  installed (sourcekit-lsp, TypeScript, Python, Go, Rust, or your own in Settings), errors, completion and
  go to definition.
- **Worktrees**: ⌘N can start a session in a new git worktree on its own branch, so several agents can work on one
  repository. A `.patchbay.json` copies gitignored files over and runs a setup command:
  `{ "copy": [".env"], "setup": "npm install" }`.
- **Agents directing agents**: Claude in Patchbay gets MCP tools to start, read, type into and wait for other
  sessions, so one session can split work across others (*"fix these three bugs on separate branches and tell me
  when they're done"*). It can only drive sessions it started, and leaves their permission prompts to you.
- **Automations**: start an agent or a command on a schedule (*"review yesterday's commits"* every weekday), in a
  folder or a fresh worktree. Runs only while the app is open; a missed run starts once it's back.
- **Bring in Claude from other terminals**: Claude sessions in Terminal, iTerm etc. are listed in the sidebar; move
  one here and the conversation resumes in a pane (a task in progress is interrupted).
- **History** (⇧⌘H): a searchable timeline of prompts, finished turns and shell commands. Jump back to a session,
  resume a closed conversation or rerun a command.
- **Claude usage**: your plan's 5-hour and weekly limits at the bottom of the sidebar (Pro/Max). Claude Code only
  hands these to its status line, so point `statusLine` in `~/.claude/settings.json` at the app's `statusline.sh`.
- **Restore**: on relaunch the layout, folders and Claude conversations come back.

## Build & install

Requires macOS 15+ and Xcode (Swift 6).

```sh
./build.sh            # builds build/Patchbay.app
./build.sh --install  # also copies it to ~/Applications and opens it
```

## Shortcuts

| | |
|---|---|
| ⌘N / ⌘T | New session… / new shell in the current folder |
| ⌘W | Close session |
| ⌘1…⌘9, ⇧⌘] / ⇧⌘[ | Switch sessions |
| ⌘J | Next session that needs you |
| ⌘Y / ⇧⌘Y | Allow / deny a permission request |
| ⌘D / ⇧⌘D | Split right / down |
| ⌘] / ⌘[ | Next / previous pane |
| ⌥⌘W | Remove pane (session keeps running) |
| ⇧⌘O / ⇧⌘H | Overview / history |
| ⌘R | Rename session |

## How status tracking works

Nothing in your own config is modified. Each session's zsh loads your startup files through a `ZDOTDIR` wrapper
in `~/Library/Application Support/Patchbay/`, which reports commands, exit codes and the directory, and starts
`claude` with the app's hooks added. The hooks append events to a file per session that the app reads. Esc in
Claude fires no hook, so a working session that's silent for 8 s counts as waiting again.

Other agents have no hooks: they show *Working* while output flows, and permission prompts are recognised by their
text on screen (set per agent in Settings).

The integration is zsh-only; other shells get a plain terminal. Terminal emulation is
[SwiftTerm](https://github.com/migueldeicaza/SwiftTerm).
