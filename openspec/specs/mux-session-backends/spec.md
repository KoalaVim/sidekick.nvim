# Mux Session Backends

## Purpose

Defines how sidekick persists AI CLI sessions inside a terminal multiplexer, covering the
backend contract that every mux backend implements, the tmux and zellij backends (session
naming, discovery, creation, attach and placement per `cli.mux.create`), how a persisted
session survives a Neovim restart and is re-attached, and the shared scrollback support that
renders a mux pane's captured history in a Neovim buffer.

## Requirements

### Requirement: Mux backend contract and registration

Every mux backend SHALL be registered under its own name only when its binary is executable,
checked at session setup for `tmux`, `zellij` and `herdr`; the built-in `terminal` backend
SHALL always be registered. A backend SHALL implement: `sessions()` returning the mux sessions
it can see as plain session states, an optional `init()` hook that classifies a session as
embedded or external and sets its `priority`, `start()` and `attach()` which either act on the
multiplexer directly or return a terminal command (`{ cmd = ..., env = ... }`) for sidekick to
host in a Neovim terminal, `is_running()`, `send()`/`submit()` for delivering text, `detach()`
for teardown, and an optional `dump()` that provides scrollback. Sidekick SHALL select the
backend from `cli.mux.backend` when `cli.mux.enabled` is true and SHALL use `terminal`
otherwise. The herdr backend implements the same contract and its behavior is specified by the
herdr mux backend capability.

#### Scenario: Backend registered for an installed multiplexer
- **WHEN** `tmux` is executable and session setup runs
- **THEN** a `tmux` backend SHALL be registered and selectable through `cli.mux.backend`

#### Scenario: Start returns a command to host
- **WHEN** a backend's `start()` or `attach()` returns a terminal command
- **THEN** sidekick SHALL spawn a Neovim terminal session running that command, recording the
  originating backend as `mux_backend` and the multiplexer session as `mux_session`

#### Scenario: Backend acts on the multiplexer itself
- **WHEN** a backend's `start()` creates the session in the multiplexer and returns nothing
- **THEN** no Neovim terminal SHALL be opened and sidekick SHALL drive the session through the
  backend's `send()` and `submit()`

#### Scenario: Teardown does not kill the mux session
- **WHEN** sidekick detaches from a mux-backed session
- **THEN** the backend's `detach()` SHALL run and the multiplexer session SHALL keep running,
  so it can be discovered and re-attached later

### Requirement: Session identity derived from tool and working directory

A session identity (`sid`) SHALL be computed from the tool name and the normalized absolute
working directory as `"<tool> <hash>"`, where `<hash>` is a prefix of the SHA-256 of the cwd,
shortened as the tool name grows so the identity keeps a fixed short width. The identity SHALL
be stable for the same tool and cwd across Neovim restarts, and SHALL differ for the same tool
in a different directory. Backends SHALL use it as the multiplexer session name they create,
so that a later run can recognize its own session.

#### Scenario: Same tool and directory yield the same identity
- **WHEN** the same tool is requested twice from the same working directory, in different
  Neovim instances
- **THEN** the computed identity SHALL be identical

#### Scenario: Different directories are distinct sessions
- **WHEN** the same tool is requested from two different working directories
- **THEN** the identities SHALL differ and two independent mux sessions SHALL be possible

### Requirement: Tmux embedded session creation

The tmux backend SHALL create an embedded session when `cli.mux.create` is `"terminal"`, or
whenever Neovim is not running inside tmux (`$TMUX` unset): a `tmux new -A -s <identity>`
command started with `-c <cwd>`, the tool's configured environment, and the tool's command,
hosted in a Neovim terminal. Because of `-A`, the command SHALL attach to an existing
session with that name instead of failing. The created session SHALL have its status line
turned off (`set-option status off`) and `detach-on-destroy` set to `on`. Tool environment
entries SHALL be passed as `-e KEY=VALUE`, and entries configured as `false` SHALL be unset
with `-u KEY`. An embedded session SHALL NOT be marked external and SHALL be given a higher
discovery priority (50) than an external one (10).

#### Scenario: New embedded session
- **WHEN** the user starts a tool with `cli.mux.create = "terminal"` and no tmux session for
  that identity exists
- **THEN** a tmux session named after the identity SHALL be created in the tool's cwd and shown
  in a Neovim terminal

#### Scenario: Existing session is attached instead of duplicated
- **WHEN** a tmux session for that identity already exists
- **THEN** the same command SHALL attach to it rather than creating a second session

#### Scenario: Window or split requested outside tmux
- **WHEN** `cli.mux.create` is `"window"` or `"split"` but `$TMUX` is not set
- **THEN** the session SHALL fall back to the embedded terminal behavior

