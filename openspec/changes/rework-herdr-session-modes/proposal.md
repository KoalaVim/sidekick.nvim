## Why

`mux.create = "terminal"` under herdr is broken in three ways at once, and they share one root cause. The backend splits a herdr pane, moves it to its own tab, runs the tool in it, and then returns `herdr agent attach <pane_id>` for a Neovim terminal to host. That straddle — the agent living in a herdr pane *and* being mirrored into Neovim — produces every symptom:

- **`agent_not_found` on every start.** `agent attach` resolves against herdr's live agent registry, not the pane tree. Herdr needs ~250–500ms to detect an agent after `pane run` (measured), and the attach command is spawned at t+0ms, so the Neovim terminal dies with `[Process exited 1]`. `herdr agent wait` cannot fix this: it waits for state transitions of an *already known* agent and returns `agent_not_found` in 0.01s.
- **Not hidden.** herdr has no detached or hidden pane. Every pane lives in `workspace → tab → pane` and the UI renders all of it, so `pane move --new-tab` is a visible tab by construction. No CLI flag, config key, or plugin placement changes this.
- **Cropped view.** `agent attach` resizes the source pane to the attaching client's PTY and leaves it that way (measured: 49 → 24 rows, persisting after detach). The herdr tab then renders a 24-row pane in a 50-row tab. The crop *is* the tab existing.

Separately, `sessions()` sets `mux_session` to the tool name, which can never equal `sid` (`"<tool> <sha>"`). Every rediscovered herdr agent is therefore permanently `external` and `attach()` always returns `nil`, so the spec's own "Reattach after Neovim restart" scenario cannot pass.

The previous change's design ruled out the embedded alternative on two grounds that direct probing disproves: pane metadata tokens *are* settable and do round-trip, and a pane hosting Neovim *can* be registered as an agent.

## What Changes

- **BREAKING** (behavior, not config): `mux.create = "terminal"` no longer creates a herdr pane. The tool runs in a Neovim terminal, and sidekick registers that session on Neovim's own pane via `herdr pane report-agent`. No extra pane, no extra tab, no crop, and no attach race.
- Sidekick unsets `HERDR_PANE_ID` for the embedded tool so the agent's own integration hook cannot claim Neovim's pane. Every hook begins `[ -n "${HERDR_PANE_ID:-}" ] || exit 0`; a claim is unrecoverable once made, so preventing it is the only route.
- Sidekick owns the agent lifecycle for embedded sessions, reporting `idle` / `working` / `blocked` from a non-`herdr:*` source. herdr does not drive status for a reported agent (verified: status stayed `idle` for 12s while the agent worked).
- `split` and `window` stay herdr-native: a real pane, herdr's own detection, sidekick as controller. `pane move` gains `--no-focus` instead of compensating with `tab focus $HERDR_TAB_ID`.
- Fix `sessions()` to derive `mux_session` from tool and cwd so a rediscovered agent can be attached instead of being forced external, and stamp sidekick-owned panes with `pane report-metadata --token`.
- Subscribe to herdr's `pane.agent_status_changed` event so native-mode sessions carry real agent status, replacing polling.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `herdr-mux-backend`: what `mux.create = "terminal"` means, who owns agent lifecycle for an embedded session, session rediscovery identity, and status as a pushed signal rather than a polled one.

## Impact

- `lua/sidekick/cli/session/herdr.lua` — embedded mode, native mode, discovery identity, lifecycle reporting.
- `lua/sidekick/cli/session/init.lua` — status plumbing if the event subscription lands here rather than in the backend.
- Users on `create = "terminal"` lose herdr's native detection for that session (herdr cannot see a process behind Neovim's PTY) and lose agent-session resume, which is what the disabled hook provided. They gain a session that actually starts, is genuinely hidden, and is not cropped. `split` and `window` keep full native detection.
- Only one embedded session per Neovim instance can be registered, because Neovim has exactly one herdr pane.
- Requires a herdr build with `pane report-agent`, `pane report-metadata`, and `events.subscribe` (verified against herdr 0.8.2, socket schema version 1, protocol 20).
