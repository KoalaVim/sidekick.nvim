# CLI Terminal Window

## Purpose

Defines the Neovim terminal window that hosts an AI CLI tool: how the terminal buffer and job
are created and what environment the tool is started with, how the window is laid out and sized,
which window and buffer options and keymaps are applied to it, how showing, hiding, focusing and
closing behave with respect to the running job, and how text and keys are delivered to the tool.
Session bookkeeping, backend selection and the action dispatch table used by keymaps are owned by
the CLI session management capability and are only referenced here.

## Requirements

### Requirement: Terminal buffer and job creation

Starting a terminal session SHALL create a scratch, unlisted buffer, apply the buffer options,
set `b:sidekick_cli` to the session's tool, install the configured keymaps, open the window, and
then start the tool's command as a terminal job in the session's `cwd`. The job SHALL be started
from inside the terminal window so that the pty is sized to that window. Starting SHALL be a
no-op when the session's job is already running. On Windows, the command SHALL be resolved with
`exepath`; when the resolved path is empty or is not an `.exe`, the command SHALL instead be
passed as a single joined command string, otherwise the resolved executable path SHALL replace
the first argument. On success the session SHALL record the job's pid, SHALL be marked as started
with status `idle`, and the file watcher SHALL be enabled when `cli.watch` is `true`. Status
changes SHALL also be reported to the session's parent session when it has one, because the tool
runs in this terminal rather than in a multiplexer pane.

#### Scenario: Tool starts successfully

- **WHEN** a terminal session is started for an installed tool
- **THEN** a terminal buffer with `b:sidekick_cli` set SHALL exist, the tool SHALL run as a job in
  the session's `cwd`, and the session SHALL report status `idle`

#### Scenario: Tool is not installed

- **WHEN** the job cannot be started and the tool's command is not executable
- **THEN** an error naming the command SHALL be reported as "`<cmd>` is not installed?" and the
  session SHALL be closed

#### Scenario: Job fails for another reason

- **WHEN** the job cannot be started but the command is executable
- **THEN** an error "Failed to run `<cmd>`" SHALL be reported and the session SHALL be closed

#### Scenario: Start on an already running session

- **WHEN** start is requested for a session whose job is still running
- **THEN** no second buffer, window or job SHALL be created

### Requirement: Terminal job environment

The terminal job SHALL be started with `clear_env`, so its environment is built explicitly from
the current process environment plus, in order of increasing precedence: the editor proxy, the
tool's configured `env`, the tool's own `env`, and a fixed set of sidekick overrides. When the
`bin/sidekick-editor-proxy` script is found on the runtime path, `EDITOR` and `VISUAL` SHALL be
set to it. The overrides SHALL set `NVIM` to Neovim's server name and `TERM` to `xterm-256color`,
and SHALL unset `NVIM_LISTEN_ADDRESS`, `NVIM_LOG_FILE`, `VIM` and `VIMRUNTIME`. Any env entry
whose value is `false` SHALL be removed from the environment rather than passed as a string.

#### Scenario: Tool can talk back to Neovim

- **WHEN** a tool runs in the terminal
- **THEN** it SHALL see `NVIM` set to Neovim's server name and `TERM` set to `xterm-256color`

#### Scenario: Editor proxy is available

- **WHEN** `bin/sidekick-editor-proxy` is found on the runtime path
- **THEN** the tool SHALL see `EDITOR` and `VISUAL` pointing at that proxy

#### Scenario: Tool env is applied and can clear variables

- **WHEN** a tool configures `env` entries
- **THEN** those entries SHALL be set for the job, and an entry whose value is `false` SHALL be
  absent from the job's environment

#### Scenario: Neovim's own variables do not leak

- **WHEN** a tool runs in the terminal
- **THEN** `VIM`, `VIMRUNTIME`, `NVIM_LISTEN_ADDRESS` and `NVIM_LOG_FILE` SHALL NOT be set for it

### Requirement: Window layout

The window layout SHALL be selected by `cli.win.layout`, one of `float`, `left`, `right`, `top`
or `bottom`, defaulting to `right`. A `float` layout SHALL open an editor-relative, focusable,
minimal-style floating window titled `" Sidekick "` centered in the title bar. A non-float layout
SHALL open a split against the whole editor area (not against the current window), placed above,
below, left or right according to the layout, with `right` used for any unrecognized value. A
`top` or `bottom` split SHALL have its height fixed and a `left` or `right` split SHALL have its
width fixed, so that other window operations do not resize the terminal. The window SHALL be
opened without entering it, and SHALL carry `w:sidekick_cli` (the tool) and
`w:sidekick_session_id` (the session id). Opening SHALL be a no-op when the window is already
open or the session has no buffer.

