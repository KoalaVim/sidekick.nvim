# Plugin Diagnostics

## Purpose

Covers the diagnostic and maintenance surfaces of sidekick.nvim that are used to verify an
installation, to reproduce Next Edit Suggestion (NES) behavior while developing, and to keep
the user-facing documentation in sync with the code. Three concerns live here: the
`:checkhealth sidekick` report, the `debug` option together with the `:Sidekick debug nes ...`
developer commands, and the README documentation generator driven by `scripts/docs`.

## Requirements

### Requirement: Health report structure and Neovim version gate

`require("sidekick.health").check` SHALL provide the `:checkhealth sidekick` report, grouping
its findings into the sections `Sidekick`, `Sidekick Copilot LSP`, `Sidekick AI CLI`, and
`Sidekick AI CLI Tools`. Reporting SHALL go through Neovim's health API and SHALL remain
functional on installations that only expose the legacy `vim.health.report_*` names.

Neovim `>= 0.11.2` SHALL be reported as `ok`. A lower version SHALL be reported as an `error`
and SHALL abort the whole report, because every remaining check depends on APIs that version
introduces.

#### Scenario: Supported Neovim
- **WHEN** the user runs `:checkhealth sidekick` on Neovim 0.11.2 or newer
- **THEN** the report SHALL contain an `ok` entry stating that Neovim >= 0.11.2 is in use
- **AND** the Copilot LSP, AI CLI, and AI CLI Tools sections SHALL follow

#### Scenario: Unsupported Neovim
- **WHEN** the user runs `:checkhealth sidekick` on a Neovim older than 0.11.2
- **THEN** the report SHALL contain an `error` stating that Neovim >= 0.11.2 is required
- **AND** no further check SHALL run

### Requirement: Copilot LSP prerequisite verification

The health report SHALL verify that a Copilot language server is usable. A configuration whose
name contains `copilot` (case-insensitive) and that is enabled via `vim.lsp.enable` SHALL be
reported as `ok` by name. When no such configuration is enabled and no Copilot client is
running, the report SHALL raise an `error` stating that no Copilot LSP server is enabled with
`vim.lsp.enable(...)`.

For every running Copilot client the report SHALL state whether sidekick owns the client's
`didChangeStatus` handler: `ok` when the handler is sidekick's status handler, `error` when it
is not, since sidekick then cannot observe Copilot's status. When a running client's command
points into a `copilot.lua` or `copilot.vim` install, the report SHALL additionally note that
the plugin's bundled LSP server is in use. When Copilot clients with more than one distinct
name are running, the report SHALL raise an `error` listing those names.

#### Scenario: Enabled Copilot configuration
- **WHEN** `vim.lsp.enable("copilot")` has been called for a Copilot configuration
- **THEN** the report SHALL contain an `ok` entry naming that configuration as enabled

#### Scenario: No Copilot server
- **WHEN** no Copilot configuration is enabled and no Copilot client is attached
- **THEN** the report SHALL contain an `error` telling the user to enable a Copilot LSP server

#### Scenario: Status notifications hijacked
- **WHEN** a Copilot client is running but its `didChangeStatus` handler is not sidekick's
- **THEN** the report SHALL contain an `error` naming the client id whose status notifications
  sidekick is not handling

#### Scenario: Conflicting Copilot servers
- **WHEN** two Copilot clients with different names are running at the same time
- **THEN** the report SHALL contain an `error` listing the conflicting server names

### Requirement: Editor and multiplexer environment verification

The `Sidekick AI CLI` section SHALL report the environment that AI CLI sessions depend on.
`autoread` SHALL be reported as `ok` when enabled and as a `warn` when disabled, because file
changes made by AI CLI tools are then not picked up automatically. The current state of
`cli.mux.enabled` SHALL be reported as `ok` whether the integration is enabled or disabled.

For each known multiplexer (`tmux`, `zellij`, `herdr`) the report SHALL state `ok` when the
executable is found, `error` when it is missing and it is the configured `cli.mux.backend`, and
`ok` when it is missing but is not the configured backend. On non-Windows systems `ps` and
`lsof` SHALL be reported as `ok` when present and as a `warn` when absent, since running
processes and ports cannot then be detected; on Windows they SHALL NOT be checked.

