# 9. Scheduled agent runs

## Goal

Start an agent with a prompt on a schedule ("every weekday at 9: summarize overnight CI failures", "every hour:
check dependency updates"). The Codex app (Automations), Claude Code (Routines) and Superset have this; results
land in a review queue.

## User flow

- Settings → Schedules, or right-click a session → "Schedule This…": folder, agent, prompt, optional new
  worktree per run (plan 2), when (daily at, weekdays, every N hours).
- At the time, Patchbay opens a new session in the background (not stealing focus), runs it, and marks it
  `unseen` when the agent finishes, with a notification. It appears in History like any run.
- Runs only while Patchbay is running; missed runs while the Mac slept run once on wake (or are skipped,
  per schedule).

## Design

- `Schedule: Codable` (id, folder, agent id, prompt, worktree flag, rule, lastRun). Stored in UserDefaults.
- Check due schedules in the existing 1 s `tick()` (comparing dates is cheap), or a 60 s timer.
- Reuses `newSession(… select: false)`, so nothing new for running.
- Non-interactive agents need the prompt passed at start (plan 3's `promptStyle`). Permission prompts still
  stop the run, which then shows as "needs input" like any session; the user decides how much to pre-approve
  via the agent's own settings.
- **Cost**: scheduled runs spend plan usage. Show the next runs in Settings, and a per-schedule on/off switch.

## Swift to learn

- `Calendar` and `DateComponents` for "next matching date".
- `NSWorkspace.didWakeNotification` for catching up after sleep.
