# 7. File watching

## Goal

Replace polling with the file system telling us when something changed, where it pays off. Optional: the current
timers are cheap, and the "Lean" rule says not to add a mechanism for its own sake. Do this only for the git part,
and only when [plan 4 (changes review)](../04-changes-review.md) needs live updates.

## Where it helps, where it doesn't

| Today | Watch instead? |
|---|---|
| Events file poll, 0.25 s | No. It is one small file read per session and works; leave it. |
| Git status refresh, 3 s per session (off-main) | Yes, for a faster and cheaper result: refresh when files change, not on a clock. |
| `usage.json` (written by `statusline.sh`) | Maybe: one file, `DispatchSource` is trivial. Low value. |
| Claude transcript existence check | No. Only on restore. |

## Design

- **FSEvents** (`FSEventStreamCreate`, CoreServices) watches a directory tree recursively with coalescing built in.
  Create one stream per session working directory, with `kFSEventStreamCreateFlagFileEvents` and a latency of
  about 0.5 s. On any event, mark that session's git state stale; the existing git refresh then runs for it.
- Ignore noise: events under `.git/objects`, `node_modules`, `build`, `.build`. `.git/index` and `.git/HEAD`
  changing means a commit or checkout happened.
- Keep the 3 s timer as a slow safety net (e.g. 30 s), since FSEvents can drop events on very busy trees.
- Git still runs with `--no-optional-locks` off the main thread.
- A stream is a C API: wrap it in a tiny `FolderWatcher` class (callback closure, `deinit` stops and releases the
  stream), like the hotkey wrapper in [plan 4](04-global-hotkey.md).
- Bonus: a per-session "files changed in the last minute" count in the sidebar, almost free once the stream exists.
  Do not add it until asked.

## Files

| File | Change |
|---|---|
| new `FolderWatcher.swift` | FSEvents wrapper |
| `Git.swift`, `SessionStore.swift` | refresh on change, slower fallback timer |

## Testing

In a scratch repo: `touch a`, `git add`, `git commit`; check the sidebar updates within a second. Then a 5,000
file `npm install`-style burst, and check CPU stays low (Activity Monitor), which is the point of the ignore list.

## Swift to learn

- Another C callback with `Unmanaged` context.
- Debouncing: coalescing many events into one refresh.
