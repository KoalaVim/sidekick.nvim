# Development Tooling

## Purpose

Defines the repository's own development contract: how the headless test harness is bootstrapped
and run, the conventions a spec file must follow, how README documentation is generated from Lua
annotations and fixtures, which formatting and lint gates the sources must satisfy, and what CI
runs on which trigger before a change can be merged.

## Requirements

### Requirement: Headless test harness bootstrap

The repository SHALL provide `./scripts/test`, which runs `nvim -l tests/minit.lua --minitest`
and forwards any extra arguments. `tests/minit.lua` SHALL redirect all Neovim state into the
repository-local `.tests` directory by setting `LAZY_STDPATH=".tests"` (which is git-ignored), and
SHALL bootstrap lazy.nvim from `~/projects/lazy.nvim` when that directory exists, otherwise by
downloading and executing lazy.nvim's `bootstrap.lua` over the network. It SHALL then call
`require("lazy.minit").setup()` with a spec containing the plugin under test (the current working
directory), `nvim-treesitter` (branch `main`, installing the `python`, `rust`, `javascript`,
`typescript`, `go` and `lua` parsers), `nvim-treesitter-textobjects` (branch `main`) and
`snacks.nvim`; `--minitest` SHALL additionally pull in `mini.test` and `luassert`. Test
dependencies SHALL be installed automatically, so a contributor SHALL NOT be required to install
them by hand.

#### Scenario: First run on a clean checkout

- **WHEN** `./scripts/test` is run and `.tests` does not exist
- **THEN** lazy.nvim SHALL be bootstrapped, the declared test dependencies and treesitter parsers
  SHALL be installed under `.tests`, and the suite SHALL then run

#### Scenario: Local lazy.nvim checkout is preferred

- **WHEN** `~/projects/lazy.nvim` exists
- **THEN** the harness SHALL bootstrap from that directory instead of downloading `bootstrap.lua`

#### Scenario: Harness state stays out of the working tree

- **WHEN** the suite has finished
- **THEN** all plugin, cache and state files SHALL live under the git-ignored `.tests` directory
  and the working tree SHALL be otherwise unchanged

### Requirement: Test selection and exit-status contract

The suite SHALL be collected by `mini.test` from files matching `tests/**/*_spec.lua`. When
positional arguments are passed to `./scripts/test`, they SHALL replace that glob so only the
named files run. The runner SHALL require headless Neovim (`nvim -l`) and SHALL exit with status
`0` when every case passes and a non-zero status when any case fails or errors, so the script's
exit code is the authoritative pass/fail signal for humans and CI alike.

#### Scenario: Full suite passes

- **WHEN** `./scripts/test` runs and no case fails
- **THEN** the process SHALL exit `0` after reporting results on stdout

#### Scenario: A case fails

- **WHEN** any collected case fails or raises an error
- **THEN** the process SHALL exit non-zero and the failure SHALL be reported on stdout

#### Scenario: Running a single spec file

- **WHEN** the contributor runs `./scripts/test tests/diff_spec.lua`
- **THEN** only that file SHALL be collected and run

### Requirement: Offline test mode

The harness SHALL support an offline mode in which no plugin update is attempted: setting
`LAZY_OFFLINE=1` (or passing `--offline` to `./scripts/test`) SHALL skip lazy.nvim's update step.
Offline mode SHALL be used for fully offline or network-restricted CI, and SHALL rely on an
already-populated `.tests` directory: only the update step is skipped, so lazy.nvim still tries
to install any plugin that is missing from `.tests`. Because the suite may run in such an
environment, tests SHALL NOT make third-party network calls and SHALL use stubs or fixtures
instead.

#### Scenario: Offline run with dependencies present

- **WHEN** `LAZY_OFFLINE=1 ./scripts/test` runs and `.tests` already contains the dependencies
- **THEN** no update or download SHALL be attempted and the suite SHALL run against the installed
  versions

#### Scenario: Test needs external data

- **WHEN** a new test would otherwise fetch data over the network
- **THEN** it SHALL stub the call or read from `tests/fixtures` instead

### Requirement: Test authoring conventions

Spec files SHALL live in `tests/` as `<topic>_spec.lua`, SHALL use the `describe` / `it` /
`before_each` / `after_each` form, and SHALL assert with the `luassert` API exposed by the
harness (for example `assert.are.same`, `assert.are.equal`, `assert.is_true`, `assert.is_nil`,
`assert.matches`). Combinatorial behavior SHALL be expressed as table-driven cases -- a list of
named case tables iterated to generate assertions -- as done in `tests/diff_spec.lua`,
`tests/util_spec.lua` and `tests/commands_spec.lua`. A change to a covered area SHALL extend the
corresponding spec: diffing changes in `tests/diff_spec.lua`, status reporting in
`tests/status_spec.lua`.

#### Scenario: Adding combinatorial coverage

- **WHEN** a change adds behavior with many input permutations
- **THEN** the new coverage SHALL be added as entries in a table of cases rather than as many
  near-duplicate `it` blocks

