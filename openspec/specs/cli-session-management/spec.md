# CLI Session Management

## Purpose

Defines the public `require("sidekick.cli")` API and the session state model behind it:
how CLI tool sessions are discovered, classified, selected, attached to, reused and torn
down, how a multiplexer backend is chosen, and how the named keymap actions available
inside a CLI window are dispatched. Terminal window creation and layout belong to the CLI
terminal window capability, individual multiplexer implementations to the mux session
backends and herdr mux backend capabilities, and tool command definitions to the CLI tool
registry capability.

## Requirements

### Requirement: Public CLI entry points

The module SHALL expose `show`, `toggle`, `hide`, `close`, `focus`, `select`, `send`,
`prompt` and `render` as the public API, every one of which except `render` SHALL be
mirrored by a `:Sidekick cli <sub>` sub-command. `show`, `toggle`, `focus`, `hide` and
`close` SHALL also accept a single string, which SHALL be interpreted as the tool name,
while a single string passed to `send` SHALL be interpreted as the message. Option normalization
SHALL fold `opts.name` into `opts.filter.name`, so that a tool name and an explicit filter
select the same candidates. `show` SHALL attach (starting a session if needed) and display
the session, requesting focus according to `opts.focus`. `toggle` SHALL toggle the visible
terminal window of an already attached session and SHALL focus it when it ends up open
unless `opts.focus` is `false`; when the call itself performed the attach, the freshly
started window SHALL NOT be toggled away. `focus` SHALL blur the terminal when it is
already focused and focus it otherwise. `hide` SHALL only consider states that own a
Neovim terminal and SHALL hide their windows. `close` SHALL detach the matching sessions.
`hide`, `close` and `show` SHALL accept `all = true` to act on every matching attached
session instead of asking the user to pick one. The deprecated aliases `select_prompt`,
`select_tool` and `ask` SHALL keep working while emitting a deprecation warning that names
the replacement.

#### Scenario: Tool name shorthand

- **WHEN** `require("sidekick.cli").show("claude")` is called
- **THEN** it SHALL behave exactly as `show({ filter = { name = "claude" } })`

#### Scenario: Toggle an open window

- **WHEN** `toggle()` is called and the matching session already has an open terminal window
- **THEN** the window SHALL be hidden

#### Scenario: Focus toggles back to the editor

- **WHEN** `focus()` is called while the cursor is already inside the CLI terminal window
- **THEN** the window SHALL be blurred and the previous window restored, without hiding the terminal

#### Scenario: Close every attached session

- **WHEN** `close({ all = true })` is called with two attached sessions
- **THEN** both sessions SHALL be detached

### Requirement: Session dispatch and implicit attach

`show`, `toggle`, `hide`, `close`, `focus` and `send` SHALL all resolve the session they act
on through a single dispatch step over the currently attached sessions matching the caller's
filter. When no attached session matches and the operation is allowed to attach (`show`,
`toggle`, `focus`, `send`), the selection picker SHALL be opened in automatic mode with the
caller's filter so a session can be started or adopted. When more than one attached session
matches and `all` was not requested, the picker SHALL be opened in automatic mode restricted
to attached sessions. Otherwise the operation SHALL be applied to each matching attached
session. Callbacks SHALL run scheduled on the main loop, and SHALL receive both the resolved
state and whether that call performed the attach.

#### Scenario: Nothing attached yet

- **WHEN** `send("hello")` is called and no session is attached
- **THEN** a session SHALL be selected automatically or via the picker, attached, shown, and only then SHALL the message be sent

#### Scenario: Ambiguous attached sessions

- **WHEN** `hide()` is called while two attached sessions match the filter and `all` is not set
- **THEN** the picker SHALL ask which attached session to hide

#### Scenario: Non-attaching operation with nothing attached

- **WHEN** `close()` or `hide()` is called and no attached session matches the filter
- **THEN** nothing SHALL happen and no session SHALL be started

### Requirement: Attach and detach lifecycle

