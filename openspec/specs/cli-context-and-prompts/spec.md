# CLI Context and Prompts

## Purpose

Defines how sidekick turns editor state into the message text that is sent to an AI CLI tool: the
context snapshot taken at invocation time, the built-in context providers and the placeholders they
expand to, the template syntax used by `cli.prompts` entries, treesitter-backed function/class
resolution, and the prompt picker that previews an expanded prompt before handing it to the active
tool.

## Requirements

### Requirement: Invocation-time editor context snapshot

Every render SHALL start from a snapshot of the editor taken before any CLI window is shown or
focused, so that the message describes where the user was when they invoked the action. The snapshot
SHALL contain a window, its buffer, that window's working directory, the cursor position, and an
optional visual range. Windows whose buffer has filetype `sidekick_terminal` SHALL be excluded from
consideration; the remaining windows SHALL be ordered by the `w:sidekick_visit` timestamp
(maintained on `WinEnter`) so the most recently visited editor window wins, and the current window
SHALL be used when no candidate window remains. The row SHALL be 1-based and the column SHALL be
reported 1-based (one more than Neovim's 0-based cursor column). The working directory SHALL be
the window-local `getcwd()` normalized with forward slashes, falling back to the directory reported
by a plain `getcwd()` when the window is invalid or the window-local call fails.

#### Scenario: Cursor position is captured

- **WHEN** the cursor is on line 2, column 5 (0-based) of an editor window and a snapshot is taken
- **THEN** the snapshot SHALL report that window and buffer with row 2 and column 6

#### Scenario: CLI terminal windows are never the context

- **WHEN** a `sidekick_terminal` window is the most recently visited window
- **THEN** the snapshot SHALL still describe the most recently visited non-terminal editor window

#### Scenario: Snapshot precedes tool focus

- **WHEN** a message is sent while no CLI session is visible
- **THEN** the snapshot SHALL be taken before the session is attached, shown, or focused, and the
  rendered text SHALL describe the editor window rather than the CLI window

### Requirement: Visual selection capture

A snapshot taken while the user is in visual, visual-line, or visual-block mode SHALL include a
range with a `from` and `to` position (1-based row, 0-based column) and a kind of `char`, `line`, or
`block` matching the visual mode. Positions SHALL be normalized so that `from` never comes after
`to`. Capturing the range requires leaving visual mode to read the `<` and `>` marks; the previous
selection SHALL be restored afterwards (equivalent to `gv`) so the user does not lose it. When
the user is not in visual mode, no range SHALL be captured.

#### Scenario: Charwise selection

- **WHEN** a charwise visual selection spans line 1 columns 0 to 5 and a snapshot is taken
- **THEN** the snapshot range SHALL be kind `char` from `{1,0}` to `{1,5}`

#### Scenario: Backwards selection is normalized

- **WHEN** the selection was made upwards, so the cursor end precedes the anchor
- **THEN** the captured range SHALL be reordered so `from` is the earlier position

#### Scenario: Not in visual mode

- **WHEN** a snapshot is taken from normal mode
- **THEN** the snapshot SHALL have no range, and `{selection}` SHALL be unresolved

### Requirement: Context provider registry

Context providers SHALL be looked up by placeholder name, with user providers configured in
`cli.context` taking precedence over the built-ins (`position`, `file`, `line`, `this`, `buffers`,
`diagnostics`, `diagnostics_all`, `quickfix`, `selection`, `function`, `class`). A provider SHALL be
a function receiving the context snapshot and MAY return a string, a list of strings, a single
highlighted text line, a list of highlighted text lines, or a falsy value; returned values SHALL be
normalized to a list of lines, where a string is split on newlines. A provider that returns nothing,
an empty string, or an empty list SHALL be treated as unresolved. Each provider SHALL be evaluated at
most once per snapshot and its result (including the unresolved outcome) SHALL be cached for the rest
of that render. `cli.context` SHALL default to an empty table. Referencing a name that has no
provider SHALL report an error to the user naming the invalid context and SHALL count as unresolved.

#### Scenario: Custom provider overrides a built-in

- **WHEN** `cli.context.file` is set to a user function and `{file}` is expanded
- **THEN** the user function SHALL be used instead of the built-in `file` provider

#### Scenario: Providers are cached per snapshot

- **WHEN** the same placeholder is resolved three times against one snapshot
- **THEN** the provider function SHALL be called exactly once

#### Scenario: Unknown placeholder

- **WHEN** a template contains `{nonexistent_context}`
- **THEN** an error notification naming the invalid context SHALL be shown and the placeholder SHALL
  resolve to unresolved

#### Scenario: Empty provider result

- **WHEN** a provider returns an empty list
- **THEN** the placeholder SHALL be unresolved rather than expanding to nothing

### Requirement: Placeholder expansion with alternation

Message templates SHALL be expanded line by line, replacing every `{...}` occurrence with the value
of the named provider and leaving all other text verbatim. A placeholder MAY list several provider
names separated by `|` (for example `{function|line}`); the alternatives SHALL be tried left to right
and the first resolved one SHALL be used. If a placeholder cannot be resolved by any alternative, the
whole message SHALL be discarded and nothing SHALL be rendered. When a provider expands to multiple
lines, the first expanded line SHALL continue the current line, each subsequent expanded line SHALL
start a new line, and any literal text that followed the placeholder SHALL continue after the last
expanded line. Rendering SHALL produce both the plain string to send and the highlighted line
structure used for previews.

#### Scenario: Inline substitution

- **WHEN** the template is `before {var} after` and `var` resolves to `replacement`
- **THEN** the rendered line SHALL be `before replacement after`

#### Scenario: Fallback alternative is used

- **WHEN** the template is `Add documentation to {function|line}` and no function can be resolved at
  the cursor
- **THEN** `{line}` SHALL be expanded instead and the message SHALL be rendered

#### Scenario: Unresolvable placeholder discards the message

- **WHEN** the template contains a placeholder that resolves to unresolved
- **THEN** rendering SHALL return nothing and no text SHALL be sent

#### Scenario: Multi-line expansion

- **WHEN** the template is `start {multiline} end` and `multiline` resolves to two lines `line1` and
  `line2`
- **THEN** the result SHALL be two lines, `start line1` and `line2 end`

### Requirement: The `{this}` placeholder

`{this}` SHALL adapt to the snapshot buffer unless the caller disables it with `this = false`. When
the snapshot buffer is a real file, `{this}` SHALL be rewritten to `{position}`. Otherwise `{this}`
SHALL be replaced with the literal word `this` and, the first time that happens in a message, a blank
line followed by `{selection}` SHALL be appended to the message. Consequently, in a non-file buffer
with no visual selection the appended `{selection}` SHALL be unresolved and the whole message SHALL
be discarded. Because `this` is registered as a no-op provider that resolves to nothing, a message
that still contains `{this}` when the rewrite is disabled SHALL always be discarded.

#### Scenario: File buffer

- **WHEN** `Explain {this}` is rendered with the cursor in a readable, listed file buffer
- **THEN** the message SHALL contain the cursor position reference for that file

#### Scenario: Scratch buffer with a selection

- **WHEN** `test {this}` is rendered in a non-file buffer while a visual selection exists
- **THEN** the message SHALL read `test this` followed by a blank line and the selected text

#### Scenario: `{this}` disabled by the caller

- **WHEN** a message is rendered with `this = false`
- **THEN** `{this}` SHALL NOT be rewritten and no `{selection}` SHALL be appended
- **AND** any remaining `{this}` SHALL resolve to unresolved, so the message SHALL be discarded

### Requirement: File and location references

The `file`, `line`, and `position` providers SHALL each render a single reference line for the
snapshot buffer, and SHALL be unresolved unless the buffer is a real file, meaning it is `buflisted`,
has buftype `""` or `help`, and its name is readable on disk. A reference SHALL start with `@`
followed by the buffer path made relative to the snapshot working directory when possible, or
`[No Name]` for an unnamed buffer. `file` SHALL render the path only. `line` SHALL append ` :L<row>`,
extended to ` :L<from>-L<to>` for a multi-line range. `position` SHALL append ` :L<row>:C<col>`,
where the rendered column is one greater than the snapshot's already 1-based column, extended to
`:L<row>:C<from>-C<to>` for a range within one line and
`:L<from>:C<col>-L<to>:C<col>` for a range spanning lines, the range columns being rendered one
greater than their 0-based values; when the captured range is linewise,
`position` SHALL use the line-only form. Path, `L`/`C` markers, numbers, and delimiters SHALL carry
distinct highlight groups (`SidekickLocFile`, `SidekickLocRow`, `SidekickLocCol`, `SidekickLocNum`,
`SidekickLocDelim`) so previews can highlight them. The `buffers` provider SHALL render one
markdown list item (`- ` plus a file reference) per real-file buffer in the buffer list, relative to
the snapshot working directory.

#### Scenario: Position in a project file

- **WHEN** `{position}` is expanded with the cursor on row 10 at Neovim's 0-based column 4 of a file
  inside the snapshot working directory
- **THEN** the reference SHALL name the path relative to that directory, separated from the location
  by a single space, and end with `:L10:C6`

#### Scenario: Non-file buffer

- **WHEN** `{file}`, `{line}`, or `{position}` is expanded while the snapshot buffer is a scratch
  buffer
- **THEN** the provider SHALL be unresolved

#### Scenario: Open buffer list

- **WHEN** `{buffers}` is expanded with two readable, listed file buffers open
- **THEN** the result SHALL be two markdown list items, each referencing one of those files

### Requirement: Selection content provider

The `selection` provider SHALL render the text covered by the snapshot range, syntax highlighted with
the source buffer's treesitter parser when one is available, and SHALL be unresolved when the
snapshot has no range. For a charwise range the first line SHALL be trimmed to the start column
(padded with spaces to preserve the original alignment) and the last line SHALL be trimmed to the
end column. For a blockwise range
every line SHALL be trimmed to the column span between the range's smallest and largest column. For
a linewise range whole lines SHALL be used. Common leading indentation SHALL be removed from the
result.

#### Scenario: Charwise selection is sent

- **WHEN** `{selection}` is expanded with a charwise selection over part of one line
- **THEN** the rendered text SHALL be just that part of the line

#### Scenario: No selection

- **WHEN** `{selection}` is expanded with no range in the snapshot
- **THEN** the provider SHALL be unresolved and any message containing it SHALL be discarded

### Requirement: Diagnostics providers

The `diagnostics` provider SHALL report the diagnostics of the snapshot buffer and `diagnostics_all`
SHALL report the diagnostics of all buffers; both SHALL be unresolved when there are no diagnostics.
Diagnostics SHALL be ordered by line and then by column, and each SHALL render as a severity tag in
brackets (for example `[ERROR]`, highlighted with the matching `DiagnosticVirtualText*` group),
the message rendered with `markdown_inline` highlighting, then the diagnostic source and code when
present, then a location reference pointing at the diagnostic's own buffer and its start-to-end
range. When the snapshot has a visual range, only diagnostics whose line falls inside that range
SHALL be reported. A multi-line diagnostic message SHALL be rendered across multiple lines.

#### Scenario: Buffer diagnostics

- **WHEN** `{diagnostics}` is expanded and the snapshot buffer has two diagnostics
- **THEN** both SHALL be rendered, ordered by position, each with its severity tag, message, and
  location reference

#### Scenario: Restricted to the selection

- **WHEN** `{diagnostics}` is expanded while a visual range covers only part of the buffer
- **THEN** only diagnostics on lines inside that range SHALL be reported

#### Scenario: No diagnostics

- **WHEN** `{diagnostics_all}` is expanded and no buffer has diagnostics
- **THEN** the provider SHALL be unresolved

### Requirement: Quickfix provider

The `quickfix` provider SHALL render the current quickfix list and SHALL be unresolved when that list
is empty. When the list has a title that does not look like a generated command title (a leading `:`
followed by a non-space character), the output SHALL begin with a `Quickfix: <title>` heading line.
Each entry SHALL render as a markdown list item starting with `- `, followed by a location reference
built from the entry's filename or buffer relative to the snapshot working directory and its
line/column range, or `@[No Name]` when the entry identifies no file. The entry type, when set, SHALL
follow in brackets, highlighted per severity (`E`, `W`, `I`, `N`, `H`). The entry text SHALL follow,
trailing whitespace trimmed, highlighted as `markdown_inline`, with extra message lines rendered as
indented continuation lines.

#### Scenario: Entry with type and text

- **WHEN** the quickfix list has title `Test Quickfix` and one error entry on line 2 of a file with
  text `Test error message`
- **THEN** the output SHALL start with `Quickfix: Test Quickfix` and the entry line SHALL contain
  `- @`, the file name, `:L2`, `[E]`, and `Test error message`

#### Scenario: Command-style title is omitted

- **WHEN** the quickfix title is `:setqflist()`
- **THEN** no heading line SHALL be emitted and the first output line SHALL be the first entry

#### Scenario: Empty quickfix list

- **WHEN** `{quickfix}` is expanded with an empty quickfix list
- **THEN** the provider SHALL be unresolved

### Requirement: Treesitter textobject scope providers

The `function` and `class` providers SHALL locate the innermost enclosing function or class at the
cursor using the outer treesitter textobject query and render it as `<type> <name> @<location>`,
where the type is `function` or `class`, the name is the node's name when one can be determined, and
the location is a position reference at the node's start, whose rendered column follows the same
convention as `position` and is therefore two greater than the node's 0-based start column. Name
detection SHALL try the node's `name`,
`identifier`, and `field` fields and then any child whose node type contains `identifier`, and the
name MAY be omitted when none is found. Resolution SHALL be unresolved, without raising an error,
when the buffer is invalid, `nvim-treesitter-textobjects` is not installed, the buffer has no
treesitter parser, the language has no `textobjects` query, the query lookup fails, or the cursor is
not inside a matching node. The same lookup MAY also be used to return the highlighted source lines
of the matched node with common indentation removed. The underlying lookup SHALL additionally support
the `block`, `parameter`, `comment`, `call`, `conditional`, `loop`, `assignment`, `return`, and
`number` textobject types and an `inner` option that selects the inner textobject instead of the
outer one, but only `function` and `class` SHALL be exposed as context placeholders.

#### Scenario: Cursor inside a function

- **WHEN** `{function}` is expanded with the cursor inside a Lua function whose parser and
  textobjects query are available
- **THEN** the result SHALL be one line naming the function and its start location

#### Scenario: Cursor outside any function

- **WHEN** `{function}` is expanded with the cursor on a top-level statement
- **THEN** the provider SHALL be unresolved

#### Scenario: Unsupported filetype

- **WHEN** `{function}` is expanded in a buffer whose filetype has no treesitter parser or
  textobjects query
- **THEN** the provider SHALL be unresolved and no error SHALL be raised

#### Scenario: Textobject types beyond the exposed placeholders

- **WHEN** the lookup is called directly for the `block` type with the cursor inside an `if` block
- **THEN** the block SHALL be resolved, even though no `{block}` placeholder exists

### Requirement: Prompt templates

Prompts SHALL be configured as named entries in `cli.prompts`, where an entry MAY be a template
string, a table with a `msg` template string, or a function receiving the context snapshot and
returning a template string. Rendering a message MAY combine a caller-supplied `msg` with a named
prompt; in that case the prompt's lines SHALL be appended after the message's lines. Requesting a
prompt name that is not configured SHALL report an error stating that the name is not a valid prompt
name, and render nothing. Prompt templates SHALL go through the same placeholder expansion as any
other message, so they MAY use any built-in or custom context placeholder. The default prompts
SHALL include `changes`, `diagnostics`, `diagnostics_all`, `document` (using `{function|line}`),
`explain`, `fix`, `optimize`, `review`, `tests`, and the single-placeholder prompts `buffers`, `file`, `line`,
`position`, `quickfix`, `selection`, `function`, and `class`.

#### Scenario: String prompt

- **WHEN** a prompt configured as the string `This is a test prompt` is rendered
- **THEN** the rendered text SHALL be exactly that string

#### Scenario: Function prompt

- **WHEN** a prompt configured as a function returning text derived from the snapshot is rendered
- **THEN** the function SHALL receive the context snapshot and its returned template SHALL be
  expanded

#### Scenario: Message plus prompt

- **WHEN** a message with `msg = "msg text"` and `prompt` naming a prompt whose template is
  `prompt text` is rendered
- **THEN** the result SHALL be `msg text` followed by a newline and `prompt text`

#### Scenario: Unknown prompt name

- **WHEN** a message names a prompt that is not present in `cli.prompts`
- **THEN** an error naming the invalid prompt SHALL be reported and nothing SHALL be rendered

### Requirement: Prompt picker

Selecting a prompt SHALL take one context snapshot, then offer the configured prompt names in
alphabetical order through `vim.ui.select`. Each candidate SHALL be expanded against that single
snapshot up front, and a prompt whose template cannot be fully expanded in the current context SHALL
be omitted from the list. Each list entry SHALL show the prompt name followed by its raw template,
padded to a fixed column, with placeholders and escaped newlines visually distinguished; a function
prompt SHALL be listed with `[function]` as its template. The picker SHALL preview the fully expanded
text of the highlighted entry, carrying over the highlight groups produced during rendering, and
SHALL offer a yank action for the previewed text when the snacks picker is used. Choosing an entry
SHALL hand both the expanded string and its highlighted lines to the caller's callback; cancelling
SHALL invoke the callback with no message so nothing is sent. By default the chosen prompt SHALL be
sent to the active CLI tool without further expansion.

#### Scenario: Listing prompts

- **WHEN** the prompt picker is opened
- **THEN** the configured prompts SHALL be listed alphabetically, each showing its name and raw
  template

#### Scenario: Prompt not applicable in the current context

- **WHEN** a configured prompt requires `{selection}` and the user is not in visual mode
- **THEN** that prompt SHALL NOT appear in the picker

#### Scenario: Preview of the expanded prompt

- **WHEN** an entry is highlighted in the picker
- **THEN** the preview SHALL show the prompt with all placeholders already expanded for the captured
  context

#### Scenario: Cancelling the picker

- **WHEN** the user dismisses the picker without choosing
- **THEN** no message SHALL be sent to any CLI tool

### Requirement: Sending rendered text to the active tool

Sending SHALL render the requested message or prompt against a fresh snapshot unless the caller
already supplies rendered text. When neither a message nor a prompt is given and the user is in
visual mode, the message SHALL default to `{selection}`. If rendering yields no text, the user SHALL
be warned with `Nothing to send.` and nothing SHALL be sent; a message that renders to just a
newline SHALL be sent as an empty line, allowing a bare submit. Otherwise the rendered lines SHALL
be converted to a string by the active tool's formatter, which SHALL pass a tool's `format` hook
both the rendered lines and the default joined string and SHALL fall back to that default string when
the hook returns nothing, so a tool MAY reshape the text, and
delivered to that tool's session followed by a newline; the caller MAY additionally request
submission. Visual mode SHALL be left before the text is delivered.

#### Scenario: Visual mode default

- **WHEN** a send is requested with no message and no prompt while a visual selection is active
- **THEN** the selected text SHALL be sent

#### Scenario: Nothing to send

- **WHEN** the requested message or prompt cannot be rendered
- **THEN** a `Nothing to send.` warning SHALL be shown and no text SHALL reach the tool

#### Scenario: Tool-specific formatting

- **WHEN** the active tool configures a `format` function
- **THEN** that function SHALL receive the rendered lines together with the default joined string,
  and its returned string SHALL be what is sent