#### Scenario: Tool env applied
- **WHEN** the tool configures env entries, including entries set to `false`
- **THEN** the set entries SHALL be exported for the tmux session and the `false` entries SHALL
  be unset

### Requirement: Tmux native placement in a window or split

The tmux backend SHALL create the session in the user's own tmux client, instead of a Neovim
terminal, when Neovim runs inside tmux and `cli.mux.create` is `"window"` or `"split"`:
`tmux new-window` for `"window"` and `tmux split-window` for `"split"`, both run detached so
focus is not stolen, in the session's cwd, with the tool's environment and command. For a
split, the orientation SHALL follow `cli.mux.split.vertical` (default `true`, producing a
side-by-side split) and the size SHALL follow `cli.mux.split.size` (default `0.5`), where a
value of 1 or less is applied as a percentage of the available space and a larger value is
applied as an absolute size. Such a session SHALL be marked external, its pane and pane pid
SHALL be recorded from the created pane, and the user SHALL be notified which placement was
used. The notification SHALL be emitted for the attempted placement itself, so it appears even
when the command produced no pane and nothing was recorded. No Neovim terminal SHALL be opened
for it.

#### Scenario: New tmux window
- **WHEN** the user starts a tool inside tmux with `cli.mux.create = "window"`
- **THEN** a detached tmux window SHALL be created running the tool in the session's cwd, the
  session SHALL be external, and a notification SHALL report the new window

#### Scenario: New tmux split with default options
- **WHEN** the user starts a tool inside tmux with `cli.mux.create = "split"` and default split
  options
- **THEN** a detached side-by-side split taking 50% of the space SHALL be created and the
  session SHALL be external

#### Scenario: Absolute split size
- **WHEN** `cli.mux.split.size` is greater than 1
- **THEN** the split SHALL be created with that value as an absolute size rather than a
  percentage

#### Scenario: Horizontal split
- **WHEN** `cli.mux.split.vertical` is `false`
- **THEN** the split SHALL be created above/below the current pane instead of beside it

#### Scenario: Placement notification when no pane was created
- **WHEN** the `new-window` or `split-window` command reports no pane, so no pane id, pane pid or
  tmux session name is recorded and the session stays unstarted
- **THEN** the placement notification SHALL still be shown, alongside the reported command
  failure

### Requirement: Tmux session discovery and liveness

The tmux backend's `sessions()` SHALL list every pane of every tmux session on the server and,
for each pane, walk the pane process tree to find a process matching a configured tool. Each
match SHALL be reported as a session identified by the pane's process id, with the working
directory taken from the matched process or the pane, the pane id and pane pid recorded, the
tmux session name as `mux_session`, and the pids of the pane's process tree plus the pids of
the clients attached to that tmux session. `is_running()` SHALL be true exactly while the
recorded pane process still exists. Discovered sessions SHALL be classified external when the
tmux session name differs from the computed identity, and embedded when it matches. `sessions()`
itself SHALL report every match; when sidekick later builds the list of sessions it shows, a
session that is not attached SHALL be dropped if another session with overlapping pids has a
higher priority, so the Neovim terminal hosting a mux session (priority 100) is shown instead of
a duplicate entry for the embedded tmux session it already displays (priority 50).

#### Scenario: Tool running in a pane is discovered
- **WHEN** a configured tool is running in any tmux pane on the server
- **THEN** it SHALL be reported as a session with its pane, pane pid, tmux session name and cwd

#### Scenario: Hand-started session is external
- **WHEN** the user started a tool themselves in a tmux session whose name is not the computed
  identity
- **THEN** the discovered session SHALL be external

#### Scenario: Pane closed
- **WHEN** the pane hosting a discovered session has exited
- **THEN** `sessions()` SHALL no longer report it and `is_running()` SHALL return false for a
  session that recorded that pane

#### Scenario: No panes running a tool
- **WHEN** no tmux pane runs a configured tool
- **THEN** `sessions()` SHALL return an empty list without reporting an error

### Requirement: Tmux session persistence across Neovim restarts

Because the tool runs in a tmux session rather than a Neovim job, it SHALL survive Neovim
exiting and restarting. After a restart, discovery SHALL find the session again, and attaching
to it SHALL reuse it rather than start a second copy: for a session whose tmux session name
equals the computed identity, `attach()` SHALL return `tmux attach-session -t <identity>` to be
hosted in a Neovim terminal; for any other (external) session, `attach()` SHALL return nothing
and sidekick SHALL drive the existing pane in place without opening a terminal.

#### Scenario: Re-attach an embedded session after restart
- **WHEN** Neovim is restarted while a sidekick-created tmux session for the current tool and
  cwd is still running
- **THEN** selecting that tool SHALL attach to the existing tmux session in a Neovim terminal,
  with its conversation intact

