# 7. Sessions that survive restarts

## Goal

Quitting or updating Patchbay shouldn't stop running agents. Today the app restores sessions by restarting the
shell and resuming Claude's conversation (`claude --resume`). That loses running commands, interrupts an agent
mid-task, and doesn't work for agents without resume. Superset, Tortie, herdr and Alethe keep terminals alive
across restarts.

## Options

| | How | For | Against |
|---|---|---|---|
| A. tmux backend | each session runs inside `tmux -L patchbay new -A -s <uuid>`; on launch, reattach | small change, battle-tested | tmux's own key bindings, mouse and scrollback handling interfere with the terminal; adds a dependency |
| B. Own helper daemon (recommended) | a small `patchbay-ptyd` (launchd agent) owns the pseudo-terminals and keeps the last N KB of output per session; the app connects over a Unix socket, replays the buffer into SwiftTerm and streams from there | no tmux quirks; full control; good Swift systems project | the most work: process lifecycle, protocol, versioning between app and daemon |
| C. Keep today's quit-and-resume | | nothing to do | interrupts work |

## Design (B)

- **Daemon**: `forkpty` per session, a ring buffer of output, a socket protocol: `create(id, shell, env, cwd)`,
  `attach(id) → buffered output + live stream`, `input(id, bytes)`, `resize(id, cols, rows)`, `kill(id)`,
  `list()`. Exits when no sessions remain and no app is connected.
- **App**: SwiftTerm's `LocalProcessTerminalView` starts its own process today; switch to a plain
  `TerminalView` fed from the socket (SwiftTerm supports custom data sources via `TerminalViewDelegate.send`).
  The events files and hooks stay the same (they're files, independent of who owns the pty).
- **Replaying**: feeding the saved raw output into a fresh terminal rebuilds the screen. Full-screen apps
  (Claude's UI) redraw on the next resize; send a resize after attaching.
- **Updates**: the app checks the daemon's protocol version; a newer app restarts an old daemon only when no
  session is busy, otherwise keeps using it.
- **Opt-in** at first (Settings: "Keep sessions running when Patchbay quits").

## Swift to learn

- C interop: `forkpty`, file descriptors, `DispatchSource.makeReadSource`.
- A second executable target in `Package.swift`, and a launchd agent plist.
- Designing a small binary or JSON-lines protocol and versioning it.
