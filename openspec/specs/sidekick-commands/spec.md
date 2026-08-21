# Sidekick Commands

## Purpose

Defines the `:Sidekick` user command surface: a nested tree of subcommands that acts as a thin
wrapper around sidekick's Lua API, together with the rules for resolving a typed command path,
parsing trailing `key = value` arguments as a Lua expression, offering tab completion, reporting
incomplete or invalid input, and preserving the visual selection when the command is invoked
with a range.

## Requirements

### Requirement: Sidekick user command registration

Calling `require("sidekick.config").setup()` SHALL register a single user command named
`Sidekick` with description `Sidekick`. The command SHALL accept an optional argument string,
SHALL accept a range, and SHALL provide command-line completion driven by
`require("sidekick.commands").complete`. Invocation SHALL be handled by
`require("sidekick.commands").cmd`, which receives the command argument table.

#### Scenario: Command available after setup
- **WHEN** `setup()` has run
- **THEN** `:Sidekick` SHALL exist as a user command, SHALL accept a leading range, and
  SHALL complete its arguments from the command tree

#### Scenario: Command invoked with no arguments
- **WHEN** the user runs `:Sidekick` with no arguments
- **THEN** the handler SHALL be called with an empty argument string and SHALL report an
  incomplete command rather than performing an action

### Requirement: Nested command tree

The command surface SHALL be a nested table `M.commands` whose leaves are functions. The tree
SHALL expose the branches `nes`, `cli`, and `debug`, so that a command line has the shape
`:Sidekick <module> <command> [args]`. Every leaf SHALL be reachable by naming each branch on
the path in order. A leaf SHALL be called with exactly one argument: the parsed argument table.

#### Scenario: Two-level path resolves to a leaf
- **WHEN** the user runs `:Sidekick cli show`
- **THEN** the leaf function at `commands.cli.show` SHALL be invoked

#### Scenario: Deeper path resolves to a leaf
- **WHEN** the user runs `:Sidekick debug nes inspect`
- **THEN** the leaf function at `commands.debug.nes.inspect` SHALL be invoked

### Requirement: NES subcommands dispatch to the nes module

The `nes` branch SHALL expose the leaves `apply`, `enable`, `disable`, `toggle`, `update`,
`clear`, and `jump`. Each leaf SHALL dispatch to the correspondingly named function of
`require("sidekick.nes")`, except that `enable` SHALL call `nes.enable(true)` and `disable`
SHALL call `nes.enable(false)`. These leaves SHALL ignore any parsed arguments and SHALL NOT
forward them to the nes module. This capability SHALL NOT define what those nes operations do.

#### Scenario: Enabling and disabling next edit suggestions
- **WHEN** the user runs `:Sidekick nes enable` or `:Sidekick nes disable`
- **THEN** `require("sidekick.nes").enable` SHALL be called with `true` or `false` respectively

#### Scenario: Other nes leaves
- **WHEN** the user runs `:Sidekick nes <apply|toggle|update|clear|jump>`
- **THEN** the identically named function of `require("sidekick.nes")` SHALL be called with no
  arguments

### Requirement: CLI subcommands dispatch to the cli module with parsed options

The `cli` branch SHALL expose the leaves `show`, `toggle`, `hide`, `close`, `focus`, `select`,
`send`, and `prompt`. Each of these SHALL dispatch to the correspondingly named function of
`require("sidekick.cli")`. All of them except `prompt` SHALL forward the parsed argument table
as the single `opts` argument; `prompt` SHALL be called with no arguments. This capability SHALL
NOT define what those cli operations do.

#### Scenario: Arguments become the opts table
- **WHEN** the user runs `:Sidekick cli show name=claude`
- **THEN** the call SHALL be equivalent to
  `require("sidekick.cli").show({ name = "claude" })`

