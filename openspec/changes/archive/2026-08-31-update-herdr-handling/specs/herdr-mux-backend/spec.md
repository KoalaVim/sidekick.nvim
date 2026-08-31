## MODIFIED Requirements

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

## REMOVED Requirements

### Requirement: Embedded sessions are registered on Neovim's own pane
**Reason**: Herdr natively detects the tool running in the Neovim terminal. Manual registration via `pane report-agent` with a custom source, display metadata with TTL, label refresh timers, and stale registration reaping are all unnecessary.
**Migration**: Remove `register()`, `report_agent()`, `report_metadata()`, `refresh_label()`, `reap()`, `probe()`, `M._embedded`, and the `SOURCE`, `TOKEN`, `LABEL_TTL`, `LABEL_REFRESH` constants.

### Requirement: The embedded tool must not claim Neovim's pane
**Reason**: The tool claiming Neovim's pane via its herdr integration hook is now the desired behavior — it is how herdr natively detects the tool. Sidekick no longer calls `report-agent`, so there is nothing to lock out.
**Migration**: Stop clearing `HERDR_PANE_ID` in the embedded env. Remove the `env = { HERDR_PANE_ID = false }` from `start_embedded()`.
