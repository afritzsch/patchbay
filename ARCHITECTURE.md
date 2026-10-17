# Patchbay architecture

A guide to how the app is built, written for learning Swift with it. For what the app does, see README.md.

## The big picture

Three layers: a shell/Claude integration that writes events to files, a model layer that reads them into
observable Swift objects, and SwiftUI views (with AppKit where SwiftUI falls short) that draw the model.

```
┌──────────────── PatchbayApp (@main, SwiftUI App) ─────────────────┐
│  AppDelegate (AppKit lifecycle, notifications, ⌘W, quit dialog)   │
│        owns ↓                                                     │
│  SessionStore  (@Observable, @MainActor: the single source of     │
│                 truth for sessions, pane layout, mode, saving)    │
│     │ owns many          │ owns                                   │
│     ▼                    ▼                                        │
│  TerminalSession     HistoryStore, UsageMonitor                   │
│  (one shell + status)                                             │
│     │ owns                                                        │
│     ▼                                                             │
│  SessionTerminalView (SwiftTerm's AppKit NSView, runs the pty)    │
└───────────────────────────────────────────────────────────────────┘
       ▲ events, polled every 0.25 s
zsh wrapper + claude-hook.sh ──► events/<session-uuid>.events
(both written at launch by ShellIntegration)
```

**Data flows one way.** The shell and Claude Code append lines to an events file,
`TerminalSession.pollEvents()` turns them into a `status`, and SwiftUI redraws because the session is
`@Observable`. Views never change state directly: they call methods on `SessionStore`
(`drop(session:on:zone:)`, `closePane`, `newSession`, …).

## Layers and files

### 1. App shell
- `PatchbayApp.swift`: the `@main` `App`, menus (`Commands`) and `AppDelegate`. AppKit is still needed for
  notifications, the "sessions are busy" quit confirmation, and a key monitor so ⌘W closes the session
  instead of the window.
- `DevHooks.swift`: lets the development MCP server (`scripts/dev-mcp.swift`) drive a test copy of the app
  through distributed notifications (`DistributedNotificationCenter`, messages between processes).

### 2. Model (the core)
- `SessionStore.swift`: the hub. Owns the sessions, the `PaneLayout`, the main mode (panes / overview /
  history), timers, saving to UserDefaults and restoring on launch, notifications and the dock badge.
- `TerminalSession.swift`: one shell. Contains a small state machine (`SessionStatus`), the hook payload
  parser (`HookPayload`) and an incremental file reader (`EventFileReader`).
- `Agent.swift`: a terminal coding agent as data (name, command, how a first prompt is passed): Claude Code,
  Codex, Gemini and custom ones from Settings. A session counts as running an agent while its command is in the
  foreground.
- `Git.swift`: a folder's branch, changed files and ahead/behind, from one `git status` call, with a pure
  parser. The store refreshes it off the main thread.
- `PaneLayout.swift`: a recursive enum, a tree of splits whose leaves are session IDs. Pure value-type
  code with no UI: the cleanest file to learn from and the easiest to test.
- `History.swift`: the activity log, appended as JSON lines.
- `Usage.swift`: Claude plan usage, read from the `usage.json` the status line script writes.

### 3. Integration with the outside world
- `ShellIntegration.swift`: writes the zsh `ZDOTDIR` wrapper, the Claude hook settings and scripts, and the
  status line script into Application Support at launch, and builds each shell's environment.
- `ExternalSessions.swift`: finds Claude sessions in other terminals through `~/.claude/sessions`, reading
  process details with `sysctl` and ending them with `kill`, C APIs called from Swift.

### 4. Views
- `ContentView.swift`: the window: sidebar plus the main area, which shows `LayoutNodeView` (panes),
  `OverviewView` or `HistoryView`.
- `SidebarView.swift`: session rows, other-terminal sessions, usage bars.
- `PaneViews.swift`: `LayoutNodeView` draws the `PaneLayout` tree recursively, mirroring the enum.
  The terminal is an AppKit `NSView` bridged into SwiftUI: `TerminalContainer` (`NSViewRepresentable`) wraps
  a `TerminalHostView`, which sizes the terminal and is the drop target for panes.
- `OverviewView.swift`, `HistoryView.swift`, `NewSessionSheet.swift` (also the Settings view),
  `StatusStyle.swift` (status icons, colours and text).
- `SessionTerminalView.swift`: subclass of SwiftTerm's terminal view that reports output, input and bells.

## Swift concepts to study here

| Concept | Where |
|---|---|
| `@Observable` (Observation framework), `@ObservationIgnored` | `SessionStore`, `TerminalSession` |
| `@MainActor` and Swift 6 concurrency: `MainActor.assumeIsolated`, `nonisolated`, `@preconcurrency`, `@unchecked Sendable` | timers in `SessionStore.init`, `AppDelegate`'s notification methods, `URLCollector` |
| Recursive enums with associated values, `Codable` | `PaneLayout` |
| Immutable updates: methods return a new value (`removing`, `inserting`, `replacing`) | `PaneLayout` |
| Enums as namespaces (no cases, only `static` members) | `ShellIntegration`, `ExternalSessionScanner`, `Theme` |
| `switch` as an expression | `DropZone.axis`, `isVisible` in `SessionStore.newSession` |
| SwiftUI ↔ AppKit: `NSViewRepresentable`, KVO with `observe(\.firstResponder)` | `PaneViews.swift`, `AppDelegate.mainWindow` |
| Environment injection: `.environment(store)`, `@Environment(SessionStore.self)`, `@Bindable` | `PatchbayApp` and every view |
| Closures as callbacks, `[weak self]` against retain cycles | `onAlert` / `onRecord` in `SessionStore.newSession` |
| Calling C: `sysctl`, `kinfo_proc`, `withUnsafeBytes` | `ExternalSessionScanner.arguments(of:)` |
| Running a command and reading its output: `Process`, `Pipe`; work off the main actor with `Task.detached` | `Git.info(at:)`, `SessionStore.refreshGit` |
| Optional value type instead of a `Bool`, `Codable` with an optional legacy key | `TerminalSession.agent`, `SavedSession` |
| Raw string literals `#"""…"""#` holding shell scripts | `ShellIntegration` |

## Suggested reading order

1. `PaneLayout.swift`: self-contained value types and recursion.
2. `TerminalSession.swift`: a state machine fed by parsed events.
3. `SessionStore.swift`: how one store coordinates everything.
4. `PatchbayApp.swift`, `ContentView.swift`, `SidebarView.swift`: how SwiftUI reads the store.
5. `PaneViews.swift`: SwiftUI/AppKit bridging and drag and drop, the hardest part.

## Weak spots, and learning exercises they suggest

- **No tests.** Add a test target for `PaneLayout` and `HookPayload`: the natural way to learn Swift Testing
  (`import Testing`, `@Test`, `#expect`).
- **`SessionStore` does a lot** (~500 lines). Extracting persistence or notifications into their own types
  is a good refactoring exercise.
- **Polling instead of events.** The 0.25 s and 1 s timers could become `DispatchSource` file watchers or an
  `AsyncStream` consumed by a `Task`: practice for structured concurrency.
