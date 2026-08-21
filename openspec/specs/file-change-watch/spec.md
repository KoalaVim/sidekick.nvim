# File Change Watch

## Purpose

Keeps Neovim buffers in sync with files that an AI CLI tool edits behind the editor's back. While a
sidekick CLI session is running, the capability watches the directories that back the user's open
buffers, and turns a filesystem change into a single buffer reload check, so the editor never shows a
stale version of a file the agent just rewrote and never silently discards the user's own unsaved
work.

## Requirements

### Requirement: Watcher activation follows `cli.watch` and CLI session lifetime

The `cli.watch` option SHALL control the watcher and SHALL default to `true`. When it is enabled, the
watcher SHALL be started as soon as sidekick has successfully started a CLI tool in a Neovim
terminal, and SHALL be stopped when the last such CLI terminal session is closed. Both starting and
stopping SHALL be idempotent: starting an already active watcher SHALL be a no-op, and stopping an
inactive watcher SHALL be a no-op and SHALL NOT error. When `cli.watch` is `false`, no watcher, no
directory watch and no autocommand SHALL be created for any session.

#### Scenario: First CLI session starts the watcher

- **WHEN** `cli.watch` is `true` and a CLI tool has started in a Neovim terminal
- **THEN** the watcher SHALL become active and SHALL begin watching the directories of the currently
  eligible buffers

#### Scenario: Watching disabled by configuration

- **WHEN** `cli.watch` is `false` and a CLI tool is started
- **THEN** no directory SHALL be watched, no buffer reload check SHALL be triggered by this
  capability, and no error SHALL be reported

#### Scenario: Additional session while already watching

- **WHEN** a second CLI terminal session starts while the watcher is already active
- **THEN** the watcher SHALL stay active with a single set of watches and SHALL NOT install duplicate
  watches or duplicate autocommands

#### Scenario: Last session closes

- **WHEN** the last CLI terminal session is closed
- **THEN** the watcher SHALL be stopped, regardless of whether it was ever active

### Requirement: Watched directories are derived from eligible buffers

The watcher SHALL watch directories, not individual files, and the set of watched directories SHALL
be exactly the set of parent directories of the eligible buffers. A buffer SHALL be eligible only
when it is loaded, has an empty `buftype`, is `buflisted`, has a non-empty name, and its name
resolves to a path that currently exists on disk. Buffers that fail any of these conditions -- such
as the CLI terminal buffer itself, scratch and special buffers, unlisted buffers, unloaded buffers,
and buffers whose file does not exist on disk -- SHALL contribute no watch. Several eligible buffers
that share a directory SHALL be covered by a single watch for that directory.

#### Scenario: Ordinary file buffer

- **WHEN** the watcher is active and a listed, loaded buffer names a file that exists on disk
- **THEN** that file's parent directory SHALL be watched

#### Scenario: Special buffers are ignored

- **WHEN** the only open buffers are terminal, scratch, help or other non-file buffers
- **THEN** no directory SHALL be watched on their behalf

#### Scenario: Buffers sharing a directory

- **WHEN** two eligible buffers live in the same directory
- **THEN** that directory SHALL be watched once, and the watch SHALL remain while at least one of
  them is still eligible

#### Scenario: Last buffer for a directory goes away

- **WHEN** the last eligible buffer in a watched directory is deleted or wiped out
- **THEN** the watch for that directory SHALL be stopped and its handle SHALL be closed

### Requirement: The watch set is kept current through buffer lifecycle events

While active, the watcher SHALL recompute its watch set on buffer lifecycle changes, listening for
`BufAdd`, `BufDelete`, `BufWipeout` and `BufReadPost` in its own `sidekick.watch` augroup, and SHALL
also compute it once at activation. Recomputation SHALL start watches for newly eligible directories
and stop watches for directories that are no longer represented. Recomputation SHALL be coalesced
with a trailing delay of about 100 ms, so a burst of buffer events results in a single pass.

#### Scenario: Opening a file in an unwatched directory

- **WHEN** the user opens a file whose directory is not yet watched
- **THEN** a watch for that directory SHALL be started

#### Scenario: Burst of buffer events

- **WHEN** many buffers are added or deleted in rapid succession
- **THEN** the watch set SHALL be recomputed once after the burst settles rather than once per event

### Requirement: Change detection is event-driven and coalesced into one reload check

Detection SHALL use the operating system's filesystem event notifications for each watched directory
rather than polling, and SHALL be non-recursive: only entries directly inside a watched directory are
observed. When an event names a changed entry, the watcher SHALL record that entry's path and SHALL
schedule a reload check. Reload checks SHALL be coalesced with a trailing delay of about 100 ms and
SHALL run on the main loop, so a rewrite of many files by an AI CLI tool results in a single check.
The reload check SHALL be performed by triggering Neovim's own file-change detection (`:checktime`),
which covers every loaded buffer, not only the buffers under the directory that reported the event.
After each check the recorded set of changed paths SHALL be cleared; when `debug` is enabled the
recorded paths SHALL be reported to the user as a notification.