#### Scenario: Default layout

- **WHEN** the terminal window is opened with the default configuration
- **THEN** it SHALL be a full-height split at the right edge of the editor with a fixed width

#### Scenario: Float layout

- **WHEN** `cli.win.layout` is `"float"`
- **THEN** the terminal SHALL be shown in a centered floating window titled `" Sidekick "`

#### Scenario: Horizontal layouts

- **WHEN** `cli.win.layout` is `"top"` or `"bottom"`
- **THEN** the terminal SHALL be a split at the top or bottom edge of the editor with a fixed height

#### Scenario: Window identifies its session

- **WHEN** the terminal window is open
- **THEN** `w:sidekick_session_id` SHALL hold the session id and `w:sidekick_cli` the tool, so that
  other features can resolve a window back to its session

### Requirement: Window sizing

Sizes SHALL be taken from `cli.win.float` for the `float` layout and from `cli.win.split` for the
split layouts. A width or height less than or equal to `1` SHALL be interpreted as a fraction of
`columns` or `lines` respectively; a larger value SHALL be interpreted as an absolute number of
cells. Float defaults SHALL be `width = 0.9` and `height = 0.9`, and a float SHALL never be
smaller than 80 columns by 10 lines. A float's `row` and `col` SHALL default to `0.5` and, when
less than or equal to `1`, SHALL be interpreted as a fraction of the leftover space so that `0.5`
centers the window. Split defaults SHALL be `width = 80` and `height = 20`, and a split size of
`0` SHALL mean "let Neovim choose", leaving that dimension unset.

#### Scenario: Fractional float size

- **WHEN** the float width is `0.9`
- **THEN** the window SHALL be 90% of the editor's columns wide

#### Scenario: Float minimum size

- **WHEN** the computed float size is smaller than 80 columns or 10 lines
- **THEN** the window SHALL be widened or heightened to that minimum

#### Scenario: Absolute split size

- **WHEN** `cli.win.split.width` is `80` and the layout is `"right"`
- **THEN** the split SHALL be 80 columns wide

#### Scenario: Default split size

- **WHEN** a split's width or height is set to `0`
- **THEN** that dimension SHALL NOT be requested and Neovim's default split size SHALL apply

### Requirement: Window and buffer options and the config callback

The terminal window SHALL be given sidekick's window options and the buffer sidekick's buffer
options, with user values from `cli.win.wo` and `cli.win.bo` merged on top. The defaults SHALL
include `filetype = "sidekick_terminal"` and `swapfile = false` for the buffer, and for the window
a `winhighlight` mapping normal, non-current-normal, end-of-buffer and sign-column highlights to
`SidekickChat`, plus disabled `number`, `relativenumber`, `list`, `spell`, `wrap`, `cursorline`,
`cursorcolumn`, `winbar`, `colorcolumn`, a `signcolumn` of `"no"` and an empty `statuscolumn`,
because left padding interferes with terminal reflow, plus `fillchars = "eob: "`,
`listchars = "tab:  "` and `sidescrolloff = 0`. `cursorline` SHALL be enabled only while the
terminal window is the current window and the editor is not in terminal mode, and SHALL be updated
(debounced) when terminal mode or window focus changes. Each session SHALL take its own deep copy
of `cli.win` at creation time, and `cli.win.config` SHALL be called with the session before it is
started so it can adjust that copy's options.

#### Scenario: Defaults and user overrides

- **WHEN** the terminal window is opened with `cli.win.wo` or `cli.win.bo` entries configured
- **THEN** sidekick's defaults SHALL be applied first and the configured entries SHALL win

#### Scenario: Config callback adjusts one session

- **WHEN** `cli.win.config` changes the passed session's window options
- **THEN** the change SHALL apply to that session's window only and SHALL take effect before the
  window is opened

#### Scenario: Cursorline follows mode

- **WHEN** the user leaves terminal mode in the focused terminal window
- **THEN** `cursorline` SHALL be enabled, and it SHALL be disabled again on returning to terminal
  mode or leaving the window

### Requirement: Show, hide, focus, blur and close

`show` SHALL start the session if needed and open its window; `hide` SHALL close the window while
leaving the buffer and job intact; `toggle` SHALL hide an open window and show a hidden one;
`focus` SHALL show the window, make it the current window and enter terminal mode; `blur` SHALL
return to the previous window and leave insert mode, but only when the terminal window is
currently focused. `focus` SHALL NOT change the current window when the job is not running. Only
`close` SHALL end the tool: it SHALL stop the job, delete the buffer, hide the window, drop its
send timer and autocommands, detach the session, and SHALL be safe to call more than once. When
hiding would close the last window in the editor, another listed buffer SHALL be opened first, or
a new empty buffer when there is none, so that Neovim is not left without a window. Entering the
terminal window SHALL restore the mode the user last left it in: terminal mode by default, or
normal mode if the user had switched to normal mode there.

