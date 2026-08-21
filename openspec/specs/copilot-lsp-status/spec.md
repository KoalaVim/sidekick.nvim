# Copilot LSP Status

## Purpose

Tracks the GitHub Copilot LSP server's self-reported state by handling the server's
`didChangeStatus` notification, keeps the latest status per Copilot client, exposes it
through the `require("sidekick.status").get()` API so statusline components can render it,
and turns problem statuses into user notifications according to the `copilot.status`
configuration.

## Requirements

### Requirement: Copilot status handler installation

When `copilot.status.enabled` is `true` (the default), the system SHALL install its
`didChangeStatus` handler on every Copilot LSP client, both for clients already running when
`require("sidekick.status").setup()` runs and for clients that attach later, by watching
`LspAttach` on sidekick's augroup. A client SHALL be treated as a Copilot client when its
name contains `copilot`, case-insensitively. Installing the handler SHALL set
`client.handlers.didChangeStatus` to `require("sidekick.status").on_status`, replacing any
handler previously registered on that client. When `copilot.status.enabled` is `false`, no
handler SHALL be installed and no `LspAttach` autocmd SHALL be created for status tracking.

#### Scenario: Handler installed on an attaching Copilot client

- **WHEN** `copilot.status.enabled` is `true` and a Copilot LSP client attaches to a buffer
- **THEN** that client's `didChangeStatus` handler SHALL be `require("sidekick.status").on_status`

#### Scenario: Handler installed on already running clients

- **WHEN** setup runs while one or more Copilot clients are already running
- **THEN** each of those clients SHALL have the `didChangeStatus` handler installed without
  waiting for a new `LspAttach`

#### Scenario: Non-Copilot clients are left alone

- **WHEN** an LSP client whose name does not contain `copilot` attaches
- **THEN** its handlers SHALL NOT be modified

#### Scenario: Status tracking disabled

- **WHEN** `copilot.status.enabled` is `false`
- **THEN** no Copilot client SHALL receive the `didChangeStatus` handler

### Requirement: Per-client status capture

The handler SHALL store the received status per LSP client, keyed by the notification
context's client id, so that several Copilot clients can be tracked independently. Each
notification SHALL replace the previously stored status for that client, so only the latest
status is retained. The stored value SHALL be a copy of the received payload, so later
mutation of the notification result SHALL NOT change the stored status. When the handler is
invoked with an error, it SHALL ignore the notification entirely: no status SHALL be stored
and no notification SHALL be emitted.

#### Scenario: Status stored for the reporting client

- **WHEN** the Copilot client with id `42` sends `didChangeStatus` with
  `{ busy = true, kind = "Warning", message = "issue detected" }`
- **THEN** the status recorded for client `42` SHALL be exactly that busy, warning status with
  that message

#### Scenario: Latest status wins

- **WHEN** a client sends a second `didChangeStatus` with different fields
- **THEN** the stored status for that client SHALL be the second payload only

#### Scenario: Error responses ignored

- **WHEN** the handler is called with a non-nil error
- **THEN** the previously stored status SHALL be left unchanged and no notification SHALL be
  emitted

### Requirement: Status shape surfaced to consumers

A status SHALL carry a `busy` boolean telling whether the Copilot LSP server is currently
working on a request, a `kind` that is one of `"Normal"`, `"Warning"`, `"Error"` or
`"Inactive"`, and an optional `message` string with the server's human-readable description.
The values SHALL be surfaced as reported by the server and SHALL NOT be normalized, so a
status whose `kind` or `message` is absent SHALL be exposed with those fields absent.
Consumers SHALL be able to distinguish an error state by comparing `kind` to `"Error"` and a
working state by reading `busy`.

#### Scenario: Busy warning status

- **WHEN** the server reports a busy status of kind `"Warning"` with a message
- **THEN** a consumer reading the status SHALL see `busy` true, `kind` `"Warning"` and that
  message

#### Scenario: Statusline highlight selection

- **WHEN** a statusline component reads the status to pick a highlight
- **THEN** it SHALL be able to select an error highlight for `kind == "Error"`, a warning
  highlight for a `busy` status, and a normal highlight otherwise

### Requirement: Status query API

`require("sidekick.status").get(buf)` SHALL return the status of the Copilot client attached
to `buf`, defaulting to the current buffer when `buf` is omitted. When such a client exists
but no `didChangeStatus` notification has been recorded for it yet, `get()` SHALL return an
idle default status with `busy` false and `kind` `"Normal"`, so consumers can render a
present-but-idle Copilot without special-casing startup. When `copilot.status.enabled` is
`false`, `get()` SHALL return `nil` regardless of any recorded status, so a statusline
component keyed on `get() ~= nil` disappears when status tracking is turned off. When more
than one Copilot client is attached to the buffer, `get()` SHALL report the status of one of
them rather than aggregating them.

#### Scenario: Status available for the buffer's client

- **WHEN** a Copilot client is attached to the buffer and has reported a status
- **THEN** `get()` SHALL return that recorded status

#### Scenario: Client attached but silent

- **WHEN** a Copilot client is attached to the buffer and has never sent `didChangeStatus`
- **THEN** `get()` SHALL return a status with `busy` false and `kind` `"Normal"`

#### Scenario: Status tracking disabled

- **WHEN** `copilot.status.enabled` is `false`
- **THEN** `get()` SHALL return `nil`

