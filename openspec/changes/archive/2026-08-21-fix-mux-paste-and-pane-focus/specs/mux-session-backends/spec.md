## MODIFIED Requirements

### Requirement: Mux backend contract and registration

Every mux backend SHALL be registered under its own name only when its binary is executable,
checked at session setup for `tmux`, `zellij` and `herdr`; the built-in `terminal` backend
SHALL always be registered. A backend SHALL implement: `sessions()` returning the mux sessions
it can see as plain session states, an optional `init()` hook that classifies a session as
embedded or external and sets its `priority`, `start()` and `attach()` which either act on the
multiplexer directly or return a terminal command (`{ cmd = ..., env = ... }`) for sidekick to
host in a Neovim terminal, `is_running()`, `send()`/`submit()` for delivering text, `detach()`
for teardown, an optional `focus()` that brings the session's own surface in front of the user,
and an optional `dump()` that provides scrollback. `focus()` SHALL default to doing nothing, so
a backend whose multiplexer offers no way to focus a named pane needs no implementation and
callers need no backend-specific knowledge. Sidekick SHALL select the backend from
`cli.mux.backend` when `cli.mux.enabled` is true and SHALL use `terminal` otherwise. The herdr
backend implements the same contract and its behavior is specified by the herdr mux backend
capability.

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

#### Scenario: Backend without a focus implementation
- **WHEN** a session's backend does not implement `focus()` and focusing is requested
- **THEN** nothing SHALL happen and no error SHALL be reported

#### Scenario: Teardown does not kill the mux session
- **WHEN** sidekick detaches from a mux-backed session
- **THEN** the backend's `detach()` SHALL run and the multiplexer session SHALL keep running,
  so it can be discovered and re-attached later

### Requirement: Tmux input delivery

The tmux backend SHALL deliver prompt text by loading it into a dedicated tmux buffer named
after the target pane and pasting that buffer into the pane as a bracketed paste, so that
multi-line text arrives intact and is inserted as text rather than interpreted as keystrokes;
`submit()` SHALL send an `Enter` key to the pane. Bracketed paste is required because a tool
with a modal composer runs unframed input through its mode machine, consuming the leading
characters as commands. For a tool declaring `mux_focus`, a focus-in sequence SHALL be sent to
the pane first and the paste SHALL be delayed briefly, since such tools ignore input while
unfocused. All of these act on the pane recorded for the session, which is how prompts reach an
external pane that sidekick discovered but does not host.

#### Scenario: Send a multi-line prompt
- **WHEN** sidekick sends text to a tmux-backed session
- **THEN** the text SHALL be loaded into a tmux buffer and pasted into the session's pane as a
  bracketed paste

#### Scenario: Modal composer in normal mode
- **WHEN** the target tool has a vim mode enabled and its composer is in normal mode
- **THEN** the full payload SHALL arrive as text rather than being partly consumed as commands

#### Scenario: Tool requiring focus
- **WHEN** the target tool declares `mux_focus`
- **THEN** a focus-in event SHALL be sent before the text, with a short delay in between

#### Scenario: Submit the prompt
- **WHEN** sidekick submits the current input
- **THEN** an `Enter` key SHALL be sent to the session's pane
