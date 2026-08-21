# Next Edit Suggestions

## Purpose

Defines requirements for the Next Edit Suggestion (NES) orchestration lifecycle: deciding when
NES is active for a buffer, asking the Copilot LSP client for edit suggestions, keeping at most
one meaningful set of suggestions per buffer while invalidating them as the buffer changes, and
exposing the consumer-facing operations `have()`, `update()`, `clear()`, `jump()` and `apply()`
through `require("sidekick.nes")` and the `:Sidekick nes ...` commands. The visual presentation
of a suggestion (extmarks, signs, inline diff highlighting) and the diff algorithm itself belong
to the NES diff rendering capability.

## Requirements

### Requirement: Global NES activation

The module SHALL start deactivated and SHALL expose `enable(enable?)`, `disable()` and
`toggle()` to change the global activation state, mirrored by `:Sidekick nes enable|disable|toggle`.
`enable()` called with no argument, or with any value other than `false`, SHALL activate NES;
`enable(false)` and `disable()` SHALL deactivate it. Calling either operation when the state is
already the requested one SHALL be a no-op. Activating SHALL install the NES autocmds and key
watcher exactly once for the lifetime of the Neovim session, even across repeated
deactivate/activate cycles, and SHALL immediately request a fresh suggestion. Activating SHALL
also repair an explicit `nes.enabled = false` configuration by setting `nes.enabled` to `true`, so
that an explicit `enable()` is not defeated by the configured opt-out; any other `nes.enabled`
value (including a predicate function) SHALL be left untouched. Deactivating SHALL clear all
active suggestions. Plugin setup SHALL activate NES automatically unless `nes.enabled` is `false`.

#### Scenario: Enabling from the deactivated state

- **WHEN** `require("sidekick.nes").enable()` is called while NES is deactivated
- **THEN** NES SHALL become active, the trigger/clear autocmds SHALL be registered, and a
  suggestion request SHALL be issued for the current buffer

#### Scenario: Repeated enable is a no-op

- **WHEN** `enable()` is called while NES is already active
- **THEN** nothing SHALL happen: no additional autocmds SHALL be registered and no new request
  SHALL be issued

#### Scenario: Toggling

- **WHEN** `toggle()` is called
- **THEN** NES SHALL switch to the opposite activation state, with the same effects as calling
  `enable()` or `disable()` directly

#### Scenario: Enable overrides a configured opt-out

- **GIVEN** `nes.enabled` is configured as `false`
- **WHEN** `enable()` is called
- **THEN** `nes.enabled` SHALL be set to `true` and NES SHALL become active

#### Scenario: Disabling clears suggestions

- **WHEN** `disable()` is called while a suggestion is active
- **THEN** all stored suggestions SHALL be dropped, any pending request SHALL be cancelled, and
  the rendering SHALL be refreshed to show nothing

### Requirement: Per-buffer and global enable predicate

Every NES operation SHALL evaluate whether NES is enabled for a specific buffer. A buffer SHALL
be considered NES-enabled only when all of the following hold: NES is globally active, the buffer
is a valid and loaded buffer, and the `nes.enabled` option allows it. `nes.enabled` SHALL accept
either a boolean or a predicate `fun(buf:integer):boolean?`; a predicate SHALL be called with the
buffer number and a `nil` or `false` result SHALL be treated as disabled. The default
`nes.enabled` SHALL be a predicate that reports enabled unless `vim.g.sidekick_nes` is `false` or
`vim.b.sidekick_nes` is `false`, giving users a global and a per-buffer opt-out that require no
reconfiguration. The default predicate SHALL read `vim.b` of the current buffer and SHALL ignore
its buffer argument, so a buffer-local opt-out only applies while that buffer is the current one.

#### Scenario: Enabled by default

- **WHEN** neither `vim.g.sidekick_nes` nor `vim.b.sidekick_nes` is set for a buffer
- **THEN** the default `nes.enabled` predicate SHALL report the buffer as enabled

#### Scenario: Global opt-out

- **WHEN** `vim.g.sidekick_nes` is set to `false`
- **THEN** the default predicate SHALL report every buffer as disabled

#### Scenario: Per-buffer opt-out

- **WHEN** `vim.b.sidekick_nes` is set to `false` for the current buffer
- **THEN** the default predicate SHALL report disabled, while buffers that do not set the variable
  stay enabled when they are current

#### Scenario: Unusable buffer

