# Known Defects

Findings from writing the capability specs under `openspec/specs/`. Every spec was authored
from the source by one agent and then re-audited against the source by a different agent; the
items below are places where the code does something other than what its option names,
annotations, comments, or the README imply.

None of these are fixed. The specs deliberately document the **actual** behavior, so fixing a
defect here means updating the owning spec in the same change. Each entry names that spec.

## Behavioral defects

### `cli.tools.<name> = false` cannot disable a shipped tool

- `lua/sidekick/cli/tool.lua:26-27` resolves `Config.cli.tools[name] or {}`, so a `false` value
  falls back to the bundled `sk/cli/<name>.lua` definition.
- `lua/sidekick/config.lua:281-287` iterates `pairs(M.cli.tools)`, so the key still lists.
- `lua/sidekick/config.lua:192` merges with `vim.tbl_deep_extend("force", ...)`, which cannot
  delete keys, so there is no way to remove a shipped tool through `setup()` either.
- For a *user-added* key set to `false` there is no bundled `cmd`, and `cli/state.lua:103` and
  `health.lua:108` index `tool.cmd[1]`.
- Spec: `cli-tool-registry`, `plugin-configuration`.

### Position references render a column two greater than the cursor's

- `lua/sidekick/cli/context/init.lua:219` stores `col = cursor[2] + 1`, converting Neovim's
  0-based cursor column to 1-based.
- `lua/sidekick/cli/context/location.lua:76-80` then renders `from[2] + 1` again.
- A cursor at 0-based column 4 therefore renders `:L10:C6`. The `+ 1` is correct for *ranges*,
  whose columns are genuinely 0-based, but wrong for the cursor snapshot.
- The same off-by-one reaches textobject locations (`textobject.lua:141` also stores
  `start_col + 1`), so a function starting at column 0 renders `:C2`.
- Spec: `cli-context-and-prompts`.

### `filter.cwd = false` filters as if it were `true`

- `lua/sidekick/cli/state.lua:39` reads
  `(filter.cwd == nil or (t.session and t.session.cwd == Session.cwd()))` and never compares
  the filter's value, so any non-nil `cwd` demands a session in the current directory.
- Spec: `cli-session-management`.

### A prompt function that returns `nil` raises

- `lua/sidekick/cli/context/init.lua:164` evaluates
  `type(prompt) == "string" and prompt or prompt.msg or ""`. When a `cli.prompts` entry is a
  function that returns nothing, `prompt` is `nil` and `prompt.msg` indexes it.
- The type annotation allows `string?`, so returning `nil` is a documented option.
- Spec: `cli-context-and-prompts` (does not specify this path).

### The tmux placement notification fires even when nothing started

- `lua/sidekick/cli/session/tmux.lua:43` and `:51` call `Util.info("Started ... in a new tmux
  window/split")` unconditionally after `self:spawn(cmd)`.
- `spawn` only records pane state when `panes(...)[1]` exists (`tmux.lua:58-67`), so a failed
  `new-window` / `split-window` produces both a failure notification and a success one.
- Spec: `mux-session-backends`.

### Stopping the file watcher does not cancel armed timers

- `lua/sidekick/cli/watch.lua:71-72` wraps `refresh` and `update` in shared 100 ms debounce
  timers created at module load.
- `M.disable()` (`watch.lua:87-96`) clears the augroup and closes fs-event handles but does not
  cancel those timers, and `M.update` (`watch.lua:55-69`) never checks `M.enabled`.
- An `update` armed just before the stop therefore fires afterwards and re-creates directory
  watches with no augroup left to remove them.
- Spec: `file-change-watch`.

### `text.sub` mixes display columns with character offsets

- `lua/sidekick/text.lua` computes `offset` and `sub_width` from `Util.width` (display cells)
  but slices partial chunks with `vim.fn.strcharpart` (character offsets), at `text.lua:32`.
- Slicing a line containing tabs or double-width characters lands on the wrong boundary.
- Spec: `core-utilities` (describes the intended column semantics without asserting exactness
  for wide characters).

### Empty picker selections send a whitespace-only message

- `lua/sidekick/cli/picker/init.lua:40` seeds the outgoing text with `{ { " " } }`, and
  `cli/init.lua:180-189` skips its "Nothing to send." guard when `opts.text` is pre-supplied.
- Only the fzf-lua adapter guards an empty selection (`picker/fzf-lua.lua:22-24`). The snacks
  adapter (`picker/snacks.lua:21-34`) and the telescope adapter (`picker/telescope.lua:40-56`,
  where `get_selected_entry()` may be `nil`) both invoke the callback with an empty list.
- Spec: `file-pickers`.

### An unknown picker name aborts resolution instead of falling through

- `lua/sidekick/cli/picker/init.lua:22-32` walks
  `{ Config.cli.picker, "snacks", "telescope", "fzf-lua" }`. An uninstalled *host plugin*
  silently falls through to the next candidate, but a name with no adapter module returns
  `Util.error("Invalid picker: ...")` and abandons the remaining candidates.
- Spec: `file-pickers`.

### `debug = false` leaks into the generated README config block

- `lua/sidekick/docs.lua:6` strips the developer-only option with
  `config:gsub("%s*debug = false.\n", "\n")`, but `lua/sidekick/config.lua:177` reads
  `debug = false, -- enable debug logging`. The single `.` cannot span the trailing comment, so
  nothing is stripped and `README.md:408` currently publishes the option.
- Fix: `%s*debug = false.-\n`. After that, tighten the `plugin-diagnostics` and
  `development-tooling` requirements back to the stricter claim.
- Spec: `plugin-diagnostics`, `development-tooling`.

## Documentation drift

