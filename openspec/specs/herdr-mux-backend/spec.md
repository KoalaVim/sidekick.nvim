# Herdr Mux Backend

## Purpose

Defines requirements for the herdr multiplexer backend, enabling sidekick to manage AI agent sessions through herdr panes with native agent detection, lifecycle management, and session discovery.

## Requirements

### Requirement: Herdr backend registration

The system SHALL register a herdr mux backend when the `herdr` executable is found in `PATH`, alongside the tmux and zellij backends. Registration SHALL depend only on the executable being present and SHALL NOT depend on `HERDR_ENV`, so the backend stays available for explicit selection outside a herdr environment. When `herdr` is absent the backend SHALL NOT be registered, and registration itself SHALL raise no error; selecting an unregistered backend is a separate failure covered by the CLI session management capability.

#### Scenario: Herdr available and running inside herdr
- **WHEN** `herdr` is executable and `HERDR_ENV` equals `1`
- **THEN** the herdr backend SHALL be registered and available for session creation

#### Scenario: Herdr not installed
- **WHEN** `herdr` is not found in PATH
- **THEN** the herdr backend SHALL NOT be registered, and backend registration SHALL complete without error

#### Scenario: Not running inside herdr
- **WHEN** `herdr` is executable but `HERDR_ENV` is not set
- **THEN** the herdr backend SHALL still be registered (for manual selection) but SHALL NOT be auto-selected

### Requirement: Herdr backend auto-detection

The mux config SHALL auto-detect herdr as the preferred backend when `HERDR_ENV=1` is set. The detection priority SHALL be: `HERDR_ENV` → herdr, `ZELLIJ` → zellij, default → tmux. Users SHALL be able to override auto-detection via explicit `mux.backend` config.

#### Scenario: Auto-select herdr inside herdr environment
- **WHEN** `HERDR_ENV=1` is set and no explicit `mux.backend` is configured
- **THEN** the mux backend SHALL default to `"herdr"`

#### Scenario: Explicit config overrides auto-detection
- **WHEN** the user sets `mux.backend = "tmux"` and `HERDR_ENV=1` is set
- **THEN** the tmux backend SHALL be used, not herdr

### Requirement: Agent start in herdr pane

For `mux.create = "split"` and `"window"`, the backend SHALL create a pane via `herdr pane split` and start the tool in it via `herdr pane run <pane_id> exec env <env> <cmd>`, built from the tool's own command, and SHALL NOT use `herdr agent start`. The pane id SHALL be read from `result.pane.pane_id`. These sessions SHALL be external and SHALL rely on herdr's native detection. For `mux.create = "terminal"` no pane SHALL be created and no attach command SHALL be returned.

#### Scenario: Start agent in split mode
- **WHEN** `mux.create` is `"split"` and the user starts a new agent session
- **THEN** the backend SHALL split a herdr pane, run the tool in it, and the session SHALL be external

#### Scenario: Start agent in window mode
- **WHEN** `mux.create` is `"window"` and the user starts a new agent session
- **THEN** the backend SHALL split a pane, move it to its own tab, and the session SHALL be external

#### Scenario: Herdr detects native sessions
- **WHEN** an agent is started in a herdr pane
- **THEN** `herdr agent list` SHALL show the agent with correct status and session identity, without a start handshake

#### Scenario: Start failure
- **WHEN** `herdr pane split` returns no pane id, or running the tool in the pane fails
- **THEN** the backend SHALL report the error including the offending output, close the pane it created, and the session SHALL NOT be marked as started

### Requirement: Embedded sessions run in Neovim, not in a herdr pane

For `mux.create = "terminal"` the backend SHALL NOT create a herdr pane. The tool SHALL run in a Neovim terminal and the backend SHALL NOT return a `herdr agent attach` command. Herdr SHALL natively detect the tool running inside the Neovim terminal on Neovim's own pane. The backend SHALL preserve the full herdr environment for the tool, including `HERDR_PANE_ID`, so that herdr's native detection and integration hooks operate normally.

#### Scenario: Embedded start creates no pane and no tab
- **WHEN** `mux.create` is `"terminal"` and the user starts a new agent session
- **THEN** no new herdr pane or tab SHALL be created, and the tool SHALL run in a Neovim terminal

#### Scenario: No attach race
- **WHEN** an embedded session starts
- **THEN** no `herdr agent attach` SHALL be spawned, and the session SHALL NOT fail with `agent_not_found`

#### Scenario: No pane is resized
- **WHEN** an embedded session starts
- **THEN** no herdr pane's viewport SHALL be resized to the Neovim terminal's dimensions

#### Scenario: Herdr detects the tool natively
- **WHEN** an embedded session has started
- **THEN** herdr SHALL detect the tool on Neovim's pane via its native detection, and `herdr agent list` SHALL report an agent for that tool

