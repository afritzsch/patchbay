# 6. Patchbay as an MCP server for agents

## Goal

Let an agent use Patchbay itself: open new sessions (in worktrees), give them tasks, watch their status and
read their output. A "lead" Claude can then split work across several agents that the user still sees and
controls in the sidebar. This is what "IDE for agents" means beyond running them side by side (Vigil, Runner,
diri and super.engineering try the same).

## Tools

| Tool | Does |
|---|---|
| `list_sessions` | id, name, agent, status, folder, branch, last prompt |
| `new_session(folder, agent, prompt?, worktree?: {branch, base})` | opens a session (plans 2 and 3), returns its id |
| `send_input(session, text, submit)` | types into a session (bracketed paste), optionally presses Enter |
| `read_output(session, lines)` | last N lines of the terminal buffer as plain text |
| `wait_for(session, status, timeout)` | returns when the session is done / needs input |
| `close_session(session)` | closes it (never deletes a worktree without the user) |

## Design

- **Transport**: a small stdio MCP server executable (`patchbay-mcp`, like `scripts/dev-mcp.swift` but for the
  real app) that talks to the running app over a **Unix domain socket** in the support folder. The dev hooks use
  distributed notifications, which can't carry replies well; a socket gives request/response.
- **Registration**: only for agents started inside Patchbay: Claude with `--mcp-config <file>` added by the
  `claude()` wrapper (like `--settings` today); other agents per their config flags. Nothing in the user's own
  config.
- **Safety**: the socket only accepts the current user (file permissions 0600). A session can only see sessions
  of the same app instance. New sessions created by an agent are marked "started by <session name>" in the
  sidebar. Optionally a Settings switch to turn the server off.
- **Reading output**: SwiftTerm's buffer can be read line by line (`terminal.getTerminal().getLine(row:)`);
  strip trailing spaces.

## Order

1. Socket server in the app plus `list_sessions` / `read_output` (read-only, safe to try).
2. `new_session`, `send_input`, `wait_for`.
3. A "Lead session" convenience: ⌘N option that starts Claude with a system prompt explaining the tools.

## Swift to learn

- Sockets with `Network.framework` (`NWListener` on a Unix endpoint) or plain POSIX calls.
- JSON-RPC with `Codable`: one request enum, one response type.
- Swift concurrency across a network boundary: an `actor` for the connection state.