### README prompt list is stale

- `README.md:613` documents `document` as `Add documentation to {position}`;
  `lua/sidekick/config.lua:134` ships `Add documentation to {function|line}`.
- The same list omits the single-placeholder default prompts that config defines: `buffers`,
  `file`, `line`, `position`, `quickfix`, `selection`, `function`, `class`.
- Spec: `cli-context-and-prompts`.

### README overstates what the picker sends

- The "Snacks.nvim Picker Integration" section claims grep results carry line numbers and
  position ranges. The adapters do capture positions, but the shared send callback renders each
  item with `kind = opts.kind or "file"` (`cli/picker/init.lua:42`), and
  `cli/context/location.lua:67-82` appends nothing for a `file` kind. Only paths are sent.
- Spec: `file-pickers`.

### `AGENTS.md` points at a path that does not exist

- `AGENTS.md:15` says `./scripts/docs` uses the snippets in `tests/readme.lua`. The real path is
  `tests/fixtures/readme.lua` (`lua/sidekick/docs.lua:10-14`).
- Spec: `development-tooling`.

## Lint and CI

### `selene.toml`'s globals list omits `after_each`

- `vim.yml` declares `describe`, `it` and `before_each` but not `after_each`, which is used by
  `tests/commands_spec.lua`, `context_spec.lua`, `diff_spec.lua`, `nes_spec.lua`,
  `status_spec.lua` and `textobject_spec.lua`.
- `selene` is listed as an everyday command in `AGENTS.md` but is not run by CI, so this has
  gone unnoticed. A local run is unlikely to be clean.
- Spec: `development-tooling`.

### The shared CI build job never runs

- The delegated `folke/github` workflow detects `scripts/test`, `scripts/docs` and
  `scripts/build`; this repo provides only the first two.
- Spec: `development-tooling`.

### `scripts/docs` uses a non-portable shebang

- The shebang is `#!/bin/env bash` rather than `#!/usr/bin/env bash`, which does not resolve on
  macOS when the script is executed directly.

## Latent and minor

### Unreachable "no action for keymap" error

- `lua/sidekick/cli/terminal.lua:539-546` ends its resolution chain with `or rhs`, so any string
  action always resolves - to itself, as a literal right-hand side. The error at `terminal.lua:552`
  can only fire when the action is neither a string nor a function.
- Spec: `cli-terminal-window`.

### `Util.set_state` can raise

- `lua/sidekick/util.lua:228` calls `vim.fn.mkdir(state_dir, "p")` unguarded, and `vim.fn.mkdir`
  throws on failure (`E739`). Only the JSON encode and the `io.open` that follow are guarded.
- Spec: `core-utilities`.

### `Util.set_extmark` can raise on its own error path

- `lua/sidekick/util.lua:80` deep-copies the raw `opts` while the API call uses `opts or {}`. A
  caller passing `nil` opts whose extmark then failed would raise while building the error
  report. All three current callers (`nes/ui.lua:27,47,56`) pass a table.
- Spec: `core-utilities`.

### A corrupt NES patch file raises

- `lua/sidekick/debug.lua` decodes the patch store's JSON outside the surrounding `pcall`, and
  `nes_save` notifies before it writes.
- Spec: `plugin-diagnostics`.

### Failed NES requests stay recorded as in flight

- `lua/sidekick/nes/init.lua:202-206` returns before the request-id check when a response
  carries an error or the client has vanished, so the tracked id survives until the next clear
  or cancel.
- Spec: `next-edit-suggestions`.

### Post-apply cursor column always overshoots

- `lua/sidekick/nes/init.lua:327-331` adds the byte length of the *entire* replacement block to
  the edit's start column. `nvim_win_set_cursor` clamps it, so the cursor lands at the end of
  the last replacement line rather than at the end of the inserted text.
- Spec: `next-edit-suggestions`.

### Copilot status entries are never pruned

- `lua/sidekick/status.lua` keys recorded statuses by client id and never removes them when a
  client stops. Harmless today because `get()` is gated on a live client, and ids are not reused
  within a session.
- Spec: `copilot-lsp-status`.

### `cli.win.nav` cannot be overridden per session

- `lua/sidekick/cli/actions.lua:62` reads the global `Config.cli.win.nav` rather than the
  session's own `terminal.opts.nav`, unlike every other `cli.win` option, so the
  `cli.win.config` callback cannot change navigation for one session.
- Spec: `cli-terminal-window`.

### Command completion matches its input as a Lua pattern

- `lua/sidekick/commands.lua:125` filters candidates with `key:find(prefix) == 1`, without the
  plain flag, so magic characters in the typed text are matched as a pattern. `:Sidekick cli s.`
  offers `select`, `show` and `send`.
- Spec: `sidekick-commands`.

### Dead code

- `resume` and `continue` in `sk/cli/claude.lua`, `codex.lua`, `copilot.lua`, `pi.lua` and
  `opencode.lua` are stored on the tool definition and never read anywhere in `lua/`.
- `Procs.env`, `P:find` and `P:list` (`lua/sidekick/cli/procs.lua`) have no in-tree caller.
- The `@private` filter in `lua/sidekick/docs.lua:33` is unreachable: `snacks.meta.docs` already
  drops `@private`, `@protected`, `@package`, `@hide` and `_`-prefixed methods.
- `zellij.lua:113-135` is a commented-out `dump()`, which is why sidekick scrollback is
  unavailable for zellij.
- `tests/fixtures/keymaps.lua` has no consumer in `lua/`, `tests/`, `scripts/` or `README.md`.
- `debug.setupvalue` is called for in `AGENTS.md` and the `development-tooling` spec, but no test
  currently uses it.