#### Scenario: Configured backend missing
- **WHEN** `cli.mux.backend` is `"tmux"` and `tmux` is not installed
- **THEN** the report SHALL contain an `error` that the multiplexer backend is not installed

#### Scenario: Unused multiplexer missing
- **WHEN** `zellij` is not installed and is not the configured backend
- **THEN** the report SHALL contain an `ok` entry noting it is absent but not the configured
  backend

#### Scenario: autoread disabled
- **WHEN** `autoread` is off
- **THEN** the report SHALL contain a `warn` that AI CLI file changes will not be detected
  automatically

#### Scenario: Process inspection tools missing
- **WHEN** the platform is not Windows and `lsof` is not installed
- **THEN** the report SHALL contain a `warn` that running processes and ports will not be
  detected

### Requirement: Herdr embedded registration probe

The health report SHALL actively probe whether herdr accepts sidekick's agent reports for the
current pane when `cli.mux.backend` is `herdr`, the `herdr` executable exists, and Neovim runs
inside a herdr environment, using the probe of the herdr mux backend capability. A successful
probe SHALL be reported as `ok` with the probe's message. A failed probe SHALL be reported as a
`warn` that also states that `cli.mux.create = "terminal"` still works but the session will not
show up in herdr. The probe SHALL be the only place this degradation is surfaced, and it SHALL
NOT be run for other backends or outside a herdr environment.

#### Scenario: Herdr accepts sidekick's reports
- **WHEN** the backend is herdr, herdr is installed, and the probe succeeds
- **THEN** the report SHALL contain an `ok` entry with the probe result

#### Scenario: Herdr rejects sidekick's reports
- **WHEN** the backend is herdr and the probe fails
- **THEN** the report SHALL contain a `warn` with the reason and the note that terminal
  sessions still work but herdr will not display them

#### Scenario: Different backend
- **WHEN** `cli.mux.backend` is not `herdr`
- **THEN** no herdr probe SHALL be performed

### Requirement: AI CLI tool executable verification

The `Sidekick AI CLI Tools` section SHALL list every configured tool in `cli.tools`, sorted by
tool name, and SHALL check the first element of each tool's resolved command for
executability. A present executable SHALL be reported as `ok` ("installed"); a missing one
SHALL be reported as a `warn` ("not installed"), never as an `error`, because tools are
individually optional.

#### Scenario: Tool installed
- **WHEN** a configured tool's command is on `PATH`
- **THEN** the report SHALL contain an `ok` entry that the tool is installed

#### Scenario: Tool not installed
- **WHEN** a configured tool's command is not on `PATH`
- **THEN** the report SHALL contain a `warn` entry that the tool is not installed
- **AND** the overall report SHALL NOT be failed by that tool alone

### Requirement: Debug logging gated by the debug option

The configuration SHALL expose a top-level boolean `debug` option defaulting to `false`. Debug
messages emitted through sidekick's debug logger SHALL be suppressed entirely while `debug` is
`false`, and SHALL be delivered as scheduled `vim.notify` messages at warning level with the
`Sidekick` title while `debug` is `true`. When a debug message carries an accompanying value,
the value SHALL be appended to the message inspected inside a fenced `lua` block, so it renders
readably in notifier plugins.

The option SHALL be read at emit time rather than cached, so toggling it at runtime takes effect
immediately. Debug messages SHALL be diagnostic only: no behavior of NES, the CLI sidecar, the
file watcher, or the mux backends SHALL depend on whether `debug` is enabled.

#### Scenario: Debug disabled by default
- **WHEN** the user has not set `debug`
- **THEN** no debug notification SHALL be produced by any sidekick subsystem

#### Scenario: Debug enabled
- **WHEN** `debug = true` and a subsystem emits a debug message with a value
- **THEN** a warning-level notification titled `Sidekick` SHALL appear containing the message
  and the inspected value in a `lua` code fence