Attaching a state SHALL reuse its existing session, or create a new session for the state's
tool in the current working directory when the state has none. A session that is not yet
started SHALL be started, and an already started session SHALL be attached to. When the
backend answers with a command to run, that command SHALL be hosted in a Neovim terminal
session whose id is derived from that session's identity, which SHALL record the mux backend and
mux session it fronts and SHALL keep the mux session as its parent. Attach SHALL emit
`SidekickCliAttach` and detach SHALL emit `SidekickCliDetach`, both carrying the session id.
Detaching a session that fronts a mux session SHALL also detach the parent, because the
terminal is sidekick's only handle on it. Detaching a state that has no session, or that
sidekick is not attached to, SHALL do nothing. Detaching a state SHALL close the terminal when
the session runs in a Neovim terminal, and otherwise SHALL detach the session and report
`Detached from` the tool. Enumerating sessions SHALL detach every session that is recorded as
attached but is no longer reported as running, so the attached set never outlives the
processes behind it. Attaching a session with no terminal of its own SHALL report
`Attached to` the tool when that call performed the attach. When `show` was requested the
session's surface SHALL be shown, and it SHALL be focused unless focus was explicitly declined:
for a session hosted in a Neovim terminal that means showing and focusing the terminal, and
only when the terminal is running; for a session with no terminal of its own that means asking
the session to focus itself, which reaches the multiplexer pane the session actually lives in.
Focusing SHALL NOT be conditional on this call having performed the attach, so a repeated
request against an already attached session focuses it again.

#### Scenario: First attach starts a session

- **WHEN** a state without a session is attached
- **THEN** a new session for that tool and working directory SHALL be created and started

#### Scenario: Attaching to an external session

- **WHEN** an already started external session is attached and it needs no Neovim terminal
- **THEN** an informational message SHALL report that sidekick attached to the tool, and `SidekickCliAttach` SHALL be emitted

#### Scenario: Showing a session that has no terminal

- **WHEN** a session with no Neovim terminal is attached with `show` requested and focus not declined
- **THEN** the session SHALL be asked to focus itself, so the multiplexer pane hosting it comes in front of the user

#### Scenario: Repeated request against an attached session

- **WHEN** a session that sidekick is already attached to is resolved again with `show` requested
- **THEN** it SHALL be focused again, even though no attach was performed

#### Scenario: Focus declined

- **WHEN** a session is attached with `show` requested and `focus = false`
- **THEN** the session SHALL be shown and SHALL NOT be focused, whether or not it has a terminal

#### Scenario: Closing a terminal-hosted mux session

- **WHEN** a session hosted in a Neovim terminal that fronts a mux session is closed
- **THEN** the terminal SHALL be closed and the parent mux session SHALL be detached as well

#### Scenario: Detaching something that is not attached

- **WHEN** `close()` resolves a state whose session sidekick is not attached to
- **THEN** nothing SHALL happen: no terminal SHALL be closed and no detach SHALL be reported

#### Scenario: Session disappeared

- **WHEN** an attached session is no longer reported as running by its backend
- **THEN** it SHALL be detached automatically the next time sessions are enumerated

### Requirement: Candidate session enumeration

The state model SHALL present a single list of candidate sessions built by combining every
running session reported by the registered backends (multiplexer panes and live Neovim
terminals) with every configured tool that has no local session for the current working
directory; an external session SHALL NOT suppress its tool's plain candidate, so the tool can
still be started locally beside it.
Sessions reported by a backend SHALL be marked as started and as installed, since a running
session proves the tool exists. Tool-only candidates SHALL carry no session and SHALL record
whether the tool's first command argument is executable. When two running sessions share
process ids, only the highest priority one SHALL be listed unless the lower priority one is
attached; Neovim terminal sessions SHALL rank above native mux sessions, which SHALL rank
above external panes, so the same agent seen through two backends appears once. When the
filter asks only for attached sessions, no tool-only candidates SHALL be added.

#### Scenario: Configured but not installed

- **WHEN** a tool is configured and its executable is missing from `PATH`
- **THEN** it SHALL still appear as a candidate, marked as not installed

#### Scenario: Same agent seen twice