#### Scenario: Changing diff or status behavior

- **WHEN** `lua/sidekick/nes/diff.lua` or `lua/sidekick/status.lua` changes behavior
- **THEN** `tests/diff_spec.lua` or `tests/status_spec.lua` respectively SHALL be updated or
  extended to cover it

### Requirement: Stubbing and state restoration in tests

Tests SHALL stub collaborators by reassigning functions or config fields and SHALL restore the
originals in an `after_each` hook, so no case leaks state into another. Config values that a test
mutates (for example `Config.nes.diff.inline`, `Config.nes.enabled`), module functions (for
example `require("sidekick.util").notify`, `Config.get_client`, treesitter helpers) and Neovim
globals or buffer variables (for example `vim.g.sidekick_nes`, `vim.b[buf].sidekick_nes`) SHALL be
captured before the change and put back afterwards, and scratch buffers created by a test SHALL be
deleted. Helpers that are only reachable as upvalues SHALL be replaced with `debug.setupvalue`.
Tests SHALL NOT rely on `vim.lsp._set_clients`; they SHALL stub `Config.get_client` or the
relevant `vim.lsp` functions directly.

#### Scenario: Stubbed function is restored

- **WHEN** a test replaces a module function or config field
- **THEN** an `after_each` hook SHALL restore the original value before the next case runs

#### Scenario: LSP client is needed

- **WHEN** a test needs a Copilot LSP client to be present or absent
- **THEN** it SHALL stub `Config.get_client` (or a `vim.lsp` function) rather than using
  `vim.lsp._set_clients`

### Requirement: Documentation fixtures

`tests/fixtures/` SHALL hold Lua data files that are inputs to tooling rather than test cases;
because they do not match `*_spec.lua`, the runner SHALL NOT collect them.
`tests/fixtures/readme.lua` SHALL define the plugin-setup, `blink.cmp`, `lualine` and
`snacks.nvim` picker examples as named top-level locals (`base`, `custom`, `blink`, `lualine`,
`snacks_picker`) that the docs generator extracts verbatim into README; each snippet SHALL
therefore remain valid, stylua-formatted Lua, and a snippet whose layout must survive formatting
SHALL carry a `-- stylua: ignore` comment (such comment lines are stripped during extraction).
`tests/fixtures/keymaps.lua` SHALL provide the per-tool CLI keymap reference table keyed by tool
name and SHALL return it, printing the sorted union of key notations whenever the file is loaded.

#### Scenario: Changing a documented setup example

- **WHEN** a README setup example needs to change
- **THEN** the corresponding local in `tests/fixtures/readme.lua` SHALL be edited and the docs
  regenerated

#### Scenario: Renaming an extracted local

- **WHEN** one of the named locals in `tests/fixtures/readme.lua` is renamed or removed
- **THEN** the docs generator SHALL fail because its extraction pattern no longer matches

### Requirement: Generated README documentation

`./scripts/docs` SHALL regenerate the derived README sections by running `lua/sidekick/docs.lua`
under the test harness environment (`nvim -u tests/minit.lua -l lua/sidekick/docs.lua`), which
requires the test dependencies (`lazy.nvim`, `snacks.nvim`) to be installed. It SHALL extract the
`sidekick.Config` class from `lua/sidekick/config.lua` (whose `debug` entry the generator tries
to strip, but does not, because that line carries a trailing comment), the named snippets from
`tests/fixtures/readme.lua`, and an API table per module for `nes` and `cli` built
from `sidekick.commands` plus the public annotated methods of `lua/sidekick/<mod>/init.lua`,
skipping methods marked `@private`. Each result SHALL be written between the matching
`<!-- <tag>:start -->` and `<!-- <tag>:end -->` markers in `README.md`, and the script SHALL print
`Updated docs` on success. Those regions and `doc/sidekick.nvim.txt` are generated output and
SHALL NOT be edited by hand; the source annotations, fixtures or config SHALL be edited and
`./scripts/docs` re-run instead.

#### Scenario: Configuration option added

- **WHEN** a new option is added to the `sidekick.Config` class in `lua/sidekick/config.lua`
- **THEN** `./scripts/docs` SHALL be run so the `config` region of `README.md` reflects it, rather
  than the README being edited directly

#### Scenario: Command without a documented method

- **WHEN** `sidekick.commands` exposes a command for a module that has no matching public method
  in that module's `init.lua`
- **THEN** the generator SHALL abort with a `Missing method: <name>` error and README SHALL be
  left unchanged

#### Scenario: Marker missing

- **WHEN** a start/end marker pair for a generated tag is absent from `README.md`
- **THEN** the generator SHALL fail with a "tag not found" error instead of silently skipping the
  section

### Requirement: Formatting and lint gates