#### Scenario: Toggled at runtime
- **WHEN** `debug` is changed after `setup`
- **THEN** subsequent debug messages SHALL follow the new value without a restart

### Requirement: NES patch store for simulated suggestions

Developer NES patches SHALL be persisted as a JSON object in the file `sidekick-patch.json`
under Neovim's state directory, keyed by absolute buffer name, with one stored edit per file.
`:Sidekick debug nes add` SHALL load the store, capture the first pending NES edit, store it
under the current buffer's name, persist the store, and notify that a patch was added; when no
edit is pending it SHALL report an error and store nothing. `:Sidekick debug nes del` SHALL remove
the current buffer's entry and persist the store, or report an error when the buffer has no
patch. `:Sidekick debug nes edit` SHALL open the patch file in the current window so patches can
be hand-edited. Loading SHALL tolerate a missing patch file as a no-op, and saving and loading
SHALL each notify the user.

#### Scenario: Capture a suggestion
- **WHEN** a NES suggestion is displayed and the user runs `:Sidekick debug nes add`
- **THEN** the suggestion SHALL be written to the patch file under the current buffer's name
- **AND** the user SHALL be notified that a patch was added

#### Scenario: Nothing to capture
- **WHEN** no NES suggestion is pending and the user runs `:Sidekick debug nes add`
- **THEN** an error notification SHALL be shown and the patch file SHALL be left unchanged

#### Scenario: Remove a patch for an unpatched file
- **WHEN** the current buffer has no stored patch and the user runs `:Sidekick debug nes del`
- **THEN** an error notification SHALL state that no patch was found for this file

#### Scenario: Hand-edit the store
- **WHEN** the user runs `:Sidekick debug nes edit`
- **THEN** the patch file SHALL be opened for editing

### Requirement: NES inspection and handler patching

`:Sidekick debug nes inspect` SHALL display the first pending NES edit in an inspector window
(provided by snacks.nvim). Both inspection and capture SHALL first drop the edit's cached diff
and its associated command, so what is shown and stored is the plain suggestion payload; when no
edit is pending, inspection SHALL show nothing.

`:Sidekick debug nes patch` SHALL install a wrapper around the NES LSP response handler that, for
any request whose buffer has a stored patch, replaces the server response with a copy of that
stored edit retargeted at the requesting buffer and its current text document version, warns
which file was patched, and otherwise passes the real response through. Patching SHALL load the
store, request a NES update immediately so the patch takes effect without further editing, warn
that patching happened, and SHALL be idempotent-by-refusal: a second invocation in the same
session SHALL report an error that NES is already patched and SHALL NOT install a second wrapper.

#### Scenario: Inspect the current suggestion
- **WHEN** a NES suggestion is pending and the user runs `:Sidekick debug nes inspect`
- **THEN** the suggestion SHALL be shown in an inspector window without its cached diff or
  command

#### Scenario: Patched buffer receives the stored suggestion
- **WHEN** NES has been patched and a NES request completes for a file that has a stored patch
- **THEN** the stored suggestion SHALL be presented instead of the server's response, retargeted
  at the current buffer and document version
- **AND** a warning naming the patched file SHALL be shown

#### Scenario: Unpatched buffer is unaffected
- **WHEN** NES has been patched and a NES request completes for a file with no stored patch
- **THEN** the real server response SHALL be handled unchanged

#### Scenario: Patching twice
- **WHEN** the user runs `:Sidekick debug nes patch` a second time
- **THEN** an error SHALL report that NES is already patched and no additional wrapper SHALL be
  installed

### Requirement: Documentation generator and machine-owned README sections

`scripts/docs` SHALL regenerate the README by running `lua/sidekick/docs.lua` in a headless
Neovim with the test bootstrap, which provides the `lazy.nvim` and `snacks.nvim` doc-generation
helpers the generator depends on. Generated content SHALL be injected into `README.md` between
paired HTML comment markers of the form `<!-- <tag>:start -->` and `<!-- <tag>:end -->`,
replacing whatever currently sits between them. When a marker pair for a generated tag is
missing from the README, generation SHALL fail with an error naming that tag rather than
silently skipping it.

