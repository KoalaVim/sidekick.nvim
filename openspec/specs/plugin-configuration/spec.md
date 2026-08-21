# Plugin Configuration

## Purpose

Defines the plugin entry point and configuration system: the `setup(opts)` call that merges user
options over the shipped defaults, the option surface itself, the deferred initialization that
wires up state, highlights, autocommands and status tracking, the validation of enum-valued
options, and the read-through accessor plus shared helpers that the rest of the plugin resolves
configuration and Copilot clients through.

## Requirements

### Requirement: Public plugin API

The `sidekick` module SHALL expose exactly three entry points: `setup(opts)`, which forwards to the
configuration system; `clear()`, which clears any active next edit suggestion; and
`nes_jump_or_apply()`, which jumps to or applies the pending next edit suggestion. Loading the
module SHALL NOT by itself configure the plugin or create any autocommand; all wiring SHALL happen
in `setup`.

#### Scenario: Setup forwards to the configuration system

- **WHEN** the user calls `require("sidekick").setup(opts)`
- **THEN** the configuration system SHALL be set up with `opts` and the plugin SHALL become active

#### Scenario: Clear discards the pending suggestion

- **WHEN** the user calls `require("sidekick").clear()`
- **THEN** any displayed next edit suggestion SHALL be cleared

#### Scenario: Jump or apply reports whether it acted

- **WHEN** `nes_jump_or_apply()` is called while a suggestion is active
- **THEN** it SHALL first attempt to jump to the suggestion, and if the cursor is already at the
  suggestion it SHALL apply the edit instead
- **AND** it SHALL return `true` when it jumped or applied

#### Scenario: Nothing to jump to or apply

- **WHEN** `nes_jump_or_apply()` is called and no suggestion is active for the current buffer, or
  neither jumping nor applying succeeds
- **THEN** it SHALL return `false` and SHALL leave the buffer and cursor untouched

### Requirement: Deep-merged user options

`setup(opts)` SHALL build the effective configuration by deep-merging `opts` over a fresh copy of
the shipped defaults, with user values winning on conflict. Omitting `opts` (or passing `nil`)
SHALL yield the defaults unchanged. Nested tables SHALL be merged key by key so that a user may
override a single leaf option without restating its siblings, while list-valued options such as
`nes.trigger.events` SHALL be replaced wholesale rather than appended to. Each `setup` call SHALL
recompute the configuration from the defaults, so options set by a previous call and omitted by the
current one SHALL revert to their defaults. The defaults themselves SHALL NOT be mutated by a
`setup` call.

#### Scenario: Partial nested override

- **WHEN** the user calls `setup({ cli = { win = { layout = "float" } } })`
- **THEN** `cli.win.layout` SHALL be `"float"` and every other `cli.win` option, including `keys`
  and `split`, SHALL keep its default value

#### Scenario: No options passed

- **WHEN** `setup()` is called with no arguments
- **THEN** the effective configuration SHALL equal the shipped defaults

#### Scenario: List option replaced, not merged

- **WHEN** the user sets `nes.trigger.events` to a single-entry list
- **THEN** the effective trigger events SHALL be exactly that list and SHALL NOT retain the default
  entries

#### Scenario: Re-running setup

- **WHEN** `setup` is called a second time with a different table
- **THEN** the configuration SHALL reflect the new table merged over the defaults, and options only
  present in the first call SHALL be back at their defaults

### Requirement: Option surface and defaults

The configuration SHALL consist of the top-level groups `nes`, `cli`, `copilot`, `ui`, and the
scalar `debug`, which SHALL default to `false` and gate debug logging. The notable defaults SHALL
be:

- `nes.enabled`: a predicate that reports enabled unless `vim.g.sidekick_nes` or
  `vim.b.sidekick_nes` is `false`; `nes.debounce` is `100`; `nes.clear.esc`, `nes.signs` and
  `nes.jumplist` are `true`; `nes.diff.inline` is `"words"` and `nes.diff.show` is `"always"`
- `cli.watch` is `true`; `cli.win.layout` is `"right"`; `cli.win.float` is 0.9 of width and height;
  `cli.win.split` is 80 columns by 20 lines; `cli.picker` is `"snacks"`; `cli.context` and the
  `cli.win.wo`/`cli.win.bo` option tables are empty
- `cli.mux.enabled` is `false`, `cli.mux.create` is `"terminal"`, `cli.mux.dump` is `2000`, and
  `cli.mux.backend` is auto-detected from the environment as described by the mux backend
  capabilities
