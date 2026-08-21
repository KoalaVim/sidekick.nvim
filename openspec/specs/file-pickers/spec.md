# File Pickers

## Purpose

Defines requirements for the pluggable picker that lets the user choose files or open buffers
and hand them to an AI CLI tool as context. The capability covers the `cli.picker` option and
how a concrete backend is resolved from it, the common interface every backend adapter
implements (a pick request plus a selection callback), multi-selection, the per-backend
adapters for snacks.nvim, telescope.nvim and fzf-lua, the terminal keymaps that open the
picker, and cancellation.

## Requirements

### Requirement: Picker backend configuration and resolution

The `cli.picker` option SHALL select the preferred picker backend and SHALL accept `"snacks"`,
`"telescope"` or `"fzf-lua"`, defaulting to `"snacks"`. When a picker is requested without an
explicit backend name, resolution SHALL try candidates in order: the configured `cli.picker`,
then `"snacks"`, then `"telescope"`, then `"fzf-lua"`, and SHALL return the first candidate
whose host plugin can be loaded. When an explicit backend name is requested, only that
candidate SHALL be tried. If a candidate names no known adapter, resolution SHALL report the
error `Invalid picker: <name>`, SHALL stop without trying further candidates, and SHALL return
no picker. If no candidate's host plugin can be loaded, resolution SHALL report the error
`No valid picker found` and SHALL return no picker.

#### Scenario: Configured picker is installed

- **WHEN** `cli.picker` is `"telescope"` and telescope.nvim is installed
- **THEN** the telescope adapter SHALL be used for pick requests

#### Scenario: Configured picker plugin is not installed

- **WHEN** `cli.picker` is `"snacks"` but snacks.nvim is not installed and fzf-lua is
- **THEN** resolution SHALL fall through the candidate order and SHALL use the fzf-lua adapter

#### Scenario: No supported picker plugin installed

- **WHEN** none of snacks.nvim, telescope.nvim or fzf-lua can be loaded
- **THEN** an error `No valid picker found` SHALL be reported, no picker SHALL open, and
  nothing SHALL be sent to the tool

#### Scenario: Unknown backend name

- **WHEN** `cli.picker` is set to a name for which no adapter exists
- **THEN** an error `Invalid picker: <name>` SHALL be reported and no picker SHALL open

### Requirement: Common picker interface

Every backend adapter SHALL expose an `open(source, cb, opts)` entry point, where `source`
names what to pick, `cb` is the selection callback, and `opts` carries backend-specific picker
options that SHALL be forwarded to the host plugin. The system SHALL support at least the
sources `"files"` (files under the working directory) and `"buffers"` (open buffers); a
`"grep"` source SHALL also be supported. The callback SHALL be invoked exactly once per
confirmed selection, with a list of location items; each item MAY carry a file `name`, a `buf`
handle, a `cwd`, a `row` and `col`, and a `range`. Items SHALL be normalized to this common
shape by the adapter, so callers never see host-plugin entry types.

#### Scenario: Picking files

- **WHEN** a pick request is opened with source `"files"`
- **THEN** the host plugin's file picker SHALL open, restricted to files, and confirming a
  result SHALL invoke the callback with one location item per chosen file

#### Scenario: Picking buffers

- **WHEN** a pick request is opened with source `"buffers"`
- **THEN** the host plugin's buffer picker SHALL open, listing open buffers, and confirming a
  result SHALL invoke the callback with location items for the chosen buffers

#### Scenario: Extra picker options

- **WHEN** a caller passes backend-specific picker options with the pick request
- **THEN** those options SHALL be passed through to the host plugin's picker

### Requirement: Multi-selection

Each adapter SHALL support choosing more than one entry, and SHALL hand the callback the full
multi-selection as a list of location items in selection order. When the host picker has no
multi-selection, the adapter SHALL fall back to the single entry under the cursor and SHALL
hand back a one-item list. The callback SHALL always receive a list, never a bare item.

#### Scenario: Several entries selected

- **WHEN** the user marks three entries and confirms
- **THEN** the callback SHALL receive a list of three location items and all three SHALL be
  handed to the caller

#### Scenario: No entry explicitly marked

- **WHEN** the user confirms without having marked any entry
- **THEN** the callback SHALL receive a single-item list for the entry under the cursor

### Requirement: Backend adapter behavior

