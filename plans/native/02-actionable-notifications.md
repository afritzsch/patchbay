# 2. Actionable notifications

## Goal

Answer an agent from the notification itself. Today a notification only brings you to the session. When Claude
asks "Allow Bash: npm test?", you should be able to press **Allow** on the banner and never leave what you're doing.

## User flow

- **Needs input** notification: buttons **Allow** and **Deny** when the request is a permission prompt (plan 5),
  and a **Reply…** text field for a question the agent asked.
- **Done** notification: **Open** (the default click) and, optionally, **Next prompt…** with a text field that
  types the next prompt into the session.
- Notifications for one session stack in a group (already: `threadIdentifier`), and an answered or since-viewed
  notification is removed from Notification Center, so a stale "Allow?" can't be pressed twice.

## Design

- Register categories once at launch with `UNUserNotificationCenter.setNotificationCategories`:
  - `permission`: two `UNNotificationAction`s (`allow`, `deny`), no `.foreground` option, so pressing them
    doesn't pull Patchbay forward.
  - `question` / `done`: one `UNTextInputNotificationAction` (`reply`).
- In `notify(_:_:)` set `content.categoryIdentifier` from the session's status. Only attach `permission` when the
  session has a `pendingRequest` (plan 5); without that, the buttons would answer something the user can't see.
- In `didReceive`, switch on `response.actionIdentifier`. For `reply`, the response is a
  `UNTextInputNotificationResponse` and `userText` is the typed text. Call the same
  `session.answer(...)` / `terminal.send(txt:)` that the sidebar buttons use; do not write a second path.
- **Guard before sending.** Re-check the session still has the same pending request (compare an id or timestamp
  carried in `userInfo`) and is still `agentNeedsInput`. If not, do nothing and post a short "Already handled".
  Typing "1" into a shell that has moved on would run something.
- Remove delivered notifications when the session leaves the attention state:
  `removeDeliveredNotifications(withIdentifiers:)`. Use the session id (or request id) as the notification
  identifier instead of a fresh `UUID()`, which also makes repeated alerts replace each other.
- Actions only appear on hover or in Options for banners, and always on Alerts. Mention that in Settings help text.
- Build on [plan 5](../05-permission-inbox.md): this plan is its "notification action later" line. Do plan 5 first.

## Files

| File | Change |
|---|---|
| `SessionStore.swift` | categories, `categoryIdentifier`, stable identifiers, removal |
| `PatchbayApp.swift` | handle `actionIdentifier` and text replies in the delegate |
| `TerminalSession.swift` | the `answer` function from plan 5 |

## Testing

Test copy, scratch folder, tiny prompt that triggers one permission request. Check: Allow works with the app in
the background; pressing it twice does nothing; answering in the terminal instead removes the banner.
Notifications need the bundle, so use `start_test_app`, not `swift run`.

## Swift to learn

- Delegate callbacks with `async` and why they are `nonisolated` here (see the existing methods in `AppDelegate`).
- Passing small values through `userInfo` and validating them when they come back.
