# Core Utilities

## Purpose

Provides the shared runtime services that every other sidekick capability builds on: user-facing
notifications and error reporting, gated debug output, debounced scheduling, external command
execution, persisted plugin state, plugin-wide events, small value and editor-position helpers,
UTF-8 aware string measurement and splitting, and the highlighted-text (`sidekick.Text`) chunk
utilities used to build virtual lines and CLI context.

## Requirements

### Requirement: User-facing notification and error reporting

`sidekick.util` SHALL expose `notify(msg, level)` plus the `info`, `warn` and `error` wrappers as
the single path for user-visible messages. A message MAY be given as a string or as a list of
strings; a list SHALL be joined with a single newline before being delivered. Delivery SHALL be
deferred to the main loop with `vim.schedule` and SHALL be handed to `vim.notify` with the
resolved level and the options table `{ title = "Sidekick" }`, so every sidekick message is
attributed to the plugin. When no level is given, the level SHALL be `vim.log.levels.INFO`.
Message bodies MAY contain markdown, including fenced code blocks, which markdown-aware notifier
backends render and plain backends show verbatim; the helpers SHALL NOT strip or escape it.

#### Scenario: Error and info messages reach vim.notify

- **WHEN** `util.error("oops")` and then `util.info("hello")` are called
- **THEN** `vim.notify` SHALL be invoked twice, in that order, with `"oops"` at
  `vim.log.levels.ERROR` and `"hello"` at `vim.log.levels.INFO`
- **AND** each call SHALL pass exactly `{ title = "Sidekick" }` as its options

#### Scenario: Multi-line message

- **WHEN** a helper is called with a list of strings
- **THEN** the notification body SHALL be those strings joined by `"\n"`

#### Scenario: Notification never runs inline

- **WHEN** a helper is called from a fast-event or callback context
- **THEN** the message SHALL be delivered through `vim.schedule` rather than synchronously

#### Scenario: Extmark placement failure is reported, not raised

- **WHEN** `util.set_extmark` is called and `nvim_buf_set_extmark` fails
- **THEN** it SHALL report an error notification containing the failure message plus the offending
  mark (row, col and options) inside a fenced `lua` code block, SHALL return `nil`, and SHALL NOT
  propagate the error to the caller
- **AND** on success it SHALL return the created extmark id

### Requirement: Gated debug output and deprecation notices

`util.debug(msg, what)` SHALL produce output only while `require("sidekick.config").debug` is
truthy (default `false`); otherwise it SHALL be a no-op with no side effects. When enabled, the
message SHALL be emitted at `vim.log.levels.WARN` through the normal notification path, and when
`what` is not `nil` its `vim.inspect` rendering SHALL be appended as a fenced `lua` code block.
`util.deprecate(deprecated, replacement)` SHALL emit a warning naming the deprecated identifier
and the replacement to use, regardless of the debug flag.

#### Scenario: Debug disabled

- **WHEN** `config.debug` is `false` and `util.debug` is called
- **THEN** no notification SHALL be produced

#### Scenario: Debug with an inspected value

- **WHEN** `config.debug` is `true` and `util.debug("state", value)` is called
- **THEN** a WARN notification SHALL be produced whose body contains `state` followed by the
  inspected `value` wrapped in a fenced `lua` code block

#### Scenario: Deprecated API used

- **WHEN** `util.deprecate("old", "new")` is called
- **THEN** a WARN notification SHALL name both `old` and `new`

### Requirement: Debounced scheduling

`util.debounce(fn, ms)` SHALL return a function with the same call signature as `fn` that defers
the call by `ms` milliseconds, defaulting to `20` when `ms` is omitted. Each invocation SHALL
restart the pending timer, so only the trailing call runs and it SHALL run with the arguments of
the most recent invocation; intermediate invocations SHALL be dropped rather than queued. The
deferred call SHALL run on the main loop (it is wrapped with `vim.schedule_wrap`), so it is safe
to call the wrapper from fast events. The wrapper SHALL return immediately and SHALL NOT return
`fn`'s result. Errors raised by `fn` SHALL be swallowed so a failing callback never breaks the
autocommand or timer that triggered it. Each wrapper owns one timer, so re-calling the wrapper is
the only cancellation mechanism; there SHALL be no separate cancel or flush API.

#### Scenario: Rapid calls collapse

- **WHEN** the wrapper is called several times within the debounce window
- **THEN** `fn` SHALL run once, after the window elapses from the last call, with the arguments
  from that last call

#### Scenario: Default interval

- **WHEN** `util.debounce(fn)` is created without `ms`
- **THEN** the delay SHALL be 20 milliseconds

#### Scenario: Callback error is contained

- **WHEN** the debounced `fn` raises an error
- **THEN** the error SHALL NOT propagate out of the timer callback and later invocations SHALL
  still work

### Requirement: External command execution