#### Scenario: External session is driven in place
- **WHEN** the user attaches to a discovered external tmux session
- **THEN** no Neovim terminal SHALL be opened and prompts SHALL be delivered to the existing
  tmux pane

#### Scenario: Closing the Neovim terminal keeps the session
- **WHEN** the user closes or detaches the Neovim terminal hosting an embedded tmux session
- **THEN** the tmux session SHALL remain alive and SHALL be re-attachable later

### Requirement: Tmux input delivery

The tmux backend SHALL deliver prompt text by loading it into a dedicated tmux buffer named
after the target pane and pasting that buffer into the pane, so that multi-line text arrives
intact; `submit()` SHALL send an `Enter` key to the pane. For a tool declaring `mux_focus`, a
focus-in sequence SHALL be sent to the pane first and the paste SHALL be delayed briefly, since
such tools ignore input while unfocused. Both act on the pane recorded for the session, which is
how prompts reach an external pane that sidekick discovered but does not host.

#### Scenario: Send a multi-line prompt
- **WHEN** sidekick sends text to a tmux-backed session
- **THEN** the text SHALL be loaded into a tmux buffer and pasted into the session's pane

#### Scenario: Tool requiring focus
- **WHEN** the target tool declares `mux_focus`
- **THEN** a focus-in event SHALL be sent before the text, with a short delay in between

#### Scenario: Submit the prompt
- **WHEN** sidekick submits the current input
- **THEN** an `Enter` key SHALL be sent to the session's pane

### Requirement: Zellij backend runs embedded sessions only

The zellij backend SHALL always run the tool in a Neovim terminal, for both `start()` and
`attach()`, by generating a layout file that runs the tool's command in a single borderless,
focused pane that closes on exit and disables session serialization, then returning
`zellij --layout <layout> attach --create <identity>`. The child SHALL be started with
`ZELLIJ`, `ZELLIJ_SESSION_NAME` and `ZELLIJ_PANE_ID` unset so it does not consider itself
nested. Zellij sessions SHALL never be external. `cli.mux.create` values other than
`"terminal"` are not supported: when Neovim runs inside zellij and `cli.mux.create` is
`"window"` or `"split"`, the backend SHALL warn that zellij does not support that value and
that it is falling back to `"terminal"`, and SHALL then create the embedded session anyway.

#### Scenario: Start a zellij session
- **WHEN** the user starts a tool with the zellij backend
- **THEN** a layout file for that tool SHALL be written and a Neovim terminal SHALL run
  `zellij attach --create` for the session identity using that layout

#### Scenario: Re-attach to a live zellij session
- **WHEN** the user attaches to a zellij session that already exists
- **THEN** the same `attach --create` command SHALL reconnect to it rather than create a second
  session, and its conversation SHALL be intact after a Neovim restart

#### Scenario: Unsupported create mode
- **WHEN** `cli.mux.create` is `"window"` or `"split"` while Neovim runs inside zellij
- **THEN** a warning SHALL be shown naming the unsupported value and the fallback to
  `"terminal"`, and the session SHALL still start embedded

#### Scenario: Nested zellij variables are cleared
- **WHEN** the embedded zellij command is spawned from inside a zellij session
- **THEN** `ZELLIJ`, `ZELLIJ_SESSION_NAME` and `ZELLIJ_PANE_ID` SHALL be unset for it

### Requirement: Zellij session discovery from recorded state

Because zellij's API does not report per-session process information, the zellij backend SHALL
record the tool name and cwd in sidekick's state directory under the session identity when it
starts a session, and `sessions()` SHALL list zellij session names and report only those that
have such a recorded entry, using the recorded tool and cwd. The pids of a discovered session
SHALL be collected from the Neovim terminals currently hosting that zellij session, so it can
be de-duplicated against its terminal.

#### Scenario: Sidekick-created session is rediscovered
- **WHEN** a zellij session started by sidekick is still alive
- **THEN** it SHALL be reported with the tool and cwd recorded at start time

#### Scenario: Unrelated zellij session is ignored
- **WHEN** a zellij session exists that sidekick has no recorded state for
- **THEN** it SHALL NOT be reported as a sidekick session

#### Scenario: Zellij not reachable
- **WHEN** listing zellij sessions fails
- **THEN** no sessions SHALL be reported and no error SHALL be shown to the user

### Requirement: Scrollback capture bounded by cli.mux.dump