#### Scenario: Full herdr environment preserved
- **WHEN** an embedded tool starts
- **THEN** it SHALL see `HERDR_PANE_ID`, `HERDR_ENV`, and `HERDR_SOCKET_PATH`, so herdr's integration hooks and session resume operate normally

### Requirement: Embedded sessions are detected by herdr, not registered by sidekick

The backend SHALL NOT manually register an embedded session with herdr via `pane report-agent` or `pane report-metadata`. Herdr's native detection SHALL be the sole authority for agent presence and lifecycle on Neovim's pane. The backend SHALL NOT maintain a separate embedded registration state, label refresh timer, or crash backstop TTL. Teardown SHALL NOT call `release-agent` or clear metadata — herdr manages the agent lifecycle.

#### Scenario: No manual registration
- **WHEN** an embedded session starts
- **THEN** the backend SHALL NOT call `herdr pane report-agent` or `herdr pane report-metadata` for the session

#### Scenario: Session appears in herdr via native detection
- **WHEN** an embedded session has started
- **THEN** `herdr agent list` SHALL report the agent because herdr detected it, not because sidekick registered it

#### Scenario: Teardown does not release agent
- **WHEN** an embedded session ends normally
- **THEN** the backend SHALL NOT call `herdr pane release-agent` — herdr SHALL detect the tool's exit and clean up

### Requirement: Environment for the herdr pane

The herdr pane is spawned by the herdr server instead of a Neovim terminal job, so it inherits nothing from Neovim. The backend SHALL pass `NVIM` (the Neovim server name), the `sidekick-editor-proxy` as `EDITOR` and `VISUAL` when it is found on the runtime path, and the tool's configured env to the tool through `env` on the exec command line. Every value SHALL be shell-quoted, since `herdr pane run` joins its arguments into a command line for the pane's shell. Env entries configured as `false` SHALL be unset with `env -u <key>`. The backend SHALL NOT rely on `herdr pane split --env` for these variables, because the pane's shell startup files run afterwards and can overwrite them.

#### Scenario: Editor proxy survives shell startup
- **WHEN** the user's shell startup files export their own `EDITOR`
- **THEN** the tool running in the herdr pane SHALL still see sidekick's editor proxy as `EDITOR` and `VISUAL`

#### Scenario: Tool env is applied
- **WHEN** a tool configures `env` entries
- **THEN** those entries SHALL be set for the tool in the herdr pane, and entries set to `false` SHALL be unset

#### Scenario: Values needing quoting
- **WHEN** an env value or command argument contains characters that are significant to the shell, such as a space
- **THEN** it SHALL reach the tool intact

### Requirement: Pane placement per create mode

Pane placement SHALL follow `mux.create`:

- `terminal`: no herdr pane SHALL be created; the tool runs in a Neovim terminal and herdr natively detects it on Neovim's own pane
- `split`: a pane SHALL stay next to Neovim in the current tab, and the session SHALL be external
- `window`: a pane SHALL be moved to a tab of its own, and the session SHALL be external

New panes SHALL be split from `$HERDR_PANE_ID`, the pane running Neovim, rather than from the focused pane. A pane moved to a new tab SHALL be moved with `--no-focus`; pane ids are stable across a move within the same workspace, so the stored pane id SHALL remain valid.

#### Scenario: Embedded mode creates no pane
- **WHEN** `mux.create` is `"terminal"` and the user starts a new agent session
- **THEN** no herdr pane SHALL be created and the only copy SHALL be the Neovim terminal

#### Scenario: Split mode stays next to Neovim
- **WHEN** `mux.create` is `"split"` and the user starts a new agent session
- **THEN** the pane SHALL remain in the current tab alongside Neovim and the session SHALL be external

#### Scenario: Window mode gets its own tab
- **WHEN** `mux.create` is `"window"` and the user starts a new agent session
- **THEN** the pane SHALL be moved to its own herdr tab and the session SHALL be external

#### Scenario: Focus is not stolen
- **WHEN** the backend moves an agent pane to a new tab
- **THEN** the move SHALL be requested with `--no-focus` and the focused tab SHALL still be the tab that runs Neovim

#### Scenario: Split target is Neovim's pane
- **WHEN** a session is started while another herdr pane is focused
- **THEN** the new pane SHALL be split from the pane running Neovim

### Requirement: Pane lifetime matches the tool

For a native session, the backend SHALL start the tool with `exec`, replacing the pane's shell, so that the pane's lifetime matches the tool's. An embedded session has no herdr pane of its own, so this requirement does not apply to it.

#### Scenario: Tool exits
- **WHEN** the tool running in a herdr pane exits
- **THEN** the pane SHALL close and no leftover shell prompt SHALL remain