#### Scenario: Hide preserves the tool

- **WHEN** the user hides the terminal window
- **THEN** the window SHALL be closed, the job SHALL keep running, and showing again SHALL reveal
  the same buffer with its scrollback intact

#### Scenario: Hiding the last window

- **WHEN** the terminal window is the only window in the editor and is hidden
- **THEN** another listed buffer SHALL be shown, or a new empty buffer created, before the terminal
  window is closed

#### Scenario: Blur returns to the previous window

- **WHEN** the terminal window is focused and blur is requested
- **THEN** focus SHALL move back to the previous window, insert mode SHALL be left, and the
  terminal window SHALL stay open

#### Scenario: Mode is restored on re-entry

- **WHEN** the user had left the terminal in normal mode and later re-enters the window
- **THEN** the session SHALL stay in normal mode instead of entering terminal mode

#### Scenario: Close ends the tool

- **WHEN** a session is closed
- **THEN** its job SHALL be stopped, its buffer deleted, its window closed and its autocommands
  removed, and a second close SHALL have no further effect

### Requirement: Sending text and keys to the tool

Sending SHALL show the session first, so text can be sent to a session that has not been started
yet, and SHALL be dropped when the job is not running. Sent text SHALL be queued and delivered
only after the tool is considered ready, then paced at roughly one queued item per 100 ms, with
`\r\n` normalized to `\n`. Text SHALL be delivered by inserting it into the terminal buffer as
user-like input rather than by writing to the job's channel directly, and terminal mode SHALL be
re-entered afterwards when the terminal window is focused. Sending SHALL set the session status to
`working`. `submit` SHALL enqueue a carriage return through the same path and SHALL do nothing
when the job is not running. Readiness SHALL be detected by watching the terminal buffer settle:
once the buffer holds more than 5 lines (ignoring trailing blank lines) and the cursor has moved
past row 3, the line count must remain unchanged for 500 ms; readiness SHALL be assumed after
5000 ms regardless, and the check SHALL wait for the window and stop if the buffer becomes invalid.

#### Scenario: Send to a session that is not started

- **WHEN** text is sent to a session with no running job
- **THEN** the session SHALL be started and shown, and the text SHALL be delivered once the tool is
  ready

#### Scenario: Prompt is not lost during tool startup

- **WHEN** text is sent while the tool is still drawing its startup UI
- **THEN** the text SHALL be queued and delivered only after the tool's output has settled or the
  readiness timeout elapses

#### Scenario: Submit the queued prompt

- **WHEN** submit is requested for a running session
- **THEN** a carriage return SHALL be queued after any pending text so the tool receives the prompt
  as if the user pressed Enter

#### Scenario: Job already gone

- **WHEN** text or a submit is sent to a session whose job has exited
- **THEN** nothing SHALL be delivered and no error SHALL be raised

### Requirement: Keymap installation

Keymaps SHALL be installed on the terminal buffer from `cli.win.keys`, with the active tool's own
`keys` merged on top. The same set SHALL also be installed on a session's scrollback buffer when
that buffer is opened, which only happens for a session whose parent multiplexer session can dump
its pane contents. Each entry SHALL be a table whose first element is the left-hand side and whose
optional second element is the action; when the action is omitted the entry's name SHALL be used as
the action. An entry set to `false` SHALL install no keymap, which is how a default keymap is
disabled. An action given as a function SHALL be called with the session. An action given as a
string SHALL be resolved, in order, as a named CLI action, then as a method on the terminal session
(such as `hide`, `blur`, `show`, `toggle`, `focus` or `submit`), then as an existing Ex command,
and otherwise SHALL be used verbatim as the keymap's right-hand side. The mode SHALL default to `t`
and MAY be given as a string of mode characters such as `"nt"` or as a list of modes. Remaining
entry fields SHALL be passed through to the keymap, including `expr` and `desc`; `silent` SHALL
default to enabled and `desc` SHALL default to `Sidekick: <Name>` derived from the entry name.
Because an unrecognized string always falls back to being the literal right-hand side, only an
entry without a left-hand side, or whose action is neither a string nor a function, SHALL be
reported as an error naming the entry and SHALL install no keymap. Defaults SHALL include `q` and
`<c-q>` in normal mode and `<c-.>` to hide, `<c-z>` to blur, `<c-p>` to insert a prompt or context,
`<c-b>` and `<c-f>` for the buffer and file pickers, `<c-q>` in terminal mode to enter normal mode,
and `<cr>` in normal mode to forward a carriage return and return to terminal mode.

