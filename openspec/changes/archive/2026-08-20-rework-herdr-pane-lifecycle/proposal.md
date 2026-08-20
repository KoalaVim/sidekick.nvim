## Why

The herdr backend starts tools with `herdr agent start`, which types the tool's command into a freshly split pane's shell. That leaves the shell owning the pane, so the pane lingers at a prompt after the tool exits, and it races shell startup (`agent_pane_busy`). It also always splits a pane next to Neovim, so `mux.create = "terminal"` shows the same session twice: once in the herdr pane and once in the Neovim terminal that attaches to it. Because the pane is spawned by the herdr server rather than a Neovim terminal job, the tool also never sees `NVIM` or sidekick's editor proxy.

## What Changes

- Launch tools with `herdr pane run <pane_id> exec env <env> <cmd>` instead of `herdr agent start`. `exec` replaces the pane's shell, so the pane closes when the tool exits and the `herdr agent attach` client exits with it. Herdr detects the agent natively, so no start handshake is needed.
- **BREAKING** (behavior, not config): `mux.create` now drives pane placement — `terminal` moves the pane to a tab of its own and attaches it in a Neovim terminal, `split` keeps a visible pane next to Neovim as an external session, `window` moves it to its own tab as an external session. Focus is restored to `$HERDR_TAB_ID` after a move, since `herdr pane move --new-tab` focuses the tab it creates.
- Split from `$HERDR_PANE_ID` rather than whatever pane happens to be focused.
- Pass `NVIM`, `EDITOR`/`VISUAL` (sidekick's editor proxy), and the tool's `env` on the exec command line, shell-quoted, with `false` entries unset via `env -u`. Setting them on the pane cannot work: the pane's shell startup files run afterwards and overwrite them.
- Liveness moves from `herdr agent list` to `herdr pane get <pane_id>`, and scrollback from `herdr agent read` to `herdr pane read --lines <mux.dump>`, which finally honours `cli.mux.dump`.
- The tool-name → herdr-kind map is now only used to resolve `herdr agent list` entries back to a tool. Starting no longer requires a mapping, so tools herdr has no kind for still run in a herdr pane.
- Parse the pane id from `herdr pane split` at `result.pane.pane_id`, the shape the socket API actually returns.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `herdr-mux-backend`: how a session is started in a pane, where that pane is placed per `mux.create`, the pane's environment, liveness, scrollback, and the role of the kind mapping.

## Impact

- `lua/sidekick/cli/session/herdr.lua` — start, env, liveness, scrollback, discovery.
- Requires a herdr build with `pane run`, `pane move --new-tab`, `pane get`, and `pane read` (verified against herdr with socket protocol schema `cli:pane:*`).
- No sidekick config changes: `cli.mux.create` and `cli.mux.dump` keep their meaning and gain effect under herdr.
- Users who relied on the herdr pane staying open after a tool exits lose that leftover shell.