#### Scenario: Prompt takes no options
- **WHEN** the user runs `:Sidekick cli prompt name=claude`
- **THEN** `require("sidekick.cli").prompt()` SHALL be called without the parsed arguments

### Requirement: Debug subtree

The tree SHALL contain a `debug` branch with a nested `nes` branch exposing the leaves `add`,
`del`, `patch`, `edit`, and `inspect`, dispatching to `nes_add`, `nes_del`, `nes_patch`,
`nes_edit`, and `nes_inspect` of `require("sidekick.debug")` respectively. These leaves SHALL be
invocable by typing their full path even though the `debug` branch is hidden from completion.

#### Scenario: Debug leaf is invocable
- **WHEN** the user runs `:Sidekick debug nes patch`
- **THEN** `require("sidekick.debug").nes_patch()` SHALL be called

### Requirement: Command path resolution

`M.parse` SHALL split the argument string on runs of whitespace and SHALL consume leading parts
while the current tree node is a table containing that part as an exact key. Matching SHALL be
by exact key name only; a partial name such as `cli sh` SHALL NOT resolve to a leaf. When
resolution reaches a function, `parse` SHALL return that function together with the parsed
arguments built from the remaining parts rejoined with single spaces. When resolution stops on a
table, `parse` SHALL instead return the list of candidate keys of that table that match the next
typed part as a prefix, excluding the key `debug`. Candidate matching SHALL use `string.find`
without the plain flag, so the typed part is interpreted as a Lua pattern anchored at the start
of the key rather than as a literal prefix; completion inherits that behavior.

#### Scenario: Full path with arguments
- **WHEN** `parse("cli show name=copilot")` is called
- **THEN** it SHALL return `commands.cli.show` and the argument table `{ name = "copilot" }`

#### Scenario: Partial path returns candidates
- **WHEN** `parse("cli s")` is called
- **THEN** it SHALL return the candidate list `select`, `show`, `send`

#### Scenario: Typed part is matched as a Lua pattern
- **WHEN** `parse("cli s.")` is called
- **THEN** it SHALL return the candidates `select`, `show`, and `send`, because `s.` is matched
  as an unescaped Lua pattern from the first character of each key

#### Scenario: Unknown first part
- **WHEN** `parse("bogus")` is called
- **THEN** it SHALL return an empty candidate list, because no root key starts with `bogus`

#### Scenario: Empty input lists the root
- **WHEN** `parse("")` is called
- **THEN** it SHALL return the root candidates `cli` and `nes`

### Requirement: Arguments are parsed as a Lua chunk in a permissive environment

`M.argparse` SHALL parse the trailing argument string by loading it as a text-only Lua chunk and
running it in a dedicated environment, returning a table of the values it assigned. Assignments
to names not already present in that environment SHALL be captured as entries of the result
table, so `key = value` pairs separated by whitespace become table fields; values MAY be any Lua
expression, including table constructors such as `tags={"a","b","c"}` or
`foo = { a = 1, b = 2 }`, and whitespace around `=` SHALL be allowed. Reading an undefined name
in that environment SHALL yield the name itself as a string, so bare identifiers act as unquoted
string values and never raise an error. The environment SHALL pre-populate `vim`, so argument
expressions MAY call Neovim APIs. An empty argument string SHALL produce an empty table.

#### Scenario: Bare identifiers and booleans
- **WHEN** `argparse("name=copilot focus=true")` is called
- **THEN** it SHALL return `{ name = "copilot", focus = true }`, with `copilot` captured as the
  string `"copilot"` and `true` as the boolean

#### Scenario: Table values
- **WHEN** `argparse('name=copilot tags={"a","b","c"}')` is called
- **THEN** it SHALL return `{ name = "copilot", tags = { "a", "b", "c" } }`

#### Scenario: No arguments
- **WHEN** `argparse("")` is called
- **THEN** it SHALL return an empty table and SHALL NOT report an error

### Requirement: Invalid argument syntax is reported and aborts the command

