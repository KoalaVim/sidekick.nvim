## 1. Simplify embedded herdr sessions

- [x] 1.1 In `start_embedded()`, stop clearing `HERDR_PANE_ID` — remove `env = { HERDR_PANE_ID = false }` from the returned `Cmd`, and remove the scheduled `self:register()` call
- [x] 1.2 In `start_embedded()`, subscribe to the status watch on Neovim's pane: call `M.watch(vim.env.HERDR_PANE_ID)` so status comes from herdr
- [x] 1.3 Remove `register()`, `report_agent()`, `report_metadata()`, `refresh_label()` methods
- [x] 1.4 Remove `reap()` and `probe()` functions
- [x] 1.5 Remove `M._embedded` state, and the `SOURCE`, `TOKEN`, `LABEL_TTL`, `LABEL_REFRESH` constants
- [x] 1.6 Simplify `set_status()` — remove the embedded-specific `report_agent()` call; reduce to the base class behavior or remove the override entirely
- [x] 1.7 Simplify `detach()` — remove `release-agent` and metadata clearing for embedded sessions; keep only `M.unwatch()`
- [x] 1.8 Update `is_running()` for embedded — remove the `M._embedded` check; consider using herdr's pane check or the terminal backend's existing check

## 2. Update session discovery

- [x] 2.1 In `sessions()`, stop skipping agents on Neovim's own pane (`pane_id == nvim_pane`) — include them as non-external discoverable sessions
- [x] 2.2 Remove the stale-registration reaping logic that called `M.reap()` for agents on Neovim's pane

## 3. Surface session status

- [x] 3.1 Add `status` field to `sidekick.cli.Status` type annotation in `lua/sidekick/status.lua`
- [x] 3.2 Include `status = session.status or "unknown"` in `update_cli_status()` when building each `cli_sessions` entry
- [x] 3.3 Emit `SidekickCliStatus` from `B:set_status()` in `lua/sidekick/cli/session/init.lua` when the status changes
- [x] 3.4 Add `SidekickCliStatus` to the autocmd pattern list in `lua/sidekick/status.lua` alongside `SidekickCliAttach` and `SidekickCliDetach`

## 4. Clean up

- [x] 4.1 Remove the `probe()` health check from `lua/sidekick/health.lua`
- [x] 4.2 Update the `mux.create` comment in `lua/sidekick/config.lua` — remove the note about herdr not detecting embedded tools natively

## 5. Verification

- [ ] 5.1 Confirm that starting a tool with herdr embedded mode shows the agent in `herdr agent list` via native detection (not sidekick's `report-agent`)
- [ ] 5.2 Confirm that the agent's status transitions are reflected in `require("sidekick.status").cli()` via herdr's watch
- [ ] 5.3 Confirm that `sessions()` discovers the agent on Neovim's pane and the dedup logic prevents a double entry when attached via a Neovim terminal