- **WHEN** a Neovim terminal session and a mux session report overlapping process ids and neither is attached
- **THEN** only the higher priority session SHALL be listed

#### Scenario: Tool already running here

- **WHEN** a non-external session for tool `X` is already running in the current working directory
- **THEN** no additional tool-only candidate for `X` SHALL be added

#### Scenario: External session does not hide the tool

- **WHEN** the only session for tool `X` in the current working directory is an external multiplexer pane
- **THEN** both that session and a plain candidate for `X` SHALL be listed

### Requirement: Candidate filtering and ordering

Candidates SHALL be filterable by `attached`, `cwd`, `external`, `installed`, `name`,
`session` (session id), `started` and `terminal` (whether the candidate owns a Neovim
terminal); an absent filter field SHALL match everything, and a `cwd` filter with any
non-nil value SHALL match only candidates whose session runs in the current working
directory. Because tool-only candidates record neither `attached` nor `started`, an explicit
`attached = false` or `started = false` SHALL exclude them and match only sessions.
The resulting list SHALL be
ordered deterministically: installed before not installed, then candidates belonging to the
current working directory (including tool-only candidates) before others, then started
before not started, then candidates with a Neovim terminal before those without, then local
before external, and finally by tool name.

#### Scenario: Filtering by tool name

- **WHEN** candidates are requested with `filter = { name = "codex" }`
- **THEN** only candidates whose tool is `codex` SHALL be returned

#### Scenario: Ordering favours the current directory

- **WHEN** one session runs in the current working directory and another runs elsewhere for the same tool
- **THEN** the session in the current working directory SHALL be listed first

#### Scenario: Filtering for candidates that are not attached

- **WHEN** candidates are requested with `filter = { attached = false }`
- **THEN** only sessions that sidekick is not attached to SHALL be returned
- **AND** tool-only candidates SHALL be left out, even though they are not attached either

#### Scenario: Empty result

- **WHEN** no candidate matches the filter
- **THEN** the list SHALL be empty

### Requirement: Session status classification