The snacks adapter SHALL open the picker via `Snacks.picker.pick` with the requested source
passed through unchanged, SHALL install its selection handler as the picker's `confirm` action,
SHALL read the selection from the picker (with fallback to the current item), SHALL derive each
item's `name` from the snacks path helper, its `buf` and `cwd` from the picker item, and its
`row`, `col` and `range` from the item's position and end position, and SHALL close the picker before invoking the callback. The
telescope adapter SHALL map source `"files"` to `find_files` and `"grep"` to `live_grep`,
SHALL pass any other source name through to the matching `telescope.builtin` picker, SHALL
replace the default select action with its selection handler, SHALL close the prompt before
invoking the callback, and SHALL derive each item's `buf`, `name`, `row`, `col` and `cwd` from
the telescope entry's buffer number, path or filename, line number, column and cwd. The
fzf-lua adapter SHALL map source `"files"` to `files` and `"grep"` to `live_grep`, SHALL pass
any other source name through to the matching `fzf-lua` picker, SHALL install its selection
handler as the `default` action, SHALL parse each selected line with fzf-lua's entry-to-file
helper into `name`, `row`, `col` and `buf`, SHALL default `cwd` to the picker's cwd or the
current working directory, and SHALL invoke the callback on the scheduled event loop.

#### Scenario: Snacks grep selection carries position

- **WHEN** the snacks adapter confirms a grep result that has a position and end position
- **THEN** the resulting location item SHALL carry the row, column and range of that match

#### Scenario: Telescope source name mapping

- **WHEN** a pick request with source `"files"` is opened through the telescope adapter
- **THEN** `telescope.builtin.find_files` SHALL be launched, and the selected entry SHALL be
  converted into a location item

#### Scenario: fzf-lua entry parsing

- **WHEN** the fzf-lua adapter receives selected lines from its `default` action
- **THEN** each line SHALL be parsed into a location item with its path and, when present,
  line and column numbers

### Requirement: Sending the selection to the CLI tool

The picker module SHALL provide an `open(source, opts, popts)` entry point that resolves a
backend, opens the requested source, and on confirmation renders the chosen items and sends
them to a CLI session. Each item SHALL be rendered as a location whose kind defaults to
`"file"` (path only), unless the caller requests another kind such as `"line"` or
`"position"`. Rendered locations SHALL be concatenated into a single message separated by
spaces, and that message SHALL also carry a leading and a trailing space, so the tool receives
the locations padded on both sides. The message SHALL be sent through the CLI send path so
that session filtering, attaching and showing behave as for any other send. When no backend
can be resolved, no picker SHALL open and nothing SHALL be sent. Each adapter SHALL
additionally expose a `send` action that can be bound directly in the host plugin's own
picker, so a selection made in any picker of that plugin can be sent to the current session.

#### Scenario: Selection is sent as context

- **WHEN** the user confirms two files in the picker opened from a CLI terminal
- **THEN** a single message containing both file locations, separated by a space, SHALL be
  sent to that terminal's session

#### Scenario: Host plugin keymap sends a selection

- **WHEN** the user triggers the snacks adapter's `send` action from any snacks picker, as
  documented for the `<a-a>` mapping
- **THEN** the current selection SHALL be converted to location items and sent to the current
  AI CLI session

### Requirement: Picker reachable from CLI terminal keymaps

The CLI terminal SHALL bind default keymaps that open the picker for context: `<c-f>` for the
`files` source and `<c-b>` for the `buffers` source, both active in normal and terminal mode.
Triggering either SHALL leave insert mode before the picker opens, and the resulting selection
SHALL be sent to the session owning that terminal. Users MAY override or disable these keymaps
through the CLI window keymap option.

#### Scenario: Opening the file picker from the terminal

- **WHEN** the user presses `<c-f>` in a CLI terminal window
- **THEN** insert mode SHALL be left, the configured picker SHALL open on the `files` source,
  and the chosen files SHALL be sent to that terminal's session

#### Scenario: Opening the buffer picker from the terminal

- **WHEN** the user presses `<c-b>` in a CLI terminal window
- **THEN** the configured picker SHALL open on the `buffers` source and the chosen buffers
  SHALL be sent to that terminal's session

### Requirement: Cancellation sends nothing

Aborting the picker SHALL be a no-op for the CLI tool. When the user closes or cancels the
picker without confirming, the selection callback SHALL NOT be invoked, no message SHALL be
sent to any session, and no error SHALL be reported. Only the fzf-lua adapter SHALL guard
against an empty selection by returning without invoking the callback; the snacks and
telescope adapters SHALL invoke the callback with an empty list, which sends a message
consisting only of whitespace.

#### Scenario: User aborts the picker

- **WHEN** the user closes the file or buffer picker without confirming a selection
- **THEN** no selection callback SHALL run and nothing SHALL be sent to the AI CLI tool

#### Scenario: Empty selection from the fzf-lua picker

- **WHEN** the fzf-lua adapter's selection handler is invoked with no selected entries
- **THEN** it SHALL return without invoking the callback and without sending anything
