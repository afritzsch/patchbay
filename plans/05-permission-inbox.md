# 5. Permission inbox

## Goal

When several agents wait for approval ("Allow Bash: npm test?"), see the exact request and answer it from the
sidebar or overview without opening each pane. Calyx, Axel, octomux and tuios have this; it's what makes
supervising many agents bearable.

## User flow

- A session waiting for permission shows the request itself, not just "Needs your input":
  `Bash: rm -rf build && npm run build`, or `Edit: Sources/Foo.swift`.
- Under it, buttons: **Allow**, **Deny**, (for Claude) **Always allow**. Keyboard: with the session selected,
  ⌘Y allow / ⌘N… pick shortcuts that don't clash (⌘N is New Session).
- The overview card gets the same buttons. ⌘J (next needing attention) already walks through them.
- A notification action ("Allow" button on the macOS notification) is possible later.

## Design

Two ways to answer; recommendation first.

### A. Type the answer into the terminal (recommended)

The agent shows its own permission prompt in the terminal. The app sends the keys a user would press.
- Claude: the permission prompt is a numbered menu, so `1` + Enter allows, Esc denies; check the "always" option
  number in the current version.
- Codex and Gemini have similar prompts with their own keys: a small per-agent key map in `Agent` (plan 3).
- Works for every agent with an interactive prompt, needs no new hook, and the terminal stays the truth: the user
  can always answer there instead.
- Risk: the menu layout changes between versions. Keep the mapping in one place and only send keys while the
  session's status says it's waiting.

The request text comes from what we already receive:
- Claude: the `Notification` hook message, plus the last `PreToolUse` payload (`tool_name`, `tool_input` with
  the command or file path). Store `pendingTool: (name, summary)` on the session.
- Gemini: `Notification` / `BeforeTool` payloads, same idea.
- Others: the notification text only.

### B. Answer through a blocking hook (Claude)

Claude Code's `PermissionRequest` hook can return an allow/deny decision as JSON
(`hookSpecificOutput.decision.behavior`; check the official hooks reference for the exact format). The hook
script would write the request to the events file, then wait for a response file the app writes.
- Cleaner than keystrokes, but the hook blocks until answered or timed out, which may delay the prompt in the
  terminal, and malformed output may be ignored silently. Claude only.
- Consider it only if A turns out to be too fragile.

## Files

| File | Change |
|---|---|
| `TerminalSession.swift` | `pendingRequest` from Notification/PreToolUse payloads; `answer(.allow/.deny)` |
| `Agent.swift` | per-agent answer keys |
| `SidebarView.swift`, `OverviewView.swift` | request text and buttons |
| `PatchbayApp.swift` | shortcuts |

## Testing

In the test copy with a Claude session in a scratch folder: ask it to run `ls`, watch the request appear, allow
from the sidebar. Keep these runs tiny (plan usage).

## Swift to learn

- Enums with associated values for the request (`case bash(command: String)`, `case edit(path: String)`).
- Parsing nested JSON (`tool_input`) with `Codable` instead of `[String: Any]`.
