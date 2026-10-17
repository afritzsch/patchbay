# Patchbay

A Mac app for running several Claude Code sessions (and Codex, Gemini, other agents and plain shells) side by side,
with a sidebar that shows what each one is doing.

- **Sidebar**: every session with its status (*Working · Bash*, *Needs your input*, *Done*, *Running `npm test`*,
  *Idle*), how long it's been in that state, the last prompt you gave Claude or the question it's asking, and
  its folder. Drag to reorder, right-click to rename / open a sibling shell / show in Finder.
- **Split panes**: drag a session from the sidebar (or a pane by its title bar) onto a pane. Drop it on an
  edge to split left/right/top/bottom, or in the centre to swap it in. Drag the dividers to resize (double-click
  one to even them out); terminals reflow to their new size as you drag and when the window is resized. Clicking a
  session in the sidebar shows it in the focused pane. The × on a pane removes it from the screen while the
  session keeps running in the sidebar.
- **Bring in Claude sessions from other terminals**: Claude Code sessions running in Terminal, iTerm etc. are listed
  under *Claude in Other Terminals* in the sidebar (found through Claude's own registry in `~/.claude/sessions`).
  Drag one onto a pane (edge = split, centre = replace), into the session list, or click its arrow: Claude quits
  in the other terminal and the same conversation resumes here (`claude --resume`, keeping options like `--model`
  or `--dangerously-skip-permissions`). Dragging a terminal window's title-bar folder icon into the app does the
  same when Claude is running in that folder. A running process itself can't be moved between apps on macOS, so
  this is a quit-and-resume: if Claude is mid-task, that step is interrupted (you're asked first).
- **Drop from Finder**: a folder dropped on the sidebar opens a new session there; dropped on a pane's edge it
  opens in a split. Files dropped in the middle of a pane are typed in as escaped paths, as in Terminal (handy for
  giving Claude an image or a file).
- **Overview** (⇧⌘O): every session as a card in a grid that fills the window and resizes with it. Drag the gaps
  between columns or rows to make cards bigger or smaller (double-click a gap to even them out); the Columns
  toolbar menu picks a fixed number of columns or fits them to the window. Each card is the live terminal: click into
  it to type, and the terminal reflows to the card's size. Cards needing you have an orange border, the one you're
  typing in a blue one. Double-click a card's header (or its ⤡ button) to open it in the panes, or drag the header
  onto a pane.
- **Claude usage**: progress bars at the bottom of the sidebar for your plan's 5-hour and weekly limits (green,
  orange from 70%, red from 90%) with when each resets. Claude Code only hands these numbers to its status line,
  so `~/.claude/settings.json` points `statusLine` at the app's `statusline.sh`, which shows
  `model · folder · 5h 23% · week 41%` in Claude and saves the numbers for the app. They're as fresh as the last
  status line update from any Claude session (Pro/Max plans only).
- **History** (⇧⌘H): a timeline of everything you did, grouped by day: prompts you gave Claude, when Claude
  finished (and how long it took) or asked for input, shell commands with exit code and duration, sessions
  opened, closed or moved in. Search it, filter by session or kind (right-click a session → *Show History*), and
  from an entry jump to its session, resume a closed Claude conversation, run a command again, or open a new
  session in that folder. Kept in `~/Library/Application Support/Patchbay/history.jsonl` for 90 days by
  default (Settings: 7 days to forever, or clear it).
- **Attention**: sessions where Claude needs input or finished while you weren't looking get an orange dot, a
  dock badge, and a macOS notification. Clicking the notification opens that session. ⌘J jumps to the next one.
  Long shell commands (>10 s) that finish in the background are flagged too.
- **Restore**: on relaunch, the pane layout comes back, sessions reopen in their last folder and Claude conversations resume
  (`claude --resume <id>`). Both can be turned off in Settings (⌘,).

## Build & install

Requires macOS 15+ and Xcode (Swift 6).

```sh
./build.sh            # builds build/Patchbay.app
./build.sh --install  # also copies it to ~/Applications and opens it
```

You can also open `Package.swift` in Xcode.

## Shortcuts

| | |
|---|---|
| ⌘N | New session… (folder, name, shell or agent, optional first prompt) |
| ⌘T | New shell in the current session's folder |
| ⌘W | Close session (asks if an agent or a command is still running) |
| ⌘1…⌘9, ⇧⌘] / ⇧⌘[ | Switch sessions |
| ⌘J | Next session that needs you |
| ⌘D / ⇧⌘D | Split right / down (new shell in the same folder) |
| ⌘] / ⌘[ | Next / previous pane |
| ⌥⌘W | Remove pane (session keeps running) |
| ⌃⌘= | Even out panes |
| ⇧⌘O | Toggle overview |
| ⇧⌘H | Toggle history |
| ⌘R | Rename session |
| ⌘= / ⌘- / ⌘0 | Font size |

## How status tracking works

Nothing in your own config is modified. The app keeps its files in
`~/Library/Application Support/Patchbay/`:

- `zsh/`: a `ZDOTDIR` wrapper. Each session's zsh loads your own `.zshenv`, `.zprofile`, `.zshrc` and `.zlogin`
  unchanged, then adds `preexec`/`precmd` hooks that report the running command, exit code and directory, and a
  `claude` shell function that adds `--settings <app>/claude-settings.json`. `ZDOTDIR` is handed back afterwards,
  so nested shells behave normally.
- `claude-settings.json`: Claude Code hooks (`SessionStart`, `UserPromptSubmit`, `Pre/PostToolUse`,
  `Notification`, `Stop`, `SessionEnd`), merged by Claude with your own settings. Each hook runs
- `claude-hook.sh`, which appends the event to `events/<session>.events`. The app reads these files.
  Outside the app (no `PATCHBAY_SESSION_ID`), the script does nothing.

Pressing Esc/Ctrl-C in Claude fires no hook, so a "working" session whose screen has been silent for 8 s is
shown as waiting for a prompt again.

Other agents: Codex and Gemini are built in, and Settings → Other agents adds any command. A session counts as
running an agent while that command (the first word of the command line, or the whole configured command) is in the
foreground. These agents have no hooks yet, so they show *Working* while their output flows (typing doesn't count)
and *Waiting for prompt* after 8 s of silence; a bell and the long-command notification work as for any command.
Claude has full status (tools, questions, done). Sessions with other agents restart them fresh when reopened.

Limitations: the integration is zsh-only (other shells get a plain terminal; Claude sessions still start but
don't report status). An alias named `claude` (Claude's local installer adds one) keeps working: the wrapper
runs the alias's command with the app's settings added.

Terminal emulation is [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm).