- `cli.tools` lists the built-in tool names, each with an empty override table, and `cli.prompts`
  ships a set of named prompt templates
- `copilot.status.enabled` is `true` with `copilot.status.level` at `vim.log.levels.WARN`, where
  `vim.log.levels.OFF` disables the notifications
- `ui.icons` provides the icon used for next edit suggestions (`nes`) and the icons for the CLI
  session states `attached`, `started`, `installed` and `missing`, plus external and terminal
  variants of the attached and started states only

Option groups SHALL be additive in the sense that any tool, prompt, context provider or keymap the
user adds under `cli` SHALL be preserved alongside the shipped entries, and a shipped `cli.win.keys`
entry SHALL be disabled by setting it to `false`.

#### Scenario: Defaults observed without configuration

- **WHEN** the plugin is set up with no options
- **THEN** reading `cli.win.layout` SHALL yield `"right"`, `cli.mux.enabled` SHALL be `false`,
  `nes.debounce` SHALL be `100`, and `debug` SHALL be `false`

#### Scenario: Adding to a keyed option group

- **WHEN** the user adds a tool under `cli.tools` or a prompt under `cli.prompts`
- **THEN** the added entry SHALL be available in addition to the shipped entries

#### Scenario: Debug logging gate

- **WHEN** `debug` is `true`
- **THEN** debug messages SHALL be surfaced as notifications; when it is `false` they SHALL be
  suppressed

### Requirement: Read-through configuration accessor

The `sidekick.config` module SHALL act as the single read-through accessor for the effective
configuration: reading any option group as a field of the module SHALL return the corresponding
value from the merged configuration, without the caller needing to know whether `setup` has run.
Before `setup` is called, the accessor SHALL return the shipped defaults. After a `setup` call, all
readers SHALL observe the new values without re-resolving anything. Reading a key that is neither a
configuration key nor a module member SHALL yield `nil`.

#### Scenario: Reading configuration before setup

- **WHEN** a module reads a configuration option and `setup` has not been called
- **THEN** the default value SHALL be returned rather than `nil` or an error

#### Scenario: Reading configuration after setup

- **WHEN** `setup` has been called with user options
- **THEN** subsequent reads through the accessor SHALL return the merged values

#### Scenario: Module members are not shadowed

- **WHEN** a caller reads a helper or resource exposed by the module, such as its highlight
  namespace or augroup
- **THEN** the module member SHALL be returned rather than a configuration lookup

### Requirement: Sidekick user command registration

`setup` SHALL register the `:Sidekick` user command synchronously, before any deferred
initialization, so the command is usable as soon as `setup` returns. The command SHALL accept a
range, SHALL take at most one argument (`nargs = "?"`), SHALL carry the description `Sidekick`, and
SHALL provide command-line completion. Invoking the command SHALL dispatch to the commands
capability with the received command arguments, and completion SHALL be delegated to the same
capability with the current command line; the set of subcommands and their behavior belongs to the
commands capability.

#### Scenario: Command available after setup

- **WHEN** `setup` returns
- **THEN** `:Sidekick` SHALL be a registered user command

#### Scenario: Invoking with a subcommand over a range

- **WHEN** the user runs `:'<,'>Sidekick <subcommand>`
- **THEN** the command SHALL dispatch to the commands capability with the range and the single
  argument

#### Scenario: Completion at the command line

- **WHEN** the user requests completion for `:Sidekick `
- **THEN** the candidates SHALL be produced by the commands capability from the current command line

### Requirement: Deferred initialization

After merging options and registering the user command, `setup` SHALL schedule the remaining
initialization to run on the next event loop iteration rather than performing it inline, so that
`setup` never blocks startup and so that other plugins and the color scheme may finish loading
first. The scheduled work SHALL, in order: create the plugin state directory, define the plugin
highlight groups, register the color scheme and window-focus autocommands, enable next edit
suggestions when configured, set up status tracking, and validate the enum-valued options.

#### Scenario: Setup does not block

- **WHEN** `setup` is called
- **THEN** it SHALL return before the state directory, highlight groups, autocommands, next edit
  suggestions and status tracking are set up

#### Scenario: Initialization completes on the next tick

- **WHEN** the event loop next runs after `setup`
- **THEN** the state directory SHALL exist, the highlight groups SHALL be defined, the color scheme
  and window-focus autocommands SHALL be registered, status tracking SHALL be active, and the
  enum-valued options SHALL have been validated

