# 4. Changes and diff review

## Goal

See what an agent changed without leaving Patchbay, and send feedback on specific lines back to it. Claude Code
desktop, the Codex app, Conductor and Superset all have this; it's the main reason people pick their apps over
plain terminals.

## User flow

1. A session with changes shows `●3` (plan 1). Click it, or ⇧⌘D, to open the **Changes** panel for the focused
   session: a side panel to the right of the panes (like an inspector), not a pane of its own.
2. Left: the changed files (status letter, path, +/− counts). Right: the diff of the selected file.
3. Click a line's gutter to add a comment. Comments collect in a tray at the bottom. **Send to agent** types them
   into the session's terminal as one message:
   ```
   Review comments:
   - Sources/Foo.swift:42: this should handle nil
   - Sources/Bar.swift:10-14: duplicate of Baz.make()
   ```
   Works for any agent, since it's just typed text.
4. Per file: **Open in editor** (`code -g file:line`, or the default app), **Discard changes** (with
   confirmation).

## Design

- **What to compare**: for a worktree session (plan 2), against the merge base with the branch it was based on
  (`git diff <base>...`), so committed work shows too. Otherwise against `HEAD` (uncommitted changes only),
  with a toggle "Include commits since <upstream>".
- **Data**: `git diff --numstat` for the list; `git diff --no-color -U3 -- <file>` for one file, parsed into
  hunks and lines (pure code, easy to test). Untracked files: show as all-added (`git diff --no-index /dev/null
  <file>`).
- **Rendering**: a SwiftUI `List`/`LazyVStack` of lines, monospaced, green/red backgrounds, old/new line numbers.
  No syntax highlighting at first. Big diffs: only render the selected file; cap at a few thousand lines with
  "Open in editor" beyond that.
- **Refresh**: when the panel is open, reload on the agent's "turn finished" event and on the git refresh from
  plan 1 when `changed` differs.
- **Sending**: `session.terminal.send(txt:)` wrapped in bracketed paste (`ESC[200~ … ESC[201~`) so a multi-line
  message arrives as one paste, not line by line. Don't press Enter automatically; the user checks and sends.

## Later

- Stage / commit from the panel; "Create PR" running `gh pr create --fill` in a new shell session (the user
  sees the output and can edit).
- PR and CI status in the sidebar (`gh pr view --json state,statusCheckRollup`), like cmux.
- "Ask agent to review": sends a fixed review prompt.

## Files

| File | Change |
|---|---|
| `Git.swift` | `changedFiles`, `diff(file:)`, diff parser |
| `ChangesView.swift` | new: panel, file list, diff view, comment tray |
| `ContentView.swift` | inspector panel toggle |
| `PatchbayApp.swift` | ⇧⌘D menu item |

## Swift to learn

- Parsing text into value types (`enum DiffLine { case context, added, removed }`).
- `.inspector` in SwiftUI (macOS 14+) for a side panel.
- Performance: `LazyVStack` vs `List`, and `Identifiable` with stable ids for large lists.