### Requirement: Send text to agent

The backend's `send()` method SHALL send text to the agent's herdr pane using `herdr pane send-text`, framed as a bracketed paste: the payload SHALL be preceded by `ESC [ 200 ~` and followed by `ESC [ 201 ~`. Framing is required because `pane send-text` writes its bytes to the pane tty unmodified, so an unframed payload is indistinguishable from typing and a tool with a modal composer runs it through its mode machine — consuming the leading characters as commands and inserting only the remainder. The framing SHALL be unconditional and SHALL NOT depend on the target tool, because a bracketed paste is a text-insertion event by definition and every tool in the registry is a terminal UI that enables bracketed paste. The trailing newline SHALL sit inside the framing so it remains a newline in the input rather than a submission. The `submit()` method SHALL remain a separate Enter keypress via `herdr pane send-keys`, so text can be delivered without being submitted. An embedded session SHALL send nothing, because its tool runs in a Neovim terminal rather than in the pane.

#### Scenario: Send prompt text
- **WHEN** sidekick calls `send(text)` on a herdr session
- **THEN** the text SHALL be delivered to the agent's herdr pane via `herdr pane send-text`, wrapped in bracketed paste markers

#### Scenario: Modal composer in normal mode
- **WHEN** the target tool has a vim mode enabled and its composer is in normal mode
- **THEN** the full payload SHALL arrive as text, and the composer's mode SHALL NOT be changed by the delivery

#### Scenario: Multi-line payload
- **WHEN** the payload spans several lines
- **THEN** every line SHALL arrive intact and the trailing newline SHALL NOT submit the input

#### Scenario: Submit prompt
- **WHEN** sidekick calls `submit()` on a herdr session
- **THEN** an Enter keypress SHALL be sent to the agent's pane via `herdr pane send-keys`

#### Scenario: Send without submit
- **WHEN** sidekick sends a message without `submit`
- **THEN** the text SHALL be left pending in the agent's input, editable by the user

### Requirement: Focus the agent's pane

The backend SHALL implement `focus()` by focusing the pane recorded for the session, using the `pane.focus` method of herdr's socket API, so that a session living in a herdr pane can be brought in front of the user the same way a session living in a Neovim terminal can. Focusing SHALL NOT be gated on herdr having detected an agent in the pane: herdr reports a freshly started tool as an agent only after a delay, so an agent-resolved focus would miss the very send that creates the session. `pane.focus` has no CLI verb, so the backend SHALL issue it over `HERDR_SOCKET_PATH` as a bounded request whose wait is a stuck-server backstop rather than an expected cost, keeping focus resolved before the text is delivered. When there is no socket path to talk to, the backend MAY fall back to `herdr agent focus <pane_id>`, which the CLI can resolve on its own but which carries the agent-detection limitation. Focusing SHALL be best effort and SHALL NOT report an error, so a failure never raises a notification on every send. An embedded session SHALL return early without focusing, because its tool runs in a Neovim terminal that the terminal window capability focuses instead, and Neovim's own pane is already where the user is.

#### Scenario: Sending focuses the agent's pane
- **WHEN** sidekick sends a message to a native herdr session and focus was not declined
- **THEN** the session's herdr pane SHALL be focused

#### Scenario: Focus is declined
- **WHEN** the caller passes `focus = false`
- **THEN** the text SHALL still be delivered and the herdr pane SHALL NOT be focused

#### Scenario: Pane in another tab
- **WHEN** the session's pane was placed in its own tab by `mux.create = "window"`
- **THEN** focusing the session SHALL move to that tab

#### Scenario: The session was just created
- **WHEN** the send that starts a native session focuses it, before herdr has detected an agent in the new pane
- **THEN** the pane SHALL still be focused

#### Scenario: Tool herdr does not detect
- **WHEN** `focus()` targets a pane running a tool with no herdr kind mapping
- **THEN** the pane SHALL still be focused, because the pane is the target rather than an agent inside it

#### Scenario: Focus cannot be delivered
- **WHEN** the focus request fails or no socket is reachable
- **THEN** the failure SHALL be silent and delivery SHALL proceed unaffected

#### Scenario: Embedded session
- **WHEN** `focus()` is called for a session started with `mux.create = "terminal"`
- **THEN** no `herdr agent focus` SHALL be issued

### Requirement: Session discovery

The backend's `sessions()` method SHALL discover running agent sessions via `herdr agent list` and match them against sidekick's configured tools. Agents on Neovim's own pane (`$HERDR_PANE_ID`) SHALL be discoverable, because herdr natively detects tools running in the Neovim terminal. A discovered session on a pane other than Neovim's SHALL be external: sidekick SHALL drive it over herdr's pane API and SHALL NOT open a Neovim terminal for it. A discovered session on Neovim's own pane SHALL NOT be external. The `mux_session` of a discovered session SHALL identify its pane; the bare tool name SHALL NOT be used, because it is the same for every pane running that tool.

