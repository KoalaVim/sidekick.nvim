## ADDED Requirements

### Requirement: CLI session status API

`require("sidekick.status").cli()` SHALL return a list of `sidekick.cli.Status` objects for
every attached CLI session. Each object SHALL include `id` (the session id), `tool` (the
tool name), `cwd` (the session's working directory), and `status` (the session's agent
activity status: `"idle"`, `"working"`, `"blocked"`, or `"unknown"`). The `status` field
SHALL reflect the value of `session.status` at the time of the last refresh. When a session
has no status set, `status` SHALL default to `"unknown"`.

#### Scenario: Status included in CLI status output
- **WHEN** a CLI session is attached and its status is `"working"`
- **THEN** `require("sidekick.status").cli()` SHALL return an entry for that session with `status` equal to `"working"`

#### Scenario: Default status for sessions without a known state
- **WHEN** a CLI session is attached but no backend has reported its status
- **THEN** `require("sidekick.status").cli()` SHALL return an entry with `status` equal to `"unknown"`

#### Scenario: Status reflects latest transition
- **WHEN** a session transitions from `"idle"` to `"working"` and then to `"idle"`
- **THEN** `require("sidekick.status").cli()` SHALL return `status` equal to `"idle"` after the final transition

### Requirement: Real-time status refresh via event

The status module SHALL listen for a `SidekickCliStatus` user event in addition to the
existing `SidekickCliAttach` and `SidekickCliDetach` events. When `SidekickCliStatus` fires,
the status module SHALL refresh its CLI session list immediately rather than waiting for the
periodic poll. The existing 5-second periodic poll SHALL remain as a backstop.

#### Scenario: Status change triggers immediate refresh
- **WHEN** a session's status changes and `SidekickCliStatus` is emitted
- **THEN** `require("sidekick.status").cli()` SHALL return the updated status on the next call without waiting for the periodic poll

#### Scenario: Poll backstop still works
- **WHEN** a backend changes a session's status without emitting `SidekickCliStatus`
- **THEN** `require("sidekick.status").cli()` SHALL still reflect the change within 5 seconds

### Requirement: Status event emitted on transitions

The session base class's `set_status()` SHALL emit a `SidekickCliStatus` user event carrying
the session id whenever the status value changes. The event SHALL NOT fire when `set_status()`
is called with the same value the session already holds.

#### Scenario: Transition from idle to working emits event
- **WHEN** `set_status("working")` is called on a session whose current status is `"idle"`
- **THEN** a `SidekickCliStatus` user event SHALL be emitted with the session's id

#### Scenario: Redundant set_status does not emit
- **WHEN** `set_status("idle")` is called on a session whose current status is already `"idle"`
- **THEN** no `SidekickCliStatus` event SHALL be emitted
