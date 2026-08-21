## MODIFIED Requirements

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
