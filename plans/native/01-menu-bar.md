# 1. Menu bar extra

## Goal

See which agents need you without bringing Patchbay to the front. The menu bar is visible in every app and every
Space, which the dock badge (already there) is not when the Dock is hidden or the app is on another screen.

## User flow

- A small icon in the menu bar. Idle: plain. Anything needs attention: the icon fills and shows the count
  (`attentionCount`, the same number as the dock badge).
- Click: a list, one row per session: status dot, name, branch, `statusLabel` ("Needs your input", "Working 2m").
  Sessions needing attention first.
- Click a row: Patchbay comes forward with that session selected (what clicking a notification does today).
- Bottom of the list: the 5h and week usage bars (same data as the sidebar), **New Session…**, **Open Patchbay**.
- Settings: **Show in menu bar** (default on). Optional later: hide the Dock icon when only the menu bar is shown.

## Design

SwiftUI's `MenuBarExtra` scene, next to the existing `Window` and `Settings` scenes in `PatchbayApp`:

```swift
MenuBarExtra(isInserted: $showMenuBar) { MenuBarList().environment(appDelegate.store) } label: { MenuBarLabel() }
    .menuBarExtraStyle(.window)
```

- `.window` style allows custom views (the rows, the usage bars); `.menu` style is only plain menu items. Start
  with `.window`; the rows are the same SwiftUI views the sidebar uses, so factor out a small `SessionRow` rather
  than copying.
- Selecting a session reuses the notification-click code in `AppDelegate`
  (`selectedID`, `showOverview = false`, `makeKeyAndOrderFront`). Pull that into `store.reveal(_ id:)` and call it
  from both places.
- Label: `Image(systemName:)` plus `Text("\(count)")` when `attentionCount > 0`. The store is `@Observable`, so the
  label updates by itself; no new timer.
- `isInserted` bound to a `@AppStorage` bool for the Settings switch.

## Files

| File | Change |
|---|---|
| `PatchbayApp.swift` | `MenuBarExtra` scene, `@AppStorage("showMenuBar")` |
| new `MenuBarView.swift` | list, label |
| `SidebarView.swift` | extract the row so both lists share it |
| `SessionStore.swift` | `reveal(_:)` shared with the notification click |
| `SettingsView` (in `PatchbayApp`/Settings file) | the switch |

## Testing

In the test copy: start two shell sessions, run `sleep 5` in one, check the icon, list, and that a row click
selects the session. `snapshot` renders only the app window, not the menu bar, so check the list view by
temporarily showing it in a window, or by hand.

## Swift to learn

- Scenes beyond `Window`: how `MenuBarExtra` and `Settings` are declared in `App.body`.
- `@AppStorage` as a binding to UserDefaults.
- Extracting a shared SwiftUI view and passing it only the data it needs.
