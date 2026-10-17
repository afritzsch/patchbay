# 8. Small native touches

Each of these is a few hours at most and stands alone. Pick as wanted; none depends on another.

## Terminal-specific

- **Secure Keyboard Entry.** Native terminals offer this: while on, other apps can't observe key presses
  (protects passwords typed into the terminal). `EnableSecureEventInput()` / `DisableSecureEventInput()`
  (Carbon HIToolbox); toggle in the Patchbay menu with a checkmark, and enable only while a Patchbay terminal is
  first responder. S.
- **Open in…** context menu on a session: Reveal in Finder (`NSWorkspace.activateFileViewerSelecting`),
  Open in VS Code / default editor (`NSWorkspace.open(_:withApplicationAt:)`), Copy path. S.
- **Quick Look.** Space on a file path selected in the terminal (or in the future changes list) opens
  `QLPreviewPanel`. Needs a path-detecting hook in the terminal view; M.
- **Drag out.** Drag a file path from a session's row or the changes list into Mail, Finder or Slack as a real
  file (`NSDraggingSource`, file URL pasteboard). Dropping files *into* a pane already works (it pastes the paths).
  M.
- **Dock icon states.** Bounce once (`NSApp.requestUserAttention(.informationalRequest)`) when a session needs input
  and the app is in the background, as an alternative to notification sounds; setting off by default. S.

## Credentials

- **Keychain for custom agents.** Custom agents (in UserDefaults `customAgents`) may need API keys. Don't put keys
  in UserDefaults or in the shell's environment string: store them with `SecItemAdd` / `SecItemCopyMatching` and
  inject as environment variables only when launching that agent. S–M. The Mac's Keychain prompt on first access
  is expected; ad-hoc signing changes identity on each build, so every rebuild may re-prompt (test with the
  installed copy).

## Search and accessibility

- **Spotlight for history.** `CoreSpotlight` can index `history.jsonl` entries (prompt text, folder, date) so typing
  a phrase into Spotlight finds the session and opens `patchbay://session/<id>` (needs
  [plan 3](03-url-scheme-and-finder.md)). Respect the history retention setting: delete index items when
  history is pruned. M.
- **VoiceOver / accessibility labels.** Sidebar rows should read "api, needs your input, branch main" instead of
  a dot and text. `.accessibilityElement(children: .combine)` plus an explicit `.accessibilityLabel` per row;
  keyboard-only operation of the overview grid. S, and worth doing early.
- **Spoken alerts.** `NSSpeechSynthesizer`: "api needs you". Off by default. S.

## Distribution

- **Developer ID, notarization, Sparkle updates.** Needed once anyone else installs it: a signed and notarized app
  opens without the Gatekeeper warning, keeps the same identity across builds (fixes Keychain re-prompts and some
  notification permission oddities), and enables entitlements like time-sensitive notifications
  ([plan 5](05-dock-menu-and-focus.md)). Costs a paid Apple developer account. Sparkle (SwiftPM package) adds
  in-app updates from an appcast file. M, mostly build-script and hosting work.

## Skip for now

- **Handoff / `NSUserActivity`:** only makes sense once there is an iOS/remote client ([plan 10](../10-remote-access.md)).
- **Touch Bar, Siri, Apple Watch:** not worth it.
- **AppleScript dictionary:** the MCP server ([plan 6](../06-mcp-control.md)) covers scripting with less
  ceremony.