When the argument string fails to compile, or raises an error while running, `M.argparse` SHALL
return `nil`. Unless the caller passes `error = false`, it SHALL report an error notification
whose text is `Invalid args: ` followed by the offending argument string in backticks and a
second line `Error: ` followed by the underlying Lua message. When arguments fail to parse, `M.cmd` SHALL
NOT invoke the resolved leaf and SHALL NOT emit any additional `Invalid command` error for the
same input.

#### Scenario: Malformed assignment
- **WHEN** the user runs `:Sidekick cli show focus=`
- **THEN** exactly one error matching `Invalid args` SHALL be reported and
  `require("sidekick.cli").show` SHALL NOT be called

#### Scenario: Silent parsing for completion
- **WHEN** `argparse` is called with `error = false` on a malformed string
- **THEN** it SHALL return `nil` and SHALL NOT report any error

### Requirement: Command-line completion

`M.complete` SHALL take the current command line, strip a leading `Sidekick` token together with
surrounding whitespace, and resolve the remainder with argument errors suppressed. It SHALL
return the candidate key list when resolution stops on a table, and an empty list otherwise
(including when the path already resolves to a leaf). The `debug` key SHALL be omitted from
every candidate list, so the debug subtree is not discoverable through completion; once `debug`
is typed explicitly, its own child keys SHALL be offered.

#### Scenario: Completing the root
- **WHEN** completion runs for the line `Sidekick `
- **THEN** it SHALL offer `cli` and `nes` and SHALL NOT offer `debug`

#### Scenario: Completing a prefix
- **WHEN** completion runs for the line `Sidekick cli s`
- **THEN** it SHALL offer `select`, `show`, and `send`

#### Scenario: No candidates
- **WHEN** completion runs for the line `Sidekick unknown`
- **THEN** it SHALL return an empty list

#### Scenario: Completion never notifies
- **WHEN** completion runs for a line whose trailing arguments are not valid Lua
- **THEN** no error notification SHALL be shown

### Requirement: Incomplete and invalid command reporting

`M.cmd` SHALL distinguish incomplete from invalid input. When resolution stops on a table that
still has at least one candidate, it SHALL report an error reading `Incomplete command: `
followed by the typed arguments in backticks and a second line `Expecting: ` followed by the
candidate names joined with `|` inside square brackets, also in backticks. When resolution
yields neither a leaf function nor any candidate, it SHALL report `Invalid command: ` followed
by the typed arguments in backticks. In both cases no
leaf SHALL be invoked. A missing argument string SHALL be treated as the empty string in these
messages.

#### Scenario: Branch typed without a leaf
- **WHEN** the user runs `:Sidekick cli`
- **THEN** an `Incomplete command` error SHALL be reported and SHALL list the available `cli`
  subcommands

#### Scenario: Unknown command
- **WHEN** the user runs `:Sidekick bogus`
- **THEN** exactly one error matching `Invalid command` SHALL be reported and no leaf SHALL run

### Requirement: Visual selection restored for ranged invocations

When `:Sidekick` is invoked with a range, `M.cmd` SHALL restore the previous visual selection
before invoking the resolved leaf, by feeding `gv` with the `nx` mode flags, so the keys are
not remapped and are executed immediately. When the
command is invoked without a range, the selection SHALL NOT be re-entered. This allows
selection-aware operations such as `:'<,'>Sidekick cli send msg="{selection}"` to observe the
marked region.

#### Scenario: Ranged invocation
- **WHEN** the user runs `:'<,'>Sidekick cli send msg="{selection}"`
- **THEN** the visual selection SHALL be reselected before
  `require("sidekick.cli").send` is called with `{ msg = "{selection}" }`

#### Scenario: Plain invocation
- **WHEN** the user runs `:Sidekick cli send msg="hello"`
- **THEN** no visual selection SHALL be re-entered and the leaf SHALL be invoked directly
