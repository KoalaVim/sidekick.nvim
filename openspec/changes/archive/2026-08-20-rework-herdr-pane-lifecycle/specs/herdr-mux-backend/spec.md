## ADDED Requirements

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

Pane placement SHALL follow `mux.create`, so that a session is never visible twice:

- `terminal`: the pane SHALL be moved to a tab of its own, and the tool SHALL be shown in a Neovim terminal that attaches to it
- `split`: the pane SHALL stay next to Neovim in the current tab, and the session SHALL be external
- `window`: the pane SHALL be moved to a tab of its own, and the session SHALL be external

New panes SHALL be split from `$HERDR_PANE_ID`, the pane running Neovim, rather than from the focused pane. Whenever a pane is moved to a new tab, the backend SHALL restore focus to `$HERDR_TAB_ID`, because `herdr pane move --new-tab` focuses the tab it creates.

#### Scenario: Embedded mode shows one copy
- **WHEN** `mux.create` is `"terminal"` and the user starts a new agent session
- **THEN** the herdr pane SHALL live in a tab of its own and the only visible copy SHALL be the Neovim terminal attached to it

#### Scenario: Split mode stays next to Neovim
- **WHEN** `mux.create` is `"split"` and the user starts a new agent session
- **THEN** the pane SHALL remain in the current tab alongside Neovim and the session SHALL be external

#### Scenario: Window mode gets its own tab
- **WHEN** `mux.create` is `"window"` and the user starts a new agent session
- **THEN** the pane SHALL be moved to its own herdr tab and the session SHALL be external

#### Scenario: Focus is not stolen
- **WHEN** the backend moves an agent pane to a new tab
- **THEN** the focused tab SHALL still be the tab that runs Neovim

#### Scenario: Split target is Neovim's pane
- **WHEN** a session is started while another herdr pane is focused
- **THEN** the new pane SHALL be split from the pane running Neovim

### Requirement: Pane lifetime matches the tool

The backend SHALL start the tool with `exec`, replacing the pane's shell, so that the pane's lifetime matches the tool's.

#### Scenario: Tool exits
- **WHEN** the tool running in a herdr pane exits
- **THEN** the pane SHALL close, no leftover shell prompt SHALL remain, and any `herdr agent attach` client SHALL exit with it

## MODIFIED Requirements

### Requirement: Agent start in herdr pane

The backend's `start()` method SHALL create a new herdr pane via `herdr pane split` and start the tool in it via `herdr pane run <pane_id> exec env <env> <cmd>`, built from the tool's own command. It SHALL NOT use `herdr agent start`: herdr detects the agent natively once it runs, so no start handshake is needed, and typing the command into the pane's shell would leave that shell owning the pane. The pane id SHALL be read from the `herdr pane split` response at `result.pane.pane_id`. In embedded mode (`create = "terminal"`), `start()` SHALL return a `Cmd` containing `herdr agent attach <pane_id>` so that sidekick hosts the agent inside a Neovim terminal buffer.

#### Scenario: Start agent in embedded mode
- **WHEN** `mux.create` is `"terminal"` and the user starts a new agent session
- **THEN** the backend SHALL split a herdr pane, run the tool in it, and return a `Cmd` with `herdr agent attach` so the agent appears inside Neovim

#### Scenario: Start agent in split mode
- **WHEN** `mux.create` is `"split"` and the user starts a new agent session
- **THEN** the backend SHALL split a herdr pane alongside the current pane, run the tool in it, and NOT return a `Cmd` (the session is external)

#### Scenario: Herdr detects the agent natively
- **WHEN** an agent is started via the herdr backend
- **THEN** `herdr agent list` SHALL show the agent with correct status and session identity

#### Scenario: Start is not raced by shell startup
- **WHEN** the tool is started immediately after the pane is created, before the pane's shell has reached its prompt
- **THEN** the tool SHALL still start, without an `agent_pane_busy` failure

#### Scenario: Start failure
- **WHEN** `herdr pane split` returns no pane id, or running the tool in the pane fails
- **THEN** the backend SHALL report the error, including the offending output, close the pane it created, and the session SHALL NOT be marked as started

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

### Requirement: Tool name to herdr kind mapping

The backend SHALL maintain a mapping between sidekick tool names and the agent kinds herdr reports, and SHALL use it only to resolve agents from `herdr agent list` back to a sidekick tool. Starting a tool SHALL NOT require a mapping, because the tool is launched by its own command rather than by kind.

#### Scenario: Known agent kind
- **WHEN** `herdr agent list` reports an agent whose kind maps to a configured tool (e.g., `claude` → `claude`, `pi` → `pi`)
- **THEN** the agent SHALL be discovered as a session for that tool

#### Scenario: Tool without a kind mapping
- **WHEN** the user starts a sidekick tool that has no herdr kind mapping
- **THEN** the tool SHALL still start in a herdr pane, and it SHALL simply not be rediscovered through `herdr agent list`
