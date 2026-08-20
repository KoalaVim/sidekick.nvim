## Context

`lua/sidekick/cli/session/herdr.lua` was modelled on the tmux backend, but the two multiplexers differ in a way that matters: a tmux session created for `create = "terminal"` is invisible until something attaches to it, while a herdr pane is part of the visible layout the moment it exists. The backend also started tools with `herdr agent start`, which asks herdr to type the tool's command into the pane's interactive shell. Three consequences:

- The shell outlives the tool, so a finished session leaves an idle prompt in a pane.
- `herdr agent start` refuses a pane whose shell has not reached its prompt (`agent_pane_busy`), which is a race against shell startup — measured at 2–4s with the reporting user's zsh.
- With `create = "terminal"` the user sees the session twice: in the herdr pane and in the Neovim terminal attached to it.

Separately, the pane is spawned by the herdr server, so it inherits nothing from Neovim: `NVIM` and the `sidekick-editor-proxy` that the terminal backend injects at `jobstart` never reach the tool.

Behaviour of the herdr CLI was verified against a live server (socket protocol `cli:pane:*`, `cli:agent:*`) rather than assumed.

## Goals / Non-Goals

**Goals:**

- A session is visible exactly once, and where `mux.create` says it should be.
- A pane exists for exactly as long as its tool does.
- The tool sees the same environment it would get from the terminal backend.
- Starting a session is not a race.

**Non-Goals:**

- Re-attaching a rediscovered session into a Neovim terminal after Neovim restarts. `sessions()` still reports every discovered agent as external, because there is no way to mark a pane as sidekick-owned: `herdr pane report-metadata` is display-only and `PaneInfo.tokens` is not settable from the CLI.
- Registering a tool that runs inside a Neovim terminal as a herdr agent (`pane report-agent` on Neovim's own pane). One pane can only host one agent, and that pane already hosts Neovim.
- Supporting herdr builds without `pane run`, `pane move`, `pane get`, or `pane read`.

## Decisions

**Launch with `pane run <pane> exec env <env> <cmd>`, not `agent start`.**
`exec` replaces the pane's shell with the tool, which makes pane lifetime equal tool lifetime — herdr closes the pane when the tool exits, and the `agent attach` client exits with rc 1, so the Neovim terminal closes too. Detection is not lost: herdr recognises `pi` (lifecycle hook) and `claude` (detection manifest) within ~1s of an `exec`-launched process, the same way it recognises agents a user starts by hand. Launching by command also carries `tool.cmd` arguments (`--resume`, `--continue`) and works for tools that have no herdr `--kind`.

*Alternative considered:* keep `agent start` for its synchronous handshake and close the pane from `detach()` once `is_running()` notices the tool is gone. Rejected: cleanup then depends on sidekick polling, and nothing cleans up if Neovim exits first.

*Alternative considered:* keep `agent start` and add a retry loop around `agent_pane_busy`. Rejected once `pane run` was measured to need no readiness wait at all — a command sent immediately after `pane split` is buffered by the pane's tty and runs when the shell reaches its prompt.

**Set env on the exec line, not on the pane.**
`herdr pane split --env` was tried first and does not hold: the pane's shell startup files run after the pane env is applied, and the reporting user's zshrc exports its own `EDITOR`, which won. `env K=V … cmd` is applied at exec time, after all shell startup, so it wins. `pane run` joins its arguments into a shell command line without quoting them, so every value is passed through `shellescape`; `false` entries become `env -u KEY`.

**Placement keyed off `mux.create`, using `pane move --new-tab`.**
There is no primitive for "create a pane in another tab", so a pane is split next to Neovim and then moved. `terminal` and `window` move it to its own tab; `split` leaves it in place. `pane move --new-tab` focuses the tab it creates, so the backend focuses `$HERDR_TAB_ID` afterwards — matching `tmux new-window -d`, which also does not switch. For `terminal` the moved pane stays alive and grouped under the same workspace, so it still shows in herdr's agents pane while the Neovim terminal is the only visible copy.

**Split from `$HERDR_PANE_ID`.**
`herdr pane split` with no target splits the *focused* pane, which put a pane in an unrelated workspace during testing. Neovim's own pane is the correct parent.

**Liveness from `pane get`, scrollback from `pane read`.**
Now that the pane is the tool, pane existence is the exact liveness signal (`rc 1` / `pane_not_found` when gone), and it also covers tools herdr does not detect — where `agent list` would report a running session as dead. `pane read` accepts `--lines`, so `cli.mux.dump` is honoured, which `agent read` could not do.

**Keep the kind map for discovery only.**
`herdr agent list` reports kinds, so the map is still needed to resolve an agent back to a sidekick tool. Requiring it to *start* a tool was an artificial restriction inherited from `agent start --kind`.

## Risks / Trade-offs

- **A tool whose pane closes on exit loses its final screen.** → Deliberate: it is the reported complaint. The scrollback is available through sidekick's own dump while the session runs, and `create = "split"` users see the pane the whole time.
- **`create = "terminal"` adds a background herdr tab per session.** → Accepted over the duplicate-view alternative; the tab disappears with the pane, and the agent stays visible in herdr's agents pane.
- **No start handshake, so a tool that fails to launch is only noticed later.** → `pane run` failures still close the pane and report; a tool that starts and immediately dies shows up as a closed pane through `is_running()`.
- **`pane run` argument quoting is ours to get right.** → Every env value and command argument goes through `shellescape`; verified with a value containing a space.
- **Depends on a recent herdr CLI surface.** → All four commands are in the bundled socket schema of the herdr in use; older builds would fail loudly on `start()` rather than silently misbehave.
- **`sessions()` still marks rediscovered agents external**, so after a Neovim restart a `terminal`-mode session can be driven but not re-embedded. → Left as is; noted in Non-Goals.

## Migration Plan

Replacing the body of one backend module; no config or data migration. `cli.mux.create` and `cli.mux.dump` keep their meaning and simply start taking effect under herdr. Rollback is reverting the module.