- **WHEN** the buffer under consideration is invalid or not loaded
- **THEN** it SHALL be treated as disabled regardless of `nes.enabled`, and no request SHALL be
  made for it

### Requirement: Suggestion request to the Copilot LSP client

`update()` (also `:Sidekick nes update`) SHALL first clear the current suggestion state and then,
only if the current buffer is NES-enabled and a Copilot language server client is attached to it,
send a `textDocument/copilotInlineEdit` request to that client. Copilot clients SHALL be
identified by a client name containing `copilot` (case-insensitive), and the first such client
attached to the buffer SHALL be used. The request parameters SHALL be the current cursor position
params encoded with the client's `offset_encoding`, extended with the buffer's current LSP
document version and a `context.triggerKind` of `2`. When no Copilot client is attached, `update()`
SHALL return quietly after clearing, without error or notification, so that NES is inert in
buffers and setups without Copilot.

#### Scenario: Request for an enabled buffer

- **WHEN** `update()` runs in an NES-enabled buffer with an attached Copilot client
- **THEN** a `textDocument/copilotInlineEdit` request SHALL be sent carrying the cursor position,
  the buffer's document version, and `triggerKind = 2`

#### Scenario: No Copilot client attached

- **WHEN** `update()` runs in a buffer with no Copilot client attached
- **THEN** the previous suggestions SHALL be cleared, no request SHALL be sent, and no error SHALL
  be raised

#### Scenario: Buffer not enabled

- **WHEN** `update()` runs while NES is globally inactive or the buffer is opted out
- **THEN** the previous suggestions SHALL be cleared and no request SHALL be sent

#### Scenario: Server error

- **WHEN** the server answers the request with an error, or the responding client no longer exists
- **THEN** the response SHALL be ignored, no suggestion SHALL be stored, and no error SHALL be
  surfaced to the user

### Requirement: In-flight and stale request handling

At most one suggestion request per Copilot client SHALL be tracked as in flight. A request SHALL
NOT be tracked when the client refuses it or when it already completed synchronously during the
call. Clearing suggestions (including the clearing done at the start of `update()`) SHALL cancel
every tracked request through the client's request cancellation and forget it. A response SHALL be
accepted only when its request id matches the id currently tracked for the responding client;
any other response SHALL be discarded as stale, leaving the existing suggestion state untouched.
When a response is accepted, the tracked request SHALL be forgotten and the previously stored
suggestions SHALL be replaced wholesale by the accepted ones. When a response carries an error, or
the responding client no longer exists, the handler SHALL return before the id check and therefore
SHALL NOT forget the tracked request, which stays recorded as in flight until the next clear or
cancel.

#### Scenario: Retrigger cancels the previous request

- **WHEN** a new `update()` happens while an earlier request for the same client is still in flight
- **THEN** the earlier request SHALL be cancelled and only the newer request's response SHALL be
  able to produce suggestions

#### Scenario: Late response from a cancelled request

- **WHEN** a response arrives whose request id no longer matches the tracked request for that
  client
- **THEN** the response SHALL be ignored and the current suggestions SHALL NOT be replaced

#### Scenario: Error response leaves the request recorded

- **WHEN** the response carries an error, or the responding client no longer exists
- **THEN** no suggestion SHALL be stored and the request id SHALL remain recorded as in flight for
  that client until the next clear or cancel

#### Scenario: Synchronous response

- **WHEN** the client answers the request synchronously, before the request call returns
- **THEN** the handler SHALL be invoked inline and no request SHALL be left recorded as in flight
- **AND** because no request id is tracked yet, a synchronous response that carries a request id
  SHALL be discarded as stale

### Requirement: Debounced triggers and clear events

Suggestion requests SHALL be driven by the autocmd events listed in `nes.trigger.events`,
defaulting to `ModeChanged i:n`, `TextChanged` and `User SidekickNesDone`, so that suggestions are
requested when the user leaves insert mode, edits text in normal mode, or finishes applying a
previous suggestion. Trigger events SHALL be debounced by `nes.debounce` milliseconds, default
`100`, so that a burst of events results in a single request. Suggestions SHALL be cleared
immediately, without debounce, on the events in `nes.clear.events`, defaulting to `TextChangedI`
and `InsertEnter`. When `nes.clear.esc` is enabled (the default), typing `<Esc>` SHALL also clear
the current suggestion, independently of any autocmd. Event entries MAY carry an autocmd pattern
separated by whitespace (as in `ModeChanged i:n`), and all autocmds SHALL be registered in the
plugin's own augroup. When `nes.diff.show` is `cursor`, a debounced `CursorMoved` refresh SHALL
additionally be registered; what it renders is defined by the NES diff rendering capability.

