# 4. Global hotkey

## Goal

A key combination that works in every app: bring Patchbay forward, or jump straight to the next session that needs
you. The in-app ⌘J ("Next Needing Attention") only works while Patchbay is frontmost, which is exactly when you
need it least.

## User flow

- **⌃⌥Space** (default, changeable): activates Patchbay, shows the main window.
- **⌃⌥J** (default): activates Patchbay and selects the next session needing attention.
- Settings → **Global shortcuts**: on/off per shortcut, and a recorder field to change the key.
- Pressing the hotkey again while Patchbay is frontmost switches back to the previous app (optional; this is how
  quake-style terminals behave).

## Design

- Use the Carbon `RegisterEventHotKey` API. It is old but still the supported way to get a system-wide hotkey
  **without** Accessibility permission. `NSEvent.addGlobalMonitorForEvents` needs that permission and can't
  consume the key.
- Wrap it in one small `HotKey` class: `init(keyCode:modifiers:handler:)`, `deinit` unregisters. The C callback
  can't capture context; pass `self` through the `userData` pointer (`Unmanaged`), and hop to the main actor
  inside it.
- Swift 6 mode: the callback is a C function pointer, so it is non-isolated. Keep it to "call
  `DispatchQueue.main.async` / `Task { @MainActor in … }`" and put no logic in it.
- Store as `keyCode` + modifier mask in UserDefaults. The recorder can be a tiny `NSView` that takes the next
  `keyDown`; or start with a fixed set of choices in a picker and add the recorder later.
- Conflicts: a combination that another app already registered silently fails; show "Unavailable" when
  `RegisterEventHotKey` returns an error.
- Default off until the user turns it on in Settings, per this folder's README.

## Files

| File | Change |
|---|---|
| new `HotKey.swift` | Carbon wrapper |
| `SessionStore.swift` | `bringToFront()` / reuse `reveal` from plan 1 |
| Settings | switches, recorder |

## Testing

The test copy can register its own combination (use a different default, e.g. ⌃⌥⇧Space, when
`PATCHBAY_DEV_DIR` is set) so it doesn't fight the real app. Key events from outside can't be simulated here, so
test by hand; unit-test only the key-code-to-string display.

## Swift to learn

- Calling C APIs from Swift: function pointers, `Unmanaged`, `UnsafeMutableRawPointer`.
- Why a C callback and Swift 6 actor isolation need an explicit hop to the main actor.