#### Scenario: Agent rewrites a file

- **WHEN** an AI CLI tool writes to a file inside a watched directory
- **THEN** within roughly 100 ms a single reload check SHALL run and the buffer for that file SHALL be
  brought up to date with the contents on disk

#### Scenario: Agent rewrites many files at once

- **WHEN** many files in watched directories change within the coalescing window
- **THEN** exactly one reload check SHALL run for the whole batch

#### Scenario: Change outside the watched directories

- **WHEN** a file changes in a directory that backs no eligible buffer
- **THEN** no filesystem event SHALL be observed for it and no reload check SHALL be triggered by that
  change

### Requirement: Unsaved local modifications are never silently overwritten

The reload check SHALL delegate entirely to Neovim's standard file-change handling. A buffer with no
local modifications SHALL be reloaded from disk when `'autoread'` is set, as it is by default, and
SHALL otherwise be reported as changed for the user to reload. A buffer that has unsaved local
modifications SHALL NOT be silently replaced with the on-disk contents; Neovim's conflict handling
SHALL decide the outcome and SHALL inform the user. The watcher SHALL NOT write buffers, SHALL NOT
force a reload, and SHALL NOT suppress Neovim's file-changed messages or `FileChangedShell`
handling, so the user is always told when a file underneath a buffer changed.

#### Scenario: Clean buffer

- **WHEN** the reload check runs and a buffer is unmodified while its file on disk has newer contents
- **THEN** with the default `'autoread'` the buffer SHALL be reloaded from disk, and with
  `'noautoread'` Neovim SHALL warn about the change instead of reloading it

#### Scenario: Buffer with unsaved edits

- **WHEN** the reload check runs and a buffer has unsaved local modifications while its file on disk
  also changed
- **THEN** the local modifications SHALL NOT be discarded without the user's involvement, and the
  conflict SHALL be surfaced by Neovim's own file-changed reporting

#### Scenario: User is informed

- **WHEN** a file underneath a loaded buffer changed
- **THEN** the change SHALL be reported through Neovim's normal file-change reporting, and when
  `debug` is enabled the watcher SHALL additionally notify the list of changed paths

### Requirement: Files deleted on disk

A buffer whose file no longer exists on disk SHALL NOT be eligible, so it SHALL contribute no watch,
and the watch for its directory SHALL be stopped once no other eligible buffer remains there. The
watcher SHALL NOT delete, empty or unload a buffer whose file was removed; the deletion SHALL be
surfaced by the reload check through Neovim's own reporting for a file that is no longer available.

#### Scenario: Agent deletes a file that is open

- **WHEN** an AI CLI tool deletes a file inside a watched directory that a buffer is editing
- **THEN** the reload check SHALL run, Neovim SHALL report that the file is no longer available, and
  the buffer's contents SHALL be left intact rather than cleared

#### Scenario: Deleted file stops contributing a watch

- **WHEN** the watch set is recomputed after a buffer's file has been deleted from disk
- **THEN** that buffer SHALL be treated as ineligible, and its directory SHALL stop being watched if
  no other eligible buffer lives there

### Requirement: No watcher or timer leaks

Stopping the watcher SHALL close every open filesystem watch handle and SHALL remove the
`sidekick.watch` augroup and its autocommands, so that after the last CLI terminal session ends no
watch handle stays open and no autocommand of this capability remains registered. Closing a handle
SHALL be safe to request more than once and SHALL never close an already closing handle twice.
Removal of the autocommands SHALL be tolerant of the group already being gone. If starting a watch
for a directory fails, the error SHALL be reported to the user, the partially created handle SHALL be
closed, and that directory SHALL NOT be recorded as watched, so a later recomputation can retry it.
Coalescing timers SHALL be one-shot, so no repeating timer stays armed after the watcher stops.
Stopping SHALL NOT cancel a coalescing timer that is already armed, so a recomputation or reload
check scheduled just before the stop MAY still run once afterwards.

#### Scenario: Clean teardown

- **WHEN** the last CLI terminal session closes while directories are being watched
- **THEN** every watch handle SHALL be closed and the `sidekick.watch` augroup SHALL be removed
- **AND** with no armed coalescing timer left over, no further reload check SHALL be triggered by
  this capability

#### Scenario: Repeated teardown

- **WHEN** the watcher is stopped twice, or stopped when it was never started
- **THEN** the second stop SHALL be a no-op and SHALL NOT raise an error

#### Scenario: Watch cannot be started

- **WHEN** a filesystem watch for a directory cannot be started, for example because the platform
  limit on watches is exhausted
- **THEN** an error SHALL be reported, the handle SHALL be closed, that directory SHALL NOT count as
  watched, and the remaining directories SHALL still be watched
