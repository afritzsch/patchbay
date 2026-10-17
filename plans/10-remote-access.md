# 10. Phone and remote access

## Goal

Know when an agent needs you while away from the Mac, and ideally answer it. Happy, Paseo, Orca, T3 Code and
Claude Code's Remote Control all do some of this.

## Steps, smallest first

1. **Push to phone (S)**: Settings → "Also send notifications to" a webhook URL (ntfy.sh topic, Pushover,
   Slack incoming webhook). `SessionStore.notify` already builds the text; post it with `URLSession` too. Only
   when the Mac is idle or locked, so it doesn't double-notify at the desk.
2. **Read-only status page (M)**: a tiny HTTP server in the app (`NWListener`) serving a page with the session
   list and statuses, reachable over Tailscale/local network, protected by a token. Reuses the plan 6 data.
3. **Answer from the phone (M)**: add the permission buttons (plan 5) and a text box that sends input
   (bracketed paste) to a session. Needs real authentication; the token from step 2 at minimum, ideally only
   over Tailscale.
4. **Native iOS app (L)**: only if the web page isn't enough. Big; would also be a SwiftUI-on-iOS learning
   project.

## Security

Anything that can send input to a terminal can run commands as the user. Off by default, token required,
bind only to the Tailscale interface or localhost unless the user chooses otherwise, and show clearly in the
app when remote access is on.

## Swift to learn

- `URLSession` with `async`/`await` (step 1).
- `Network.framework` HTTP basics (step 2); serving a static page plus a JSON endpoint.