Scrollback support SHALL be available only for a Neovim terminal whose hosting mux session
implements `dump()` and whose tool does not declare `native_scroll`. A backend's `dump()` SHALL
reach back at most `cli.mux.dump` lines into the pane's history (default `2000`) and include ANSI
escape sequences, so colors and styling survive. The tmux backend SHALL capture from that point
in the history through to the end of the pane with escape sequences preserved, resolving the pane
first when it is not yet known by listing the panes of its tmux session and adopting the first
one. The zellij backend SHALL NOT provide `dump()`, because zellij's screen dump omits
ANSI escape sequences; sessions on a backend without `dump()` SHALL therefore have no sidekick
scrollback and SHALL fall back to Neovim's own terminal buffer scrolling.

#### Scenario: Capture tmux history
- **WHEN** scrollback is requested for a tmux-backed session
- **THEN** up to `cli.mux.dump` lines of that pane's history SHALL be captured with ANSI escape
  sequences

#### Scenario: Dump limit is configurable
- **WHEN** the user lowers or raises `cli.mux.dump`
- **THEN** the number of captured history lines SHALL follow that value, trading load time for
  history depth

#### Scenario: Backend without scrollback
- **WHEN** the hosting session is a zellij session, or any backend that does not implement
  `dump()`
- **THEN** no scrollback buffer SHALL be created and the terminal SHALL keep its normal Neovim
  scrolling

#### Scenario: Tool scrolls natively
- **WHEN** the tool declares `native_scroll`
- **THEN** scrollback SHALL NOT be enabled for its terminal, leaving scrolling to the tool

### Requirement: Scrollback viewing in the terminal window

While a mux-backed terminal is focused and left terminal mode, sidekick SHALL replace the
terminal buffer in that window with a scratch buffer holding the freshly dumped history,
rendered through a terminal channel so ANSI styling is displayed, and SHALL position the view
at the bottom with the cursor on the last non-blank line. Mouse wheel scrolling over the
terminal window, and clicking it while it is already focused, SHALL also open the scrollback.
Re-entering terminal mode SHALL restore the live terminal buffer in the window. When the
terminal buffer that most recently entered terminal mode is a different buffer than this
window's, sidekick SHALL re-enter terminal mode instead of opening the scrollback, so leaving
terminal mode in one terminal does not open the history of another. If `dump()` returns nothing,
no scrollback buffer SHALL be created and the live terminal buffer SHALL simply be scrolled to
the bottom instead.

#### Scenario: Leaving terminal mode opens the history
- **WHEN** the user leaves terminal mode in a focused mux-backed terminal
- **THEN** the captured history SHALL be shown in that window, scrolled to the bottom with
  styling preserved

#### Scenario: Scrolling with the mouse
- **WHEN** the user scrolls the mouse wheel over a mux-backed terminal window
- **THEN** the scrollback SHALL open so the history can be scrolled

#### Scenario: Returning to the live session
- **WHEN** the user enters terminal mode while the scrollback is shown
- **THEN** the live terminal buffer SHALL be restored in the window and input SHALL go to the
  tool again

#### Scenario: Terminal mode was left in a different terminal
- **WHEN** a focused mux-backed terminal is in normal mode but the buffer that last entered
  terminal mode is another terminal's buffer
- **THEN** terminal mode SHALL be re-entered for the focused terminal and no scrollback SHALL be
  opened

#### Scenario: Dump unavailable at open time
- **WHEN** the backend's `dump()` returns no content
- **THEN** the terminal buffer SHALL remain in the window and SHALL be scrolled to the bottom

### Requirement: Error handling for missing multiplexers and failing commands

A backend whose binary is not executable SHALL NOT be registered, and requesting it explicitly
through `cli.mux.backend` SHALL fail with an unknown-backend error rather than silently
starting the tool somewhere else; with `cli.mux.enabled = false` the plain `terminal` backend
SHALL be used and no multiplexer SHALL be required. Commands used for discovery, such as
listing panes, clients or zellij sessions, SHALL fail quietly and yield no sessions, so a
missing or unreachable multiplexer server does not spam the user. Commands that create or
inspect a session on the user's behalf SHALL report the failing command and its stderr, and a
creation that produces no pane SHALL leave the session unstarted with nothing recorded.

#### Scenario: Multiplexer not installed
- **WHEN** the configured mux binary is not on `PATH`
- **THEN** the backend SHALL NOT be registered, and selecting it SHALL surface an unknown-backend
  error

#### Scenario: Mux disabled
- **WHEN** `cli.mux.enabled` is `false`
- **THEN** sessions SHALL run in plain Neovim terminals and no multiplexer SHALL be needed

#### Scenario: Discovery command fails
- **WHEN** listing panes or sessions exits non-zero, for example with no multiplexer server
  running
- **THEN** no sessions SHALL be reported and no error notification SHALL be shown

#### Scenario: Session creation fails
- **WHEN** creating a tmux window or split fails or returns no pane
- **THEN** the failure SHALL be reported with the command and its stderr, and the session SHALL
  NOT be marked as started
