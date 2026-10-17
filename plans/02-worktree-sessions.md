# 2. Worktree sessions

## Goal

Run several agents on the same repository without them overwriting each other: a session can start in its own
**git worktree** (a second checkout of the same repo on its own branch). This is the most standard feature of
every competitor (Claude Code desktop, Codex app, Conductor, Superset, Copilot app).

It must work for **any agent and for plain shells**, so Patchbay creates the worktree with `git` itself, rather
than using `claude --worktree`.

## User flow

1. ⌘N, pick a folder inside a git repo. A new section appears:
   - **Toggle "New worktree"**, off by default (remembered in `@AppStorage`).
   - **Branch name**, prefilled from the session name (slugged: "Fix login bug" → `fix-login-bug`), or
     `patchbay/<adjective-noun>` when the name is empty.
   - **Based on**: a picker of local branches, default the repo's current branch.
2. Start → Patchbay runs `git worktree add`, then opens the session in the new folder and runs the chosen agent
   (plan 3) or a shell.
3. The sidebar row shows the branch (plan 1) and a worktree marker (SF Symbol `square.on.square.dashed` or
   similar) so it's clear this isn't the main checkout.
4. Closing the session (⌘W) when no other session uses that worktree asks what to do with it (see Cleanup).

Also from the sidebar context menu: **"New Worktree Session…"**, which opens ⌘N prefilled with that session's
repo and the toggle on.

## Where worktrees go

`~/.patchbay/worktrees/<repo-name>/<branch>`

- Outside the repo, so it doesn't show up in the repo's own `git status`, and editors and file watchers on the
  main checkout don't see it.
- No spaces in the path. "Application Support" has one, and some build tools and scripts break on spaces.
- Superset (`~/.superset/worktrees`) and Conductor (`~/conductor/workspaces`) do the same kind of thing.
- `<repo-name>` alone could clash between two repos with the same name. Use `<repo-name>-<short hash of the repo
  path>` if that becomes a problem; not needed at first.

## Design

### Git operations (in `Git.swift` from plan 1)

```swift
extension Git {
    static func localBranches(at repo: String) -> [String]          // git branch --format=%(refname:short)
    static func addWorktree(repo: String, branch: String, base: String, at path: String) throws
    static func removeWorktree(_ path: String, force: Bool) throws // git worktree remove [--force]
    static func deleteBranchIfMerged(_ branch: String, repo: String) // git branch -d, ignore failure
}
```

- `addWorktree`: `git -C <repo> worktree add -b <branch> <path> <base>`. If the branch already exists, offer
  to check it out instead (`git worktree add <path> <branch>`). That's also how to review a colleague's branch.
- Errors (branch exists, invalid name, base missing) come from git's stderr, shown in an alert in the sheet.
- Validate the branch name early with `git check-ref-format --branch <name>`.
- Run these off the main thread too; `worktree add` on a big repo takes a moment, so show a spinner in the sheet.

### Session state

`TerminalSession` gets `let worktree: String?`, the worktree path this session was created in. It's stored
explicitly rather than derived from `cwd`, because the user may `cd` elsewhere inside the session.
`SavedSession` gets the same optional field, so it survives restarts. (Older saved data simply has `nil`.)

### Cleanup on close

Extend `SessionStore.confirmAndClose`. It already asks when Claude or a command is running; this becomes one
alert, not two:

- Close a worktree session, when **no other session has the same `worktree`**:
  - Message: "Close “fix-login-bug”?"
  - Info: "It has its own worktree on branch fix-login-bug." Add "3 uncommitted changes will be lost." if
    `git.changed > 0`, and "Claude is still running." if busy.
  - Buttons: **Close** (keeps the worktree, which can be reopened from History or Finder), **Close and Delete
    Worktree**, **Cancel**.
- Delete = `git worktree remove --force <path>` (force only because the user just confirmed, with the
  uncommitted-changes warning), then `git branch -d <branch>`. `-d` refuses unmerged branches, so commits are
  never lost; the branch is kept and that's fine.

Quitting the app never deletes worktrees: sessions are restored with them.

### Housekeeping

- At launch, `git worktree prune` for repos with worktrees under `~/.patchbay/worktrees` that no longer exist
  (e.g. deleted by hand). Cheap, optional.
- History entries for a deleted worktree point at a missing folder. `newSession` already falls back to the home
  folder; resuming a Claude conversation needs the original path though. Show "Worktree was deleted" there
  instead of a broken resume.

### Phase 2: setup per repo

New worktrees lack gitignored files (`.env`, `node_modules`). Conductor and Superset solve it with a per-repo
config file. Patchbay version, `.patchbay.json` in the repo root (committed or not, the user's choice):

```json
{
  "copy": [".env", ".env.local"],
  "setup": "npm install"
}
```

`copy`: files copied from the main checkout into the new worktree. `setup`: run as the session's first command,
before the agent starts (`setup && claude`). Only do this when someone actually needs it.

## Files

| File | Change |
|---|---|
| `Git.swift` | branch list, add/remove worktree, delete merged branch |
| `NewSessionSheet.swift` | worktree toggle, branch name, base picker, error display, spinner |
| `SessionStore.swift` | `newSession(… worktree:)`, `SavedSession.worktree`, cleanup in `confirmAndClose` |
| `TerminalSession.swift` | `let worktree: String?` |
| `SidebarView.swift` | worktree marker, "New Worktree Session…" menu item |
| `README.md`, `ARCHITECTURE.md` | document |

## Open questions

- Claude Code asks "Do you trust the files in this folder?" for every new folder. Check whether it already
  trusts worktrees of a trusted repo. If not, consider whether it's acceptable.
- Should sessions be grouped by repo in the sidebar once there are many worktrees? Wait and see.

## Testing

- Test copy against a throwaway repo (`git init` in the scratchpad), not a real project.
- Create a worktree session, edit a file, close → alert shows "1 uncommitted change"; delete → folder and
  `git worktree list` entry gone, branch kept if it has commits.
- Two sessions in one worktree (⌘T in it): closing the first doesn't ask about the worktree.
- Restart the test app: the worktree session comes back in the worktree folder.

## Swift to learn

- Throwing functions and turning `Process` exit codes plus stderr into a Swift `Error`.
- `async` work from a SwiftUI sheet: a `@State var isWorking`, a `Task { }` in the button action, `await`, then
  dismiss.
- `Codable` evolution: adding an optional field without breaking saved data.
