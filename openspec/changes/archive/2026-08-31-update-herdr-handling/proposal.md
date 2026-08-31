## Why

The embedded herdr mode (`mux.create = "terminal"`) was built on the assumption that herdr
cannot detect a tool running inside a Neovim terminal. That assumption is wrong — herdr can
see it. As a result, the embedded path carries a large manual registration machinery
(`register()`, `report-agent`, `report-metadata`, label refresh timer, `reap()`, `probe()`,
`M._embedded` state, `SOURCE`/`TOKEN`/`LABEL_TTL`/`LABEL_REFRESH` constants) that duplicates
what herdr already does natively. It also clears `HERDR_PANE_ID` to prevent the tool from
claiming the pane, and manually drives status transitions via `set_status()` → `report_agent()`.

Since herdr natively detects the tool, all of this is unnecessary. The embedded path should
let herdr handle detection, lifecycle, and status — just like native mode does — and
subscribe to herdr's status watch on Neovim's own pane for status events.

## What Changes

- **Remove the manual registration machinery**: Drop `register()`, `report_agent()`,
  `report_metadata()`, `refresh_label()`, `reap()`, `probe()`, `M._embedded`, and the
  `SOURCE`, `TOKEN`, `LABEL_TTL`, `LABEL_REFRESH` constants.
- **Stop clearing `HERDR_PANE_ID`**: Let the tool see its herdr context so herdr detects it
  natively.
- **Subscribe to status watch on Neovim's pane**: Embedded sessions get the same
  `pane.agent_status_changed` subscription that native sessions get, so status comes from
  herdr instead of being manually driven.
- **Simplify `set_status()`**: Remove the embedded-specific `report_agent()` call — herdr
  drives status natively.
- **Simplify `detach()`**: Just unwatch; no `release-agent` or metadata clearing needed.
- **Update `sessions()` discovery**: Stop skipping agents on Neovim's own pane — herdr
  sees the tool there now, so it should be discoverable.
- **Simplify `is_running()` for embedded**: Use the same pane-based check as native, or
  rely on herdr's agent list.
- **Remove the health check probe**: `probe()` tested whether herdr accepts sidekick's
  custom source; that source is no longer used.
- **Surface session status**: Add `status` field to `sidekick.cli.Status` so statusline
  components can render agent activity.

## Capabilities

### New Capabilities
- `cli-session-status`: Specifies the `require("sidekick.status").cli()` API — what fields
  it returns (including agent activity status), how it refreshes, and how backends feed
  status changes into it.

### Modified Capabilities
- `herdr-mux-backend`: The embedded session requirements change substantially — manual
  registration is replaced by herdr's native detection, status is driven by herdr's watch
  instead of sidekick's `report-agent`, and the `sessions()` discovery no longer skips
  Neovim's own pane.

## Impact

- `lua/sidekick/cli/session/herdr.lua`: Major simplification — remove ~100 lines of manual
  registration code, update `start_embedded()`, `set_status()`, `detach()`, `is_running()`,
  `sessions()`.
- `lua/sidekick/status.lua`: Add `status` field to `sidekick.cli.Status`, listen for status
  change events.
- `lua/sidekick/cli/session/init.lua`: Emit `SidekickCliStatus` from `B:set_status()`.
- `lua/sidekick/health.lua`: Remove the `probe()` health check.
- `lua/sidekick/config.lua`: Update the comment about embedded mode limitations.
