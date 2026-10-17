# 6. Sleep, wake, network, power

## Goal

Agents run for minutes to hours. The Mac sleeping, throttling a background app, or losing Wi-Fi are the most common
reasons a long run silently stalls. A native app can see all of these.

## Parts

### A. Keep awake while agents work (first, most valuable)

When any session is `agentWorking` (or a shell command runs, optionally), hold a power assertion so the Mac
doesn't idle-sleep mid-run; release it when nothing works.

- `ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated], reason:)`, and
  `endActivity` with the returned token. No IOKit needed.
- Settings → **Keep Mac awake while agents work** (default off; it costs battery). Closing the lid still sleeps
  the Mac; this only stops idle sleep. A small "☕" mark in the sidebar footer while active.
- Drive it from the existing 1 s timer: compare "any working" with whether a token is held.

### B. App Nap (verify first)

When Patchbay is hidden or fully covered, macOS may "nap" it and coalesce timers, which could slow the 0.25 s
events poll and the 8 s silence check. Check whether it matters: run a Claude session, cover the window for a
few minutes, compare notification delay. If it does, the same `beginActivity` (with
`.userInitiatedAllowingIdleSystemSleep`) stops the nap without preventing sleep. Do this one even with A off.

### C. Sleep and wake

`NSWorkspace.shared.notificationCenter`: `willSleepNotification`, `didWakeNotification`.
- On wake: run the git refresh and usage read immediately instead of waiting up to 3 s; skip "interrupted"
  detection for the first few seconds (silence during sleep is not an interrupted agent: reset the silence
  clock of working sessions on wake).
- Optional: notify "Mac slept while 2 agents were working" on wake.

### D. Network

`NWPathMonitor` (`import Network`): when the path goes unsatisfied while agents work, show a small warning on those
sessions' rows ("Offline"); a Claude run will usually retry, but you want to know.

### E. Power

`ProcessInfo.processInfo.isLowPowerModeEnabled` and `NSProcessInfoPowerStateDidChange`. Informational only, e.g.
a note next to the keep-awake switch ("Low Power Mode is on").

## Files

| File | Change |
|---|---|
| `SessionStore.swift` | activity token, sleep/wake observers, path monitor |
| `TerminalSession.swift` | reset silence clock on wake |
| Settings, `SidebarView.swift` | the switch, the footer mark |

## Testing

`pmset -g assertions` shows whether the assertion is held (works from a shell). `pmset sleepnow` then wake tests C.
Network: toggle Wi-Fi off.

## Swift to learn

- Observing notifications with blocks vs `async` sequences (`NotificationCenter.notifications(named:)`).
- Keeping a token in a property and releasing it (RAII-style lifetime in Swift).
