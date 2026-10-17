# Native macOS plans

Ideas that only a real Mac app can do, and web or Electron wrappers can't (or only badly). The numbered plans in
`../` are about what Patchbay does for agents; these are about how it fits into the system around it. Patchbay
today imports only SwiftUI, AppKit, UserNotifications and SwiftTerm, so almost all of this is untouched ground.

| # | Plan | Size | Tooling risk |
|---|---|---|---|
| 1 | [Menu bar extra](01-menu-bar.md) | S | none |
| 2 | [Actionable notifications](02-actionable-notifications.md) | S–M | none; builds on [plan 5](../05-permission-inbox.md) |
| 3 | [URL scheme, Open With, Services](03-url-scheme-and-finder.md) | S–M | `build.sh` Info.plist |
| 4 | [Global hotkey](04-global-hotkey.md) | S | none |
| 5 | [Dock menu and Focus](05-dock-menu-and-focus.md) | S | time-sensitive may need an entitlement |
| 6 | [Sleep, wake, network, power](06-system-events.md) | S | none |
| 7 | [File watching](07-file-watching.md) | S–M | none, optional |
| 8 | [Small native touches](08-small-touches.md) | S each | Sparkle/notarization needs a paid developer account |
| 9 | [App Intents, Shortcuts, Spotlight](09-app-intents.md) | M | **unknown**: the build is SwiftPM, not Xcode |
| 10 | [Widgets](10-widgets.md) | L | **blocked** without an Xcode project (needs an app extension) |

Suggested order: 1, 2, 3, then 6 (cheap and fixes real surprises), 4, 5, 8 as picked. Do 9 only after a spike
shows App Intents metadata can be produced by `build.sh`; leave 10 until the project moves to Xcode.

Rules from `../README.md` still apply (agent-neutral, lean, never block the main thread, test with the test copy).
Two more for this folder:

- **Every system integration gets a switch** in Settings (menu bar item, global hotkey, URL scheme, keep-awake).
  A terminal app that grabs a hotkey or fills the menu bar unasked is annoying.
- **Treat anything that arrives from outside the app as untrusted.** URLs, Services, Shortcuts and notification
  replies can all be triggered by other apps or web pages. They may open the New Session sheet prefilled or
  select a session; they must not start an agent with a prompt, or type into a terminal, without the user
  confirming (the exception is a notification reply the user typed themselves, plan 2).
