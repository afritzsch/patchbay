# 5. Dock menu and Focus

## Goal

Two small ways to be a better neighbour on the Mac: a useful right-click menu on the Dock icon, and notifications
that respect Focus modes instead of ignoring or fighting them.

## A. Dock menu

Right-click the Dock icon: a list of sessions with status ("● api — Needs your input"), then **New Session…** and
**New Shell Here**. Click a session to reveal it. Works while the main window is closed or hidden.

- `AppDelegate.applicationDockMenu(_:)` returns an `NSMenu`, built fresh each time it opens (so no observation
  needed). Menu item title uses `displayName` and `statusLabel`; `representedObject` holds the session id.
- Items call `store.reveal(_:)` (introduced in [native plan 1](01-menu-bar.md)).

## B. Focus and interruption levels

Notifications have an `interruptionLevel`:

| Event | Level | Why |
|---|---|---|
| Agent needs input | `.timeSensitive` | breaks through Focus: work is blocked on you |
| Agent finished | `.active` (default) | normal banner |
| Idle, interrupted, errors you caused | `.passive` | lands in Notification Center silently |

- **Check first:** on iOS `.timeSensitive` needs the Time Sensitive Notifications entitlement, and Patchbay is
  ad-hoc signed with no provisioning profile. Test whether it takes effect in the test copy; if the entitlement
  is required, skip that row (it would need a paid developer account, see [small touches](08-small-touches.md))
  and use `.active` / `.passive` only.
- Add the user's own control: Settings → Notifications → **Only when needs input** (finishing a turn is quiet).
  This is the cheap version of Focus filtering and works with no entitlement.
- Users can also add Patchbay to a Focus's allowed apps in System Settings; the help text can say so.

## Files

| File | Change |
|---|---|
| `PatchbayApp.swift` | `applicationDockMenu` |
| `SessionStore.swift` | `interruptionLevel` in `notify`, the "only when needs input" setting |

## Testing

Dock menu: test copy, right-click its Dock icon by hand. Focus: enable a Focus that hides Patchbay, trigger each
status, see which arrive.

## Swift to learn

- Building an `NSMenu` and `NSMenuItem` with an `@objc` action and `representedObject` in code.