#### Scenario: Leaving insert mode requests a suggestion

- **WHEN** the user leaves insert mode for normal mode with NES active
- **THEN** a suggestion request SHALL be issued after the `nes.debounce` delay

#### Scenario: Rapid edits collapse into one request

- **WHEN** several trigger events fire within `nes.debounce` milliseconds
- **THEN** only one suggestion request SHALL be issued, for the state after the last event

#### Scenario: Entering insert mode clears

- **WHEN** the user enters insert mode or types in insert mode while a suggestion is shown
- **THEN** the suggestion SHALL be cleared immediately and any pending request cancelled

#### Scenario: Escape clears

- **GIVEN** `nes.clear.esc` is `true`
- **WHEN** the user types `<Esc>`
- **THEN** the current suggestion SHALL be cleared

### Requirement: Copilot focus notification

The system SHALL notify every attached Copilot client of the current buffer's URI while NES is
active, because Copilot requires the non-standard `textDocument/didFocus` notification to know
which document the user is looking at. The notification SHALL be sent when entering a buffer or
window (debounced by 10ms), when a Copilot client attaches, and when the NES autocmds are first
installed. It SHALL NOT be sent while NES is inactive, nor for special buffers (any buffer whose
`buftype` is not empty). The same URI SHALL NOT be re-notified to a client that was already told
about it, so that repeatedly re-entering the same buffer produces at most one notification per
client.

#### Scenario: Entering a normal buffer

- **WHEN** the user enters a normal file buffer or its window while NES is active
- **THEN** each attached Copilot client SHALL receive a `textDocument/didFocus` notification for
  that buffer's URI

#### Scenario: Special buffers are skipped

- **WHEN** the user enters a buffer whose `buftype` is not empty
- **THEN** no focus notification SHALL be sent

#### Scenario: Client attaches later

- **WHEN** a Copilot client attaches to a buffer
- **THEN** the focus notification for the current buffer SHALL be sent

#### Scenario: No duplicate notifications

- **WHEN** the user re-enters a buffer already notified to a client
- **THEN** no further notification SHALL be sent for that client and URI

### Requirement: Suggestion storage and invalidation

Accepted suggestions SHALL be stored as a single flat list of edits, each carrying the LSP range,
replacement text and optional command from the server, plus the buffer it applies to and byte-based
start and end positions. The target buffer SHALL be resolved from the edit's `textDocument.uri`
without creating a buffer, LSP character positions SHALL be converted to byte columns using the
responding client's `offset_encoding`, and the end position SHALL be clamped to the last line of
the buffer. Queries for the active edits of a buffer SHALL return only edits that are still
usable, filtering out any edit whose buffer is no longer valid, whose recorded document version
differs from the buffer's current LSP document version, whose buffer is no longer NES-enabled, or
whose diff contains no hunks (the server sometimes returns an edit that changes nothing).
Suggestions SHALL therefore become invisible to consumers as soon as the buffer text changes,
without requiring an explicit clear.

#### Scenario: Buffer text changes

- **WHEN** the buffer is modified so that its LSP document version no longer matches the version
  recorded on a stored edit
- **THEN** that edit SHALL be excluded from the active edits of the buffer

#### Scenario: Disabled after the fact

- **GIVEN** stored edits for a buffer
- **WHEN** `vim.g.sidekick_nes` is set to `false`
- **THEN** querying the active edits of that buffer SHALL return an empty list

#### Scenario: Empty suggestion

- **WHEN** the server returns an edit whose replacement text produces no diff hunks against the
  buffer
- **THEN** the edit SHALL NOT be reported as an active edit

#### Scenario: Edit for an unopened file

- **WHEN** an edit's document URI does not correspond to an existing buffer
- **THEN** the edit SHALL be rejected and SHALL NOT be stored

### Requirement: Querying active suggestions

`have()` SHALL report whether the current buffer has at least one usable suggestion. It SHALL
return `false` when the current buffer is not NES-enabled, and otherwise `true` if and only if the
buffer has at least one active edit after invalidation filtering. `clear()` (also
`:Sidekick nes clear`) SHALL discard all stored edits regardless of buffer, cancel pending
requests, and refresh the rendering.