#### Scenario: Status tracking is always set up

- **WHEN** deferred initialization runs
- **THEN** status tracking SHALL be set up regardless of the `nes` settings, so that Copilot LSP
  status and CLI session status are observable

### Requirement: Conditional next edit suggestion enablement

Deferred initialization SHALL enable next edit suggestions unless `nes.enabled` is literally
`false`. Because the default `nes.enabled` is a predicate, the default configuration SHALL enable
them, with the predicate deciding per buffer at request time. Setting `nes.enabled = false` SHALL
leave next edit suggestions unwired at startup; they SHALL remain reachable through the plugin's
own enable and toggle entry points, which belong to the next edit suggestion capability.

#### Scenario: Enabled by default

- **WHEN** the plugin is set up without touching `nes.enabled`
- **THEN** next edit suggestions SHALL be enabled during deferred initialization

#### Scenario: Explicitly disabled

- **WHEN** the user sets `nes.enabled = false`
- **THEN** next edit suggestions SHALL NOT be enabled during deferred initialization

#### Scenario: Predicate or boolean true

- **WHEN** `nes.enabled` is a predicate function or `true`
- **THEN** next edit suggestions SHALL be enabled, and a predicate SHALL be consulted per buffer
  rather than at setup time

### Requirement: Highlight group definition

The plugin SHALL define its highlight groups as links to standard groups, using the `Sidekick`
prefix, and SHALL define each of them with `default` semantics so a color scheme or a user
definition always wins. The groups SHALL cover next edit suggestion diffs
(`SidekickDiffContext` linked to `DiffChange`, `SidekickDiffAdd` to `DiffText`, `SidekickDiffDelete`
to `DiffDelete`), the suggestion sign (`SidekickSign` to `Special`), the chat window
(`SidekickChat` to `NormalFloat`), CLI tool states (`SidekickCliMissing` and
`SidekickCliUnavailable` to `DiagnosticError`, `SidekickCliAttached` to `Special`,
`SidekickCliStarted` to `DiagnosticWarn`, `SidekickCliInstalled` to `DiagnosticOk`), and location
rendering (`SidekickLocDelim` to `Delimiter`, `SidekickLocFile` to `@markup.link`,
`SidekickLocNum` to `@attribute`, with `SidekickLocRow` and `SidekickLocCol` linked to
`SidekickLocDelim`). The highlight groups SHALL be re-applied whenever the `ColorScheme` event
fires, so that switching color schemes does not leave the plugin unstyled.

#### Scenario: Groups defined during initialization

- **WHEN** deferred initialization has run
- **THEN** every `Sidekick`-prefixed highlight group SHALL be defined as a default link to its
  standard group

#### Scenario: User override survives

- **WHEN** the user or a color scheme defines a `Sidekick`-prefixed highlight group explicitly
- **THEN** that definition SHALL take precedence over the plugin's default link

#### Scenario: Color scheme change

- **WHEN** the user switches color scheme
- **THEN** the plugin highlight groups SHALL be re-applied

### Requirement: Window visit tracking

The plugin SHALL record, per window, the time at which it was last focused, by stamping a window
variable on every `WinEnter`. This ordering information SHALL be used to present buffers and
windows most-recently-visited first, for example when building CLI context; a window that has never
been focused since startup SHALL be treated as least recently visited rather than causing an error.

#### Scenario: Focusing a window records a visit

- **WHEN** the user moves focus into a window
- **THEN** that window's last-visit timestamp SHALL be updated

#### Scenario: Ordering by recency

- **WHEN** consumers order windows by their recorded visit time
- **THEN** the most recently focused window SHALL sort first, and windows without a recorded visit
  SHALL sort last

### Requirement: Enum option validation

Deferred initialization SHALL validate the enum-valued options and report every invalid value as an
error notification, without aborting initialization or falling back to a default. The validated
options and their permitted values SHALL be `cli.win.layout` (`float`, `left`, `bottom`, `top`,
`right`), `cli.mux.backend` (`tmux`, `zellij`, `herdr`), `cli.mux.create` (`terminal`, `window`,
`split`), and `nes.diff.show` (`always`, `cursor`). The validator SHALL be reusable for type checks
as well: given a type name instead of a list of permitted values, it SHALL report when the option's
value is not of that type. Every report SHALL name the offending option path as `opts.<path>` and
SHALL include both the value found and what was expected, and the validator SHALL report whether
the option was valid.

