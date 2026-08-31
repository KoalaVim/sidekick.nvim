## Context

The herdr backend has two session modes:

1. **Native** (split/window): Creates a herdr pane, runs the tool in it. Herdr natively
   detects the tool, drives its lifecycle and status. Sidekick subscribes to
   `pane.agent_status_changed` via herdr's socket and drives the session over the pane API.
2. **Embedded** (terminal): Runs the tool in a Neovim terminal. Currently built on the
   wrong assumption that herdr cannot detect it, so it manually registers with herdr via
   `report-agent`, drives status itself, and carries ~100 lines of registration machinery.

Since herdr CAN detect the tool running inside a Neovim terminal, embedded mode should
work like native mode: let herdr handle detection and status, subscribe to the watch.

## Goals / Non-Goals

**Goals:**
- Let herdr natively detect embedded tools — remove manual registration.
- Get status from herdr's watch for embedded sessions, same as native.
- Surface agent status through `require("sidekick.status").cli()`.
- Keep the Neovim terminal as the user-facing surface for embedded sessions.

**Non-Goals:**
- Changing native mode — it already works correctly.
- Changing the terminal backend or the session base class contract.
- Building statusline components — consumers exist, they just lack the `status` field.

## Decisions

### Let the tool see `HERDR_PANE_ID`

**Decision:** Stop clearing `HERDR_PANE_ID` in the embedded `env`. The tool's herdr
integration hook will run and herdr will detect the tool on Neovim's pane.

**Previous approach:** Cleared `HERDR_PANE_ID` to prevent the tool from "claiming" the
pane, which would lock out sidekick's `report-agent`. Since sidekick no longer calls
`report-agent`, there is nothing to lock out.

### Subscribe to watch on Neovim's pane

**Decision:** In `start_embedded()`, call `M.watch(vim.env.HERDR_PANE_ID)` to get status
events from herdr for the tool running inside the Neovim terminal. This is the same
mechanism native sessions use.

**Why this works:** Herdr detects the tool on Neovim's pane and pushes
`pane.agent_status_changed` events for it. The watch callback updates `M._status` and the
session picks it up via `init()`.

### Remove all manual registration code

**Decision:** Delete `register()`, `report_agent()`, `report_metadata()`,
`refresh_label()`, `reap()`, `probe()`, `M._embedded`, and the `SOURCE`, `TOKEN`,
`LABEL_TTL`, `LABEL_REFRESH` constants. These existed solely because sidekick was
pretending to be herdr's agent authority for the embedded tool.

### Update `sessions()` to discover agents on Neovim's pane

**Decision:** Stop filtering out agents whose `pane_id` matches `HERDR_PANE_ID`. Herdr
now natively reports the tool there, so it should be discoverable like any other agent.
The dedup logic (terminal priority 100 > herdr priority 10/50) prevents a double entry
when the session is already attached via a Neovim terminal.

### Simplify `set_status()` and `detach()`

`set_status()` no longer needs to call `report_agent()` for embedded sessions — herdr
drives status itself. It reduces to the base class behavior.

`detach()` no longer needs to `release-agent` or clear metadata — herdr manages the
agent lifecycle. It just calls `M.unwatch()`.

### Surface status through the status module

Same as before: add `status` to `sidekick.cli.Status`, emit `SidekickCliStatus` from
`B:set_status()`, listen for it in the status module.

## Risks / Trade-offs

- **Tool claims the pane:** With `HERDR_PANE_ID` no longer cleared, the tool's herdr
  integration hook may claim the pane. This is the correct behavior — herdr should know
  the tool is there. If the claim prevents Neovim from also being visible in herdr's
  sidebar, that's acceptable: the pane IS running the tool from herdr's perspective.
- **One agent per pane:** If herdr only reports one agent per pane, a second embedded
  session won't be visible in herdr. The existing warning about single-agent panes already
  covers this — it's a herdr constraint, not a sidekick one.
- **`HERDR_PANE_ID` side effects:** The tool seeing `HERDR_PANE_ID` might trigger other
  herdr integration behavior (e.g., session resume). This is desirable — the tool gets
  the full herdr experience.