`util.exec(cmd, opts)` SHALL run `cmd` (a list of arguments) synchronously, blocking until the
process exits, and SHALL always request text (not binary) output. Additional `vim.SystemOpts`
fields such as `stdin`, `cwd` and `env` SHALL be forwarded to the underlying process. On success
it SHALL return two values: the standard output split on newlines with empty leading and trailing
entries trimmed, and the raw unsplit standard output. On failure - a non-zero exit code or missing
standard output - it SHALL return `nil` and, unless `opts.notify` is `false`, SHALL report an
error notification containing the full command line and the captured standard error. There is no
asynchronous form: callers that must not block use `vim.system` directly. `util.curl(url, opts)`
SHALL build a `curl -s -S` invocation from the optional `method`, `headers` and `data` fields,
JSON-encoding a non-string `data` and adding a `Content-Type: application/json` header for it, run
it through `util.exec`, and return the response body as a single string, or `nil` when the request
or the JSON encoding fails.

#### Scenario: Successful command

- **WHEN** `util.exec` runs a command that exits with code 0 and writes output
- **THEN** it SHALL return the output lines as a list plus the raw output string

#### Scenario: Failing command with notifications enabled

- **WHEN** the command exits non-zero and `opts.notify` is not `false`
- **THEN** `util.exec` SHALL return `nil` and SHALL report an error notification naming the
  command and including its standard error

#### Scenario: Probing command with notifications suppressed

- **WHEN** the command exits non-zero and `opts` contains `notify = false`
- **THEN** `util.exec` SHALL return `nil` and SHALL NOT notify the user

#### Scenario: JSON request body cannot be encoded

- **WHEN** `util.curl` is given a `data` value that `vim.json.encode` rejects
- **THEN** it SHALL report an encoding error, SHALL NOT run `curl`, and SHALL return `nil`

### Requirement: Persisted state and plugin events

`util.set_state(key, value)` and `util.get_state(key)` SHALL persist and read small JSON values
under the Neovim state directory, one file per key at `stdpath("state")/sidekick/<key>.json`,
creating the directory on write when needed. Both SHALL be best-effort: an unencodable value or an
unwritable file SHALL silently store nothing, and a missing or corrupt file SHALL read back as
`nil`. `util.emit(event, data)` SHALL fire a `User` autocommand whose pattern is `event` and whose
`data` is the given payload, with modeline processing disabled, so user configuration can react to
sidekick events (for example `SidekickNesDone`, `SidekickCliAttach`, `SidekickCliDetach`).

#### Scenario: Round-trip

- **WHEN** a value is written with `set_state` and later read with `get_state` using the same key
- **THEN** the decoded value SHALL be returned

#### Scenario: Unknown or damaged key

- **WHEN** `get_state` is called for a key that was never written, or whose file is not valid JSON
- **THEN** it SHALL return `nil` without raising

#### Scenario: Event observable by user autocommands

- **WHEN** `util.emit("SidekickCliAttach", { id = id })` is called
- **THEN** a `User` autocommand with pattern `SidekickCliAttach` SHALL fire with that payload as
  its `data`

### Requirement: Value and editor position helpers

`util.merge(...)` SHALL deep-merge its table arguments left to right with later values winning,
ignoring non-table arguments, returning `{}` when none are tables, and SHALL deep-copy its inputs
so callers' tables are never mutated. `util.overlaps(a, b)` SHALL report whether two lists share
at least one value. `util.ref(value)` SHALL return a weak-valued, callable container so a holder
can reference an object without keeping it alive; calling it yields the value, or `nil` once the
value has been collected. `util.fix_pos(buf, pos)` SHALL clamp a 0-based `{ row, col }` position
that points past the last line of `buf` to the end of the buffer's last line, and SHALL return
the position unchanged otherwise. `util.visual_mode()` SHALL classify the current mode as
`"char"`, `"line"` or `"block"` (returning the raw mode string as its second value) and SHALL
return `nil` when not in a visual mode; `util.exit_visual_mode()` SHALL additionally leave visual
mode and return the same classification.

#### Scenario: Merging configuration tables

- **WHEN** `util.merge(defaults, user)` is called
- **THEN** the result SHALL be a deep merge in which `user` values override `defaults`, and
  neither input table SHALL be modified

#### Scenario: Position beyond the buffer

- **WHEN** `util.fix_pos` is given a row greater than the buffer's last line index
- **THEN** it SHALL return the last line index paired with that line's length

#### Scenario: Not in visual mode

- **WHEN** `util.exit_visual_mode` is called from normal or insert mode
- **THEN** it SHALL return `nil` and SHALL NOT execute any normal-mode command

### Requirement: UTF-8 aware measurement and splitting