#### Scenario: Valid configuration is silent

- **WHEN** every enum-valued option holds a permitted value
- **THEN** validation SHALL produce no notification

#### Scenario: Invalid enum value

- **WHEN** the user sets `cli.win.layout` to a value that is not one of the permitted layouts
- **THEN** an error notification SHALL name `opts.cli.win.layout`, show the value found, and list
  the permitted values

#### Scenario: Validation does not abort setup

- **WHEN** one or more enum-valued options are invalid
- **THEN** the remaining options SHALL still be validated and the rest of the initialization
  (state directory, highlights, autocommands, status) SHALL still have been performed

#### Scenario: Type mismatch

- **WHEN** the validator is asked to check an option against a type and the option holds a
  different type
- **THEN** an error notification SHALL state the expected type and the type found

### Requirement: Shared runtime resources

The configuration module SHALL own the runtime resources the rest of the plugin shares: a single
`sidekick` augroup, created when the module loads and cleared on creation so that reloading the
plugin does not accumulate duplicate autocommands; a `sidekick.ui` extmark namespace used for the
plugin's virtual text and signs; and a state-path helper that resolves a file name to a path inside
a `sidekick` directory under Neovim's state directory. The state directory SHALL be created during
deferred initialization, including any missing parents, so callers of the helper may write to the
returned path without creating directories themselves.

#### Scenario: Plugin autocommands share one group

- **WHEN** the plugin registers its color scheme, window-focus and status autocommands
- **THEN** they SHALL all belong to the `sidekick` augroup

#### Scenario: Reload does not duplicate autocommands

- **WHEN** the configuration module is loaded again
- **THEN** the `sidekick` augroup SHALL be cleared, so previously registered plugin autocommands
  SHALL NOT fire twice

#### Scenario: Resolving a state file path

- **WHEN** a caller asks for the state path of a file name
- **THEN** it SHALL receive that name inside the plugin's directory under Neovim's state directory,
  and that directory SHALL exist once initialization has run

### Requirement: Copilot LSP client discovery

The configuration module SHALL provide the plugin's single way of finding the Copilot language
server. A client SHALL be recognized as Copilot when its name contains `copilot`, compared
case-insensitively; the check SHALL accept either a client object or a bare client name. Client
lookup SHALL return every active language server client that passes that check, honoring an optional
standard client filter, and single-client lookup SHALL return the first Copilot client attached to a
given buffer, defaulting to the current buffer. When no Copilot client matches, single-client lookup
SHALL return `nil` rather than raising, so callers can degrade gracefully.

#### Scenario: Recognizing the Copilot client

- **WHEN** a client named `copilot`, `copilot_ls`, or `GitHub Copilot` is checked
- **THEN** it SHALL be recognized as Copilot, while a client such as `lua_ls` SHALL NOT be

#### Scenario: Clients attached to a buffer

- **WHEN** single-client lookup is called for a buffer with a Copilot client attached
- **THEN** that client SHALL be returned

#### Scenario: No Copilot available

- **WHEN** single-client lookup is called and no Copilot client is attached
- **THEN** it SHALL return `nil`

#### Scenario: Filtered listing

- **WHEN** client listing is called with a filter
- **THEN** only Copilot clients matching that filter SHALL be returned

### Requirement: Tool resolution helpers

The configuration module SHALL expose the resolution of a configured CLI tool name to a usable tool
definition, combining the tool's shipped configuration with the user's overrides from
`cli.tools[name]`, and SHALL expose the resolution of every configured tool at once as a table keyed
by tool name. The set of tools the plugin offers SHALL therefore be exactly the keys present in
`cli.tools` after merging, so a user adds a tool by adding a key; because the merge is additive, a
shipped tool SHALL NOT be removable through `setup`. How a tool definition is loaded and what
fields it carries belong to the CLI capability.

#### Scenario: Resolving a configured tool

- **WHEN** a caller resolves a tool by name
- **THEN** it SHALL receive that tool's definition with the user's `cli.tools` overrides applied

#### Scenario: Resolving all tools

- **WHEN** a caller resolves all tools
- **THEN** the result SHALL contain one resolved tool per key in `cli.tools`, keyed by tool name

#### Scenario: User-added tool is offered

- **WHEN** the user adds a key under `cli.tools`
- **THEN** that name SHALL appear among the resolved tools