Everything between a marker pair SHALL be treated as machine-owned: it SHALL be regenerated by
running `scripts/docs` and SHALL NOT be hand-edited, since the next run overwrites it. Prose
outside the markers, such as the README's Requirements and FAQ sections, SHALL remain
hand-owned and SHALL NOT be touched by the generator.

#### Scenario: Regenerating documentation
- **WHEN** a maintainer changes config defaults or a public API doc comment and runs
  `scripts/docs`
- **THEN** the marked README sections SHALL be rewritten from the source and the surrounding
  prose SHALL be left untouched

#### Scenario: Missing marker pair
- **WHEN** a generated tag has no start/end marker pair in `README.md`
- **THEN** generation SHALL abort with an error naming the missing tag

#### Scenario: Hand-edited generated section
- **WHEN** a generated section has been edited by hand
- **THEN** the edit SHALL be discarded on the next `scripts/docs` run, and the change SHALL
  instead be made in the source it is extracted from

### Requirement: Generated configuration and setup sections

The generator SHALL extract the annotated `sidekick.Config` defaults table from
`lua/sidekick/config.lua` and inject it as a Lua code block into the `config` section, so the
documented defaults are literally the code's defaults. The generator SHALL apply a substitution
meant to drop the developer-only `debug = false` entry from that block; because the entry in
`lua/sidekick/config.lua` carries a trailing comment, that substitution matches nothing today
and `debug` is still part of the generated default settings listing.

The installation and integration examples (`setup_base`, `setup_custom`, `setup_blink`,
`setup_lualine`, `snacks_picker`) SHALL be extracted from the corresponding named locals in
`tests/fixtures/readme.lua`, so every documented example lives in a real Lua file that is
parsed as code rather than as README prose maintained by hand.

#### Scenario: Defaults change
- **WHEN** a default value in `lua/sidekick/config.lua` changes and docs are regenerated
- **THEN** the README's default settings block SHALL show the new value

#### Scenario: Debug option in the generated block
- **WHEN** the default settings block is generated
- **THEN** it SHALL contain the `debug = false` line as written in `lua/sidekick/config.lua`,
  because the strip only matches a bare `debug = false` line with no trailing comment

#### Scenario: Example changes
- **WHEN** an example local in `tests/fixtures/readme.lua` changes and docs are regenerated
- **THEN** the matching README example section SHALL show the new content

### Requirement: Generated API tables for the nes and cli modules

For each of the `nes` and `cli` modules the generator SHALL emit an HTML table with a `Cmd` and a
`Lua` column into the `api_nes` and `api_cli` sections. Rows SHALL cover the union of that
module's `:Sidekick` subcommands and the module's public top-level functions extracted from
`lua/sidekick/<mod>/init.lua`, sorted by name, with functions whose doc comment is marked
`@private` excluded.

The `Cmd` cell of each row SHALL open with `:Sidekick <mod> <name>` when a subcommand of that
name exists and with nothing otherwise, followed in the same cell by the prose lines of the
function's doc comment. The `Lua` cell SHALL hold a Lua snippet consisting of the function's
remaining annotation lines and a `require("sidekick.<mod>").<name>(<args>)` call with the real
parameter list. Generation SHALL
fail with an assertion naming the offending command when a subcommand has no matching public
function, so the command tree and the documented API cannot drift apart.

#### Scenario: Function with a command
- **WHEN** a module exposes a public function that is also a `:Sidekick` subcommand
- **THEN** its row SHALL show both the `:Sidekick` invocation and the equivalent Lua call

#### Scenario: Lua-only function
- **WHEN** a module exposes a public function with no matching subcommand
- **THEN** its row SHALL omit the `:Sidekick` invocation and show only the doc prose and the
  Lua call

#### Scenario: Private function
- **WHEN** a top-level function's doc comment contains `@private`
- **THEN** it SHALL NOT appear in the generated table

#### Scenario: Command without an implementation
- **WHEN** a subcommand name has no matching public function in the module
- **THEN** documentation generation SHALL fail with an error naming that command