`util.width(str)` SHALL return the display width of `str` after expanding tab characters to
`'tabstop'` spaces, so wide and double-width characters count for the cells they occupy.
`util.split_words(str)` SHALL split a string into keyword runs and single non-keyword characters:
consecutive characters that Neovim classifies as keyword characters (per `'iskeyword'`) SHALL be
grouped into one element, while every other character - punctuation, whitespace, tabs, newlines,
emoji and CJK characters - SHALL be emitted as its own element, in original order, so
concatenating the result reproduces the input. `util.split_chars(str)` SHALL split a string at
UTF-8 codepoint boundaries, one element per codepoint. Both splitters SHALL return an empty list
for an empty string.

#### Scenario: Words and separators

- **WHEN** `util.split_words` is given `abc.def ghi`
- **THEN** the result SHALL be the words `abc`, `def` and `ghi` with the `.` and the space each as
  their own element, in order

#### Scenario: Multibyte handling

- **WHEN** `util.split_words` is given a word containing an accented Latin letter
- **THEN** the whole word SHALL stay a single element
- **AND** when it is given emoji or CJK text, each such character SHALL be a separate element

#### Scenario: Codepoint splitting

- **WHEN** `util.split_chars` is given a string containing an emoji followed by a modifier
  codepoint
- **THEN** the base emoji and the modifier SHALL be returned as two separate elements

#### Scenario: Empty input

- **WHEN** either splitter is given `""`
- **THEN** it SHALL return an empty list

### Requirement: Text chunk construction and rendering

`sidekick.text` SHALL represent styled text as a list of lines, each line a list of
`{ text, highlight }` chunks. `text.to_text(data)` SHALL normalize the several shapes producers
may return into that form: an empty string or empty list SHALL become an empty list of lines; a
multi-line string SHALL be split on newlines with each line becoming a single unhighlighted
chunk, so a trailing newline yields a final line holding a single empty chunk; a list of strings
SHALL become one single-chunk line per string; a single list of chunks SHALL be wrapped as one
line; and an already well-formed list of lines SHALL be returned as is. `text.lines(lines)` SHALL
flatten each line to a plain string, treating a non-string chunk payload as empty, and
`text.to_string(lines)` SHALL join those with newlines. `text.width(line)` SHALL return the
summed display width of a line's chunks and `text.lines_width(lines)` the widest line's width
(`0` for no lines), both using the same tab-expanding width measurement as `util.width`.

#### Scenario: String input with a trailing newline

- **WHEN** `text.to_text("a\nb\n")` is called
- **THEN** the result SHALL contain three lines, the last of which holds a single empty chunk

#### Scenario: Empty input

- **WHEN** `text.to_text` is given `""` or an empty list
- **THEN** it SHALL return an empty list of lines

#### Scenario: Rendering back to plain text

- **WHEN** `text.to_string` is called on a list of lines
- **THEN** the result SHALL be the concatenated chunk texts of each line, joined by newlines,
  with highlights discarded

#### Scenario: Measuring a block

- **WHEN** `text.lines_width` is called on lines of differing width
- **THEN** it SHALL return the display width of the widest line

### Requirement: Text slicing, indent normalization and transformation

`text.sub(line, from, to)` SHALL return the part of a line covering display columns `from` through
`to` inclusive, 1-based, defaulting to the start and to the end of the line respectively. Chunks
lying entirely inside the range SHALL be kept with their highlight untouched, a partially covered
chunk SHALL be sliced while keeping its highlight, chunks outside the range SHALL be dropped, and
iteration SHALL stop once `to` is passed. `text.fix_indent(lines)` SHALL expand tabs to
`'tabstop'` spaces in each line's first chunk, determine the smallest leading-whitespace width
common to those chunks, and remove exactly that much indentation from every line; when the common
indent is zero, or no line has a first chunk, the lines SHALL be returned with no indentation
stripped, the tab expansion having already been applied in place. `text.split(str, pattern)` SHALL
split a string while keeping the matched substrings as their own elements, in order, so
placeholder patterns can be located and replaced. `text.transform(lines, cb, filter)` SHALL
rewrite chunk texts in place by calling `cb(text, chunk)` and using its return value, keeping the
original text when `cb` returns `nil`, and SHALL visit only chunks carrying one of the highlights
named by `filter` when a filter (a single name or a list of names) is given.

#### Scenario: Slicing a highlighted line

- **WHEN** `text.sub` is called with a range that starts in the middle of a chunk
- **THEN** that chunk SHALL be replaced by its covered part with the same highlight, and the
  chunks fully inside the range SHALL be preserved

#### Scenario: Open-ended range

- **WHEN** `text.sub(line, n)` is called without a `to`
- **THEN** everything from column `n` to the end of the line SHALL be returned

#### Scenario: Common indentation removed

- **WHEN** `text.fix_indent` is given lines that all start with the same indentation
- **THEN** that indentation SHALL be stripped from every line, with tabs first expanded to
  `'tabstop'` spaces

#### Scenario: Filtered transformation

- **WHEN** `text.transform` is called with a highlight filter
- **THEN** only chunks carrying one of the filtered highlights SHALL be passed to the callback,
  and other chunks SHALL be left untouched