Lua sources SHALL be formatted with `stylua` using the committed `stylua.toml`: spaces, indent
width 2, column width 120, and `sort_requires` enabled; `stylua lua tests` SHALL leave no changes.
Lua sources SHALL be linted with `selene` using the committed `selene.toml`, which selects the
repository-local `vim.yml` standard library (`lua51` base, luajit, and the `vim`, `Snacks`, `jit`,
`assert`, `describe`, `it`, `before_each` globals) and allows `mixed_table`. That list is what
`vim.yml` declares today and it omits `after_each`, which several spec files use, so a selene run
is not currently guaranteed to be clean; selene is not part of CI either. All files SHALL follow
`.editorconfig`: UTF-8, space indentation of width 2, and a final newline. Markdown SHALL lint
clean under `markdownlint-cli2` with the committed `.markdownlint-cli2.yaml`, which disables
`MD013` (line length) and `MD033` (inline HTML). Content SHALL stay ASCII unless the surrounding
context is already Unicode, and leftover debug calls (`dd(`) SHALL NOT be committed under `lua/`.

#### Scenario: Unformatted Lua

- **WHEN** a change leaves Lua that `stylua` would reformat
- **THEN** the formatting gate SHALL fail and the change SHALL be reformatted before merge

#### Scenario: New global used in a test

- **WHEN** a test or source file uses a global that is not declared in `vim.yml`
- **THEN** `selene` SHALL report it and either the usage SHALL change or the standard library
  definition SHALL be extended

#### Scenario: Debug helper left behind

- **WHEN** a call to `dd(` remains on a non-comment line under `lua/`
- **THEN** CI SHALL fail the debug-message check

### Requirement: CI checks and merge gate

The `CI` workflow (`.github/workflows/ci.yml`) SHALL run on pushes to `main`/`master` and on every
pull request by delegating to the shared reusable workflow `folke/github/.github/workflows/ci.yml`
with `plugin: sidekick.nvim` and `repo: folke/sidekick.nvim`. That workflow SHALL detect the
presence of `scripts/test`, `scripts/docs` and `scripts/build` -- this repository provides the
first two only, so the shared build job never runs; SHALL run `stylua --check lua`;
SHALL fail if a `dd(` debug call remains under `lua/`; and SHALL run `./scripts/test` on a Neovim
runner (with `libreadline-dev` installed, a `.tests` cache keyed on `tests/minit.lua` and
`scripts/test`, and a 10 minute timeout) whenever `scripts/test` exists. A change SHALL pass the
test, formatting and docs checks before it is merged. CI itself gates only stylua, the `dd(`
check and the test suite -- there is no `selene`, `markdownlint` or docs-freshness job -- so in
practice `./scripts/test`, `stylua lua tests`, `selene` and `./scripts/docs` SHALL be run locally
and the regenerated docs committed.

#### Scenario: Pull request opened

- **WHEN** a pull request is opened or updated
- **THEN** the stylua check, the debug-message check and the headless test suite SHALL run, and a
  failure in any of them SHALL block the merge

#### Scenario: Docs left stale

- **WHEN** a change edits config annotations or README fixtures without regenerating docs
- **THEN** the generated README/vimdoc regions SHALL be out of sync and the change SHALL NOT be
  considered ready for merge until `./scripts/docs` has been run and its output committed

### Requirement: Repository automation and release

Post-merge automation SHALL be handled by workflows rather than by hand. In the upstream
repository (jobs gated on `repo == github.repository` and `ref == refs/heads/main`, and therefore
inactive in forks), the shared CI workflow SHALL, after tests pass, run `./scripts/docs` and
auto-commit generated docs, generate vimdoc via panvimdoc and auto-commit it, and run
`release-please` to open/publish releases and move the `stable` tag on a release. `pr.yml` SHALL
validate pull request titles as conventional commits with a required scope and a subject that does
not start with an uppercase letter, on `pull_request_target` open/edit/synchronize/reopen/ready.
`labeler.yml` SHALL apply size labels, and path labels only when a `.github/labeler.yml`
config exists, which this repository does not provide; `stale.yml` SHALL run daily to mark and close
stale issues (pull requests exempt); `update.yml` SHALL run hourly (and on demand) to refresh
repository metadata; and `dependabot.yml` SHALL propose weekly GitHub Actions updates.
`sync.yml` SHALL run weekly (and on demand) to rebase this fork onto upstream
`folke/sidekick.nvim`, reporting into its tracking issue. The `stale.yml` and `update.yml`
workflows SHALL only run when the repository owner is `folke` or `LazyVim`.

#### Scenario: Change merged upstream

- **WHEN** a change lands on `main` of the upstream repository and tests pass
- **THEN** generated docs and vimdocs SHALL be regenerated and auto-committed, and
  `release-please` SHALL update the release pull request or cut a release

#### Scenario: Fork CI run

- **WHEN** CI runs in a fork whose repository is not `folke/sidekick.nvim`
- **THEN** the docs, build and release jobs SHALL be skipped and only the checks SHALL run

#### Scenario: Non-conventional pull request title

- **WHEN** a pull request title lacks a conventional-commit type and scope, or its subject starts
  with an uppercase letter
- **THEN** the PR title check SHALL fail
