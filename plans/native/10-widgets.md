# 10. Widgets

## Status: blocked on tooling. Not before an Xcode project exists.

## Goal

A desktop or Notification Center widget: sessions with status dots, the number needing attention, and the 5h/week
usage bars. Glanceable from the desktop with no app switching, and (on macOS 15) in the menu-bar-less case where
[plan 1](01-menu-bar.md) is off.

## Why it is large

- A WidgetKit widget is an **app extension** (`.appex`): a separate target with its own executable, Info.plist,
  entitlements and code signature, embedded in `Patchbay.app/Contents/PlugIns/`. SwiftPM can't produce app
  extensions; this needs an Xcode project (or `xcodebuild` with a generated one) and proper signing. The
  extension process is sandboxed, so it needs an **App Group** to share data with the app, which needs a
  developer account, not ad-hoc signing.
- A widget doesn't run live: it shows timeline entries and is refreshed by the app calling
  `WidgetCenter.shared.reloadAllTimelines()` (rate-limited by the system, so "live status" will lag seconds to
  minutes). It will not match the sidebar's real-time dots.

## If we get there

1. App writes a small snapshot (`[{name, status, since}]`, usage numbers) to the App Group container on status
   changes (not every 0.25 s tick; at most every few seconds, and only when the snapshot differs).
2. Widget reads it and renders; tapping a row opens `patchbay://session/<id>` ([plan 3](03-url-scheme-and-finder.md)).
3. App calls `reloadAllTimelines()` after writing, throttled.

## Decision

Leave it. [Menu bar extra](01-menu-bar.md) and [actionable notifications](02-actionable-notifications.md) deliver
most of the value with no tooling change. Revisit if the project moves to Xcode for other reasons (App Intents,
notarization, Sparkle).
