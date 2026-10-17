# 8. Browser / preview pane

## Goal

See the app an agent is building next to its terminal: a web view pane showing the dev server
(`localhost:3000`) or a local HTML file. Claude Code desktop, Superset, cmux and Orca all have one.

## User flow

- When a session's output prints a local URL (`http://localhost:5173`), or its process tree starts listening on
  a port, the pane header shows a globe button with the port. Click → a browser pane opens split to the right.
- ⌘L in a browser pane: address bar. Reload ⌘R (when the browser pane is focused).
- The sidebar row can show listening ports, as cmux does (`:5173`).

## Design

- **Pane content**: `PaneLayout` leaves are session IDs today. Add a leaf kind for web pages:
  `case pane(UUID)` stays, and a browser is a lightweight "session" of a new kind (`BrowserSession`: id, URL,
  title) kept in the store next to terminal sessions, so dragging, splitting and closing reuse everything.
  Alternative: generalize the leaf to `enum PaneContent { case terminal(UUID), browser(UUID) }`; cleaner model,
  more changes. Decide when building; the first is leaner.
- **View**: `WKWebView` in an `NSViewRepresentable`, like `TerminalContainer`.
- **Port detection**: regex on terminal output for `https?://(localhost|127\.0\.0\.1|0\.0\.0\.0):\d+` (cheap,
  hook into `onOutput`, throttled). Listening ports via `lsof -iTCP -sTCP:LISTEN -a -p <pids>` for the session's
  process tree, on the 3 s timer: more reliable, more expensive; only if the regex isn't enough.
- **Agent access**: later, expose the page to agents via plan 6 (screenshot, console log) so they can check
  their own UI changes.

## Swift to learn

- `WKWebView` and its delegates (navigation, title KVO).
- Generalizing a recursive enum (`PaneLayout`) and keeping `Codable` compatibility.