#### Scenario: Default keymaps are active in the terminal

- **WHEN** the terminal window is focused
- **THEN** the default keymaps SHALL be available on its buffer in their configured modes, for
  example `<c-z>` returning to the previous window without hiding the terminal

#### Scenario: Disabling a default keymap

- **WHEN** the user sets a `cli.win.keys` entry to `false`
- **THEN** no keymap SHALL be created for that entry

#### Scenario: Custom keymap with a function action

- **WHEN** the user adds an entry whose action is a function
- **THEN** pressing the key SHALL call that function with the session, and its return value SHALL be
  used as the typed keys when the entry sets `expr`

#### Scenario: Tool-specific keymaps

- **WHEN** the active tool defines its own `keys`
- **THEN** they SHALL override entries of the same name from `cli.win.keys` for that session

#### Scenario: Misconfigured entry

- **WHEN** an entry has no left-hand side, or its action is neither a string nor a function
- **THEN** an error naming the entry SHALL be reported and the remaining entries SHALL still be
  installed

### Requirement: Window navigation keymaps

The `nav_left`, `nav_down`, `nav_up` and `nav_right` entries SHALL bind `<c-h>`, `<c-j>`, `<c-k>`
and `<c-l>` as expression keymaps that move focus out of the terminal window. Navigation SHALL only
take effect when the layout is not `float` and a window exists in that direction; otherwise the
keymap SHALL return the corresponding control key so that it reaches the tool running in the
terminal instead. With the default `right` layout this means only `<c-h>` navigates. Navigation
SHALL be performed by `cli.win.nav` when it is set, and by `vim.cmd.wincmd` otherwise, allowing
integration with external window navigation plugins. Unlike every other `cli.win` option, `nav`
SHALL be read from the global configuration rather than from the session's own copy, so
`cli.win.config` cannot override navigation for a single session.

#### Scenario: Navigating out of a split terminal

- **WHEN** the layout is `"right"` and the user presses `<c-h>` in the terminal
- **THEN** focus SHALL move to the window on the left

#### Scenario: No window in that direction

- **WHEN** the user presses `<c-l>` in a terminal that is the rightmost window
- **THEN** focus SHALL NOT move and `<c-l>` SHALL be sent to the tool

#### Scenario: Float layout

- **WHEN** the layout is `"float"`
- **THEN** none of the navigation keys SHALL move focus, and each SHALL be sent to the tool

#### Scenario: Custom navigation handler

- **WHEN** `cli.win.nav` is set to a function
- **THEN** that function SHALL be called with the direction (`h`, `j`, `k` or `l`) instead of
  `vim.cmd.wincmd`

### Requirement: Job exit handling and teardown

When the terminal job exits, the session status SHALL become `unknown`, because nothing is known
about the tool once its job is gone. The window SHALL then be closed automatically, except when the
terminal ended too quickly to have been used: within 500 ms of the session being created or of the
terminal window last being entered, or, for a non-zero exit status, within 3000 ms, so that a tool
that failed to start leaves its error output on screen. Teardown SHALL deregister the session, stop
and dispose its send timer, clear and delete its autocommand group, and disable the file watcher
once no terminal sessions remain.

#### Scenario: Tool exits normally after use

- **WHEN** the tool exits after the terminal has been open and in use
- **THEN** the session SHALL be closed and its window removed

#### Scenario: Tool fails to start

- **WHEN** the job exits with a non-zero status within 3000 ms
- **THEN** the window SHALL stay open so the error output remains visible

#### Scenario: Immediate exit

- **WHEN** the job exits within 500 ms of the session being created or of the terminal window
  being entered
- **THEN** the window SHALL stay open regardless of exit status

#### Scenario: Last session closed

- **WHEN** the last terminal session is closed
- **THEN** the file watcher SHALL be disabled

### Requirement: Snacks integration surface

The terminal window SHALL always be a Neovim window opened by sidekick itself; snacks.nvim SHALL
NOT be required and SHALL NOT provide the terminal. snacks.nvim integration is limited to the
optional picker, and the legacy module `sidekick.cli.snacks` SHALL remain only as a compatibility
shim: calling its `send` SHALL emit a deprecation warning naming
`require("sidekick.cli.picker.snacks").send()` as the replacement and SHALL delegate to it.

#### Scenario: snacks.nvim is not installed

- **WHEN** snacks.nvim is not available
- **THEN** the terminal window SHALL still open and work normally

#### Scenario: Legacy snacks send

- **WHEN** a user configuration calls `require("sidekick.cli.snacks").send(picker)`
- **THEN** a deprecation warning naming the picker replacement SHALL be shown and the call SHALL be
  forwarded to it
