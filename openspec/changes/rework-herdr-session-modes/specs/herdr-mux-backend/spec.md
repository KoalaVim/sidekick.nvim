## ADDED Requirements

### Requirement: Embedded sessions run in Neovim, not in a herdr pane

For `mux.create = "terminal"` the backend SHALL NOT create a herdr pane. The tool SHALL run in a Neovim terminal, and the backend SHALL NOT return a `herdr agent attach` command. Herdr cannot natively detect an agent running inside a Neovim terminal, because Neovim gives its terminal child a separate controlling tty and herdr admits agents from the pane's tty foreground process group; this limitation SHALL be accepted rather than worked around.

#### Scenario: Embedded start creates no pane and no tab
- **WHEN** `mux.create` is `"terminal"` and the user starts a new agent session
- **THEN** no new herdr pane or tab SHALL be created, and the tool SHALL appear only in the Neovim terminal

#### Scenario: No attach race
- **WHEN** an embedded session starts
- **THEN** no `herdr agent attach` SHALL be spawned, and the session SHALL NOT fail with `agent_not_found`

#### Scenario: No pane is resized
- **WHEN** an embedded session starts
- **THEN** no herdr pane's viewport SHALL be resized to the Neovim terminal's dimensions

### Requirement: Embedded sessions are registered on Neovim's own pane

The backend SHALL register an embedded session as a herdr agent on `$HERDR_PANE_ID` using `herdr pane report-agent` with a source that is not one of herdr's registered integration sources, because herdr corroboration-gates `herdr:*` sources and rejects them for a pane whose foreground process is not the agent. The backend SHALL also set display metadata via `herdr pane report-metadata`, including a TTL so a crashed Neovim does not leave a stale agent.

#### Scenario: Session appears in herdr's agent list
- **WHEN** an embedded session has started
- **THEN** `herdr agent list` SHALL report an agent on Neovim's pane for that tool

#### Scenario: Sidebar navigation lands on Neovim
- **WHEN** the user focuses that agent from herdr's sidebar
- **THEN** focus SHALL move to the pane running Neovim, which is the pane hosting the session

#### Scenario: Registered source is accepted
- **WHEN** the backend reports the agent
- **THEN** it SHALL use a source outside herdr's registered integration sources, and the report SHALL be admitted

#### Scenario: One embedded registration per Neovim
- **WHEN** a second embedded session is started in the same Neovim instance
- **THEN** it SHALL still run, SHALL NOT overwrite the first session's registration, and the reason SHALL be reported

#### Scenario: Teardown
- **WHEN** an embedded session ends normally
- **THEN** the backend SHALL release the agent, clear its display metadata, and clear its pane token

#### Scenario: Crash backstop
- **WHEN** Neovim exits without running teardown
- **THEN** the reported metadata SHALL expire by its TTL rather than persisting indefinitely

### Requirement: The embedded tool must not claim Neovim's pane

The backend SHALL unset `HERDR_PANE_ID` for an embedded tool, so the tool's herdr integration exits early and cannot report an agent session for Neovim's pane. `HERDR_ENV` and `HERDR_SOCKET_PATH` SHALL remain set. This is required because a pane carrying an agent session claim rejects every subsequent `pane report-agent` from any source, and the claim cannot be cleared — not by `release-agent`, and not by `pane.clear_agent_authority`.

#### Scenario: Hook does not claim the pane
- **WHEN** an embedded tool whose herdr integration is installed starts
- **THEN** Neovim's pane SHALL carry no agent session claim, and sidekick's own report SHALL be admitted

#### Scenario: Remaining herdr context is preserved
- **WHEN** an embedded tool runs
- **THEN** it SHALL still see `HERDR_ENV` and `HERDR_SOCKET_PATH`

#### Scenario: Agent-session resume is forfeited
- **WHEN** an embedded session is registered
- **THEN** no agent session id or transcript path SHALL be reported, and herdr's session resume SHALL NOT cover that session

### Requirement: Session status

A session SHALL carry a status of `idle`, `working`, `blocked` or `unknown`, defaulting to `unknown`. For embedded sessions the backend SHALL own that status and report each transition to herdr, because herdr does not drive status for an externally reported agent. For native sessions the status SHALL come from herdr, via a subscription to its agent status change event where available.

#### Scenario: Embedded status is driven by sidekick
- **WHEN** an embedded session's tool begins or finishes work
- **THEN** the backend SHALL report the new state to herdr, and `herdr agent list` SHALL reflect it

#### Scenario: Native status is pushed by herdr
- **WHEN** a native session's agent changes state
- **THEN** the backend SHALL learn the new status from herdr's event stream rather than by polling

#### Scenario: Status is not guessed
- **WHEN** the backend has no signal for a session's state
- **THEN** the status SHALL be `unknown` rather than an assumed value

#### Scenario: Event stream unavailable
- **WHEN** the status subscription cannot be established
- **THEN** the backend SHALL continue to function, with status left `unknown`

## MODIFIED Requirements

### Requirement: Pane placement per create mode

Pane placement SHALL follow `mux.create`:

- `terminal`: no herdr pane SHALL be created; the tool runs in a Neovim terminal and is registered on Neovim's own pane
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

### Requirement: Session discovery

The backend's `sessions()` method SHALL discover running agent sessions via `herdr agent list` and match them against sidekick's configured tools. A discovered session lives in a herdr pane, so it SHALL be external: sidekick SHALL drive it over herdr's pane API and SHALL NOT open a Neovim terminal for it. The `mux_session` of a discovered session SHALL identify its pane; the bare tool name SHALL NOT be used, because it is the same for every pane running that tool. Where a pane carries sidekick's ownership token, that token SHALL be reported as ownership information; it SHALL NOT make the session embeddable.

#### Scenario: Discover running agents
- **WHEN** sidekick queries for active sessions
- **THEN** the herdr backend SHALL return all agents from `herdr agent list` that match configured sidekick tools

#### Scenario: Reattach after Neovim restart
- **WHEN** Neovim restarts and a sidekick-owned agent is still running in a herdr pane
- **THEN** `sessions()` SHALL rediscover it as external, and selecting it SHALL attach to it in place without opening a Neovim terminal or resizing its pane

#### Scenario: Ownership survives via pane token
- **WHEN** a sidekick-started pane is rediscovered after a Neovim restart
- **THEN** its `sidekick` pane token SHALL identify it as sidekick-owned

#### Scenario: Hand-started agent stays external
- **WHEN** the user started an agent in a herdr pane themselves
- **THEN** it SHALL be discovered and reported as external

#### Scenario: Agent no longer running
- **WHEN** an agent pane has been closed in herdr
- **THEN** the agent SHALL NOT appear in `sessions()` results and sidekick SHALL prune its attached session

## REMOVED Requirements

### Requirement: Attach to existing session

**Reason**: `herdr agent attach` was the mechanism behind all three reported failures. It resolves against herdr's live agent registry rather than the pane tree, so attaching immediately after `pane run` fails with `agent_not_found` — and `herdr agent wait` cannot bridge the gap because it waits for transitions of an already-known agent. It also permanently resizes the target pane to the attaching client, which is what made the mirrored pane render cropped in its own tab. Embedded sessions no longer mirror a herdr pane, so nothing attaches. Native sessions are external and are attached to by the user in herdr itself.

**Migration**: Users on `mux.create = "terminal"` get the tool in a Neovim terminal registered on Neovim's pane, instead of a mirrored pane in a separate tab. Users who want a herdr-hosted pane should use `split` or `window`.