Every candidate SHALL be classified into exactly one status, in decreasing precedence:
`attached` (sidekick is attached to a live session), `started` (a live session exists that
sidekick is not attached to), `installed` (no session, but the tool's executable was found)
and `missing` (no session and no executable). The status SHALL select both the icon
`ui.icons[status]` and the highlight group `SidekickCli<Status>`. Candidates that have a
session SHALL additionally show the `ui.icons.external_<status>` icon when that session is
external and the `ui.icons.terminal_<status>` icon otherwise, where an external session is
one that lives in a multiplexer pane and is never hosted in a Neovim terminal.

#### Scenario: Attached session

- **WHEN** a candidate's session is attached
- **THEN** its status SHALL be `attached` regardless of it also being started and installed

#### Scenario: Running but not attached

- **WHEN** an external multiplexer pane is running a configured tool and sidekick is not attached to it
- **THEN** the candidate's status SHALL be `started` and it SHALL be shown with the `external_started` icon

#### Scenario: Uninstalled tool

- **WHEN** a configured tool's executable cannot be found
- **THEN** the candidate's status SHALL be `missing` and use the `missing` icon and `SidekickCliMissing` highlight

### Requirement: Mux backend registry and selection

Session backends SHALL be kept in a registry keyed by name, and registration SHALL happen
once, lazily, on first session enumeration. Tool definitions SHALL be loaded before
registration so that a tool may register its own backend. The `tmux`, `zellij` and `herdr`
backends SHALL each be registered only when an executable of that name is found in `PATH`;
the `terminal` backend SHALL always be registered. A new session SHALL use the backend named
by `cli.mux.backend` when `cli.mux.enabled` is `true`, and the `terminal` backend otherwise;
`cli.mux.enabled` SHALL default to `false`. The default `cli.mux.backend` SHALL be
auto-detected from the environment as `herdr` when `HERDR_ENV` is set, `zellij` when
`ZELLIJ` is set, and `tmux` otherwise, and SHALL be validated against those three names at
setup. Requesting a backend that is not in the registry SHALL fail loudly with an
`unknown backend` error rather than silently falling back.

#### Scenario: Multiplexer disabled

- **WHEN** `cli.mux.enabled` is left at its default
- **THEN** new sessions SHALL be created on the `terminal` backend

#### Scenario: Auto-detected backend

- **WHEN** Neovim runs with `ZELLIJ` set in the environment and no explicit `cli.mux.backend`
- **THEN** `cli.mux.backend` SHALL be `zellij`

#### Scenario: Configured backend not installed

- **WHEN** `cli.mux.enabled` is `true`, `cli.mux.backend` is `tmux` and the `tmux` executable is absent
- **THEN** creating a session SHALL raise an `unknown backend: tmux` error

#### Scenario: Sessions from all registered backends

- **WHEN** candidates are enumerated
- **THEN** every registered backend SHALL be asked for its running sessions and each returned session SHALL be tagged with that backend's name

### Requirement: Session identity and reuse per working directory

A session's identity SHALL be derived from its tool name and its normalized absolute working
directory, so that at most one canonical session id exists per tool per directory. The
working directory SHALL default to the current window's working directory. When a session is
requested for a specific tool in automatic mode, an already running session in the current
working directory SHALL be adopted instead of starting a second one beside it; if nothing is
running in this directory, a fresh session SHALL be started; if only sessions from other
directories exist, the user SHALL be asked to pick rather than having one adopted silently.

#### Scenario: Reuse an external pane in this directory

- **WHEN** an external multiplexer pane is already running the requested tool in the current working directory and `show` is called for that tool
- **THEN** sidekick SHALL attach to that pane instead of starting a duplicate session

#### Scenario: Start fresh in a new directory

- **WHEN** the requested tool is running only in other working directories and `show` is called for it
- **THEN** a new session SHALL be started for the current working directory rather than adopting a foreign one

#### Scenario: Only foreign sessions and none startable

- **WHEN** the only candidates for the requested tool are sessions from other working directories
- **THEN** the picker SHALL be shown so the user chooses explicitly

### Requirement: Session selection picker

Selecting a session SHALL be done through `vim.ui.select` with the prompt
`Select CLI tool:` and the kind `sidekick_cli`, over the filtered and ordered candidate list.
Each entry SHALL render the status icon, the tool name, and for candidates with a session
also the external/terminal icon, a bracketed backend label and the session's working
directory shortened relative to the home directory. The backend label SHALL name the mux
backend when the session is hosted in a terminal on behalf of a multiplexer, otherwise the
session's own backend, and for external sessions SHALL append the multiplexer session name.
Choosing an entry SHALL invoke the caller's callback with the selected state, or with no
state when the user aborts. In automatic mode a single matching candidate SHALL be chosen
without prompting. By default, `select` SHALL attach the chosen state and show it, honoring
the caller's `focus` option.

#### Scenario: Single candidate in automatic mode

- **WHEN** exactly one candidate matches the filter and automatic mode is active
- **THEN** that candidate SHALL be used immediately without showing a picker

#### Scenario: Entry shows where the session lives

- **WHEN** an external multiplexer session is rendered in the picker
- **THEN** the entry SHALL show its backend and multiplexer session name in brackets and the session's working directory

#### Scenario: User aborts

- **WHEN** the user cancels the picker
- **THEN** the callback SHALL be invoked without a state and no session SHALL be started

### Requirement: Sending messages and prompts

`send` SHALL accept either a message string or options with `msg`, `prompt` or pre-rendered
`text`, SHALL render the message through the context/template layer when no text was given,
and SHALL then attach, show and deliver the result to the resolved session followed by a
newline. When neither `msg` nor `prompt` is given and the editor is in visual mode, the
selection SHALL be sent. A render that produces nothing SHALL abort with a
`Nothing to send.` warning and SHALL NOT start or show a session. A render that produces only
a newline SHALL be sent as a bare newline. Before delivery, visual mode SHALL be exited, and
the message SHALL be formatted by the target tool so tool-specific text handling applies.
When `submit` is set, the session SHALL additionally be told to submit the input. `prompt`
SHALL open the prompt picker and, by default, send the selected prompt's rendered text via
`send`; a caller-supplied callback SHALL replace that default. `render` SHALL expose the
same template rendering without sending anything.

#### Scenario: Sending the visual selection

- **WHEN** `send()` is called from visual mode with no message or prompt
- **THEN** the current selection SHALL be rendered and sent, and visual mode SHALL be exited

#### Scenario: Nothing to send

- **WHEN** the requested message renders to an empty result
- **THEN** a `Nothing to send.` warning SHALL be shown and no session SHALL be attached or shown

#### Scenario: Send and submit

- **WHEN** `send({ msg = "hi", submit = true })` is called
- **THEN** the text SHALL be delivered to the session and the session SHALL then be asked to submit

#### Scenario: Prompt selection

- **WHEN** `prompt()` is called and a prompt is chosen
- **THEN** the rendered prompt SHALL be sent to the resolved session; if the user aborts, nothing SHALL be sent

### Requirement: Named keymap actions

Keymaps configured under `cli.win.keys`, plus any tool-specific keymaps, SHALL resolve their
right-hand side by name in a fixed order: a named action from the CLI actions module, then a
method of the terminal object with that name, then an existing Vim command, and finally the
string itself used as a literal keymap right-hand side. The named actions SHALL include
`prompt` (leave insert mode, pick a prompt, send it followed by a newline and return to
insert mode), `insert_cr` (enter insert mode and feed a carriage return), `buffers` and
`files` (open the buffer or file picker scoped to the current session and mark the terminal
as no longer in normal mode), and `nav_left`, `nav_down`, `nav_up`, `nav_right`. Window
navigation SHALL move to the window in that direction using `cli.win.nav` when configured and
`wincmd` otherwise, but SHALL instead pass the original control key through to the tool when
there is no window in that direction or the CLI window is floating. `hide` and `blur` SHALL
resolve to the corresponding terminal methods and `stopinsert` to the Vim command. Keymaps
default to terminal mode, and a missing left-hand side or an unresolvable action SHALL be
reported as an error naming the offending keymap.

#### Scenario: Action name resolves to a terminal method

- **WHEN** a keymap is configured with the right-hand side `hide`
- **THEN** pressing it SHALL hide the CLI terminal window

#### Scenario: Navigation at the edge

- **WHEN** `nav_left` is triggered and there is no window to the left, or the CLI window is a float
- **THEN** the literal `<c-h>` SHALL be sent to the tool instead of changing windows

#### Scenario: Picker scoped to the session

- **WHEN** the `files` action is triggered from a CLI window
- **THEN** the file picker SHALL open filtered to that session so the selection is sent to it

#### Scenario: Unknown action

- **WHEN** a keymap names an action that is neither a known action, a terminal method, nor an existing command
- **THEN** the string SHALL be used as a literal keymap right-hand side, and a keymap with no left-hand side SHALL be reported as an error

### Requirement: Error reporting for unusable tools and sessions

When the user selects a candidate whose tool is not installed, the selection SHALL be
rejected: an error SHALL report that the tool is not installed, the tool's `url` SHALL be
opened in the browser when one is configured, and the callback SHALL be invoked without a
state so nothing is started. Failure to open the URL SHALL itself be reported as an error.
When a backend fails to start or attach to a session, the failure SHALL be surfaced by that
backend (see the mux session backends capability) and the session SHALL NOT be recorded as
attached.

#### Scenario: Selecting a missing tool

- **WHEN** the user picks a candidate with status `missing`
- **THEN** an error SHALL state that the tool is not installed, its documentation URL SHALL be opened if configured, and no session SHALL be started

#### Scenario: URL cannot be opened

- **WHEN** opening the configured URL for a missing tool fails
- **THEN** the failure SHALL be reported as an error including the reason

#### Scenario: No candidates at all

- **WHEN** a selection is requested and no candidate matches the filter
- **THEN** the user SHALL be warned that no tools match the given filter and the callback SHALL NOT be invoked