### Requirement: Absent or detached Copilot client

`get()` SHALL return `nil` when no Copilot client is attached to the buffer, including before
the server has started, in buffers the server does not attach to, and after the client has
stopped or detached. A status recorded earlier SHALL NOT keep a statusline component alive
once the client is gone, so a consumer that guards on `get() ~= nil` SHALL render nothing in
those cases.

#### Scenario: No Copilot client at all

- **WHEN** no Copilot LSP client is attached to the buffer
- **THEN** `get()` SHALL return `nil`

#### Scenario: Client detaches after reporting status

- **WHEN** a Copilot client reported a status and then stopped or detached from the buffer
- **THEN** `get()` SHALL return `nil` instead of the last recorded status

### Requirement: Status notifications gated by configured level

When a received status carries a `message`, the system SHALL notify the user through
sidekick's notifier, titled `Sidekick`, with the message prefixed by `**Copilot:** `. The
notification SHALL be emitted only when the severity implied by the status `kind` is at least
`copilot.status.level`, which defaults to `vim.log.levels.WARN`. Severity SHALL be derived
from `kind` as `"Normal"` to `INFO`, `"Warning"` to `WARN`, `"Inactive"` to `WARN` and
`"Error"` to `ERROR`; a missing or unrecognized `kind` SHALL be treated as `INFO`. The level
at which the notification is raised SHALL be `ERROR` for `kind == "Error"` and `WARN` for
every other kind. A status without a `message` SHALL never notify, even when its kind is
severe.

#### Scenario: Warning message notified with the default level

- **WHEN** the server reports `kind = "Warning"` with the message `issue detected` and
  `copilot.status.level` is the default `WARN`
- **THEN** the user SHALL be notified once at `WARN` level with the text
  `**Copilot:** issue detected`

#### Scenario: Informational message stays quiet by default

- **WHEN** the server reports a `kind = "Normal"` status with a message and
  `copilot.status.level` is the default `WARN`
- **THEN** no notification SHALL be emitted, while the status SHALL still be recorded and
  returned by `get()`

#### Scenario: Notifications silenced

- **WHEN** `copilot.status.level` is set to `vim.log.levels.OFF`
- **THEN** no status SHALL ever produce a notification, of any kind, while `get()` SHALL keep
  reporting the recorded status

#### Scenario: Status without a message

- **WHEN** the server reports a status of kind `"Error"` with no `message`
- **THEN** no notification SHALL be emitted and the status SHALL still be recorded

### Requirement: Repeated statuses are reported as received

Status handling SHALL be stateless with respect to previously seen statuses: the system SHALL
NOT suppress a qualifying notification because it repeats a status already notified, and the
recorded status SHALL always reflect the most recent notification. De-duplication of
`didChangeStatus` notifications is therefore the responsibility of the Copilot LSP server.

#### Scenario: Identical status received twice

- **WHEN** the server sends the same qualifying status payload twice in a row
- **THEN** two notifications SHALL be emitted and the recorded status SHALL remain that status

#### Scenario: Recovery after a problem status

- **WHEN** the server reports an error status and later a normal status
- **THEN** `get()` SHALL report the normal status, with no residue of the error status

### Requirement: Sign-in guidance for unauthenticated messages

A notified status message that indicates the user is not signed in SHALL be accompanied by
instructions for signing in, chosen to match the installed Copilot plugin: when
the `copilot` Lua module is loaded, the hint SHALL point at `:Copilot auth`; otherwise it
SHALL point at `:LspCopilotSignIn`. Detection SHALL be based on the message containing
`not signed`.

#### Scenario: Not signed in with the native LSP setup

- **WHEN** the server reports an error status whose message contains `not signed` and the
  `copilot` module is not loaded
- **THEN** the notification SHALL be raised at `ERROR` level and SHALL include the
  `:LspCopilotSignIn` instruction in addition to the server's message

#### Scenario: Not signed in with copilot.lua loaded

- **WHEN** the same message arrives while the `copilot` Lua module is loaded
- **THEN** the notification SHALL include the `:Copilot auth` instruction instead

#### Scenario: Unrelated message

- **WHEN** a notified message does not contain `not signed`
- **THEN** the notification SHALL contain only the prefixed server message

### Requirement: Statusline composition with pending suggestion state

The Copilot LSP status SHALL describe the language server's own state only: `busy` reports
that the server is handling a request, and it SHALL NOT be used to signal that an edit
suggestion is waiting for the user. A statusline that wants to show a pending Next Edit
Suggestion SHALL combine `require("sidekick.status").get()` with the NES capability's
`require("sidekick.nes").have()`, which reports whether edits are active in the current
buffer, and MAY render it with the configured `ui.icons.nes` icon. Listing running AI CLI
sessions for the same statusline is provided by the CLI session capability through
`require("sidekick.status").cli()` and SHALL be independent of Copilot LSP status.

#### Scenario: Suggestion pending while the server is idle

- **WHEN** a Next Edit Suggestion is active in the current buffer and the Copilot LSP server
  has finished its request
- **THEN** `get()` SHALL report a non-busy status while `require("sidekick.nes").have()`
  SHALL report that edits are active, so the statusline can show both facts separately

#### Scenario: Request in flight

- **WHEN** the Copilot LSP server reports itself busy
- **THEN** `get()` SHALL report `busy` true regardless of whether any suggestion is currently
  pending
