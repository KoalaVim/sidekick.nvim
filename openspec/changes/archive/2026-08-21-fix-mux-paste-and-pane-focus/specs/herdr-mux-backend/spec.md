## ADDED Requirements

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

## MODIFIED Requirements

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