#### Scenario: Suggestion available

- **WHEN** the current buffer has a stored, still-valid, non-empty edit
- **THEN** `have()` SHALL return `true`

#### Scenario: No suggestion or disabled

- **WHEN** the current buffer has no valid edit, or is not NES-enabled
- **THEN** `have()` SHALL return `false`

#### Scenario: Clearing

- **WHEN** `clear()` is called
- **THEN** all stored edits SHALL be dropped, pending requests SHALL be cancelled, and `have()`
  SHALL subsequently return `false`

### Requirement: Jumping to a suggestion

`jump()` (also `:Sidekick nes jump`) SHALL move the cursor to the start of the first hunk of the
first active edit of the current buffer and SHALL return whether a jump was performed. It SHALL
return `false` without moving the cursor when the current buffer is not NES-enabled, when the
buffer has no active edit, when the edit's diff has no hunks, or when the cursor already sits at
the target position. The target position SHALL be clamped to the last line of the buffer, and the
cursor move SHALL be scheduled rather than performed inline, skipping the move if the originating
window is no longer valid. When `nes.jumplist` is enabled (the default `true`), the pre-jump
position SHALL be added to the jumplist so that the user can return with `<C-o>`.

#### Scenario: Jump to the suggestion

- **WHEN** `jump()` is called while an active edit exists in the current buffer and the cursor is
  elsewhere
- **THEN** the cursor SHALL move to the start of the edit's first hunk and `jump()` SHALL return
  `true`

#### Scenario: Cursor already at the suggestion

- **WHEN** `jump()` is called while the cursor is already at the target position
- **THEN** no jump SHALL be performed and `jump()` SHALL return `false`

#### Scenario: Jumplist entry

- **GIVEN** `nes.jumplist` is `true`
- **WHEN** a jump is performed
- **THEN** the previous cursor position SHALL be pushed onto the jumplist before the cursor moves

#### Scenario: Nothing to jump to

- **WHEN** `jump()` is called with no active edit for the current buffer, or in a buffer that is
  not NES-enabled
- **THEN** the cursor SHALL NOT move and `jump()` SHALL return `false`

### Requirement: Applying a suggestion

`apply()` (also `:Sidekick nes apply`) SHALL apply all active edits of the current buffer and
SHALL return whether an application was started. It SHALL return `false` immediately, after
clearing the suggestion state, when the current buffer is not NES-enabled. It SHALL return `false`
without clearing when no Copilot client is attached or when the buffer has no active edit.
Otherwise it SHALL return `true`, clear the suggestion state right away so no stale suggestion is
rendered, and schedule the actual work: replacing each edit's range with its replacement text in
the buffer using the client's `offset_encoding`, then executing each edit's server `command` (when
present) against that buffer, then emitting the `User SidekickNesDone` autocmd with the client id
and buffer number as event data, and finally moving the cursor to the last line of the last edit's
replacement text, with the column clamped to that line's end, honoring `nes.jumplist` like
`jump()` does. Because `User SidekickNesDone` is a
default trigger event, applying a suggestion SHALL cause a new suggestion request, allowing
consecutive suggestions to be chained by repeating the apply keymap.

#### Scenario: Applying active edits

- **WHEN** `apply()` is called while the current buffer has active edits and a Copilot client
- **THEN** `apply()` SHALL return `true`, the buffer text SHALL be replaced according to every
  active edit, and the suggestion SHALL no longer be rendered

#### Scenario: Cursor lands after the change

- **WHEN** the edits have been applied
- **THEN** the cursor SHALL be placed at the end of the last line of the last edit's replacement
  text, clamped to the buffer, and the pre-move position SHALL be added to the jumplist when
  `nes.jumplist` is enabled

#### Scenario: Chained suggestion

- **WHEN** the application completes
- **THEN** the `User SidekickNesDone` event SHALL be emitted with the client id and buffer, which
  SHALL trigger a new debounced suggestion request

#### Scenario: Nothing to apply

- **WHEN** `apply()` is called with no active edit for the current buffer, or with no Copilot
  client attached
- **THEN** the buffer SHALL NOT be modified, no event SHALL be emitted, and `apply()` SHALL return
  `false`

#### Scenario: Apply in a disabled buffer

- **WHEN** `apply()` is called while the current buffer is not NES-enabled
- **THEN** any stored suggestion SHALL be cleared, the buffer SHALL NOT be modified, and `apply()`
  SHALL return `false`
