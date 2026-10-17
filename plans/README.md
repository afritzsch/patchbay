# Feature plans

Plans for growing Patchbay into an IDE for agents. They came out of a look at the existing tools (October 2026):
Claude Code desktop, the Codex app, the GitHub Copilot app, Conductor, Superset, cmux, Nimbalyst and others.
Almost all of them have worktree-per-agent, diff review and git/PR status. Patchbay already stands out with
moving sessions in from other terminals, the history timeline, panes plus the overview grid, and being a native
app built around real terminals. The plans keep it that way: terminal first, no chat UI.

| # | Plan | Size | Status |
|---|---|---|---|
| 2 | [Worktree sessions](02-worktree-sessions.md) | M | next |
| 4 | [Changes and diff review](04-changes-review.md) | M | |
| 5 | [Permission inbox](05-permission-inbox.md) | M | |
| 6 | [Patchbay as an MCP server for agents](06-mcp-control.md) | M | |
| 7 | [Sessions that survive restarts](07-persistent-sessions.md) | L | |
| 8 | [Browser / preview pane](08-browser-pane.md) | M | |
| 9 | [Scheduled agent runs](09-scheduled-runs.md) | S–M | |
| 10 | [Phone and remote access](10-remote-access.md) | S → L | |

Plans for things only a native Mac app can do (menu bar, actionable notifications, URL scheme and Finder,
global hotkey, Dock/Focus, sleep and network events, App Intents) are in [native/](native/README.md).

Rules that apply to all of them:

- **Agent-neutral.** New code talks about "agents", not Claude. Claude is the first agent with full support,
  not the only one (see plan 3).
- **Lean.** Use what the app already has (the 0.25 s, 1 s and 3 s timers, the events file, `PaneLayout`)
  before adding new mechanisms.
- **Never block the main thread** on `git` or other processes.
- **Test with the test copy** (`patchbay-dev` MCP server), never the user's running app.
- Each plan ends with a "Swift to learn" note, since this is also a Swift learning project.
