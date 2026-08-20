# Herdr Mux Backend

## Purpose

Defines requirements for the herdr multiplexer backend, enabling sidekick to manage AI agent sessions through herdr panes with native agent detection, lifecycle management, and session discovery.

## Requirements

### Requirement: Herdr backend registration

The system SHALL register a herdr mux backend when the `herdr` executable is found in `PATH` and `HERDR_ENV=1` is set. The backend SHALL be registered alongside tmux and zellij in `session/init.lua`. When herdr is not available, the backend SHALL NOT be registered and no errors SHALL occur.

#### Scenario: Herdr available and running inside herdr
- **WHEN** `herdr` is executable and `HERDR_ENV` equals `1`
- **THEN** the herdr backend SHALL be registered and available for session creation

#### Scenario: Herdr not installed
- **WHEN** `herdr` is not found in PATH
- **THEN** the herdr backend SHALL NOT be registered and the system SHALL fall back to other backends

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

The backend's `start()` method SHALL create a new herdr pane via `herdr pane split` and then start the agent via `herdr agent start <name> --kind <kind> --pane <pane_id>`. The agent SHALL be detectable by herdr natively after start. In embedded mode (`create = "terminal"`), `start()` SHALL return a `Cmd` containing `herdr agent attach <pane_id>` so that sidekick hosts the agent inside a Neovim terminal buffer.

#### Scenario: Start agent in embedded mode
- **WHEN** `mux.create` is `"terminal"` and the user starts a new agent session
- **THEN** the backend SHALL split a herdr pane, start the agent in it, and return a `Cmd` with `herdr agent attach` so the agent appears inside Neovim

#### Scenario: Start agent in split mode
- **WHEN** `mux.create` is `"split"` and the user starts a new agent session
- **THEN** the backend SHALL split a herdr pane alongside the current pane, start the agent in it, and NOT return a `Cmd` (the session is external)

#### Scenario: Herdr detects the agent natively
- **WHEN** an agent is started via the herdr backend
- **THEN** `herdr agent list` SHALL show the agent with correct status and session identity

#### Scenario: Agent start failure
- **WHEN** `herdr agent start` fails (timeout or unsupported agent kind)
- **THEN** the backend SHALL report the error to the user and the session SHALL not be marked as started

### Requirement: Send text to agent

The backend's `send()` method SHALL send text to the agent's herdr pane using `herdr pane send-text`. The `submit()` method SHALL send an Enter keypress via `herdr pane send-keys`.

#### Scenario: Send prompt text
- **WHEN** sidekick calls `send(text)` on a herdr session
- **THEN** the text SHALL be delivered to the agent's herdr pane via `herdr pane send-text`

#### Scenario: Submit prompt
- **WHEN** sidekick calls `submit()` on a herdr session
- **THEN** an Enter keypress SHALL be sent to the agent's pane via `herdr pane send-keys`

### Requirement: Session discovery

The backend's `sessions()` method SHALL discover running agent sessions by querying `herdr agent list` and matching results against sidekick's configured tools. Each discovered agent SHALL be returned as a session state with correct tool, cwd, and pane information.

#### Scenario: Discover running agents
- **WHEN** sidekick queries for active sessions
- **THEN** the herdr backend SHALL return all agents from `herdr agent list` that match configured sidekick tools

#### Scenario: Agent no longer running
- **WHEN** an agent pane has been closed in herdr
- **THEN** the agent SHALL NOT appear in `sessions()` results and sidekick SHALL prune its attached session

#### Scenario: Reattach after Neovim restart
- **WHEN** Neovim restarts and an agent is still running in a herdr pane
- **THEN** `sessions()` SHALL rediscover it and sidekick SHALL allow reattaching

### Requirement: Session liveness check

The backend's `is_running()` method SHALL verify the agent session is still active by checking `herdr agent list` for the session's pane.

#### Scenario: Agent still running
- **WHEN** `is_running()` is called and the agent's pane exists in `herdr agent list`
- **THEN** it SHALL return `true`

#### Scenario: Agent terminated
- **WHEN** `is_running()` is called and the agent's pane no longer exists
- **THEN** it SHALL return `false`

### Requirement: Scrollback capture

The backend's `dump()` method SHALL capture the agent's terminal output via `herdr agent read <target> --source recent --ansi`, returning content with ANSI escape codes for rendering.

#### Scenario: Capture scrollback
- **WHEN** sidekick requests scrollback for a herdr session
- **THEN** the backend SHALL return the agent's recent terminal output with ANSI formatting

### Requirement: Attach to existing session

The backend's `attach()` method SHALL return a `Cmd` with `herdr agent attach <pane_id>` when the session's mux_session matches the stored identifier, enabling reattachment via a Neovim terminal buffer.

#### Scenario: Reattach to existing agent
- **WHEN** a previously discovered herdr session is selected for attachment
- **THEN** the backend SHALL return a `Cmd` with `herdr agent attach` so sidekick embeds the agent in a Neovim terminal

### Requirement: Detach from session

The backend's `detach()` method SHALL disconnect sidekick from the herdr session without terminating the agent. The herdr pane and agent SHALL continue running.

#### Scenario: Detach preserves agent
- **WHEN** the user detaches from a herdr-backed session
- **THEN** the agent SHALL continue running in its herdr pane and remain detectable by herdr

### Requirement: Tool name to herdr kind mapping

The backend SHALL maintain a mapping between sidekick tool names and herdr agent `--kind` values. Tools without a known herdr kind SHALL be skipped during session discovery and SHALL produce an error on `start()`.

#### Scenario: Known tool kind
- **WHEN** the user starts a sidekick tool that has a matching herdr kind (e.g., `claude` → `claude`, `pi` → `pi`)
- **THEN** the backend SHALL use the correct `--kind` value with `herdr agent start`

#### Scenario: Unknown tool kind
- **WHEN** the user starts a sidekick tool with no herdr kind mapping
- **THEN** the backend SHALL report that the tool is not supported by the herdr backend