#### Scenario: Discover running agents
- **WHEN** sidekick queries for active sessions
- **THEN** the herdr backend SHALL return all agents from `herdr agent list` that match configured sidekick tools, including agents on Neovim's own pane

#### Scenario: Agent on Neovim's pane is discovered
- **WHEN** herdr reports an agent on Neovim's own pane
- **THEN** `sessions()` SHALL include it as a non-external session

#### Scenario: Reattach after Neovim restart
- **WHEN** Neovim restarts and a sidekick-owned agent is still running in a herdr pane
- **THEN** `sessions()` SHALL rediscover it as external, and selecting it SHALL attach to it in place without opening a Neovim terminal or resizing its pane

#### Scenario: Hand-started agent stays external
- **WHEN** the user started an agent in a herdr pane themselves
- **THEN** it SHALL be discovered and reported as external

#### Scenario: Agent no longer running
- **WHEN** an agent pane has been closed in herdr
- **THEN** the agent SHALL NOT appear in `sessions()` results and sidekick SHALL prune its attached session

### Requirement: Session status

A session SHALL carry a status of `idle`, `working`, `blocked` or `unknown`, defaulting to `unknown`. For both embedded and native sessions, status SHALL come from herdr via a subscription to the `pane.agent_status_changed` event on the session's pane. The embedded session SHALL subscribe to the watch on Neovim's own pane (`$HERDR_PANE_ID`). The backend SHALL NOT manually drive status for embedded sessions via `report-agent`.

#### Scenario: Embedded status comes from herdr
- **WHEN** an embedded session's tool changes state
- **THEN** herdr SHALL push the new status via `pane.agent_status_changed` on Neovim's pane, and the backend SHALL learn it from the watch subscription

#### Scenario: Native status is pushed by herdr
- **WHEN** a native session's agent changes state
- **THEN** the backend SHALL learn the new status from herdr's event stream rather than by polling

#### Scenario: Status is not guessed
- **WHEN** the backend has no signal for a session's state
- **THEN** the status SHALL be `unknown` rather than an assumed value

#### Scenario: Event stream unavailable
- **WHEN** the status subscription cannot be established
- **THEN** the backend SHALL continue to function, with status left `unknown`

### Requirement: Session liveness check

The backend's `is_running()` method SHALL verify the session is still active by checking that its pane still exists, via `herdr pane get <pane_id>`. Because the tool replaced the pane's shell, pane existence SHALL be equivalent to the tool running, including for tools herdr does not report as agents.

#### Scenario: Agent still running
- **WHEN** `is_running()` is called and the session's pane exists
- **THEN** it SHALL return `true`

#### Scenario: Agent terminated
- **WHEN** `is_running()` is called after the tool exited and its pane closed
- **THEN** it SHALL return `false`

#### Scenario: Tool herdr does not detect
- **WHEN** `is_running()` is called for a running tool that does not appear in `herdr agent list`
- **THEN** it SHALL still return `true`

### Requirement: Scrollback capture

The backend's `dump()` method SHALL capture the pane's terminal output via `herdr pane read <pane_id> --source recent --lines <mux.dump> --ansi`, returning content with ANSI escape codes for rendering.

#### Scenario: Capture scrollback
- **WHEN** sidekick requests scrollback for a herdr session
- **THEN** the backend SHALL return the pane's recent terminal output with ANSI formatting, limited to `cli.mux.dump` lines

### Requirement: Detach from session

The backend's `detach()` method SHALL disconnect sidekick from the herdr session without terminating the agent. The herdr pane and agent SHALL continue running.

#### Scenario: Detach preserves agent
- **WHEN** the user detaches from a herdr-backed session
- **THEN** the agent SHALL continue running in its herdr pane and remain detectable by herdr

### Requirement: Tool name to herdr kind mapping

The backend SHALL maintain a mapping between sidekick tool names and the agent kinds herdr reports, and SHALL use it only to resolve agents from `herdr agent list` back to a sidekick tool. Starting a tool SHALL NOT require a mapping, because the tool is launched by its own command rather than by kind.

#### Scenario: Known agent kind
- **WHEN** `herdr agent list` reports an agent whose kind maps to a configured tool (e.g., `claude` → `claude`, `pi` → `pi`)
- **THEN** the agent SHALL be discovered as a session for that tool

#### Scenario: Tool without a kind mapping
- **WHEN** the user starts a sidekick tool that has no herdr kind mapping
- **THEN** the tool SHALL still start in a herdr pane, and it SHALL simply not be rediscovered through `herdr agent list`
