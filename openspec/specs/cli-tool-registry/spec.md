# CLI Tool Registry

## Purpose

Defines how AI CLI tools are declared, resolved and discovered: the tool definition schema,
how a bundled default definition is loaded from the runtime path and merged with the user's
`cli.tools` overrides, how sidekick decides whether a tool is installed, and how the running
process table is scanned so an already-running CLI can be matched back to a tool definition
and to a working directory.

## Requirements

### Requirement: Tool definition schema

A tool definition SHALL be a plain Lua table. The only required field is `cmd`, a list of
strings whose first element is the executable that is looked up in `PATH` and whose remaining
elements are the arguments the tool is started with. A definition MAY also declare `env`
(a map of environment variables, where a value of `false` means the variable is unset for the
tool rather than assigned), `url` (a web page opened when the tool is not installed), `keys`
(per-tool keymap entries, each either a keymap table or `false` to disable the like-named
default), `is_proc` (a Vim regex string or a predicate function used to recognise a running
process as this tool), `format` (a hook that rewrites prompt text before it is sent),
`mux_focus` (the tool must be focused before it can receive input), and `native_scroll`
(the tool handles scrolling itself, so sidekick's scrollback SHALL NOT take over).

Fields the current implementation does not interpret SHALL be preserved on the resolved tool
rather than rejected; the bundled `claude`, `codex`, `copilot` and `pi` definitions carry
`resume` and `continue` argument lists, and `opencode` carries `continue` alone, all of which are
stored and not acted on.

#### Scenario: Minimal definition

- **WHEN** a definition declares only `cmd`
- **THEN** the tool SHALL resolve successfully and no default SHALL be substituted for `env`,
  `url` or `keys`
- **AND** because a resolved tool always exposes `is_proc` and `format` as methods (the declared
  matcher and hook are kept on the tool's `config`), they SHALL behave as "matches no process"
  and "send the plain rendering"

#### Scenario: Environment variable set and unset

- **WHEN** a definition declares `env = { OPENCODE_THEME = "system", SOME_VAR = false }`
- **THEN** the tool SHALL be started with `OPENCODE_THEME` set to `system`
- **AND** `SOME_VAR` SHALL be removed from the tool's environment instead of being given a value

#### Scenario: Per-tool keymap override

- **WHEN** a definition declares `keys = { prompt = { "<a-p>", "prompt" } }`, as the bundled
  `crush` and `opencode` definitions do
- **THEN** that entry SHALL replace the like-named default window keymap for this tool only
- **AND** an entry whose value is `false` SHALL result in no keymap being set for that name

#### Scenario: Unrecognised fields survive resolution

- **WHEN** a definition declares a field the implementation does not read, such as `resume`
- **THEN** resolving the tool SHALL NOT fail and the field SHALL still be readable on the
  resolved tool

### Requirement: Default definitions loaded from the runtime path

Resolving a tool named `<name>` SHALL look for `sk/cli/<name>.lua` on the Neovim runtime path
and use the first match found, so a file placed earlier on the runtime path SHALL shadow the
bundled definition of the same name. The file SHALL be executed and its returned table used as
the tool's default definition. Loading SHALL be lazy, happening on the first resolution of that
name, and a successfully loaded default SHALL be cached for the remainder of the Neovim session.

A name with no such file, a file that raises while loading, and a file that returns anything
other than a table SHALL all be treated as "no defaults" without raising or notifying, and
SHALL NOT be cached, so a later resolution retries.

#### Scenario: Bundled tool resolves its defaults

- **WHEN** the tool `claude` is resolved for the first time
- **THEN** `sk/cli/claude.lua` SHALL be executed and its `cmd`, `is_proc`, `url` and `format`
  SHALL become the tool's defaults

#### Scenario: Tool with no bundled definition

- **WHEN** a tool name has no `sk/cli/<name>.lua` anywhere on the runtime path
- **THEN** resolution SHALL succeed with the user's configuration as the tool's only source of
  fields, and no error SHALL be reported

#### Scenario: Broken definition file

- **WHEN** `sk/cli/<name>.lua` raises an error or returns a non-table value
- **THEN** resolution SHALL continue as if the file did not exist, and the failure SHALL NOT be
  cached

#### Scenario: Defaults are loaded once

- **WHEN** the same tool is resolved repeatedly
- **THEN** its definition file SHALL be executed at most once per Neovim session

### Requirement: Tool field resolution and merging

A resolved tool SHALL be the deep merge of its default definition with the user's
`cli.tools.<name>` table, with the user's values winning on conflict. Nested tables such as
`keys` and `env` SHALL be merged key by key rather than replaced wholesale. Because
`cli.tools.<name>` defaults to `{}` for every built-in tool, an empty override table SHALL
leave every default field intact.

Resolution SHALL work on copies, so neither the cached default definition nor the user's
configuration is mutated by resolving or using a tool. A resolved tool SHALL carry its own
`name`. A resolved tool SHALL also be cloneable with a set of overrides deep-merged on top,
producing an independent tool (used, for example, to substitute a session's own `cmd` and `env`
when attaching) without changing the registry entry it came from.

A resolved tool SHALL keep the whole merged definition on its own `config` field, and the
declared `is_proc` and `format` hooks SHALL live there and nowhere else: on the tool itself
those two names SHALL always resolve to the registry's methods instead, so `tool:is_proc(proc)`
and `tool:format(text)` are callable for every tool and read the declared hooks from `config`.
Every other merged field, `cmd` and `env` and `url` and `keys` among them, SHALL be readable
directly on the tool as well. Because the matcher is memoised into `config` on first use, that
memoisation SHALL be per resolved tool rather than shared between resolutions.

#### Scenario: Empty override keeps defaults

- **WHEN** `cli.tools.claude` is `{}`
- **THEN** the resolved `claude` tool SHALL still have the bundled `cmd` and `url`, and its
  `config` SHALL still carry the bundled `is_proc` and `format`

#### Scenario: Partial override

- **WHEN** the user sets `cli.tools.claude = { cmd = { "claude", "--foo" } }`
- **THEN** the resolved tool's `cmd` SHALL be `{ "claude", "--foo" }`
- **AND** its `url` SHALL still come from the bundled definition, as SHALL the `is_proc` and
  `format` hooks its `config` carries

#### Scenario: Cloning does not affect the registry

- **WHEN** a resolved tool is cloned with a different `cmd`
- **THEN** the clone SHALL use the new `cmd` and the next resolution of that tool name SHALL
  still yield the merged registry values

### Requirement: Registry membership and adding a new tool

The set of known tools SHALL be exactly the keys of `cli.tools`. The defaults populate the
twelve names `aider`, `amazon_q`, `claude`, `codex`, `copilot`, `crush`, `cursor`, `gemini`,
`grok`, `opencode`, `pi` and `qwen`, each with an empty override table. A user adds a brand-new
tool by adding a key to `cli.tools` with at least a `cmd`; no `sk/cli` file is required, and the
new tool SHALL be listed and started like a built-in one, and matched to a running process too
when it declares `is_proc`. Because the user table is merged into the defaults, every built-in
key SHALL remain present, and a built-in key whose value is not a table SHALL be treated as an
empty override that resolves to the bundled defaults rather than removing the tool.

#### Scenario: User adds a custom tool

- **WHEN** the user sets `cli.tools.my_tool = { cmd = { "my-ai-cli", "--flag" } }`
- **THEN** `my_tool` SHALL appear alongside the built-in tools in listings and health output
- **AND** it SHALL be startable using that command

#### Scenario: Built-in names cannot be dropped by omission

- **WHEN** the user supplies a `cli.tools` table naming only some tools
- **THEN** the tools they did not name SHALL still be present with their bundled defaults

### Requirement: Session backends registered by tool definition files

A tool definition file SHALL be executed when the tool is first resolved, and it MAY register a
session backend for itself as a side effect before returning its definition table.
Session setup SHALL therefore resolve all configured tools before registering the built-in
backends, so any backend a tool file registers is in place. A tool file MAY guard that
registration on the platform and on the presence of external commands, and when the guard fails
the tool itself SHALL remain fully usable through the ordinary backends.

#### Scenario: Opencode registers its own backend

- **WHEN** the `opencode` tool is resolved on a non-Windows system where `lsof` is executable
- **THEN** an `opencode` session backend SHALL be registered in addition to the tool definition
  being returned

#### Scenario: Guard fails

- **WHEN** `opencode` is resolved on Windows, or where `lsof` is not executable
- **THEN** no `opencode` session backend SHALL be registered, no error SHALL be raised, and the
  `opencode` tool SHALL still be listed and startable

### Requirement: Installed detection and fallback when a tool cannot be run

A tool's availability SHALL be decided solely by an executable lookup of the first element of
its `cmd` on the current `PATH`: found means installed, not found means missing. No other field
of the definition SHALL affect availability, so a definition whose `cmd` names an absolute path
or a wrapper script is installed exactly when that path is executable. A tool that was
discovered as a running session SHALL be treated as installed without a lookup, since it is
already running. Availability SHALL be a reported state rather than a filter: a missing tool
SHALL still be a known tool (how candidates are then filtered and ordered belongs to the CLI
session management capability).

The `url` field SHALL be the definition's declaration of where a user is sent when the tool
cannot be run: when a missing tool is chosen, that URL SHALL be opened in the user's browser,
and a definition without a `url` SHALL simply have nothing opened (the surrounding rejection and
its messages belong to the CLI session management capability). Every bundled definition SHALL
declare a `url` pointing at the tool's own project or documentation page.

When a start attempt fails despite the tool being chosen, the reported cause SHALL be
distinguished by re-checking `cmd[1]`: not executable SHALL be reported as the command not being
installed, and otherwise the full command SHALL be reported as having failed to run.

#### Scenario: Executable present

- **WHEN** a tool's `cmd[1]` is found on `PATH`
- **THEN** the tool SHALL be reported as installed

#### Scenario: Executable absent

- **WHEN** a tool's `cmd[1]` is not found on `PATH`
- **THEN** the tool SHALL be reported as missing and SHALL still be a known, listable tool

#### Scenario: Missing tool with a url

- **WHEN** a tool that is not installed is chosen and its definition declares `url`
- **THEN** that URL SHALL be opened in the browser

#### Scenario: Start fails for another reason

- **WHEN** starting a tool fails although `cmd[1]` is executable
- **THEN** the reported error SHALL name the full command rather than claiming the command is
  not installed

### Requirement: Unknown tool names

Resolving a name that is not a key of `cli.tools` and has no `sk/cli/<name>.lua` SHALL NOT
raise; it SHALL produce a tool carrying that name and no fields. Such a name is not part of the
registry, so it SHALL never appear in listings, and filtering the tool list by it SHALL match
nothing. When a filter matches no tools, the user SHALL be told that no tools match the filter
rather than being shown an error about the name.

#### Scenario: Filtering by an unknown name

- **WHEN** the user asks for a tool name that is not configured
- **THEN** the tool list SHALL be empty and a warning SHALL state that no tools match the given
  filter

#### Scenario: Resolution is not fatal

- **WHEN** an unknown name is resolved directly
- **THEN** a tool object with that name SHALL be returned instead of an error being raised

### Requirement: Matching a running process to a tool

A tool SHALL be matched against a running process through its `is_proc` field. When `is_proc` is
a string it SHALL be compiled as a Vim regex and matched against the process's full command
line, and the compiled matcher SHALL be reused for subsequent checks on the same resolved tool.
When `is_proc` is a function it SHALL be called with the tool and the process and its result
interpreted as a boolean. When `is_proc` is absent or of any other type the tool SHALL never
match any process.

Bundled definitions use word-boundary regexes such as `\<claude\>` or `\<opencode\>` so that a
tool is not matched by an unrelated command that merely contains its name, and a definition MAY
use the function form to add exclusions - the `copilot` definition matches `\<copilot\>` but
SHALL NOT match a command line containing `language-server`. When several tools are tried
against one process, the first tool that matches SHALL claim it and no further tool SHALL be
tried; the registry is iterated in unspecified order, so which of several matching tools claims
the process is not defined. `is_proc` matching against the scanned process table SHALL be the
tmux backend's way of naming a tool and the only consumer of the field, while the herdr backend
names its tool by the agent kind herdr reports and the opencode backend by the process name, so
those two SHALL find their sessions whether or not the tool declares `is_proc`.

#### Scenario: Regex match

- **WHEN** a running process's command line is `claude`
- **THEN** the `claude` tool SHALL match it

#### Scenario: Function form with an exclusion

- **WHEN** a running process's command line names `copilot` but also contains
  `language-server`
- **THEN** the `copilot` tool SHALL NOT match it

#### Scenario: Tool without a matcher

- **WHEN** a tool definition declares no `is_proc`
- **THEN** it SHALL never be matched to a running process, and it SHALL only ever be available
  as a tool to start

#### Scenario: Backend that does not consult `is_proc`

- **WHEN** a running session is discovered by the herdr or opencode backend rather than by the
  tmux process walk
- **THEN** the tool SHALL be named without `is_proc` being consulted at all

### Requirement: Scanning the running process table

The process table SHALL be built by listing the current user's processes with `ps`, requesting
pid, parent pid and the full argument list with wide output, skipping the header line, and
restricting to `$USER` only when that variable is non-empty. Each entry SHALL expose its `pid`,
`ppid` and `cmd`, and the table SHALL expose parent and child links, breadth-first traversal
from a given pid where the visiting callback MAY stop the walk by returning true, and lookup of
entries by predicate or by pattern, where a pattern SHALL be a Lua pattern searched for in the
command line and not a Vim regex as `is_proc` takes.

When `ps` is not executable, or on Windows, the table SHALL be empty and process-based discovery
SHALL simply find nothing rather than raising; the absence of `ps` or `lsof` is surfaced to the
user by the plugin diagnostics capability.

#### Scenario: Table is populated

- **WHEN** the process table is created on a system with `ps`
- **THEN** it SHALL contain one entry per listed process of the current user, each with its pid,
  parent pid and full command line

#### Scenario: Walk stops early

- **WHEN** a walk from a root pid is given a callback that returns true for some descendant
- **THEN** the walk SHALL stop at that descendant and SHALL NOT visit the remaining ones

#### Scenario: ps unavailable

- **WHEN** `ps` is not executable
- **THEN** the process table SHALL be empty, discovery SHALL report no running CLI sessions, and
  no error SHALL be raised

### Requirement: Resolving a matched process to a tool and a directory

Discovering an already-running CLI SHALL work by walking a candidate root's process tree and
testing each process against every configured tool, stopping at the first process that matches
so one root yields at most one tool. A match SHALL yield the resolved tool it matched, the
matched process's working directory falling back to the walked root's own working directory when
the process's is unknown, and the descendant pid set of the walked root's process tree, which the
backend MAY extend with the pids of the multiplexer clients attached to that root. The pid set
is what lets the same running agent seen through two backends be recognised as one (the dedup
and ordering policy itself belongs to the CLI session management capability).
Matching SHALL work equally for a CLI the user started by hand and one sidekick started, since
nothing but the process's command line is consulted.

#### Scenario: Hand-started CLI is matched

- **WHEN** the user started a configured CLI themselves and it is still running under a scanned
  root
- **THEN** the walk SHALL match it to that tool and surface the tool, the process's working
  directory or the root's when the process's is unknown, and the root's descendant pid set

#### Scenario: First match wins

- **WHEN** more than one configured tool would match a process in the walked tree
- **THEN** exactly one of them SHALL claim it and the walk SHALL stop; which one is not defined,
  since the registry is iterated in unspecified order

#### Scenario: Nothing matches

- **WHEN** no process under the walked root matches any configured tool
- **THEN** no session SHALL be reported for that root and no error SHALL be raised

### Requirement: Process working directory, pids and environment

A process's working directory SHALL be resolved from `/proc/<pid>/cwd` where a `/proc`
filesystem is available, and otherwise by asking `lsof` for that pid's cwd descriptor; the
result SHALL be normalised to a canonical path. A process's environment SHALL be resolved from
`/proc/<pid>/environ` where available and, whenever `ps` is executable, also from
`ps eww -p <pid>` with the `ps` values winning; when `ps` is not executable no environment SHALL
be reported at all, even where `/proc` supplied values. Both SHALL be resolved on demand the
first time they are read for a process entry and then cached, including the negative result, so
repeated reads do not re-run the external command. When neither source is available the working
directory SHALL be unknown rather than guessed.

The descendant pid set of a process SHALL include the process itself plus all of its
transitive children.

The environment lookup SHALL be exposed for `is_proc` functions and other callers that want it;
nothing in the plugin reads it today, so it SHALL NOT be assumed to run on any live discovery
path, whereas the working directory lookup SHALL be read for every matched process.

#### Scenario: Working directory on Linux

- **WHEN** the working directory of a discovered process is requested and `/proc` is available
- **THEN** it SHALL be read from that process's `/proc` cwd link and normalised

#### Scenario: Working directory without /proc

- **WHEN** `/proc` is unavailable but `lsof` is executable
- **THEN** the working directory SHALL be obtained from `lsof` and normalised

#### Scenario: Working directory unavailable

- **WHEN** neither `/proc` nor `lsof` can supply a working directory
- **THEN** the process's working directory SHALL be reported as unknown and discovery SHALL
  still report the session

#### Scenario: Repeated reads are cached

- **WHEN** a process's working directory or environment is read more than once
- **THEN** the external lookup SHALL happen at most once for that process entry in a given
  process table

### Requirement: Per-tool prompt text formatting

Sending text through a tool SHALL first render the structured text to a string. When the tool
declares a `format` hook, the hook SHALL be called with both the structured text and that
string; if it returns a string, that string SHALL be sent, and if it returns nothing the
structured text SHALL be re-rendered, so a hook that rewrites the text in place still takes
effect. A tool without a `format` hook SHALL send the plain rendering.

#### Scenario: No hook

- **WHEN** a tool declares no `format`
- **THEN** the plain rendering of the text SHALL be sent unchanged

#### Scenario: Hook returns a rewritten string

- **WHEN** the `claude` tool formats text containing a file location with a line range
- **THEN** file references containing characters outside word characters, `/`, `_`, `.` and `-`
  SHALL be quoted, and a ` :L<start>-L<end>` suffix on an `@`-prefixed reference SHALL be
  rewritten to `#L<start>-<end>`

#### Scenario: Hook mutates in place and returns nothing

- **WHEN** the `gemini` or `qwen` tool formats text, escaping non-word characters in file
  locations and returning nothing
- **THEN** the escaped text SHALL be re-rendered and the escaped form SHALL be sent
